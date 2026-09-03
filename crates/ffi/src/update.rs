//! Update staging.
//!
//! Updates are accumulated into a staging object and applied in one call:
//!
//! ```c
//! int32_t b; nominal_update_begin(&b);
//! nominal_update_set_name(b, "new name", &err);
//! nominal_update_set_property(b, "phase", "burn", &err);
//! nominal_asset_update_commit(client, asset, b, updated, &err);
//! nominal_update_free(b);
//! ```
//!
//! One staging type serves every resource. Fields a given resource does not
//! support are ignored by its commit function, so callers learn one set of
//! setters rather than one per type.
//!
//! **Collections replace, they do not merge.** Calling `set_property` or
//! `add_label` even once means the commit sends the accumulated set as the
//! resource's complete set, discarding whatever it held before. This mirrors
//! the underlying API. To add a label while keeping the others, read the
//! existing ones back first and re-add them all. Fields never touched are left
//! alone.

use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::strings::c_str_to_string;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicI32, Ordering};

pub type UpdateHandle = i32;

/// Accumulated edits. `None` means "leave this field alone"; `Some` means
/// "replace it with this".
#[derive(Default, Clone)]
pub(crate) struct UpdateStaging {
    pub name: Option<String>,
    pub description: Option<String>,
    pub properties: Option<HashMap<String, String>>,
    pub labels: Option<Vec<String>>,
    pub start_nanos: Option<i64>,
    pub end_nanos: Option<i64>,
}

static NEXT_UPDATE_HANDLE: AtomicI32 = AtomicI32::new(1);
static UPDATES: Lazy<Mutex<HashMap<UpdateHandle, UpdateStaging>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Take a snapshot of a staging object. Commit functions use this; the staging
/// object itself survives so the caller still frees it explicitly.
pub(crate) fn snapshot(
    handle: UpdateHandle,
    error_out: *mut ErrorHandle,
) -> Result<UpdateStaging, ErrorCode> {
    UPDATES.lock().get(&handle).cloned().ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown update handle {handle}"),
        )
    })
}

fn with_staging<F>(
    handle: UpdateHandle,
    error_out: *mut ErrorHandle,
    edit: F,
) -> Result<(), ErrorCode>
where
    F: FnOnce(&mut UpdateStaging),
{
    let mut updates = UPDATES.lock();
    match updates.get_mut(&handle) {
        Some(staging) => {
            edit(staging);
            Ok(())
        }
        None => Err(fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown update handle {handle}"),
        )),
    }
}

/// Drop every staged update. Used by shutdown.
pub(crate) fn clear_updates() {
    UPDATES.lock().clear();
}

/// Begin accumulating an update. Release it with `nominal_update_free`;
/// committing does not consume it, so one staging object can be applied to
/// several resources.
#[no_mangle]
pub extern "C" fn nominal_update_begin(
    out_update: *mut UpdateHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_update, error_out, "out_update")?;

        let handle = NEXT_UPDATE_HANDLE
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
            .unwrap_or(0);
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "update handle space exhausted",
            ));
        }

        UPDATES.lock().insert(handle, UpdateStaging::default());
        unsafe { *out_update = handle };
        Ok(())
    })
}

/// Release a staging object. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_update_free(handle: UpdateHandle) -> i32 {
    UPDATES.lock().remove(&handle);
    ErrorCode::Success as i32
}

/// Stage a new name.
#[no_mangle]
pub extern "C" fn nominal_update_set_name(
    handle: UpdateHandle,
    name: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let value = unsafe { c_str_to_string(name, "name", error_out)? };
        with_staging(handle, error_out, |s| s.name = Some(value))
    })
}

/// Stage a new description.
#[no_mangle]
pub extern "C" fn nominal_update_set_description(
    handle: UpdateHandle,
    description: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let value = unsafe { c_str_to_string(description, "description", error_out)? };
        with_staging(handle, error_out, |s| s.description = Some(value))
    })
}

/// Add a property to the staged set.
///
/// Calling this at all replaces the resource's entire property map on commit.
/// Repeating a key overwrites the earlier value.
#[no_mangle]
pub extern "C" fn nominal_update_set_property(
    handle: UpdateHandle,
    key: *const c_char,
    value: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let key = unsafe { c_str_to_string(key, "key", error_out)? };
        let value = unsafe { c_str_to_string(value, "value", error_out)? };
        with_staging(handle, error_out, |s| {
            s.properties
                .get_or_insert_with(HashMap::new)
                .insert(key, value);
        })
    })
}

/// Add a label to the staged set.
///
/// Calling this at all replaces the resource's entire label set on commit.
#[no_mangle]
pub extern "C" fn nominal_update_add_label(
    handle: UpdateHandle,
    label: *const c_char,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let label = unsafe { c_str_to_string(label, "label", error_out)? };
        with_staging(handle, error_out, |s| {
            s.labels.get_or_insert_with(Vec::new).push(label);
        })
    })
}

/// Clear the staged property set, so commit sends an empty map.
///
/// Distinct from never touching properties, which leaves them untouched.
#[no_mangle]
pub extern "C" fn nominal_update_clear_properties(
    handle: UpdateHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        with_staging(handle, error_out, |s| s.properties = Some(HashMap::new()))
    })
}

/// Clear the staged label set, so commit sends an empty set.
#[no_mangle]
pub extern "C" fn nominal_update_clear_labels(
    handle: UpdateHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        with_staging(handle, error_out, |s| s.labels = Some(Vec::new()))
    })
}

/// Stage a start time, in nanoseconds since the Unix epoch. `0` means now.
///
/// Ignored by resources that have no start time.
#[no_mangle]
pub extern "C" fn nominal_update_set_start(
    handle: UpdateHandle,
    nanos: i64,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        with_staging(handle, error_out, |s| s.start_nanos = Some(nanos))
    })
}

/// Stage an end time, in nanoseconds since the Unix epoch. `0` means now.
///
/// Ignored by resources that have no end time.
#[no_mangle]
pub extern "C" fn nominal_update_set_end(
    handle: UpdateHandle,
    nanos: i64,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        with_staging(handle, error_out, |s| s.end_nanos = Some(nanos))
    })
}
