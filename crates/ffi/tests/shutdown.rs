//! Shutdown behaviour.
//!
//! These run in their own test binary because shutdown is process-global —
//! interleaving them with other tests would tear down state those tests are
//! using. Within this file they run single-threaded for the same reason.

use nominal_ffi::client::*;
use nominal_ffi::error::*;
use nominal_ffi::runtime::nominal_shutdown;
use nominal_ffi::strings::*;
use std::ffi::CString;

fn new_client() -> i32 {
    let token = CString::new("test-token").unwrap();
    let base_url = CString::new("https://api.example.invalid/api").unwrap();
    let mut client = 0;
    let mut err = 0;
    let status = nominal_client_new(
        token.as_ptr(),
        std::ptr::null(),
        base_url.as_ptr(),
        &mut client,
        &mut err,
    );
    assert_eq!(status, 0, "client construction failed");
    client
}

#[test]
fn shutdown_cycle() {
    // Single test function: shutdown is global, so these must not interleave.

    // --- A shutdown invalidates outstanding handles ---------------------
    let client = new_client();
    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 0;
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);

    assert_eq!(nominal_shutdown(), 0);

    let status = nominal_client_base_url(client, s, &mut err);
    assert_eq!(
        status,
        ErrorCode::InvalidHandle as i32,
        "a handle held across shutdown must be rejected, not used"
    );
    nominal_error_free(err);

    // --- The runtime comes back for the next reserve/unreserve cycle ----
    // LabVIEW unreserves when a VI stops and reserves again when it reruns, so
    // shutdown has to be a pause rather than a one-way door.
    let client = new_client();
    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 0;
    assert_eq!(
        nominal_client_base_url(client, s, &mut err),
        0,
        "library unusable after a shutdown"
    );
    let len = nominal_string_length(s) as usize;
    let mut buf = vec![0u8; len + 1];
    let copied = nominal_copy_string_from_reference(s, buf.as_mut_ptr().cast(), buf.len() as u32);
    assert_eq!(
        String::from_utf8_lossy(&buf[..copied as usize]),
        "https://api.example.invalid/api"
    );

    // --- Repeated shutdowns are harmless --------------------------------
    assert_eq!(nominal_shutdown(), 0);
    assert_eq!(nominal_shutdown(), 0);
    assert_eq!(nominal_shutdown(), 0);

    // --- And it still works afterwards ----------------------------------
    let client = new_client();
    nominal_client_free(client);
    assert_eq!(nominal_shutdown(), 0);
}
