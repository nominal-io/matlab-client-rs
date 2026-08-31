//! Uploading files.
//!
//! Sends a file from disk and starts an ingest job. Unlike [`crate::write`] and
//! [`crate::stream`], which take samples from memory, this is for data that
//! already exists as a file — a CSV off a test rig, a Parquet export from
//! somewhere else.
//!
//! Uploading is synchronous but ingesting is not. The call returns once the
//! bytes are up and a job has been created; the data is not queryable until
//! that job finishes. Poll with [`nominal_ingest_job_status`], or block with
//! [`nominal_ingest_wait`].
//!
//! # Where the data lands
//!
//! Either an existing dataset, or a new one created atomically with the ingest.
//! Pass a dataset handle for the former; pass a name for the latter. Creating
//! as part of the ingest avoids a dataset that exists but never receives data,
//! which is what happens if a separate create succeeds and the upload then
//! fails.
//!
//! # Progress
//!
//! The underlying client can report upload progress through a callback. That is
//! not exposed here: a callback would run on a worker thread and call back into
//! the host, which is exactly the arrangement that panics if the host then
//! re-enters this library. Poll the job instead.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};

use nominal::core::{
    CsvIngest, DatasetCreate, DatasetTarget, IngestJob, IngestJobStatus, ParquetIngest, TimeUnit,
    Timestamp,
};

use std::os::raw::c_char;
use std::sync::Arc;

pub type IngestJobHandle = i32;

handle_registry!(
    JOBS,
    IngestJob,
    alloc_job,
    get_job,
    free_job_entry,
    clear_ingest_jobs
);

/// How a timestamp column should be read.
#[repr(i32)]
pub enum TimestampKind {
    /// ISO 8601 strings, such as `2026-07-17T21:24:40Z`.
    Iso8601 = 0,
    /// A count since the Unix epoch, in the unit given by `timestamp_unit`.
    Epoch = 1,
    /// A count from the start of the recording, in the unit given by
    /// `timestamp_unit`.
    Relative = 2,
}

/// Units for epoch and relative timestamps.
#[repr(i32)]
pub enum Unit {
    Nanoseconds = 0,
    Microseconds = 1,
    Milliseconds = 2,
    Seconds = 3,
    Minutes = 4,
    Hours = 5,
}

/// States an ingest job can be in.
///
/// `Completed`, `Failed`, and `Cancelled` are terminal; the rest mean the job
/// is still moving.
#[repr(i32)]
pub enum JobStatus {
    Submitted = 0,
    Queued = 1,
    InProgress = 2,
    Completed = 3,
    Failed = 4,
    Cancelled = 5,
    /// A state this client does not recognise.
    Unknown = 6,
}

fn unit_from_code(code: i32, error_out: *mut ErrorHandle) -> Result<TimeUnit, ErrorCode> {
    Ok(match code {
        0 => TimeUnit::Nanoseconds,
        1 => TimeUnit::Microseconds,
        2 => TimeUnit::Milliseconds,
        3 => TimeUnit::Seconds,
        4 => TimeUnit::Minutes,
        5 => TimeUnit::Hours,
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("unknown time unit {other}; expected 0-5"),
            ))
        }
    })
}

fn timestamp_from(
    column: &str,
    kind: i32,
    unit: i32,
    error_out: *mut ErrorHandle,
) -> Result<Timestamp, ErrorCode> {
    Ok(match kind {
        0 => Timestamp::iso8601(column),
        1 => Timestamp::epoch(column, unit_from_code(unit, error_out)?),
        2 => Timestamp::relative(column, unit_from_code(unit, error_out)?),
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("unknown timestamp kind {other}; expected 0 iso8601, 1 epoch, 2 relative"),
            ))
        }
    })
}

/// Resolve where the ingest should land.
///
/// A dataset handle names an existing one; otherwise `new_dataset_name` creates
/// one as part of the ingest. Exactly one is required.
fn target_from(
    dataset_handle: i32,
    new_dataset_name: *const c_char,
    error_out: *mut ErrorHandle,
) -> Result<DatasetTarget, ErrorCode> {
    if dataset_handle != 0 {
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        return Ok(DatasetTarget::from(dataset.rid().to_owned()));
    }
    if !new_dataset_name.is_null() {
        let name = unsafe { c_str_to_string(new_dataset_name, "new_dataset_name", error_out)? };
        if !name.is_empty() {
            return Ok(DatasetTarget::from(DatasetCreate::new(name)));
        }
    }
    Err(fail(
        error_out,
        ErrorCode::InvalidParameter,
        "pass either a dataset handle or a name for a new dataset",
    ))
}

fn deliver(
    job: IngestJob,
    dataset_rid: String,
    out_job: *mut IngestJobHandle,
    out_dataset_rid: StringHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_job(job);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "ingest job handle space exhausted",
        ));
    }
    unsafe { *out_job = handle };
    set_string(out_dataset_rid, dataset_rid, error_out)
}

