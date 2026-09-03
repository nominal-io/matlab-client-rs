//! Stream channels: where points get written.
//!
//! A channel in Nominal is a named series of values within a dataset — roughly
//! a column. Channels are not created as objects; one comes into existence when
//! data bearing its name arrives.
//!
//! A stream channel is the *address* those points are written to: a stream, the
//! name to record under, and the tags to stamp on each point. Creating one
//! performs no API call.
//!
//! # Why this is not merged with channel metadata
//!
//! `nominal_streamchannel_*` is this write side. The catalog's channel
//! metadata — units, description, data type — will be
//! `nominal_channelmetadata_*` when it is built. There is deliberately no
//! single unified channel handle, despite both describing the same series in
//! Nominal's data model, because the two are keyed differently:
//!
//! - Metadata identity is `(data_source_rid, name)` with **no tags**. Tags are
//!   central here and would be dead weight there.
//! - Setting metadata requires declaring the channel's data type — upstream
//!   `ChannelUpdate::new` takes it as a required argument, with no way to leave
//!   it alone. A write address has no reason to know it.
//!
//! So this is a considered split, not an oversight awaiting cleanup.
//!
//! # Tags belong to points
//!
//! Tags are attached to individual points rather than to the channel, and exist
//! to filter and group within it. Their main use is multiplexed channels — one
//! channel carrying several values at the same instant, told apart by tags,
//! such as a temperature channel with `engine=left` and `engine=right`. Two
//! addresses sharing a name but differing in tags write to the *same* channel,
//! tagging their points differently. Nothing is misrouted.
//!
//! # Timestamps here are literal
//!
//! Unlike run and event times, `0` is a real instant for data points, not
//! "now". A stream may legitimately carry timestamps relative to an epoch the
//! caller chose, so the value passes through untouched.

use crate::error::{fail, ffi_guard, guard_value, require_out, ErrorCode, ErrorHandle};
use crate::stream::{proto_timestamp, stream_or_fail, StreamHandle};
use crate::strings::{c_str_to_string, c_str_to_string_exact, set_string, StringHandle};
use nominal_streaming::prelude::{DoublePoint, StringPoint};
use nominal_streaming::types::ChannelDescriptor;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{BTreeMap, HashMap};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicI32, Ordering};

pub type StreamChannelHandle = i32;

/// A write address: which stream, and how points are labelled within it.
#[derive(Clone)]
pub(crate) struct StreamChannel {
    /// Held as a handle rather than an `Arc` so the stream's lifetime stays
    /// authoritative — writing through a channel whose stream has been freed
    /// fails, instead of quietly feeding a stream nothing else can reach.
    pub(crate) stream: StreamHandle,
    pub(crate) descriptor: ChannelDescriptor,
}

// Not the `handle_registry` macro: tags stay mutable after creation, so entries
// are stored bare rather than behind an `Arc`.
static NEXT_HANDLE: AtomicI32 = AtomicI32::new(1);
static CHANNELS: Lazy<Mutex<HashMap<StreamChannelHandle, StreamChannel>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop every stream channel. Used by shutdown.
pub(crate) fn clear_streamchannels() {
    CHANNELS.lock().clear();
}

/// Copy out a channel's stream and descriptor.
///
/// Returns a clone rather than a guard, so the registry lock is not held across
/// the enqueue that follows — that call can block on backpressure.
pub(crate) fn streamchannel_or_fail(
    handle: StreamChannelHandle,
    error_out: *mut ErrorHandle,
) -> Result<StreamChannel, ErrorCode> {
    CHANNELS.lock().get(&handle).cloned().ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown stream channel handle {handle}"),
        )
    })
}

/// Create a write address for `name` on `stream`, with no tags.
///
/// Performs no API call — nothing exists in Nominal until points are written.
/// Release with `nominal_streamchannel_free`.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_create(
    stream_handle: StreamHandle,
    name: *const c_char,
    out_channel: *mut StreamChannelHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_channel, error_out, "out_channel")?;
        // Resolve now so a bad stream handle is caught here rather than at the
        // first push, thousands of samples later.
        stream_or_fail(stream_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let Ok(handle) =
            NEXT_HANDLE.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
        else {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "stream channel handle space exhausted",
            ));
        };

        CHANNELS.lock().insert(
            handle,
            StreamChannel {
                stream: stream_handle,
                descriptor: ChannelDescriptor { name, tags: None },
            },
        );
        unsafe { *out_channel = handle };
        Ok(())
    })
}

