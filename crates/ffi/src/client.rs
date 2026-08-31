use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use nominal::core::NominalClient;
use std::os::raw::c_char;

pub type ClientHandle = i32;

/// A client plus the token it was built from.
///
/// The token is kept because `NominalClient` does not expose the `BearerToken`
/// it holds, and streaming needs one to open a channel to Core. We were handed
/// the token in the first place, so keeping our own copy is the supported route
/// — the alternative is reaching into the SDK's internals.
///
/// `Deref` to `NominalClient` so call sites read as if the client were stored
/// directly.
pub(crate) struct ClientEntry {
    client: NominalClient,
    token: String,
}

impl ClientEntry {
    /// The bearer token, for the streaming APIs that require one explicitly.
    pub(crate) fn token(&self) -> &str {
        &self.token
    }
}

impl std::ops::Deref for ClientEntry {
    type Target = NominalClient;

    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

handle_registry!(
    CLIENTS,
    ClientEntry,
    alloc_client,
    get_client,
    free_client,
    clear_clients
);

/// Look up a client handle, or fail with a described error.
pub(crate) fn client_or_fail(
    handle: ClientHandle,
    error_out: *mut ErrorHandle,
) -> Result<std::sync::Arc<ClientEntry>, ErrorCode> {
    get_client(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown client handle {handle}"),
        )
    })
}

/// Read an optional string argument, treating both NULL and empty as absent.
///
/// LabVIEW has no convenient way to wire a null pointer: an empty string on a
/// C String Pointer terminal yields a pointer to `""`, not NULL. Without this,
/// "leave the workspace unset" would arrive as an empty RID and fail to parse,
/// which reads as though the argument were mandatory.
///
/// # Safety
/// `ptr` must be NULL or point to a NUL-terminated buffer valid for the call.
unsafe fn optional_arg(
    ptr: *const c_char,
    name: &str,
    error_out: *mut ErrorHandle,
) -> Result<Option<String>, ErrorCode> {
    if ptr.is_null() {
        return Ok(None);
    }
    let value = c_str_to_string(ptr, name, error_out)?;
    Ok(if value.is_empty() { None } else { Some(value) })
}

/// Create a client and authenticate it with a bearer token.
///
/// `workspace_rid` and `base_url` are optional: pass NULL or an empty string to
/// leave either unset. An unset base URL defaults to Nominal production, and an
/// unset workspace means the client is not scoped to one — the API does not
/// require it.
///
/// Surrounding whitespace is trimmed from all three, so a token carrying a
/// trailing newline from a copy-paste still authenticates.
///
/// The token is copied; the caller's pointer is not retained. Release the
/// result with `nominal_client_free`.
#[no_mangle]
pub extern "C" fn nominal_client_new(
    token: *const c_char,
    workspace_rid: *const c_char,
    base_url: *const c_char,
    out_client: *mut ClientHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_client, error_out, "out_client")?;

        let token = unsafe { c_str_to_string(token, "token", error_out)? };
        if token.is_empty() {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "token must not be empty",
            ));
        }
        let mut builder = NominalClient::builder(token.clone());

        if let Some(url) = unsafe { optional_arg(base_url, "base_url", error_out)? } {
            builder = builder.base_url(url);
        }
        if let Some(rid) = unsafe { optional_arg(workspace_rid, "workspace_rid", error_out)? } {
            builder = builder.workspace_rid(Some(rid));
        }

        // `build()` is synchronous but constructs hyper and tonic resources,
        // which panic unless a Tokio runtime context is active. We need the
        // context, not an executor, so enter it rather than block_on.
        // `build()` is synchronous but spawns a background task, and
        // `tokio::spawn` panics with no ambient runtime. We need the context,
        // not an executor.
        let client = RUNTIME
            .in_context(|| builder.build())
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        let handle = alloc_client(ClientEntry { client, token });
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "client handle space exhausted",
            ));
        }

        unsafe { *out_client = handle };
        Ok(())
    })
}

/// Release a client. Freeing an unknown handle is a no-op.
///
/// Resources obtained through this client remain valid; they hold no reference
/// back to it.
#[no_mangle]
pub extern "C" fn nominal_client_free(handle: ClientHandle) -> i32 {
    free_client(handle);
    ErrorCode::Success as i32
}

/// Workspace RID this client is scoped to, or the empty string if unscoped.
#[no_mangle]
pub extern "C" fn nominal_client_workspace_rid(
    handle: ClientHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(handle, error_out)?;
        set_string(out_string, client.workspace_rid().unwrap_or(""), error_out)
    })
}

/// Base API URL this client targets.
#[no_mangle]
pub extern "C" fn nominal_client_base_url(
    handle: ClientHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(handle, error_out)?;
        set_string(out_string, client.base_url(), error_out)
    })
}

/// Display name of the authenticated user.
///
/// Doubles as a cheap credential check: it round-trips to the API, so a bad
/// token surfaces here rather than at the first real call.
#[no_mangle]
pub extern "C" fn nominal_client_user_display_name(
    handle: ClientHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(handle, error_out)?;
        let user = RUNTIME
            .block_on(client.users().who_am_i())
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;
        set_string(out_string, user.display_name(), error_out)
    })
}
