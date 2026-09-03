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
//! Plain HTTPS with a JSON request body, not gRPC — despite the proto declaring
//! `Query` as server-streaming. The gateway exposes only the REST mapping and
//! returns one concatenated body, so a tonic client reaches an unrouted path
//! and gets an HTML 404 back (which surfaces as `invalid compression flag: 60`,
//! 60 being the `<`). The Python client carries a hand-written REST shim for
//! exactly this reason.
//!
//! The endpoints sit under the same `/api` prefix as the rest of the API:
//! `POST /sql/v1/query`, `POST /sql/v1/query/export`, `GET /sql/v1/catalog`.
//!
//! The query response body *is* the Arrow IPC stream — the RPC maps
//! `response_body: "payload"`, so there is no JSON envelope to unwrap. Its
//! buffers are ZSTD-compressed server-side with no way to opt out; the `arrow`
//! crate handles that with its `ipc_compression` feature.

use crate::client::{client_or_fail, ClientHandle};
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};

use arrow::array::{Array, Float64Array, Int64Array, StringArray};
use arrow::datatypes::{DataType, TimeUnit};
use arrow::record_batch::RecordBatch;

use once_cell::sync::Lazy;
use std::os::raw::c_char;
use std::sync::Arc;

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

/// One client for the process, reused across calls and hosts.
///
/// `reqwest::Client` owns a connection pool and is designed to be shared, so
/// there is nothing to cache per host the way a gRPC channel needed. It carries
/// no credentials either — the token goes on each request — so one instance is
/// safe across clients holding different tokens.
///
/// Built inside the runtime: constructing it sets up pool timers that need an
/// ambient reactor even though no I/O happens yet.
static HTTP: Lazy<reqwest::Client> = Lazy::new(|| {
    RUNTIME.in_context(|| {
        reqwest::Client::builder()
            .user_agent(concat!("nominal-ffi/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("building an HTTP client with default settings cannot fail")
    })
});

/// Build a SQL endpoint URL from the client's base URL.
///
/// The service lives under the same `/api` prefix as everything else, so the
/// base URL is used whole rather than reduced to its host — unlike a gRPC
/// target, which would be scheme and authority only.
fn sql_url(base_url: &str, path: &str) -> String {
    format!("{}/sql/v1/{}", base_url.trim_end_matches('/'), path)
}

/// POST a JSON body to a SQL endpoint and return the raw response body.
///
/// A non-2xx response carries the reason in its body, so it is read as text and
/// used as the error message — the alternative is a bare status code, which for
/// a rejected query says nothing about which part of the SQL the server
/// disliked.
fn sql_post(
    base_url: &str,
    token: &str,
    path: &str,
    accept: &str,
    body: serde_json::Value,
    error_out: *mut ErrorHandle,
) -> Result<Vec<u8>, ErrorCode> {
    let url = sql_url(base_url, path);
    let request = HTTP
        .post(&url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/json")
        .header("Accept", accept)
        .body(body.to_string());

    let outcome = RUNTIME.block_on(async {
        let response = request.send().await?;
        let status = response.status();
        let bytes = response.bytes().await?;
        Ok::<_, reqwest::Error>((status, bytes))
    });

    let (status, bytes) = outcome.map_err(|e| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("SQL request to {url} failed: {e}"),
        )
    })?;

    if !status.is_success() {
        let detail = String::from_utf8_lossy(&bytes);
        let detail = detail.trim();
        return Err(fail(
            error_out,
            ErrorCode::NominalError,
            if detail.is_empty() {
                format!("SQL request to {url} returned {status}")
            } else {
                format!("SQL request to {url} returned {status}: {detail}")
            },
        ));
    }

    Ok(bytes.to_vec())
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

        // `max_rows` is deliberately absent: when present it is capped at 5000,
        // whereas leaving it out is unbounded subject to the size limit.
        // Callers who want fewer rows put a LIMIT in the SQL.
        //
        // The enum crosses by name rather than by number. Both are valid proto
        // JSON, and the name survives a renumbering.
        let body = serde_json::json!({
            "query": query,
            "workspace_rid": workspace,
            "result_format": "SQL_SERVICE_QUERY_RESULT_FORMAT_ARROW_STREAM",
        });

        // The Query RPC maps `response_body: "payload"`, so the response body
        // is the Arrow IPC stream itself — no JSON envelope to unwrap, and the
        // gateway has already concatenated what the proto declares as a stream.
        let payload = sql_post(
            client.base_url(),
            client.token(),
            "query",
            "application/octet-stream",
            body,
            error_out,
        )?;

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

        // Float32 also reports as `ColumnType::Double`, so it must be readable
        // here — widened by the same cast, which is a cheap no-op for Float64.
        let casted = match column.data_type() {
            DataType::Float64 | DataType::Float32 => {
                arrow::compute::cast(column, &DataType::Float64).map_err(|e| {
                    fail(
                        error_out,
                        ErrorCode::RuntimeError,
                        format!("could not convert column {index} to doubles: {e}"),
                    )
                })?
            }
            other => {
                return Err(fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!("column {index} is {other:?}, not a double column"),
                ))
            }
        };
        let values = casted
            .as_any()
            .downcast_ref::<Float64Array>()
            .expect("cast to Float64");

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

        // Everything `ColumnType::Int64` or `::Timestamp` covers must be
        // readable here: the narrower integer widths and booleans widen through
        // the same cast, and a timestamp is scaled so every value leaving this
        // library is in nanoseconds, whatever resolution the server sent.
        let factor: i64 = match column.data_type() {
            DataType::Int64
            | DataType::Int32
            | DataType::Int16
            | DataType::Int8
            | DataType::Boolean => 1,
            DataType::Timestamp(unit, _) => match unit {
                TimeUnit::Second => 1_000_000_000,
                TimeUnit::Millisecond => 1_000_000,
                TimeUnit::Microsecond => 1_000,
                TimeUnit::Nanosecond => 1,
            },
            other => {
                return Err(fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!("column {index} is {other:?}, not an integer or timestamp column"),
                ))
            }
        };

        let casted = arrow::compute::cast(column, &DataType::Int64).map_err(|e| {
            fail(
                error_out,
                ErrorCode::RuntimeError,
                format!("could not convert column {index} to int64: {e}"),
            )
        })?;
        let values = casted
            .as_any()
            .downcast_ref::<Int64Array>()
            .expect("cast to Int64");
        for (slot, row) in out.iter_mut().zip(0..count) {
            *slot = if values.is_null(row) {
                0
            } else {
                values.value(row).saturating_mul(factor)
            };
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

        let values = column
            .as_any()
            .downcast_ref::<StringArray>()
            .ok_or_else(|| {
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

        let body = serde_json::json!({
            "query": query,
            "workspace_rid": workspace,
        });

        // Export returns a JSON envelope rather than bytes, unlike query.
        let raw = sql_post(
            client.base_url(),
            client.token(),
            "query/export",
            "application/json",
            body,
            error_out,
        )?;

        let parsed: serde_json::Value = serde_json::from_slice(&raw).map_err(|e| {
            fail(
                error_out,
                ErrorCode::NominalError,
                format!("SQL export returned a body that is not JSON: {e}"),
            )
        })?;

        // The JSON transcoder emits lowerCamelCase; the proto's own spelling is
        // accepted too, in case a deployment transcodes with original names.
        let url = parsed
            .get("presignedUrl")
            .or_else(|| parsed.get("presigned_url"))
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                fail(
                    error_out,
                    ErrorCode::NominalError,
                    format!("SQL export response carried no presigned URL: {parsed}"),
                )
            })?;

        set_string(out_string, url, error_out)
    })
}
