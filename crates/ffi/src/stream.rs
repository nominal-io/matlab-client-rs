//! Streaming data into a dataset.
//!
//! A stream batches points in memory and ships them to Nominal Core in the
//! background. Points are written through *stream channels* rather than through
//! the stream directly — see [`crate::streamchannel`].
//!
//! # Backpressure blocks
//!
//! The underlying library holds two internal buffers. When both are full,
//! pushing waits until a flush frees one, so a caller producing faster than the
//! network can drain will block rather than queue without bound. That is the
//! upstream behaviour and this layer does not paper over it: if you cannot
//! afford to block, produce on a thread that can.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use nominal_streaming::prelude::{BearerToken, ResourceIdentifier};
use nominal_streaming::stream::{NominalDatasetStream, NominalDatasetStreamBuilder};
use std::sync::Arc;

pub type StreamHandle = i32;

handle_registry!(
    STREAMS,
    NominalDatasetStream,
    alloc_stream,
    get_stream,
    free_stream_entry,
    clear_streams
);

pub(crate) fn stream_or_fail(
    handle: StreamHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<NominalDatasetStream>, ErrorCode> {
    get_stream(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown stream handle {handle}"),
        )
    })
}

/// Convert nanoseconds since the epoch into the protobuf timestamp the wire
/// uses.
///
/// Lives here rather than in `time` because the split-second representation is
/// a streaming detail, and because `0` is a literal instant on this path.
pub(crate) fn proto_timestamp(nanos: i64) -> nominal_streaming::prelude::Timestamp {
    // Euclidean division rather than truncating: for instants before the epoch,
    // `/` and `%` would give a positive seconds value with a negative nanos
    // remainder, which protobuf rejects.
    nominal_streaming::prelude::Timestamp {
        seconds: nanos.div_euclid(1_000_000_000),
        nanos: nanos.rem_euclid(1_000_000_000) as i32,
    }
}

/// Open a stream that writes into a dataset.
///
/// Data is buffered and shipped in the background; nothing is durable until it
/// reaches Core. Close the stream with `nominal_stream_free`, which flushes
/// what is still buffered.
#[no_mangle]
pub extern "C" fn nominal_stream_create(
    client_handle: ClientHandle,
    dataset_handle: i32,
    out_stream: *mut StreamHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_stream, error_out, "out_stream")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;

        let dataset_rid = ResourceIdentifier::new(dataset.rid()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid dataset RID {:?}: {e}", dataset.rid()),
            )
        })?;

        let opts = nominal_streaming::stream::NominalStreamOpts {
            base_api_url: client.base_url().to_owned(),
            ..Default::default()
        };

        // The stream spawns background workers, so it must be built inside the
        // runtime context and handed a handle to it.
        let stream = RUNTIME.in_context(|| {
            NominalDatasetStreamBuilder::new()
                .stream_to_core(token, dataset_rid, tokio::runtime::Handle::current())
                .with_options(opts)
                .build()
        });

        let handle = alloc_stream(stream);
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "stream handle space exhausted",
            ));
        }
        unsafe { *out_stream = handle };
        Ok(())
    })
}

/// A stream that writes to a file rather than to Core, for tests.
///
/// Needs no client, dataset, or network, so it exercises the real registry and
/// enqueue paths offline.
#[cfg(test)]
pub(crate) fn alloc_file_stream() -> StreamHandle {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(0);

    let path = std::env::temp_dir().join(format!(
        "nominal-ffi-test-{}.avro",
        COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let stream = RUNTIME.in_context(|| {
        NominalDatasetStreamBuilder::new()
            .stream_to_file(path)
            .build()
    });
    alloc_stream(stream)
}

/// Close a stream, flushing whatever is still buffered.
///
/// Blocks until the flush completes. Freeing an unknown handle is a no-op.
///
/// Channels created against this stream are not freed, but stop working: a push
/// through one afterwards reports `InvalidHandle` rather than writing into a
/// stream nothing else can reach.
#[no_mangle]
pub extern "C" fn nominal_stream_free(handle: StreamHandle) -> i32 {
    crate::error::guard_value(ErrorCode::RuntimeError as i32, || {
        // Dropping the stream flushes, which needs the runtime alive.
        RUNTIME.in_context(|| free_stream_entry(handle));
        ErrorCode::Success as i32
    })
}
