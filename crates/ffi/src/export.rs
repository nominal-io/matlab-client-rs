//! Bulk export of channel data to a file.
//!
//! The server renders the data and streams back a file, which this writes to a
//! path you choose. Three formats are available, and for MATLAB one of them is
//! special: **`matfile` produces a `.mat` the caller can simply `load`**. No
//! decoder, no type inference, no timestamp parsing — the work happens
//! server-side and MATLAB reads its own native format.
//!
//! That makes this the recommended way to pull a large slice of data into
//! MATLAB. [`crate::sql`] is better for ad-hoc and aggregate queries, and
//! [`crate::compute`] for plotting-resolution reads, but for "give me these
//! channels over this window" this is both the fastest path and the one with
//! the least that can go wrong.
//!
//! # Resolution
//!
//! Exports are decimated unless you ask otherwise. `Undecimated` returns every
//! sample; `Buckets` returns a fixed number of points; `Nanoseconds` returns one
//! point per interval of that width. Undecimated over a wide window can be very
//! large — CSV is capped at 50 million rows, and the deployment sets a byte cap
//! as well.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};

use nominal_streaming::api::clients::scout::dataexport::api::{
    AsyncDataExportService, AsyncDataExportServiceClient,
};
use nominal_streaming::api::objects::api::{TimeUnit, Timestamp};
use nominal_streaming::api::objects::scout::run::api::Duration;
use nominal_streaming::api::objects::scout::compute::api::{
    Context, Dataset, NumericSeries, SavedDataset, SelectSeries, Series, StringConstant,
};
use nominal_streaming::api::objects::scout::dataexport::api::{
    AllTimestampsForwardFillStrategy, Csv, ExportChannels, ExportDataRequest, ExportFormat,
    ExportTimeDomainChannels, Matfile, MergeTimestampStrategy, RelativeTimestampFormat,
    ResolutionOption, TimeDomainChannel, TimestampFormat, UndecimatedResolution,
};
use nominal_streaming::client::conjure::http::client::{AsyncService, ConjureRuntime};
use nominal_streaming::client::conjure::object::SafeLong;
use nominal_streaming::client::conjure::runtime::{Agent, Client, UserAgent};
use nominal_streaming::prelude::BearerToken;

use futures::StreamExt;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io::Write;
use std::os::raw::c_char;
use std::sync::Arc;

/// File formats an export can produce.
#[repr(i32)]
pub enum Format {
    /// A MATLAB `.mat` file. The reason this module exists.
    Matfile = 0,
    Csv = 1,
    /// Arrow IPC. Accepts **exactly one** channel; the server rejects more.
    Arrow = 2,
}

/// How much the export is decimated.
#[repr(i32)]
pub enum Resolution {
    /// Every sample. `resolution_value` is ignored.
    Undecimated = 0,
    /// `resolution_value` points in total.
    Buckets = 1,
    /// One point per `resolution_value` nanoseconds.
    Nanoseconds = 2,
}

static SERVICES: Lazy<Mutex<HashMap<String, AsyncDataExportServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached export clients. Used by shutdown.
pub(crate) fn clear_export_services() {
    SERVICES.lock().clear();
}

fn service_for(
    base_url: &str,
    error_out: *mut ErrorHandle,
) -> Result<AsyncDataExportServiceClient<Client>, ErrorCode> {
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
            .service("nominal-ffi-export")
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
            format!("could not build export client: {e:?}"),
        )
    })?;

    let service = AsyncDataExportServiceClient::new(client, &Arc::new(ConjureRuntime::default()));
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

/// How far back forward-fill may reach for a value.
///
/// Set to the width of the exported window, so a channel that produced a sample
/// before the window opened still contributes to the first rows. A shorter
/// bound would leave leading gaps for slow channels; a longer one cannot help,
/// since nothing outside the window is read.
fn fill_look_back(
    start_nanos: i64,
    end_nanos: i64,
    error_out: *mut ErrorHandle,
) -> Result<Duration, ErrorCode> {
    let span = end_nanos.saturating_sub(start_nanos).max(0);
    let seconds = span.div_euclid(1_000_000_000);
    let nanos = span.rem_euclid(1_000_000_000);

    let convert = |value: i64| {
        SafeLong::try_from(value).map_err(|_| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                "export window is too wide to express as a fill period",
            )
        })
    };
    Ok(Duration::new(convert(seconds)?, convert(nanos)?))
}