/// Add a tag that will be stamped on every point written through this address.
///
/// Tags belong to points, not to the channel, so changing them partway through
/// acquisition is legal: earlier points keep the tags they were sent with and
/// later ones carry the new set. All of them land in the same channel. That is
/// exactly how a multiplexed channel is written — one address per tag set, all
/// sharing a name.
///
/// Keep the number of distinct tag values small. Tags are for grouping, so
/// anything that changes every point — a measurement, a timestamp, a UUID —
/// belongs in its own channel instead and will degrade queries if used here.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_set_tag(
    handle: StreamChannelHandle,
    key: *const c_char,
    value: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let key = unsafe { c_str_to_string(key, "key", error_out)? };
        let value = unsafe { c_str_to_string(value, "value", error_out)? };

        let mut channels = CHANNELS.lock();
        let channel = channels.get_mut(&handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown stream channel handle {handle}"),
            )
        })?;

        channel
            .descriptor
            .tags
            .get_or_insert_with(BTreeMap::new)
            .insert(key, value);
        Ok(())
    })
}

/// Channel name this address writes under.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_name(
    handle: StreamChannelHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = streamchannel_or_fail(handle, error_out)?;
        set_string(out_string, channel.descriptor.name, error_out)
    })
}

/// Stream this address writes to.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_stream(
    handle: StreamChannelHandle,
    out_stream: *mut StreamHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_stream, error_out, "out_stream")?;
        let channel = streamchannel_or_fail(handle, error_out)?;
        unsafe { *out_stream = channel.stream };
        Ok(())
    })
}

/// Push a batch of floating-point samples.
///
/// `timestamps_nanos` and `values` are parallel arrays of `count` elements.
/// Timestamps are nanoseconds since the Unix epoch, taken literally, zero
/// included.
///
/// Blocks if the stream's buffers are full — see [`crate::stream`].
#[no_mangle]
pub extern "C" fn nominal_streamchannel_push_doubles(
    handle: StreamChannelHandle,
    timestamps_nanos: *const i64,
    values: *const f64,
    count: u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = streamchannel_or_fail(handle, error_out)?;
        let stream = stream_or_fail(channel.stream, error_out)?;

        let (timestamps, values) = match slices(timestamps_nanos, values, count, error_out)? {
            Some(pair) => pair,
            None => return Ok(()),
        };

        let points: Vec<DoublePoint> = timestamps
            .iter()
            .zip(values)
            .map(|(&ts, &value)| DoublePoint {
                timestamp: Some(proto_timestamp(ts)),
                value,
            })
            .collect();

        stream.enqueue(&channel.descriptor, points);
        Ok(())
    })
}

/// Push a batch of string samples.
///
/// `timestamps_nanos` holds `count` elements; `values` holds `count`
/// NUL-terminated C strings.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_push_strings(
    handle: StreamChannelHandle,
    timestamps_nanos: *const i64,
    values: *const *const c_char,
    count: u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = streamchannel_or_fail(handle, error_out)?;
        let stream = stream_or_fail(channel.stream, error_out)?;

        let (timestamps, raw_values) = match slices(timestamps_nanos, values, count, error_out)? {
            Some(pair) => pair,
            None => return Ok(()),
        };

        let mut points = Vec::with_capacity(count as usize);
        for (index, (&ts, &raw)) in timestamps.iter().zip(raw_values).enumerate() {
            // Verbatim: these are samples the caller is recording, so trimming
            // them would quietly alter their data.
            let value =
                unsafe { c_str_to_string_exact(raw, &format!("values[{index}]"), error_out)? };
            points.push(StringPoint {
                timestamp: Some(proto_timestamp(ts)),
                value,
            });
        }

        stream.enqueue(&channel.descriptor, points);
        Ok(())
    })
}

/// Release a write address. Freeing an unknown handle is a no-op.
///
/// Does not affect points already sent, nor the channel in Nominal.
#[no_mangle]
pub extern "C" fn nominal_streamchannel_free(handle: StreamChannelHandle) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        CHANNELS.lock().remove(&handle);
        ErrorCode::Success as i32
    })
}

/// A validated pair of parallel arrays: timestamps and their values.
type Samples<'a, V> = (&'a [i64], &'a [V]);

/// Validate two parallel C arrays and view them as slices.
///
/// `Ok(None)` means `count` was zero, which is a no-op rather than an error —
/// an acquisition loop with nothing to send this tick should not have to guard
/// the call.
fn slices<'a, V>(
    timestamps_nanos: *const i64,
    values: *const V,
    count: u32,
    error_out: *mut ErrorHandle,
) -> Result<Option<Samples<'a, V>>, ErrorCode> {
    if count == 0 {
        return Ok(None);
    }
    if timestamps_nanos.is_null() || values.is_null() {
        return Err(fail(
            error_out,
            ErrorCode::InvalidParameter,
            "timestamps and values must not be null when count > 0",
        ));
    }
    Ok(Some(unsafe {
        (
            std::slice::from_raw_parts(timestamps_nanos, count as usize),
            std::slice::from_raw_parts(values, count as usize),
        )
    }))
}

