//! Sample buffers for synchronised multi-channel acquisition.
//!
//! [`nominal_stream_push_doubles`](crate::stream::nominal_stream_push_doubles)
//! is the general path: any channel, any timestamps, arrays you assemble
//! yourself. This module is the specialised one, for the common case of a DAQ
//! producing one sample per channel per tick against a shared clock.
//!
//! ```c
//! int32_t chans[3] = { rpm, egt, psi };
//! int32_t buf;
//! nominal_buffer_alloc(chans, 3, 1000, &buf, &err);
//!
//! bool full;
//! while (acquiring) {
//!     double row[3] = { read_rpm(), read_egt(), read_psi() };
//!     nominal_buffer_store(buf, timestamp_ns, row, 3, &full, &err);
//!     if (full) nominal_buffer_commit(stream, buf, &err);
//! }
//! nominal_buffer_commit(stream, buf, &err);   /* the partial tail */
//! nominal_buffer_free(buf);
//! ```
//!
//! The caller writes one row per tick and is told when the buffer is full; the
//! commit turns the columns into per-channel batches and hands them to the
//! stream. Rows are stored column-major so each channel's samples are already
//! contiguous at commit time, with no transpose.
//!
//! # Why commit blocks
//!
//! An earlier sketch had commit return immediately with a fresh buffer, keeping
//! a pool of in-flight ones. The upstream library does not support that: its
//! own enqueue blocks once both internal buffers are full, so an async commit
//! would only move the wait rather than remove it, while adding a pool whose
//! depth is another thing to get wrong. Commit therefore blocks exactly as long
//! as the underlying push does. If a caller cannot afford to stall its
//! acquisition loop, the right answer is a producer thread and a queue on the
//! caller's side, where the buffering policy is visible.

use crate::error::{fail, ffi_guard, guard_value, require_out, ErrorCode, ErrorHandle};
use crate::stream::{proto_timestamp, stream_or_fail, StreamHandle};
use crate::streamchannel::{streamchannel_or_fail, StreamChannelHandle};
use nominal_streaming::prelude::DoublePoint;
use nominal_streaming::types::ChannelDescriptor;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, Ordering};

pub type BufferHandle = i32;

/// One channel's samples, ready to hand to the stream.
type ChannelBatch = (ChannelDescriptor, Vec<DoublePoint>);

struct SampleBuffer {
    /// Taken from the channels at allocation, which must all belong to one
    /// stream. Kept so commit needs no stream argument.
    stream: StreamHandle,
    /// Resolved once at allocation: a channel freed mid-acquisition must not
    /// invalidate a buffer already recording against it.
    channels: Vec<ChannelDescriptor>,
    /// One timestamp per row.
    timestamps: Vec<i64>,
    /// Column-major: `columns[c][r]` is channel `c` at row `r`. Laid out this
    /// way so commit can take each channel's samples as a contiguous run.
    columns: Vec<Vec<f64>>,
    capacity: usize,
}

impl SampleBuffer {
    fn rows(&self) -> usize {
        self.timestamps.len()
    }

    fn clear(&mut self) {
        self.timestamps.clear();
        for column in &mut self.columns {
            column.clear();
        }
    }
}

static NEXT_BUFFER_HANDLE: AtomicI32 = AtomicI32::new(1);
static BUFFERS: Lazy<Mutex<HashMap<BufferHandle, SampleBuffer>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop every buffer, discarding anything uncommitted. Used by shutdown.
pub(crate) fn clear_buffers() {
    BUFFERS.lock().clear();
}

