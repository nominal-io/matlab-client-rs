//! Read-only SQL against Nominal's warehouse.
//!
//! Runs a `SELECT` and returns the result inline — no file, no download. Best
//! for ad-hoc slices, aggregates, and metadata lookups. For bulk reads into
//! MATLAB prefer [`crate::export`], whose `matfile` format needs no decoding at
//! all; for plotting-resolution reads prefer [`crate::compute`].
//!
//! # Scoping is mandatory
//!
//! Telemetry tables — `points_double`, `points_int`, `points_string`,
//! `points_struct`, `logs`, `channels` — must filter on `dataset_rid`, or the
//! query is rejected before it runs. Metadata tables — `assets`, `runs`,
//! `run_assets`, `datasets`, `events` — have no such requirement, which makes
//! `datasets` the usual way to discover a RID when you have none.
//!
//! ```sql
//! SELECT ts, channel, value FROM points_double
//! WHERE dataset_rid = 'ri.catalog...' AND channel = 'rpm'
//! ORDER BY ts
//! ```
//!
//! # Limits
//!
//! Two minutes of execution and 1 GiB of result. There is no row cap unless you
//! ask for one, and no pagination at all — page by hand with `ORDER BY ts` and
//! `WHERE ts > :last`. Pure-metadata queries are capped at 10,000 rows
//! regardless. Requests are rate-limited to roughly ten per second per
//! organisation.
//!
//! Results buffer server-side until the query finishes, so a failure arrives as
//! an error rather than a truncated success — but nothing streams until the
//! query completes.
//!
//! # Transport
//!
//! This is gRPC rather than Conjure, so it needs its own tonic channel. The
//! response arrives as an Arrow IPC stream whose buffers are ZSTD-compressed
//! server-side with no way to opt out; the `arrow` crate handles that with its
//! `ipc_compression` feature.

// The gRPC interceptor closures return `tonic::Status`, which clippy flags as a
// large Err variant. That is tonic's own signature; there is nothing to box.
#![allow(clippy::result_large_err)]

use crate::client::{client_or_fail, ClientHandle};
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};

use arrow::array::{Array, Float64Array, Int64Array, StringArray, TimestampMicrosecondArray,
                   TimestampNanosecondArray};
use arrow::datatypes::{DataType, TimeUnit};
use arrow::record_batch::RecordBatch;

use nominal_streaming::api::tonic::nominal::sql::v1::sql_service_client::SqlServiceClient;
use nominal_streaming::api::tonic::nominal::sql::v1::{
    SqlServiceExportRequest, SqlServiceQueryRequest, SqlServiceQueryResultFormat,
};

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::os::raw::c_char;
use std::sync::Arc;
use tonic::metadata::{Ascii, MetadataValue};
use tonic::transport::{Channel, ClientTlsConfig};

pub type QueryResultHandle = i32;

handle_registry!(
    RESULTS,
    RecordBatch,
    alloc_result,
    get_result,
    free_result_entry,
    clear_sql_results
);

/// Column types a result can carry, as an `int32`.
///
/// Deliberately coarse: the warehouse emits a narrow set of Arrow types, and
/// collapsing them to what a caller can actually read avoids a vocabulary that
/// mostly never appears.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    /// Read with `nominal_sql_column_doubles`.
    Double = 0,
    /// Read with `nominal_sql_column_int64`.
    Int64 = 1,
    /// Read with `nominal_sql_column_string_at`.
    String = 2,
    /// Nanoseconds since the epoch; read with `nominal_sql_column_int64`.
    Timestamp = 3,
    /// Present in the result but not readable through this interface.
    Unsupported = 4,
}

/// Channels are cached per host rather than per client, since a channel carries
/// no credentials — the token goes on each request instead. Caching the service
/// itself would be wrong: two clients may hold different tokens for one host.
static CHANNELS: Lazy<Mutex<HashMap<String, Channel>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached gRPC channels. Used by shutdown.
pub(crate) fn clear_sql_channels() {
    CHANNELS.lock().clear();
}

/// gRPC services sit at the host root, not under the API's `/api` path.
fn grpc_root(base_url: &str, error_out: *mut ErrorHandle) -> Result<String, ErrorCode> {
    let invalid = |reason: String| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid base URL {base_url:?}: {reason}"),
        )
    };
    let url = url_parse(base_url).map_err(invalid)?;
    Ok(url)
}

/// Strip the path from a base URL, keeping scheme, host, and any explicit port.
fn url_parse(base_url: &str) -> Result<String, String> {
    let (scheme, rest) = base_url
        .split_once("://")
        .ok_or_else(|| "URL has no scheme".to_owned())?;
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        return Err("URL has no host".to_owned());
    }
    Ok(format!("{scheme}://{authority}"))
}