/// Upload a CSV and start ingesting it.
///
/// `timestamp_column` names the column holding time; `timestamp_kind` and
/// `timestamp_unit` say how to read it — see [`TimestampKind`] and [`Unit`].
/// The unit is ignored for ISO 8601.
///
/// Pass `dataset_handle` to add to an existing dataset, or 0 with
/// `new_dataset_name` set to create one. `out_dataset_rid` receives the RID the
/// data is landing in, which is how you find a freshly-created dataset.
///
/// Blocks while the file uploads, which for a large file is a long time. The
/// ingest itself continues afterwards — see [`nominal_ingest_wait`].
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_ingest_csv(
    client_handle: ClientHandle,
    path: *const c_char,
    dataset_handle: i32,
    new_dataset_name: *const c_char,
    timestamp_column: *const c_char,
    timestamp_kind: i32,
    timestamp_unit: i32,
    out_job: *mut IngestJobHandle,
    out_dataset_rid: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_job, error_out, "out_job")?;
        let client = client_or_fail(client_handle, error_out)?;
        let path = unsafe { c_str_to_string(path, "path", error_out)? };
        let column = unsafe { c_str_to_string(timestamp_column, "timestamp_column", error_out)? };

        let target = target_from(dataset_handle, new_dataset_name, error_out)?;
        let timestamp = timestamp_from(&column, timestamp_kind, timestamp_unit, error_out)?;

        let (job, rid) = RUNTIME
            .block_on(
                client
                    .ingest()
                    .upload_csv(&path, target, CsvIngest::new(timestamp)),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(job, rid, out_job, out_dataset_rid, error_out)
    })
}

/// Upload a Parquet file and start ingesting it.
///
/// Arguments match [`nominal_ingest_csv`].
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_ingest_parquet(
    client_handle: ClientHandle,
    path: *const c_char,
    dataset_handle: i32,
    new_dataset_name: *const c_char,
    timestamp_column: *const c_char,
    timestamp_kind: i32,
    timestamp_unit: i32,
    out_job: *mut IngestJobHandle,
    out_dataset_rid: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_job, error_out, "out_job")?;
        let client = client_or_fail(client_handle, error_out)?;
        let path = unsafe { c_str_to_string(path, "path", error_out)? };
        let column = unsafe { c_str_to_string(timestamp_column, "timestamp_column", error_out)? };

        let target = target_from(dataset_handle, new_dataset_name, error_out)?;
        let timestamp = timestamp_from(&column, timestamp_kind, timestamp_unit, error_out)?;

        let (job, rid) = RUNTIME
            .block_on(
                client
                    .ingest()
                    .upload_parquet(&path, target, ParquetIngest::new(timestamp)),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(job, rid, out_job, out_dataset_rid, error_out)
    })
}

fn job_or_fail(
    handle: IngestJobHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<IngestJob>, ErrorCode> {
    get_job(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown ingest job handle {handle}"),
        )
    })
}

fn status_code(status: &IngestJobStatus) -> i32 {
    match status {
        IngestJobStatus::Submitted => JobStatus::Submitted as i32,
        IngestJobStatus::Queued => JobStatus::Queued as i32,
        IngestJobStatus::InProgress => JobStatus::InProgress as i32,
        IngestJobStatus::Completed => JobStatus::Completed as i32,
        IngestJobStatus::Failed => JobStatus::Failed as i32,
        IngestJobStatus::Cancelled => JobStatus::Cancelled as i32,
        _ => JobStatus::Unknown as i32,
    }
}

/// RID of an ingest job.
#[no_mangle]
pub extern "C" fn nominal_ingest_job_rid(
    handle: IngestJobHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let job = job_or_fail(handle, error_out)?;
        set_string(out_string, job.rid(), error_out)
    })
}

/// Re-read a job's status from the server.
///
/// The handle holds the status as of when it was created, so this fetches a
/// fresh one rather than reporting a stale value. `out_status` receives a
/// [`JobStatus`] code.
#[no_mangle]
pub extern "C" fn nominal_ingest_job_status(
    client_handle: ClientHandle,
    handle: IngestJobHandle,
    out_status: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_status, error_out, "out_status")?;
        let client = client_or_fail(client_handle, error_out)?;
        let job = job_or_fail(handle, error_out)?;

        let fresh = RUNTIME
            .block_on(client.ingest().get_ingest_job(job.rid()))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        unsafe { *out_status = status_code(fresh.status()) };
        Ok(())
    })
}

/// Block until a job reaches a terminal state.
///
/// Returns once the job has succeeded or failed. A failed job is reported
/// through `out_status` rather than as an error — the call did what it was
/// asked, and the ingest failing is a result, not a fault in the request.
///
/// Polls server-side; there is no timeout, so a wedged job blocks indefinitely.
/// Use [`nominal_ingest_job_status`] in a loop of your own if you need one.
#[no_mangle]
pub extern "C" fn nominal_ingest_wait(
    client_handle: ClientHandle,
    handle: IngestJobHandle,
    out_status: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_status, error_out, "out_status")?;
        let client = client_or_fail(client_handle, error_out)?;
        let job = job_or_fail(handle, error_out)?;

        let finished = RUNTIME
            .block_on(client.ingest().wait_for_ingest_job(job.rid()))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        unsafe { *out_status = status_code(finished.status()) };
        Ok(())
    })
}

/// Release an ingest job handle. Freeing an unknown handle is a no-op.
///
/// Does not cancel the ingest.
#[no_mangle]
pub extern "C" fn nominal_ingest_job_free(handle: IngestJobHandle) -> i32 {
    free_job_entry(handle);
    ErrorCode::Success as i32
}
