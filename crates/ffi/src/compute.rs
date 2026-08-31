//! Reading points back, inline.
//!
//! This is the path Nominal's own charting UI uses: it returns timestamps and
//! values in the response body, with no file and no download. Two shapes are
//! worth knowing apart.
//!
//! **Decimated** — ask for a fixed number of points across the window and the
//! server picks them. Right for plotting, where a million samples and two
//! thousand pixels make full resolution pointless. Capped at 10,000 points.
//!
//! **Full resolution** — every sample, fetched in pages of 5,000. This module
//! loops the pages internally, so a caller asks once and gets everything; the
//! cost is that a wide window means many round trips.
//!
//! For bulk reads into MATLAB, [`crate::export`] is usually better still: the
//! server writes a `.mat` and MATLAB loads it natively. Use this when you want
//! the points in memory rather than in a file, or want them decimated.
//!
//! # One channel at a time
//!
//! Each call reads a single channel. The API can batch up to 300 requests in
//! one round trip, which would be worth adding if reading many channels turns
//! out to be common — but a batch shares nothing except the connection, so the
//! saving is latency, not work.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::c_str_to_string;

use nominal_streaming::api::clients::scout::compute::api::{
    AsyncComputeService, AsyncComputeServiceClient,
};
use nominal_streaming::api::objects::api::Timestamp;
use nominal_streaming::api::objects::scout::compute::api::{
    ComputableNode, ComputeNodeRequest, ComputeNodeResponse, Context, Dataset, DecimateStrategy,
    DecimateWithBuckets, NumericSeries, PageInfo, PageStrategy, PageToken, SavedDataset,
    SelectSeries, Series, StringConstant, SummarizationStrategy, SummarizeSeries,
};
use nominal_streaming::client::conjure::http::client::{AsyncService, ConjureRuntime};
use nominal_streaming::client::conjure::object::SafeLong;
use nominal_streaming::client::conjure::runtime::{Agent, Client, UserAgent};
use nominal_streaming::prelude::BearerToken;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::os::raw::c_char;
use std::sync::Arc;

/// The server's own page limit. Asking for more is rejected.
const PAGE_SIZE: i32 = 5_000;

/// Guards against an unbounded loop if the server keeps returning tokens.
/// 5,000 pages is 25 million points — far past what belongs in memory, and a
/// sign the caller wanted `export` instead.
const MAX_PAGES: usize = 5_000;

pub type SeriesHandle = i32;

/// A fetched series: parallel timestamp and value columns.
pub(crate) struct FetchedSeries {
    pub(crate) timestamps: Vec<i64>,
    pub(crate) values: Vec<f64>,
}

handle_registry!(
    SERIES,
    FetchedSeries,
    alloc_series,
    get_series,
    free_series_entry,
    clear_compute_series
);

static SERVICES: Lazy<Mutex<HashMap<String, AsyncComputeServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached compute clients. Used by shutdown.
pub(crate) fn clear_compute_services() {
    SERVICES.lock().clear();
}

fn service_for(
    base_url: &str,
    error_out: *mut ErrorHandle,
) -> Result<AsyncComputeServiceClient<Client>, ErrorCode> {
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

    let client = RUNTIME.in_context(|| {
        Client::builder()
            .service("nominal-ffi-compute")
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
            format!("could not build compute client: {e:?}"),
        )
    })?;

    let service = AsyncComputeServiceClient::new(client, &Arc::new(ConjureRuntime::default()));
    SERVICES.lock().insert(base_url.to_owned(), service.clone());
    Ok(service)
}

fn timestamp_from_nanos(nanos: i64, error_out: *mut ErrorHandle) -> Result<Timestamp, ErrorCode> {
    let seconds = nanos.div_euclid(1_000_000_000);
    let subsec = nanos.rem_euclid(1_000_000_000);
    let convert = |value: i64, what: &str| {
        SafeLong::try_from(value).map_err(|_| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("time range {what} is outside the representable range"),
            )
        })
    };
    Ok(Timestamp::new(
        convert(seconds, "seconds")?,
        convert(subsec, "nanoseconds")?,
    ))
}