/// Assemble the request.
///
/// Each column is a compute node naming its channel and dataset, which is how
/// the export API expresses a selection — the same machinery also lets an
/// export compute derived series, though nothing here does.
///
/// The argument count mirrors the request's own shape; bundling them into a
/// struct would move the same fields somewhere else without simplifying them.
#[allow(clippy::too_many_arguments)]
fn build_request(
    dataset_rid: &str,
    names: &[*const c_char],
    start_nanos: i64,
    end_nanos: i64,
    resolution: i32,
    resolution_value: i64,
    format: i32,
    error_out: *mut ErrorHandle,
) -> Result<ExportDataRequest, ErrorCode> {
    let format = match format {
        0 => ExportFormat::Matfile(Matfile::new()),
        1 => ExportFormat::Csv(Csv::new()),
        2 => {
            if names.len() != 1 {
                return Err(fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!(
                        "arrow export accepts exactly one channel, got {}",
                        names.len()
                    ),
                ));
            }
            ExportFormat::Arrow(
                nominal_streaming::api::objects::scout::dataexport::api::Arrow::new(),
            )
        }
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("unknown export format {other}; expected 0 matfile, 1 csv, 2 arrow"),
            ))
        }
    };

    let resolution = match resolution {
        0 => ResolutionOption::Undecimated(UndecimatedResolution::new()),
        1 => ResolutionOption::Buckets(resolution_value as i32),
        2 => ResolutionOption::Nanoseconds(SafeLong::try_from(resolution_value).map_err(|_| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                "resolution is outside the representable range",
            )
        })?),
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "unknown resolution {other}; expected 0 undecimated, 1 buckets, 2 nanoseconds"
                ),
            ))
        }
    };

    // Each column is a compute node. `SelectNumeric` names the channel and its
    // dataset inline, so no variables are needed and the context stays empty —
    // the variable indirection only earns its keep for derived series that
    // reference the same input more than once.
    let mut columns = Vec::with_capacity(names.len());

    for (index, &raw) in names.iter().enumerate() {
        let name = unsafe { c_str_to_string(raw, &format!("channels[{index}]"), error_out)? };

        let select = SelectSeries::builder()
            .name(StringConstant::Literal(name.clone()))
            .dataset(Dataset::Saved(SavedDataset::new(StringConstant::Literal(
                dataset_rid.to_owned(),
            ))))
            .build();

        columns.push(TimeDomainChannel::new(
            // The column keeps the channel's own name, which is what appears
            // as a field in the exported file.
            name,
            Series::Numeric(Box::new(NumericSeries::SelectNumeric(select))),
        ));
    }

    Ok(ExportDataRequest::builder()
        .format(format)
        .start_time(timestamp_from_nanos(start_nanos, error_out)?)
        .end_time(timestamp_from_nanos(end_nanos, error_out)?)
        .resolution(resolution)
        .channels(ExportChannels::TimeDomain(
            ExportTimeDomainChannels::builder()
                // Timestamps as a number rather than an ISO-8601 string:
                // relative to the epoch in nanoseconds, so the value *is* a
                // Unix nanosecond count, matching every other timestamp in this
                // library. A string column would arrive in MATLAB as text.
                .output_timestamp_format(TimestampFormat::Relative(RelativeTimestampFormat::new(
                    Timestamp::new(SafeLong::try_from(0i64).expect("0 is in range"),
                                   SafeLong::try_from(0i64).expect("0 is in range")),
                    TimeUnit::Nanoseconds,
                )))
                // Forward-fill so every channel shares one timestamp column and
                // the result is rectangular. Without it, channels sampled on
                // different clocks come back ragged, which is no use as a
                // matrix. The look-back bounds how stale a filled value may be.
                .merge_timestamp_strategy(MergeTimestampStrategy::AllTimestampsForwardFill(
                    AllTimestampsForwardFillStrategy::new(fill_look_back(
                        start_nanos,
                        end_nanos,
                        error_out,
                    )?),
                ))
                .extend_channels(columns)
                .build(),
        ))
        .context(Context::new())
        .build())
}