fn channel_for(base_url: &str, error_out: *mut ErrorHandle) -> Result<Channel, ErrorCode> {
    if let Some(existing) = CHANNELS.lock().get(base_url) {
        return Ok(existing.clone());
    }

    let root = grpc_root(base_url, error_out)?;
    let mut endpoint = Channel::from_shared(root.clone()).map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid gRPC URL {root:?}: {e}"),
        )
    })?;

    if root.starts_with("https://") {
        endpoint = endpoint
            .tls_config(ClientTlsConfig::new().with_native_roots())
            .map_err(|e| {
                fail(
                    error_out,
                    ErrorCode::NominalError,
                    format!("TLS setup failed: {e}"),
                )
            })?;
    }

    // Connects on first use, so this does no I/O — but it does construct hyper
    // resources, which need an ambient runtime.
    let channel = RUNTIME.in_context(|| endpoint.connect_lazy());
    CHANNELS.lock().insert(base_url.to_owned(), channel.clone());
    Ok(channel)
}

fn bearer(token: &str, error_out: *mut ErrorHandle) -> Result<MetadataValue<Ascii>, ErrorCode> {
    format!("Bearer {token}").parse().map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("token is not a valid header value: {e}"),
        )
    })
}

/// Run a query and hold the result.
///
/// `workspace_rid` may be NULL or empty, in which case the client's own
/// workspace is used. One or the other is required: the SQL service always
/// needs a workspace, even though the rest of the API does not.
///
/// Release the result with `nominal_sql_free`.
#[no_mangle]
pub extern "C" fn nominal_sql_query(
    client_handle: ClientHandle,
    query: *const c_char,
    workspace_rid: *const c_char,
    out_result: *mut QueryResultHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_result, error_out, "out_result")?;
        let client = client_or_fail(client_handle, error_out)?;
        let query = unsafe { c_str_to_string(query, "query", error_out)? };

        let workspace = resolve_workspace(&client, workspace_rid, error_out)?;
        let header = bearer(client.token(), error_out)?;
        let channel = channel_for(client.base_url(), error_out)?;

        let payload = RUNTIME.block_on(async {
            let mut service = SqlServiceClient::with_interceptor(channel, move |mut req: tonic::Request<()>| {
                req.metadata_mut().insert("authorization", header.clone());
                Ok(req)
            });

            let request = SqlServiceQueryRequest {
                query,
                // Left unset: when present it is capped at 5000, whereas an
                // absent value is unbounded subject to the size limit. Callers
                // who want fewer rows put a LIMIT in the SQL.
                max_rows: None,
                workspace_rid: workspace,
                result_format: SqlServiceQueryResultFormat::ArrowStream as i32,
            };

            let mut stream = service.query(request).await?.into_inner();

            // Chunks are 64 KiB of one logical Arrow stream, so they are
            // concatenated before parsing rather than parsed individually.
            let mut bytes = Vec::new();
            while let Some(response) = stream.message().await? {
                bytes.extend_from_slice(&response.payload);
            }
            Ok::<_, tonic::Status>(bytes)
        });

        let payload = payload.map_err(|status| {
            fail(
                error_out,
                ErrorCode::NominalError,
                format!("{}: {}", status.code(), status.message()),
            )
        })?;

        let batch = decode_arrow(&payload, error_out)?;
        let handle = alloc_result(batch);
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "query result handle space exhausted",
            ));
        }
        unsafe { *out_result = handle };
        Ok(())
    })
}

fn resolve_workspace(
    client: &crate::client::ClientEntry,
    workspace_rid: *const c_char,
    error_out: *mut ErrorHandle,
) -> Result<String, ErrorCode> {
    if !workspace_rid.is_null() {
        let explicit = unsafe { c_str_to_string(workspace_rid, "workspace_rid", error_out)? };
        if !explicit.is_empty() {
            return Ok(explicit);
        }
    }
    match client.workspace_rid() {
        Some(rid) if !rid.is_empty() => Ok(rid.to_owned()),
        _ => Err(fail(
            error_out,
            ErrorCode::InvalidParameter,
            "SQL requires a workspace: pass one, or build the client with one",
        )),
    }
}

/// Parse the Arrow IPC stream into a single batch.
fn decode_arrow(bytes: &[u8], error_out: *mut ErrorHandle) -> Result<RecordBatch, ErrorCode> {
    let reader = arrow::ipc::reader::StreamReader::try_new(std::io::Cursor::new(bytes), None)
        .map_err(|e| {
            fail(
                error_out,
                ErrorCode::NominalError,
                format!("could not read the Arrow response: {e}"),
            )
        })?;

    let schema = reader.schema();
    let batches = reader.collect::<Result<Vec<_>, _>>().map_err(|e| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("could not decode the Arrow response: {e}"),
        )
    })?;

    // Concatenated so the caller sees one table: batch boundaries are an
    // artifact of transport, not of the query.
    arrow::compute::concat_batches(&schema, &batches).map_err(|e| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("could not assemble the result: {e}"),
        )
    })
}