fn nanos_from_timestamp(timestamp: &Timestamp) -> i64 {
    *timestamp.seconds() * 1_000_000_000 + *timestamp.nanos()
}

/// The channel selection shared by both fetch modes.
fn select(dataset_rid: &str, channel: &str) -> Series {
    Series::Numeric(Box::new(NumericSeries::SelectNumeric(
        SelectSeries::builder()
            .name(StringConstant::Literal(channel.to_owned()))
            .dataset(Dataset::Saved(SavedDataset::new(StringConstant::Literal(
                dataset_rid.to_owned(),
            ))))
            .build(),
    )))
}

fn request(
    node: SummarizeSeries,
    start_nanos: i64,
    end_nanos: i64,
    error_out: *mut ErrorHandle,
) -> Result<ComputeNodeRequest, ErrorCode> {
    Ok(ComputeNodeRequest::builder()
        .node(ComputableNode::Series(node))
        .start(timestamp_from_nanos(start_nanos, error_out)?)
        .end(timestamp_from_nanos(end_nanos, error_out)?)
        .context(Context::new())
        .build())
}

/// One page of a series: its points, and a token if more follow.
type Page = (Vec<i64>, Vec<f64>, Option<PageToken>);

/// Pull timestamps and values out of whichever response arm came back.
///
/// Only the plain numeric arm is handled: `outputFormat` is left unset, which
/// the server reads as its legacy JSON shape, so an Arrow arm should not
/// appear. Anything else is reported rather than silently returning nothing.
fn take_numeric(
    response: ComputeNodeResponse,
    error_out: *mut ErrorHandle,
) -> Result<Page, ErrorCode> {
    match response {
        ComputeNodeResponse::Numeric(plot) => {
            let timestamps = plot.timestamps().iter().map(nanos_from_timestamp).collect();
            let values = plot.values().to_vec();
            let token = plot.next_page_token().cloned();
            Ok((timestamps, values, token))
        }
        other => Err(fail(
            error_out,
            ErrorCode::NominalError,
            format!(
                "expected a numeric series, got {:?} — the channel may not be numeric",
                std::mem::discriminant(&other)
            ),
        )),
    }
}

fn deliver(
    series: FetchedSeries,
    out_series: *mut SeriesHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_series(series);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "series handle space exhausted",
        ));
    }
    unsafe { *out_series = handle };
    Ok(())
}

/// Fetch a channel decimated to roughly `buckets` points.
///
/// The server chooses which points to keep. Use this for plotting, where full
/// resolution is wasted: the cap is 10,000 points, and a few thousand is
/// usually indistinguishable on screen.
///
/// Timestamps are nanoseconds since the epoch, and the window is inclusive at
/// both ends.
#[no_mangle]
pub extern "C" fn nominal_compute_fetch_decimated(
    client_handle: ClientHandle,
    dataset_handle: i32,
    channel: *const c_char,
    start_nanos: i64,
    end_nanos: i64,
    buckets: u32,
    out_series: *mut SeriesHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_series, error_out, "out_series")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let channel = unsafe { c_str_to_string(channel, "channel", error_out)? };

        if buckets == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "buckets must be greater than zero",
            ));
        }

        let node = SummarizeSeries::builder()
            .input(select(dataset.rid(), &channel))
            .summarization_strategy(SummarizationStrategy::Decimate(Box::new(
                DecimateStrategy::Buckets(DecimateWithBuckets::new(buckets as i32)),
            )))
            .build();

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;
        let request = request(node, start_nanos, end_nanos, error_out)?;

        let response = RUNTIME
            .block_on(async { service.compute(&token, &request).await })
            .map_err(|e| fail(error_out, ErrorCode::NominalError, format!("{e:?}")))?;

        let (timestamps, values, _) = take_numeric(response, error_out)?;
        deliver(
            FetchedSeries { timestamps, values },
            out_series,
            error_out,
        )
    })
}