/// Export channel data to a file on disk.
///
/// `channels` is an array of `channel_count` NUL-terminated channel names.
/// `start_nanos` and `end_nanos` bound the window, inclusive, in nanoseconds
/// since the epoch.
///
/// `format` is 0 matfile, 1 csv, 2 arrow. `resolution` is 0 undecimated,
/// 1 buckets, 2 nanoseconds — with `resolution_value` supplying the count or
/// interval for the latter two, and ignored for undecimated.
///
/// The file is written to `out_path`, replacing anything already there. Blocks
/// until the whole export has been received.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_export_to_file(
    client_handle: ClientHandle,
    dataset_handle: i32,
    channels: *const *const c_char,
    channel_count: u32,
    start_nanos: i64,
    end_nanos: i64,
    resolution: i32,
    resolution_value: i64,
    format: i32,
    out_path: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let path = unsafe { c_str_to_string(out_path, "out_path", error_out)? };

        if channels.is_null() || channel_count == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "at least one channel is required",
            ));
        }
        let names = unsafe { std::slice::from_raw_parts(channels, channel_count as usize) };

        let request = build_request(
            dataset.rid(),
            names,
            start_nanos,
            end_nanos,
            resolution,
            resolution_value,
            format,
            error_out,
        )?;

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;

        RUNTIME.block_on(async {
            let body = service
                .export_channel_data(&token, &request)
                .await
                .map_err(|e| fail(error_out, ErrorCode::NominalError, format!("{e:?}")))?;

            let mut file = std::fs::File::create(&path).map_err(|e| {
                fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!("could not create {path}: {e}"),
                )
            })?;

            // Streamed rather than buffered: an undecimated export can be far
            // larger than memory.
            futures::pin_mut!(body);
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(|e| {
                    fail(
                        error_out,
                        ErrorCode::NominalError,
                        format!("export stream failed: {e:?}"),
                    )
                })?;
                file.write_all(&chunk).map_err(|e| {
                    fail(
                        error_out,
                        ErrorCode::RuntimeError,
                        format!("could not write {path}: {e}"),
                    )
                })?;
            }

            file.flush().map_err(|e| {
                fail(
                    error_out,
                    ErrorCode::RuntimeError,
                    format!("could not flush {path}: {e}"),
                )
            })
        })
    })
}

/// Ask for a download URL instead of the bytes.
///
/// The server renders the file to object storage and returns a time-limited
/// presigned URL. Useful when the caller would rather hand the link to
/// something else — a browser, another process — than receive the bytes here.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_export_presigned_url(
    client_handle: ClientHandle,
    dataset_handle: i32,
    channels: *const *const c_char,
    channel_count: u32,
    start_nanos: i64,
    end_nanos: i64,
    resolution: i32,
    resolution_value: i64,
    format: i32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;

        if channels.is_null() || channel_count == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "at least one channel is required",
            ));
        }
        let names = unsafe { std::slice::from_raw_parts(channels, channel_count as usize) };

        let request = build_request(
            dataset.rid(),
            names,
            start_nanos,
            end_nanos,
            resolution,
            resolution_value,
            format,
            error_out,
        )?;

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;

        let response = RUNTIME
            .block_on(async {
                service
                    .generate_export_channel_data_presigned_link(&token, &request)
                    .await
            })
            .map_err(|e| fail(error_out, ErrorCode::NominalError, format!("{e:?}")))?;

        set_string(out_string, response.presigned_url().url(), error_out)
    })
}