#[cfg(test)]
mod tests {
    //! The push path, which is what MATLAB's `Stream.push` reaches through
    //! `channel_push_matrix`.
    //!
    //! Unit tests rather than integration ones because they need a stream, and
    //! the only stream reachable without a network is the file-backed one.

    use super::*;
    use crate::stream::{alloc_file_stream, nominal_stream_free};
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

    fn push(handle: StreamChannelHandle, times: &[i64], values: &[f64]) -> (i32, ErrorHandle) {
        let mut err = 0;
        let status = nominal_streamchannel_push_doubles(
            handle,
            times.as_ptr(),
            values.as_ptr(),
            times.len() as u32,
            &mut err,
        );
        (status, err)
    }

    #[test]
    fn pushes_a_batch_of_doubles() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "rpm");

        let (status, _) = push(ch, &[0, 1_000_000, 2_000_000], &[1600.0, 1610.0, 1620.0]);
        assert_eq!(status, 0);

        nominal_streamchannel_free(ch);
        nominal_stream_free(stream);
    }

    #[test]
    fn an_empty_push_is_a_no_op_rather_than_an_error() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "rpm");

        // An acquisition loop with nothing to send this tick should not have to
        // guard the call.
        let mut err = 0;
        assert_eq!(
            nominal_streamchannel_push_doubles(ch, std::ptr::null(), std::ptr::null(), 0, &mut err),
            0
        );

        nominal_streamchannel_free(ch);
        nominal_stream_free(stream);
    }

    #[test]
    fn null_arrays_are_refused_when_there_are_points_to_send() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "rpm");

        let mut err = 0;
        assert_eq!(
            nominal_streamchannel_push_doubles(ch, std::ptr::null(), std::ptr::null(), 3, &mut err),
            ErrorCode::InvalidParameter as i32
        );
        crate::error::nominal_error_free(err);

        nominal_streamchannel_free(ch);
        nominal_stream_free(stream);
    }

    #[test]
    fn pushing_through_a_freed_stream_fails_rather_than_writing_nowhere() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "rpm");

        // The channel handle stays live, but its stream is gone. MATLAB's
        // teardown order relies on this failing loudly rather than silently
        // feeding a stream nothing else can reach.
        nominal_stream_free(stream);

        let (status, err) = push(ch, &[0], &[1.0]);
        assert_eq!(status, ErrorCode::InvalidHandle as i32);
        crate::error::nominal_error_free(err);

        nominal_streamchannel_free(ch);
    }

    #[test]
    fn an_unknown_channel_handle_fails_cleanly() {
        let (status, err) = push(999_999, &[0], &[1.0]);
        assert_eq!(status, ErrorCode::InvalidHandle as i32);
        crate::error::nominal_error_free(err);
    }

    #[test]
    fn a_channel_created_against_a_missing_stream_is_caught_at_create() {
        // Not at the first push, thousands of samples later.
        let name = CString::new("rpm").unwrap();
        let mut handle = 0;
        let mut err = 0;
        assert_eq!(
            nominal_streamchannel_create(999_999, name.as_ptr(), &mut handle, &mut err),
            ErrorCode::InvalidHandle as i32
        );
        crate::error::nominal_error_free(err);
    }

    #[test]
    fn tags_are_read_at_push_time_so_a_multiplexed_channel_can_retag() {
        let stream = alloc_file_stream();
        let ch = channel(stream, "temperature");
        let key = CString::new("engine").unwrap();
        let left = CString::new("left").unwrap();
        let right = CString::new("right").unwrap();
        let mut err = 0;

        assert_eq!(
            nominal_streamchannel_set_tag(ch, key.as_ptr(), left.as_ptr(), &mut err),
            0
        );
        assert_eq!(push(ch, &[0], &[20.0]).0, 0);

        // Retagging partway through is legal: earlier points keep the tags they
        // were sent with, and both sets land in the same channel.
        assert_eq!(
            nominal_streamchannel_set_tag(ch, key.as_ptr(), right.as_ptr(), &mut err),
            0
        );
        assert_eq!(push(ch, &[1], &[21.0]).0, 0);

        let channel = streamchannel_or_fail(ch, &mut err).unwrap();
        assert_eq!(
            channel.descriptor.tags.as_ref().unwrap().get("engine"),
            Some(&"right".to_string())
        );

        nominal_streamchannel_free(ch);
        nominal_stream_free(stream);
    }
}