/// Allocate a buffer holding up to `capacity` rows across `channel_count`
/// channels.
///
/// `channels` is an array of `channel_count` stream channel handles, which must
/// all belong to the same stream — a buffer commits as one batch, so a mixture
/// would have nowhere single to go. Their descriptors are copied now, so the
/// buffer keeps working if a channel handle is later freed.
///
/// Every row must supply one value per channel, in this order.
///
/// Memory is reserved up front — `capacity * channel_count` doubles plus the
/// timestamps — so no allocation happens on the acquisition path.
#[no_mangle]
pub extern "C" fn nominal_buffer_alloc(
    channels: *const StreamChannelHandle,
    channel_count: u32,
    capacity: u32,
    out_buffer: *mut BufferHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_buffer, error_out, "out_buffer")?;

        if channels.is_null() || channel_count == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "at least one channel is required",
            ));
        }
        if capacity == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "capacity must be greater than zero",
            ));
        }

        let handles = unsafe { std::slice::from_raw_parts(channels, channel_count as usize) };
        let resolved = handles
            .iter()
            .map(|&h| streamchannel_or_fail(h, error_out))
            .collect::<Result<Vec<_>, _>>()?;

        let stream = resolved[0].stream;
        if let Some(other) = resolved.iter().find(|c| c.stream != stream) {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "all channels must belong to one stream; got {} and {}",
                    stream, other.stream
                ),
            ));
        }

        let descriptors: Vec<ChannelDescriptor> =
            resolved.into_iter().map(|c| c.descriptor).collect();

        let capacity = capacity as usize;
        let buffer = SampleBuffer {
            stream,
            timestamps: Vec::with_capacity(capacity),
            columns: (0..descriptors.len())
                .map(|_| Vec::with_capacity(capacity))
                .collect(),
            channels: descriptors,
            capacity,
        };

        let Ok(handle) =
            NEXT_BUFFER_HANDLE.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
        else {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "buffer handle space exhausted",
            ));
        };

        BUFFERS.lock().insert(handle, buffer);
        unsafe { *out_buffer = handle };
        Ok(())
    })
}

/// Append one row: a timestamp and one value per channel.
///
/// `values` must hold exactly `value_count` elements, matching the channel
/// count the buffer was allocated with — a mismatch is an error rather than a
/// silent partial row, since a wrong-length row would misalign every channel.
///
/// `out_is_full` receives true when the buffer has no room for another row.
/// Commit then, or keep storing and lose rows — a store into a full buffer
/// fails rather than overwriting.
///
/// Timestamps are literal, including zero.
#[no_mangle]
pub extern "C" fn nominal_buffer_store(
    handle: BufferHandle,
    timestamp_nanos: i64,
    values: *const f64,
    value_count: u32,
    out_is_full: *mut bool,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_is_full, error_out, "out_is_full")?;
        if values.is_null() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "values must not be null",
            ));
        }

        let mut buffers = BUFFERS.lock();
        let buffer = buffers.get_mut(&handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown buffer handle {handle}"),
            )
        })?;

        if value_count as usize != buffer.columns.len() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "expected {} values, one per channel, got {value_count}",
                    buffer.columns.len()
                ),
            ));
        }
        if buffer.rows() >= buffer.capacity {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                format!(
                    "buffer is full at {} rows; commit before storing more",
                    buffer.capacity
                ),
            ));
        }

        let row = unsafe { std::slice::from_raw_parts(values, value_count as usize) };
        buffer.timestamps.push(timestamp_nanos);
        for (column, &value) in buffer.columns.iter_mut().zip(row) {
            column.push(value);
        }

        unsafe { *out_is_full = buffer.rows() >= buffer.capacity };
        Ok(())
    })
}

/// Send everything the buffer holds to its stream, then empty it for reuse.
///
/// The stream comes from the channels the buffer was allocated with, so there
/// is nothing to pass and nothing to get wrong.
///
/// Committing an empty buffer succeeds and does nothing, so this can be called
/// unconditionally at the end of acquisition to flush a partial tail.
///
/// **Blocks** while the stream is saturated — see the module docs. The buffer
/// is emptied only once the data has been handed over, so a failed commit
/// leaves the rows intact to retry.
#[no_mangle]
pub extern "C" fn nominal_buffer_commit(
    buffer_handle: BufferHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        // Resolve the stream before touching the rows, so that a stream which
        // has been freed fails with the buffer still full and retryable.
        let stream_handle = {
            let buffers = BUFFERS.lock();
            buffers
                .get(&buffer_handle)
                .map(|b| b.stream)
                .ok_or_else(|| {
                    fail(
                        error_out,
                        ErrorCode::InvalidHandle,
                        format!("unknown buffer handle {buffer_handle}"),
                    )
                })?
        };
        let stream = stream_or_fail(stream_handle, error_out)?;

        // Take the rows out under the lock, then release it before enqueuing:
        // enqueue can block for as long as the network takes to drain, and
        // holding the registry lock through that would stall every other
        // buffer operation in the process.
        let batches = {
            let mut buffers = BUFFERS.lock();
            let buffer = buffers.get_mut(&buffer_handle).ok_or_else(|| {
                fail(
                    error_out,
                    ErrorCode::InvalidHandle,
                    format!("unknown buffer handle {buffer_handle}"),
                )
            })?;

            if buffer.rows() == 0 {
                return Ok(());
            }

            let batches: Vec<ChannelBatch> = buffer
                .channels
                .iter()
                .zip(&buffer.columns)
                .map(|(channel, column)| {
                    let points = buffer
                        .timestamps
                        .iter()
                        .zip(column)
                        .map(|(&ts, &value)| DoublePoint {
                            timestamp: Some(proto_timestamp(ts)),
                            value,
                        })
                        .collect();
                    (channel.clone(), points)
                })
                .collect();

            buffer.clear();
            batches
        };

        for (channel, points) in batches {
            stream.enqueue(&channel, points);
        }
        Ok(())
    })
}

