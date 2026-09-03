//! One-shot batch writes.
//!
//! Sends a block of samples in a single synchronous call: no stream to open, no
//! background threads, no flush to wait on. When the call returns, the data has
//! been accepted.
//!
//! Compared with [`crate::stream`], which is built for continuous acquisition —
//! it batches in memory, ships in the background, and applies backpressure — this
//! is the right shape for "I have a matrix, put it in Nominal".
//!
//! # Which writer this uses
//!
//! `NominalChannelWriterService` at `/storage/writer/v1`, the same path the
//! Rust streaming library and the Python SDK use. Writes go through Nominal's
//! durable queue and fan out to live subscribers.
//!
//! Nominal's API also documents a *direct* channel writer at
//! `/storage/direct-writer/`, which would bypass that queue for lower latency
//! and lower durability. Do not reach for it: it has no server implementation.
//! The handler was deleted in July 2026 and no ingress route forwards the path,
//! so a call 404s. Only its API definition survives, which is why it still
//! appears in the documentation.
//!
//! # Sizing
//!
//! The endpoint splits oversized requests internally, but its own guidance is
//! at most 10 batches — meaning channels — and 500,000 points per request, with
//! 50,000 the comfortable figure. For anything sustained, use a stream.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::c_str_to_string;

use nominal_streaming::api::clients::storage::writer::api::{
    AsyncNominalChannelWriterService, AsyncNominalChannelWriterServiceClient,
};
use nominal_streaming::api::objects::api::rids::NominalDataSourceOrDatasetRid;
use nominal_streaming::api::objects::api::{Channel, Timestamp};
use nominal_streaming::api::objects::storage::writer::api::{
    DoublePoint, PointsExternal, RecordsBatchExternal, WriteBatchesRequestExternal,
};
use nominal_streaming::client::conjure::http::client::{AsyncService, ConjureRuntime};
use nominal_streaming::client::conjure::object::{ResourceIdentifier, SafeLong};
use nominal_streaming::client::conjure::runtime::{Agent, Client, UserAgent};
use nominal_streaming::prelude::BearerToken;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::os::raw::c_char;
use std::sync::Arc;

/// One writer client per base URL, built once — see `event.rs` for why the
/// conjure plumbing is repeated rather than borrowed from `NominalClient`.
static SERVICES: Lazy<Mutex<HashMap<String, AsyncNominalChannelWriterServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached writer clients. Used by shutdown.
pub(crate) fn clear_write_services() {
    SERVICES.lock().clear();
}

fn service_for(
    base_url: &str,
    error_out: *mut ErrorHandle,
) -> Result<AsyncNominalChannelWriterServiceClient<Client>, ErrorCode> {
    if let Some(existing) = SERVICES.lock().get(base_url) {
        return Ok(existing.clone());
    }

    let uri = base_url.try_into().map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid base URL {base_url:?}: {e:?}"),
        )
    })?;

    // Building the client sets up hyper resources, which panic without an
    // ambient runtime.
    let client = RUNTIME.in_context(|| {
        Client::builder()
            .service("nominal-ffi-writer")
            .user_agent(UserAgent::new(Agent::new(
                "nominal-ffi",
                env!("CARGO_PKG_VERSION"),
            )))
            .uri(uri)
            .build()
    });
    let client = client.map_err(|e| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("could not build writer client: {e:?}"),
        )
    })?;

    let service =
        AsyncNominalChannelWriterServiceClient::new(client, &Arc::new(ConjureRuntime::default()));
    SERVICES.lock().insert(base_url.to_owned(), service.clone());
    Ok(service)
}

fn timestamp_from_nanos(nanos: i64, error_out: *mut ErrorHandle) -> Result<Timestamp, ErrorCode> {
    // Euclidean division so instants before the epoch do not yield a negative
    // nanosecond remainder, which the API rejects.
    let seconds = nanos.div_euclid(1_000_000_000);
    let subsec = nanos.rem_euclid(1_000_000_000);

    let convert = |value: i64, what: &str| {
        SafeLong::try_from(value).map_err(|_| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("timestamp {what} is outside the range the API can represent"),
            )
        })
    };

    Ok(Timestamp::new(
        convert(seconds, "seconds")?,
        convert(subsec, "nanoseconds")?,
    ))
}

/// Write a block of samples across several channels in one call.
///
/// `channels` is an array of `channel_count` NUL-terminated channel names.
/// `timestamps` holds `row_count` nanosecond instants, shared by every channel.
/// `values` is column-major with `row_count * channel_count` elements: channel
/// `c` occupies `values[c * row_count .. (c + 1) * row_count]`, which is how
/// MATLAB already lays out an N-by-C matrix.
///
/// Timestamps are literal, including zero — a stream may carry times relative
/// to an epoch the caller chose.
///
/// Returns once the write has been accepted. Blocks for the duration.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_write_doubles(
    client_handle: ClientHandle,
    dataset_handle: i32,
    channels: *const *const c_char,
    channel_count: u32,
    timestamps_nanos: *const i64,
    values: *const f64,
    row_count: u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;

        if row_count == 0 || channel_count == 0 {
            // Nothing to send is not an error: an acquisition loop with an
            // empty tick should not have to guard the call.
            return Ok(());
        }
        if channels.is_null() || timestamps_nanos.is_null() || values.is_null() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "channels, timestamps, and values must not be null",
            ));
        }

        let rows = row_count as usize;
        let cols = channel_count as usize;
        let names = unsafe { std::slice::from_raw_parts(channels, cols) };
        let times = unsafe { std::slice::from_raw_parts(timestamps_nanos, rows) };
        let data = unsafe { std::slice::from_raw_parts(values, rows * cols) };

        // Converted once and reused across channels; every channel shares the
        // timestamp column.
        let instants = times
            .iter()
            .map(|&nanos| timestamp_from_nanos(nanos, error_out))
            .collect::<Result<Vec<_>, _>>()?;

        let mut batches = Vec::with_capacity(cols);
        for (index, &raw) in names.iter().enumerate() {
            let name = unsafe { c_str_to_string(raw, &format!("channels[{index}]"), error_out)? };
            let column = &data[index * rows..(index + 1) * rows];

            let points = instants
                .iter()
                .zip(column)
                .map(|(&timestamp, &value)| DoublePoint::new(timestamp, value))
                .collect();

            batches.push(RecordsBatchExternal::new(
                Channel(name),
                PointsExternal::Double(points),
            ));
        }

        let rid = ResourceIdentifier::new(dataset.rid()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid dataset RID {:?}: {e}", dataset.rid()),
            )
        })?;

        let request = WriteBatchesRequestExternal::builder()
            .data_source_rid(NominalDataSourceOrDatasetRid(rid))
            .extend_batches(batches)
            .session_name("nominal-ffi".to_owned())
            .build();

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;

        RUNTIME
            .block_on(async { service.write_batches(&token, &request).await })
            .map_err(|e| fail(error_out, ErrorCode::NominalError, format!("{e:?}")))?;

        Ok(())
    })
}