/// Fetch every sample of a channel in the window.
///
/// Pages internally at the server's limit of 5,000 points and stitches the
/// result together, so one call returns the whole series. A wide window
/// therefore costs many round trips — [`crate::export`] moves the same data in
/// one request when the destination is a file.
///
/// Gives up after 5,000 pages, about 25 million points, on the grounds that
/// anything larger does not belong in memory.
#[no_mangle]
pub extern "C" fn nominal_compute_fetch(
    client_handle: ClientHandle,
    dataset_handle: i32,
    channel: *const c_char,
    start_nanos: i64,
    end_nanos: i64,
    out_series: *mut SeriesHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_series, error_out, "out_series")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let channel = unsafe { c_str_to_string(channel, "channel", error_out)? };

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;

        let mut all_timestamps = Vec::new();
        let mut all_values = Vec::new();
        let mut page_token: Option<PageToken> = None;

        for page in 0..MAX_PAGES {
            let mut info = PageInfo::builder().page_size(PAGE_SIZE);
            if let Some(token) = page_token.clone() {
                info = info.page_token(token);
            }

            let node = SummarizeSeries::builder()
                .input(select(dataset.rid(), &channel))
                .summarization_strategy(SummarizationStrategy::Page(Box::new(
                    PageStrategy::PageInfo(info.build()),
                )))
                .build();

            let request = request(node, start_nanos, end_nanos, error_out)?;
            let response = RUNTIME
                .block_on(async { service.compute(&token, &request).await })
                .map_err(|e| {
                    fail(
                        error_out,
                        ErrorCode::NominalError,
                        format!("page {page} failed: {e:?}"),
                    )
                })?;

            let (timestamps, values, next) = take_numeric(response, error_out)?;
            all_timestamps.extend(timestamps);
            all_values.extend(values);

            // A token only arrives when the page came back full, so its absence
            // is the end of the series.
            match next {
                Some(token) => page_token = Some(token),
                None => break,
            }
        }

        deliver(
            FetchedSeries {
                timestamps: all_timestamps,
                values: all_values,
            },
            out_series,
            error_out,
        )
    })
}

/// Release a fetched series. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_series_free(handle: SeriesHandle) -> i32 {
    free_series_entry(handle);
    ErrorCode::Success as i32
}

/// Number of points in a fetched series.
#[no_mangle]
pub extern "C" fn nominal_series_length(
    handle: SeriesHandle,
    out_length: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_length, error_out, "out_length")?;
        let series = get_series(handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown series handle {handle}"),
            )
        })?;
        unsafe { *out_length = series.timestamps.len() as u32 };
        Ok(())
    })
}

/// Copy the timestamps into a caller-provided buffer, in nanoseconds.
#[no_mangle]
pub extern "C" fn nominal_series_timestamps(
    handle: SeriesHandle,
    buffer: *mut i64,
    capacity: u32,
    out_written: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(buffer, error_out, "buffer")?;
        require_out(out_written, error_out, "out_written")?;
        let series = get_series(handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown series handle {handle}"),
            )
        })?;

        let count = series.timestamps.len().min(capacity as usize);
        unsafe {
            std::ptr::copy_nonoverlapping(series.timestamps.as_ptr(), buffer, count);
            *out_written = count as u32;
        }
        Ok(())
    })
}

/// Copy the values into a caller-provided buffer.
#[no_mangle]
pub extern "C" fn nominal_series_values(
    handle: SeriesHandle,
    buffer: *mut f64,
    capacity: u32,
    out_written: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(buffer, error_out, "buffer")?;
        require_out(out_written, error_out, "out_written")?;
        let series = get_series(handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown series handle {handle}"),
            )
        })?;

        let count = series.values.len().min(capacity as usize);
        unsafe {
            std::ptr::copy_nonoverlapping(series.values.as_ptr(), buffer, count);
            *out_written = count as u32;
        }
        Ok(())
    })
}