/// Rows currently held, and the capacity they are held against.
#[no_mangle]
pub extern "C" fn nominal_buffer_status(
    handle: BufferHandle,
    out_rows: *mut u32,
    out_capacity: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_rows, error_out, "out_rows")?;
        require_out(out_capacity, error_out, "out_capacity")?;

        let buffers = BUFFERS.lock();
        let buffer = buffers.get(&handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown buffer handle {handle}"),
            )
        })?;

        unsafe {
            *out_rows = buffer.rows() as u32;
            *out_capacity = buffer.capacity as u32;
        }
        Ok(())
    })
}

/// Release a buffer, discarding any uncommitted rows.
///
/// Commit first if the tail matters. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_buffer_free(handle: BufferHandle) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        BUFFERS.lock().remove(&handle);
        ErrorCode::Success as i32
    })
}

#[cfg(test)]
mod tests {
    //! Row and column bookkeeping — where a misaligned channel would come from.
    //!
    //! Unit tests rather than integration ones because they need a stream, and
    //! the only stream reachable without a network is the file-backed one.

    use super::*;
    use crate::stream::alloc_file_stream;
    use crate::streamchannel::{
        nominal_streamchannel_create, nominal_streamchannel_free, nominal_streamchannel_set_tag,
    };
    use std::ffi::CString;

    fn channel(stream: StreamHandle, name: &str) -> StreamChannelHandle {
        let name = CString::new(name).unwrap();
        let mut handle = 0;
        let mut err = 0;
        assert_eq!(
            nominal_streamchannel_create(stream, name.as_ptr(), &mut handle, &mut err),
            0
        );
        handle
    }

    fn buffer(channels: &[StreamChannelHandle], capacity: u32) -> BufferHandle {
        let mut handle = 0;
        let mut err = 0;
        assert_eq!(
            nominal_buffer_alloc(
                channels.as_ptr(),
                channels.len() as u32,
                capacity,
                &mut handle,
                &mut err
            ),
            0,
            "allocation failed"
        );
        handle
    }

    fn store(handle: BufferHandle, ts: i64, row: &[f64]) -> (i32, bool, ErrorHandle) {
        let mut full = false;
        let mut err = 0;
        let status = nominal_buffer_store(
            handle,
            ts,
            row.as_ptr(),
            row.len() as u32,
            &mut full,
            &mut err,
        );
        (status, full, err)
    }

    fn rows(handle: BufferHandle) -> (u32, u32) {
        let (mut r, mut c) = (0, 0);
        let mut err = 0;
        assert_eq!(nominal_buffer_status(handle, &mut r, &mut c, &mut err), 0);
        (r, c)
    }

    #[test]
    fn fills_to_capacity_and_reports_the_boundary_exactly_once() {
        let stream = alloc_file_stream();
        let channels = [channel(stream, "a"), channel(stream, "b")];
        let buf = buffer(&channels, 3);

        for (i, expect_full) in [false, false, true].into_iter().enumerate() {
            let (status, full, _) = store(buf, i as i64, &[i as f64, i as f64 * 2.0]);
            assert_eq!(status, 0, "row {i} rejected");
            assert_eq!(full, expect_full, "row {i} reported the wrong fullness");
        }

        assert_eq!(rows(buf), (3, 3));
        nominal_buffer_free(buf);
    }

    #[test]
    fn storing_into_a_full_buffer_fails_rather_than_overwriting() {
        let stream = alloc_file_stream();
        let buf = buffer(&[channel(stream, "a")], 1);

        assert_eq!(store(buf, 0, &[1.0]).0, 0);
        let (status, _, err) = store(buf, 1, &[2.0]);

        assert_eq!(
            status,
            ErrorCode::NoCapacity as i32,
            "a full buffer must reject rather than drop or overwrite"
        );
        assert_eq!(rows(buf).0, 1, "the rejected row must not be recorded");

        crate::error::nominal_error_free(err);
        nominal_buffer_free(buf);
    }

