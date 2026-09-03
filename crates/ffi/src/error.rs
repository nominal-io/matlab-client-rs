use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Success = 0,
    InvalidHandle = 1,
    InvalidParameter = 2,
    NominalError = 3,
    RuntimeError = 4,
    BufferTooSmall = 5,
    NoCapacity = 6,
}

pub struct ErrorObject {
    code: ErrorCode,
    message: String,
}

pub type ErrorHandle = i32;

static NEXT_ERROR_HANDLE: AtomicI32 = AtomicI32::new(1);
static ERROR_REGISTRY: Lazy<Mutex<HashMap<ErrorHandle, Arc<ErrorObject>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn allocate_error(code: ErrorCode, message: impl Into<String>) -> ErrorHandle {
    let handle = NEXT_ERROR_HANDLE.fetch_add(1, Ordering::SeqCst);
    ERROR_REGISTRY.lock().insert(
        handle,
        Arc::new(ErrorObject {
            code,
            message: message.into(),
        }),
    );
    handle
}

fn get_error(handle: ErrorHandle) -> Option<Arc<ErrorObject>> {
    ERROR_REGISTRY.lock().get(&handle).cloned()
}

/// Drop every error object. Used by shutdown, which also mops up the errors a
/// caller never freed.
pub(crate) fn clear_errors() {
    ERROR_REGISTRY.lock().clear();
}

/// Record a failure: allocate an error object, hand its handle to the caller
/// through `error_out` (if provided), and return the code to propagate.
///
/// The handle is the caller's to free with `nominal_error_free`.
pub(crate) fn fail(
    error_out: *mut ErrorHandle,
    code: ErrorCode,
    message: impl Into<String>,
) -> ErrorCode {
    let handle = allocate_error(code, message);
    if !error_out.is_null() {
        unsafe { *error_out = handle };
    }
    code
}

/// Wrap an exported function body: catches panics (unwinding across an
/// `extern "C"` boundary is undefined behavior) and converts the result into
/// the uniform `i32` status code every function returns.
pub(crate) fn ffi_guard<F>(error_out: *mut ErrorHandle, f: F) -> i32
where
    F: FnOnce() -> Result<(), ErrorCode>,
{
    // Clear before running, so success always leaves 0 rather than whatever the
    // caller's variable happened to hold. Without this the caller cannot tell
    // "no error" from "stale value" by looking at the handle, and would have to
    // consult the return value first — a rule that is easy to get wrong and
    // impossible to notice getting wrong. Handle 0 is never issued, so it is an
    // unambiguous "nothing here".
    if !error_out.is_null() {
        unsafe { *error_out = 0 };
    }

    match std::panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => ErrorCode::Success as i32,
        Ok(Err(code)) => code as i32,
        Err(payload) => {
            let detail = panic_message(&payload);
            fail(
                error_out,
                ErrorCode::RuntimeError,
                format!("panic: {detail}"),
            ) as i32
        }
    }
}

/// Panic guard for exported functions that return a value rather than a status
/// code, yielding `fallback` if the body panics.
///
/// Unwinding across an `extern "C"` boundary is undefined behavior, so this is
/// required on every exported function — not only the ones that can report an
/// error. `parking_lot` mutexes do not poison, so a panic mid-lock releases it
/// rather than corrupting every later call.
pub(crate) fn guard_value<T, F>(fallback: T, f: F) -> T
where
    F: FnOnce() -> T,
{
    std::panic::catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

/// Recover the text a panic carried.
///
/// `panic!` payloads are `&'static str` for literal messages and `String` for
/// formatted ones; anything else is opaque. Without this the caller gets
/// "something panicked" and no way to tell which of a dozen causes it was.
fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_owned()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic payload".to_owned()
    }
}

/// Reject a NULL out-parameter before writing through it.
pub(crate) fn require_out<T>(
    ptr: *mut T,
    error_out: *mut ErrorHandle,
    name: &str,
) -> Result<(), ErrorCode> {
    if ptr.is_null() {
        return Err(fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("{name} must not be null"),
        ));
    }
    Ok(())
}

/// Get the error code carried by an error handle.
///
/// Returns 0 for an unknown handle, which is indistinguishable from Success —
/// check the originating function's return value, not this, to detect failure.
#[no_mangle]
pub extern "C" fn nominal_error_code(handle: ErrorHandle) -> i32 {
    guard_value(0, || get_error(handle).map(|e| e.code as i32).unwrap_or(0))
}

/// Write an error's message into a string handle.
///
/// Follows the same shape as every other getter, so reading an error is not a
/// special case. Allocate one string handle at startup and reuse it:
///
/// ```c
/// if (nominal_asset_name(asset, name, &err) != 0) {
///     nominal_error_message(err, msg);
///     nominal_error_free(err);
/// }
/// ```
#[no_mangle]
pub extern "C" fn nominal_error_message(
    handle: ErrorHandle,
    out_string: crate::strings::StringHandle,
) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        match get_error(handle) {
            // No error_out here: reporting a failure to read a failure would
            // just allocate another error to leak.
            Some(err) => {
                match crate::strings::set_string(
                    out_string,
                    err.message.clone(),
                    std::ptr::null_mut(),
                ) {
                    Ok(()) => ErrorCode::Success as i32,
                    Err(code) => code as i32,
                }
            }
            None => ErrorCode::InvalidHandle as i32,
        }
    })
}

/// Release an error handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_error_free(handle: ErrorHandle) -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        ERROR_REGISTRY.lock().remove(&handle);
        ErrorCode::Success as i32
    })
}
