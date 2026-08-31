//! String handles.
//!
//! Strings leaving the library do not cross the boundary as C strings. They
//! are held in a registry and referenced by an `int32_t` handle, and the caller
//! copies the bytes out on its own schedule:
//!
//! ```c
//! int32_t s; nominal_string_alloc(&s);
//! nominal_asset_name(asset, s, &err);           // the expensive call, once
//! uint32_t n = nominal_string_length(s);
//! char* buf = malloc(n + 1);
//! nominal_copy_string_from_reference(s, buf, n + 1);
//! nominal_string_free(s);
//! ```
//!
//! This keeps the size query away from the call that does real work: a
//! too-small buffer costs a second memcpy, not a second API round trip. The
//! byte length is authoritative — a NUL is written only as a convenience when
//! the buffer has room to spare.
//!
//! Strings entering the library are plain NUL-terminated C strings. They are
//! copied on arrival and the caller's pointer is never retained.

use crate::error::{fail, guard_value, ErrorCode, ErrorHandle};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicI32, Ordering};

pub type StringHandle = i32;

static NEXT_STRING_HANDLE: AtomicI32 = AtomicI32::new(1);
static STRING_REGISTRY: Lazy<Mutex<HashMap<StringHandle, String>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Store a value into an existing string handle, replacing whatever it held.
///
/// Every getter ends with this call, which is what makes them all share one
/// signature.
pub(crate) fn set_string(
    handle: StringHandle,
    value: impl Into<String>,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let mut registry = STRING_REGISTRY.lock();
    match registry.get_mut(&handle) {
        Some(slot) => {
            *slot = value.into();
            Ok(())
        }
        None => Err(fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown string handle {handle}"),
        )),
    }
}

/// Drop every string handle. Used by shutdown.
pub(crate) fn clear_strings() {
    STRING_REGISTRY.lock().clear();
}

/// Read a caller-provided C string into an owned `String`, trimming
/// surrounding whitespace.
///
/// Trimming is the default because almost every string entering this library is
/// an identifier — a token, a RID, a name, a tag — and leading or trailing
/// whitespace on one is invariably an accident of copy-paste rather than
/// intent. A token with a stray CRLF should authenticate, not fail with an
/// error that gives no hint the two strings differ.
///
/// Use [`c_str_to_string_exact`] for anything that is *data*, where whitespace
/// may be meaningful.
///
/// # Safety
/// `ptr` must be NULL or point to a NUL-terminated buffer valid for the
/// duration of the call.
pub(crate) unsafe fn c_str_to_string(
    ptr: *const c_char,
    name: &str,
    error_out: *mut ErrorHandle,
) -> Result<String, ErrorCode> {
    c_str_to_string_exact(ptr, name, error_out).map(|s| s.trim().to_owned())
}

/// Read a caller-provided C string verbatim, preserving whitespace.
///
/// For values the caller is storing rather than naming — a streamed string
/// sample, say — where trimming would silently corrupt their data.
///
/// # Safety
/// As [`c_str_to_string`].
pub(crate) unsafe fn c_str_to_string_exact(
    ptr: *const c_char,
    name: &str,
    error_out: *mut ErrorHandle,
) -> Result<String, ErrorCode> {
    if ptr.is_null() {
        return Err(fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("{name} must not be null"),
        ));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("{name} is not valid UTF-8"),
            )
        })
}

/// Largest index <= `limit` that does not split a UTF-8 character.
///
/// Continuation bytes match `0b10xxxxxx`; a character is at most four bytes, so
/// this walks back three positions at worst.
fn floor_char_boundary(bytes: &[u8], limit: usize) -> usize {
    let mut i = limit.min(bytes.len());
    // `i == bytes.len()` means everything fits, so there is no split to avoid
    // and no byte at `i` to inspect. Reading it would be one past the end.
    while i > 0 && i < bytes.len() && (bytes[i] & 0b1100_0000) == 0b1000_0000 {
        i -= 1;
    }
    i
}

/// Allocate an empty string handle.
///
/// One handle can be reused across any number of calls; each getter overwrites
/// whatever it held. Release it with `nominal_string_free`.
#[no_mangle]
pub extern "C" fn nominal_string_alloc(out_handle: *mut StringHandle) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        if out_handle.is_null() {
            return ErrorCode::InvalidParameter as i32;
        }
        // Stop rather than wrap: a wrapped counter would reissue a live handle.
        let Ok(handle) =
            NEXT_STRING_HANDLE.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
        else {
            return ErrorCode::NoCapacity as i32;
        };
        STRING_REGISTRY.lock().insert(handle, String::new());
        unsafe { *out_handle = handle };
        ErrorCode::Success as i32
    })
}

/// Release a string handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_string_free(handle: StringHandle) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        STRING_REGISTRY.lock().remove(&handle);
        ErrorCode::Success as i32
    })
}

/// Byte length of the string a handle holds, excluding any NUL.
///
/// Returns 0 for an unknown handle, which is indistinguishable from an empty
/// string — the originating call's status code is what tells you the handle is
/// valid.
#[no_mangle]
pub extern "C" fn nominal_string_length(handle: StringHandle) -> u32 {
    guard_value(0, || {
        STRING_REGISTRY
            .lock()
            .get(&handle)
            .map(|s| s.len() as u32)
            .unwrap_or(0)
    })
}

/// Copy a string's bytes into a caller-provided buffer.
///
/// Returns the number of bytes copied. If `buf_size` is smaller than the
/// string, as much as fits is copied, truncated at a UTF-8 character boundary
/// so the result is never invalid UTF-8 — compare the return value against
/// `nominal_string_length` to detect that. A NUL terminator is appended only
/// when the buffer has room beyond the copied bytes; the return value, not
/// `strlen`, is authoritative.
#[no_mangle]
pub extern "C" fn nominal_copy_string_from_reference(
    handle: StringHandle,
    buf: *mut c_char,
    buf_size: u32,
) -> u32 {
    guard_value(0, || {
        if buf.is_null() || buf_size == 0 {
            return 0;
        }

        let registry = STRING_REGISTRY.lock();
        let Some(value) = registry.get(&handle) else {
            return 0;
        };

        let bytes = value.as_bytes();
        let capacity = buf_size as usize;
        let copied = floor_char_boundary(bytes, capacity);

        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copied);
            // Only when there is room beyond the copied bytes; the return value
            // is what callers should trust.
            if copied < capacity {
                *buf.add(copied) = 0;
            }
        }

        copied as u32
    })
}