fn result_or_fail(
    handle: QueryResultHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<RecordBatch>, ErrorCode> {
    get_result(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown query result handle {handle}"),
        )
    })
}

fn column_of(
    batch: &RecordBatch,
    index: u32,
    error_out: *mut ErrorHandle,
) -> Result<&dyn Array, ErrorCode> {
    if index as usize >= batch.num_columns() {
        return Err(fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!(
                "column index {index} out of range ({} columns)",
                batch.num_columns()
            ),
        ));
    }
    Ok(batch.column(index as usize).as_ref())
}

/// Release a query result. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_sql_free(handle: QueryResultHandle) -> i32 {
    free_result_entry(handle);
    ErrorCode::Success as i32
}

/// Number of rows in the result.
#[no_mangle]
pub extern "C" fn nominal_sql_row_count(
    handle: QueryResultHandle,
    out_rows: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_rows, error_out, "out_rows")?;
        let batch = result_or_fail(handle, error_out)?;
        unsafe { *out_rows = batch.num_rows() as u32 };
        Ok(())
    })
}

/// Number of columns in the result.
#[no_mangle]
pub extern "C" fn nominal_sql_column_count(
    handle: QueryResultHandle,
    out_columns: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_columns, error_out, "out_columns")?;
        let batch = result_or_fail(handle, error_out)?;
        unsafe { *out_columns = batch.num_columns() as u32 };
        Ok(())
    })
}

/// Name of the column at `index`, as the query selected it.
#[no_mangle]
pub extern "C" fn nominal_sql_column_name(
    handle: QueryResultHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let batch = result_or_fail(handle, error_out)?;
        if index as usize >= batch.num_columns() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "column index {index} out of range ({} columns)",
                    batch.num_columns()
                ),
            ));
        }
        set_string(
            out_string,
            batch.schema().field(index as usize).name().as_str(),
            error_out,
        )
    })
}

/// Type of the column at `index`, as a `ColumnType` code.
#[no_mangle]
pub extern "C" fn nominal_sql_column_type(
    handle: QueryResultHandle,
    index: u32,
    out_type: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_type, error_out, "out_type")?;
        let batch = result_or_fail(handle, error_out)?;
        let column = column_of(&batch, index, error_out)?;

        let kind = match column.data_type() {
            DataType::Float64 | DataType::Float32 => ColumnType::Double,
            DataType::Int64 | DataType::Int32 | DataType::Int16 | DataType::Int8 => {
                ColumnType::Int64
            }
            DataType::Utf8 | DataType::LargeUtf8 => ColumnType::String,
            DataType::Timestamp(_, _) => ColumnType::Timestamp,
            DataType::Boolean => ColumnType::Int64,
            _ => ColumnType::Unsupported,
        };
        unsafe { *out_type = kind as i32 };
        Ok(())
    })
}

/// Copy a floating-point column into a caller-provided buffer.
///
/// Nulls become NaN — distinguishable from a real value, since the warehouse
/// does not produce NaN itself. `out_written` receives the number of elements
/// copied, which is the lesser of the row count and `capacity`.
#[no_mangle]
pub extern "C" fn nominal_sql_column_doubles(
    handle: QueryResultHandle,
    index: u32,
    buffer: *mut f64,
    capacity: u32,
    out_written: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(buffer, error_out, "buffer")?;
        require_out(out_written, error_out, "out_written")?;
        let batch = result_or_fail(handle, error_out)?;
        let column = column_of(&batch, index, error_out)?;

        let values = column.as_any().downcast_ref::<Float64Array>().ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "column {index} is {:?}, not a double column",
                    column.data_type()
                ),
            )
        })?;

        let count = values.len().min(capacity as usize);
        let out = unsafe { std::slice::from_raw_parts_mut(buffer, count) };
        for (slot, row) in out.iter_mut().zip(0..count) {
            *slot = if values.is_null(row) {
                f64::NAN
            } else {
                values.value(row)
            };
        }
        unsafe { *out_written = count as u32 };
        Ok(())
    })
}

