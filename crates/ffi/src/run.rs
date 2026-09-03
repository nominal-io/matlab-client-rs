//! Runs.
//!
//! A run is an execution of a test, simulation, or analysis, spanning a time
//! range and attached to one or more assets.
//!
//! Runs are created against an asset. Datasets are then attached to the run by
//! reference name; the run does not own them.

use crate::asset::asset_or_fail;
use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use crate::time::{instant_from_nanos, nanos_from_instant};
use crate::update::{snapshot, UpdateHandle};
use nominal::core::{Run, RunCreate, RunUpdate};
use std::os::raw::c_char;
use std::sync::Arc;

pub type RunHandle = i32;

handle_registry!(RUNS, Run, alloc_run, get_run, free_run_entry, clear_runs);

pub(crate) fn run_or_fail(
    handle: RunHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<Run>, ErrorCode> {
    get_run(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown run handle {handle}"),
        )
    })
}

fn deliver(
    run: Run,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_run(run);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "run handle space exhausted",
        ));
    }
    unsafe { *out_run = handle };
    Ok(())
}

/// Create a run on an asset.
///
/// `start_nanos` is nanoseconds since the Unix epoch; pass `0` to start the run
/// now. The run is left open: set its end with `nominal_run_set_end_time`, or
/// through a staged update.
#[no_mangle]
pub extern "C" fn nominal_run_create(
    client_handle: ClientHandle,
    asset_handle: i32,
    name: *const c_char,
    start_nanos: i64,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_run, error_out, "out_run")?;
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let create =
            RunCreate::new(name, instant_from_nanos(start_nanos)).assets([asset.rid().to_owned()]);

        let run = RUNTIME
            .block_on(client.runs().create(create))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(run, out_run, error_out)
    })
}

/// Fetch a run by RID.
#[no_mangle]
pub extern "C" fn nominal_run_get_by_rid(
    client_handle: ClientHandle,
    rid: *const c_char,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_run, error_out, "out_run")?;
        let client = client_or_fail(client_handle, error_out)?;
        let rid = unsafe { c_str_to_string(rid, "rid", error_out)? };

        let run = RUNTIME
            .block_on(client.runs().get(&rid))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(run, out_run, error_out)
    })
}

/// Close a run by setting its end time, returning the updated run as a new
/// handle.
///
/// `end_nanos` is nanoseconds since the Unix epoch; pass `0` to end the run
/// now, which is the common case at the end of a test.
#[no_mangle]
pub extern "C" fn nominal_run_set_end_time(
    client_handle: ClientHandle,
    run_handle: RunHandle,
    end_nanos: i64,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_run, error_out, "out_run")?;
        let client = client_or_fail(client_handle, error_out)?;
        let run = run_or_fail(run_handle, error_out)?;

        let update = RunUpdate::new().end(instant_from_nanos(end_nanos));
        let updated = RUNTIME
            .block_on(client.runs().update(run.rid(), update))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(updated, out_run, error_out)
    })
}

/// Attach a dataset to a run under a reference name.
///
/// The reference name is how the dataset is addressed within the run, and must
/// be unique among that run's data sources.
#[no_mangle]
pub extern "C" fn nominal_run_add_dataset(
    client_handle: ClientHandle,
    run_handle: RunHandle,
    ref_name: *const c_char,
    dataset_handle: i32,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_run, error_out, "out_run")?;
        let client = client_or_fail(client_handle, error_out)?;
        let run = run_or_fail(run_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let ref_name = unsafe { c_str_to_string(ref_name, "ref_name", error_out)? };

        let updated = RUNTIME
            .block_on(
                client
                    .runs()
                    .add_dataset(run.rid(), &ref_name, dataset.rid()),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(updated, out_run, error_out)
    })
}