    #[test]
    fn a_wrong_length_row_is_rejected_whole() {
        let stream = alloc_file_stream();
        let channels = [
            channel(stream, "a"),
            channel(stream, "b"),
            channel(stream, "c"),
        ];
        let buf = buffer(&channels, 10);

        // Too few: accepting this would misalign every later channel.
        let (status, _, err) = store(buf, 0, &[1.0, 2.0]);
        assert_eq!(status, ErrorCode::InvalidParameter as i32);
        crate::error::nominal_error_free(err);

        let (status, _, err) = store(buf, 0, &[1.0, 2.0, 3.0, 4.0]);
        assert_eq!(status, ErrorCode::InvalidParameter as i32);
        crate::error::nominal_error_free(err);

        assert_eq!(rows(buf).0, 0, "no partial row may be recorded");
        nominal_buffer_free(buf);
    }

    #[test]
    fn channels_from_different_streams_cannot_share_a_buffer() {
        let a = alloc_file_stream();
        let b = alloc_file_stream();
        let channels = [channel(a, "x"), channel(b, "y")];

        let mut handle = 0;
        let mut err = 0;
        let status = nominal_buffer_alloc(channels.as_ptr(), 2, 10, &mut handle, &mut err);

        assert_eq!(
            status,
            ErrorCode::InvalidParameter as i32,
            "a buffer commits as one batch, so mixed streams have nowhere to go"
        );
        crate::error::nominal_error_free(err);
    }

    #[test]
    fn a_buffer_outlives_the_channel_handles_it_was_built_from() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "transient");
        let buf = buffer(&[ch], 4);

        // Descriptors are copied at allocation, so releasing the channel handle
        // must not strand a buffer that is mid-acquisition.
        nominal_streamchannel_free(ch);

        assert_eq!(store(buf, 0, &[42.0]).0, 0, "freeing a channel broke it");
        nominal_buffer_free(buf);
    }

    #[test]
    fn a_buffer_captures_the_tags_present_when_it_was_allocated() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "rpm");
        let key = CString::new("bank").unwrap();
        let value = CString::new("1").unwrap();
        let mut err = 0;
        assert_eq!(
            nominal_streamchannel_set_tag(ch, key.as_ptr(), value.as_ptr(), &mut err),
            0
        );

        let buf = buffer(&[ch], 2);

        // Added after allocation: must not retroactively change this buffer.
        let late = CString::new("added-later").unwrap();
        assert_eq!(
            nominal_streamchannel_set_tag(ch, late.as_ptr(), value.as_ptr(), &mut err),
            0
        );

        assert_eq!(store(buf, 0, &[1.0]).0, 0);
        nominal_buffer_free(buf);
    }

    #[test]
    fn degenerate_allocations_are_refused() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "a");
        let mut handle = 0;
        let mut err = 0;

        assert_eq!(
            nominal_buffer_alloc(&ch, 1, 0, &mut handle, &mut err),
            ErrorCode::InvalidParameter as i32,
            "zero capacity"
        );
        crate::error::nominal_error_free(err);

        assert_eq!(
            nominal_buffer_alloc(std::ptr::null(), 0, 10, &mut handle, &mut err),
            ErrorCode::InvalidParameter as i32,
            "zero channels"
        );
        crate::error::nominal_error_free(err);

        let missing: StreamChannelHandle = 999_999;
        assert_eq!(
            nominal_buffer_alloc(&missing, 1, 10, &mut handle, &mut err),
            ErrorCode::InvalidHandle as i32,
            "unknown channel handle"
        );
        crate::error::nominal_error_free(err);
    }

    #[test]
    fn committing_to_a_freed_stream_leaves_the_rows_intact() {
        let stream = alloc_file_stream();
        let buf = buffer(&[channel(stream, "a")], 4);
        assert_eq!(store(buf, 0, &[1.0]).0, 0);

        crate::stream::nominal_stream_free(stream);

        let mut err = 0;
        assert_eq!(
            nominal_buffer_commit(buf, &mut err),
            ErrorCode::InvalidHandle as i32
        );
        assert_eq!(
            rows(buf).0,
            1,
            "a failed commit must leave the rows retryable"
        );

        crate::error::nominal_error_free(err);
        nominal_buffer_free(buf);
    }
}