/// Copy an integer or timestamp column into a caller-provided buffer.
///
/// Timestamps are converted to **nanoseconds since the Unix epoch**, whatever
/// resolution the server sent — the warehouse has been observed emitting both
/// microsecond and nanosecond columns, and normalising here means callers do
/// not have to inspect the schema to know the scale.
///
/// Nulls become 0. Use `nominal_sql_column_is_null` where that matters.
#[no_mangle]
pub extern "C" fn nominal_sql_column_int64(
    handle: QueryResultHandle,
    index: u32,
    buffer: *mut i64,
    capacity: u32,
    out_written: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(buffer, error_out, "buffer")?;
        require_out(out_written, error_out, "out_written")?;
        let batch = result_or_fail(handle, error_out)?;
        let column = column_of(&batch, index, error_out)?;

        let count = column.len().min(capacity as usize);
        let out = unsafe { std::slice::from_raw_parts_mut(buffer, count) };

        match column.data_type() {
            DataType::Int64 => {
                let values = column.as_any().downcast_ref::<Int64Array>().expect("checked");
                for (slot, row) in out.iter_mut().zip(0..count) {
                    *slot = if values.is_null(row) { 0 } else { values.value(row) };
                }
            }
            DataType::Timestamp(TimeUnit::Nanosecond, _) => {
                let values = column
                    .as_any()
                    .downcast_ref::<TimestampNanosecondArray>()
                    .expect("checked");
                for (slot, row) in out.iter_mut().zip(0..count) {
                    *slot = if values.is_null(row) { 0 } else { values.value(row) };
                }
            }
            DataType::Timestamp(TimeUnit::Microsecond, _) => {
                let values = column
                    .as_any()
                    .downcast_ref::<TimestampMicrosecondArray>()
                    .expect("checked");
                for (slot, row) in out.iter_mut().zip(0..count) {
                    *slot = if values.is_null(row) {
                        0
                    } else {
                        // Scaled here so every timestamp leaving this library
                        // is in the same unit.
                        values.value(row).saturating_mul(1_000)
                    };
                }
            }
            other => {
                return Err(fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!("column {index} is {other:?}, not an integer or timestamp column"),
                ))
            }
        }

        unsafe { *out_written = count as u32 };
        Ok(())
    })
}

/// Read one cell of a string column.
///
/// A null cell yields the empty string; use `nominal_sql_column_is_null` to
/// tell that apart from a stored empty string.
#[no_mangle]
pub extern "C" fn nominal_sql_column_string_at(
    handle: QueryResultHandle,
    index: u32,
    row: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let batch = result_or_fail(handle, error_out)?;
        let column = column_of(&batch, index, error_out)?;

        let values = column.as_any().downcast_ref::<StringArray>().ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "column {index} is {:?}, not a string column",
                    column.data_type()
                ),
            )
        })?;

        if row as usize >= values.len() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("row {row} out of range ({} rows)", values.len()),
            ));
        }

        let text = if values.is_null(row as usize) {
            ""
        } else {
            values.value(row as usize)
        };
        set_string(out_string, text, error_out)
    })
}

/// Whether the cell at (`index`, `row`) is null.
#[no_mangle]
pub extern "C" fn nominal_sql_column_is_null(
    handle: QueryResultHandle,
    index: u32,
    row: u32,
    out_is_null: *mut bool,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_is_null, error_out, "out_is_null")?;
        let batch = result_or_fail(handle, error_out)?;
        let column = column_of(&batch, index, error_out)?;

        if row as usize >= column.len() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("row {row} out of range ({} rows)", column.len()),
            ));
        }
        unsafe { *out_is_null = column.is_null(row as usize) };
        Ok(())
    })
}

/// Run a query and get a download URL for the full result as CSV.
///
/// For results too large for `nominal_sql_query`, which is bounded at 1 GiB.
/// Export runs without that cap, writes to object storage, and returns a
/// time-limited presigned URL.
///
/// CSV only, and only for queries reading telemetry tables — a query touching
/// `assets`, `runs`, or `datasets` cannot be exported this way. Some
/// deployments have no export bucket configured, in which case this fails.
#[no_mangle]
pub extern "C" fn nominal_sql_export_url(
    client_handle: ClientHandle,
    query: *const c_char,
    workspace_rid: *const c_char,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(client_handle, error_out)?;
        let query = unsafe { c_str_to_string(query, "query", error_out)? };
        let workspace = resolve_workspace(&client, workspace_rid, error_out)?;
        let header = bearer(client.token(), error_out)?;
        let channel = channel_for(client.base_url(), error_out)?;

        let response = RUNTIME.block_on(async {
            let mut service = SqlServiceClient::with_interceptor(channel, move |mut req: tonic::Request<()>| {
                req.metadata_mut().insert("authorization", header.clone());
                Ok(req)
            });
            service
                .export(SqlServiceExportRequest {
                    query,
                    workspace_rid: workspace,
                })
                .await
        });

        let response = response.map_err(|status| {
            fail(
                error_out,
                ErrorCode::NominalError,
                format!("{}: {}", status.code(), status.message()),
            )
        })?;

        set_string(out_string, response.into_inner().presigned_url, error_out)
    })
}