/// Apply a staged update and return the updated run as a new handle.
///
/// Honours every staged field, including start and end times. The staging
/// object is not consumed; free it with `nominal_update_free`.
#[no_mangle]
pub extern "C" fn nominal_run_update_commit(
    client_handle: ClientHandle,
    run_handle: RunHandle,
    update_handle: UpdateHandle,
    out_run: *mut RunHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_run, error_out, "out_run")?;
        let client = client_or_fail(client_handle, error_out)?;
        let run = run_or_fail(run_handle, error_out)?;
        let staged = snapshot(update_handle, error_out)?;

        let mut update = RunUpdate::new();
        if let Some(name) = staged.name {
            update = update.name(name);
        }
        if let Some(description) = staged.description {
            update = update.description(description);
        }
        if let Some(properties) = staged.properties {
            update = update.properties(properties);
        }
        if let Some(labels) = staged.labels {
            update = update.labels(labels);
        }
        if let Some(nanos) = staged.start_nanos {
            update = update.start(instant_from_nanos(nanos));
        }
        if let Some(nanos) = staged.end_nanos {
            update = update.end(instant_from_nanos(nanos));
        }

        let updated = RUNTIME
            .block_on(client.runs().update(run.rid(), update))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(updated, out_run, error_out)
    })
}

/// Release a run handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_run_free(handle: RunHandle) -> i32 {
    free_run_entry(handle);
    ErrorCode::Success as i32
}

/// RID of a run.
#[no_mangle]
pub extern "C" fn nominal_run_rid(
    handle: RunHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        set_string(out_string, run.rid(), error_out)
    })
}

/// Name of a run.
#[no_mangle]
pub extern "C" fn nominal_run_name(
    handle: RunHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        set_string(out_string, run.name(), error_out)
    })
}

/// Description of a run.
#[no_mangle]
pub extern "C" fn nominal_run_description(
    handle: RunHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        set_string(out_string, run.description(), error_out)
    })
}

/// Sequential run number within the workspace.
#[no_mangle]
pub extern "C" fn nominal_run_number(
    handle: RunHandle,
    out_number: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_number, error_out, "out_number")?;
        let run = run_or_fail(handle, error_out)?;
        unsafe { *out_number = run.run_number() };
        Ok(())
    })
}

/// Start time, in nanoseconds since the Unix epoch.
#[no_mangle]
pub extern "C" fn nominal_run_start_time(
    handle: RunHandle,
    out_nanos: *mut i64,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_nanos, error_out, "out_nanos")?;
        let run = run_or_fail(handle, error_out)?;
        let nanos = nanos_from_instant(run.start(), error_out)?;
        unsafe { *out_nanos = nanos };
        Ok(())
    })
}

/// End time, in nanoseconds since the Unix epoch.
///
/// An open run has no end time: `out_has_end` receives false and `out_nanos`
/// receives 0. Check `out_has_end` before reading the timestamp, since 0 is
/// also a representable instant.
#[no_mangle]
pub extern "C" fn nominal_run_end_time(
    handle: RunHandle,
    out_nanos: *mut i64,
    out_has_end: *mut bool,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_nanos, error_out, "out_nanos")?;
        require_out(out_has_end, error_out, "out_has_end")?;
        let run = run_or_fail(handle, error_out)?;

        match run.end() {
            Some(end) => {
                let nanos = nanos_from_instant(end, error_out)?;
                unsafe {
                    *out_nanos = nanos;
                    *out_has_end = true;
                }
            }
            None => unsafe {
                *out_nanos = 0;
                *out_has_end = false;
            },
        }
        Ok(())
    })
}

/// Web URL for this run in the Nominal app.
#[no_mangle]
pub extern "C" fn nominal_run_url(
    handle: RunHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        set_string(out_string, run.nominal_url(), error_out)
    })
}

/// Number of labels on a run.
#[no_mangle]
pub extern "C" fn nominal_run_label_count(
    handle: RunHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_count, error_out, "out_count")?;
        let run = run_or_fail(handle, error_out)?;
        unsafe { *out_count = run.labels().len() as u32 };
        Ok(())
    })
}

/// Label at `index`, counting from zero.
#[no_mangle]
pub extern "C" fn nominal_run_label_at(
    handle: RunHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        let labels = run.labels();
        let label = labels.get(index as usize).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("label index {index} out of range ({} labels)", labels.len()),
            )
        })?;
        set_string(out_string, label.as_str(), error_out)
    })
}

/// Value of a property, or an error if the run has no such key.
#[no_mangle]
pub extern "C" fn nominal_run_property(
    handle: RunHandle,
    key: *const c_char,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let run = run_or_fail(handle, error_out)?;
        let key = unsafe { c_str_to_string(key, "key", error_out)? };
        let value = run.properties().get(&key).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("run has no property {key:?}"),
            )
        })?;
        set_string(out_string, value.as_str(), error_out)
    })
}
