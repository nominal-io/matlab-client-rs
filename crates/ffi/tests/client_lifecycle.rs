//! Client construction and the handle/string/error conventions.
//!
//! These do no network I/O: `nominal_client_new` builds a lazily-connected
//! client, so it succeeds offline. What is being checked is that the FFI layer
//! itself behaves — no panics, codes that mean something, strings that survive
//! the round trip.

use nominal_ffi::client::*;
use nominal_ffi::error::*;
use nominal_ffi::strings::*;
use std::ffi::CString;

/// Read a string handle back into a Rust `String`, the way a C caller would.
fn read_string(handle: i32) -> String {
    let len = nominal_string_length(handle) as usize;
    let mut buf = vec![0u8; len + 1];
    let copied =
        nominal_copy_string_from_reference(handle, buf.as_mut_ptr().cast(), buf.len() as u32);
    String::from_utf8_lossy(&buf[..copied as usize]).into_owned()
}

fn describe_error(err: i32) -> String {
    let s = {
        let mut h = 0;
        nominal_string_alloc(&mut h);
        h
    };
    nominal_error_message(err, s);
    let message = read_string(s);
    nominal_string_free(s);
    format!("code {}: {message}", nominal_error_code(err))
}

fn new_test_client() -> (i32, i32) {
    let token = CString::new("test-token-not-used-offline").unwrap();
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
    (status, client)
}

#[test]
fn client_new_does_not_panic_without_an_ambient_runtime() {
    // Regression: `build()` constructs hyper and tonic resources that panic
    // outside a Tokio context. It used to surface as RuntimeError(4).
    let (status, client) = new_test_client();
    assert_ne!(
        status,
        ErrorCode::RuntimeError as i32,
        "client construction panicked"
    );
    assert_eq!(status, 0, "client construction failed");
    assert_ne!(client, 0, "handle 0 must never be issued");
    nominal_client_free(client);
}

#[test]
fn base_url_round_trips_through_a_string_handle() {
    let (status, client) = new_test_client();
    assert_eq!(status, 0);

    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 0;
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);
    assert_eq!(read_string(s), "https://api.example.invalid/api");

    nominal_string_free(s);
    nominal_client_free(client);
}

#[test]
fn a_stale_handle_is_rejected_rather_than_dereferenced() {
    let (_, client) = new_test_client();
    nominal_client_free(client);

    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 0;
    let status = nominal_client_base_url(client, s, &mut err);

    assert_eq!(status, ErrorCode::InvalidHandle as i32);
    assert!(
        describe_error(err).contains(&client.to_string()),
        "error should name the offending handle: {}",
        describe_error(err)
    );

    nominal_error_free(err);
    nominal_string_free(s);
}

#[test]
fn success_clears_the_error_handle_so_no_free_is_needed() {
    let token = CString::new("test-token").unwrap();
    let base_url = CString::new("https://api.example.invalid/api").unwrap();

    // Pre-seed with a plausible-looking handle: an uninitialised or reused
    // variable is exactly the case that used to read as a real error.
    let mut err = 1;
    let mut client = 0;
    let status = nominal_client_new(
        token.as_ptr(),
        std::ptr::null(),
        base_url.as_ptr(),
        &mut client,
        &mut err,
    );

    assert_eq!(status, 0);
    assert_eq!(
        err, 0,
        "success must clear error_out, so `if (err) free(err)` is safe"
    );

    // And the same on a getter, which is the hot path where a spurious free
    // would hurt most.
    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 7;
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);
    assert_eq!(err, 0);

    nominal_string_free(s);
    nominal_client_free(client);
}

#[test]
fn surrounding_whitespace_on_arguments_is_ignored() {
    // A token pasted from a terminal or a web page routinely carries a trailing
    // newline. Failing on that gives an error indistinguishable from a genuinely
    // bad credential.
    let token = CString::new("  test-token\r\n").unwrap();
    let base_url = CString::new("\thttps://api.example.invalid/api  \n").unwrap();

    let mut client = 0;
    let mut err = 0;
    assert_eq!(
        nominal_client_new(
            token.as_ptr(),
            std::ptr::null(),
            base_url.as_ptr(),
            &mut client,
            &mut err
        ),
        0
    );

    let mut s = 0;
    nominal_string_alloc(&mut s);
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);
    assert_eq!(read_string(s), "https://api.example.invalid/api");

    nominal_string_free(s);
    nominal_client_free(client);
}

#[test]
fn an_empty_optional_argument_means_absent() {
    // LabVIEW cannot easily wire a null pointer; an empty string terminal gives
    // a pointer to "". Both must mean "unset" rather than "an empty RID".
    let token = CString::new("test-token").unwrap();
    let empty = CString::new("").unwrap();

    let mut client = 0;
    let mut err = 0;
    assert_eq!(
        nominal_client_new(
            token.as_ptr(),
            empty.as_ptr(),
            empty.as_ptr(),
            &mut client,
            &mut err
        ),
        0,
        "empty workspace_rid must not be treated as a malformed RID"
    );

    let mut s = 0;
    nominal_string_alloc(&mut s);
    assert_eq!(nominal_client_workspace_rid(client, s, &mut err), 0);
    assert_eq!(read_string(s), "", "no workspace should be set");

    // An empty base URL falls back to the default rather than an empty host.
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);
    assert!(
        read_string(s).starts_with("https://"),
        "base URL not defaulted"
    );

    nominal_string_free(s);
    nominal_client_free(client);
}

#[test]
fn an_empty_token_is_rejected() {
    let empty = CString::new("   ").unwrap();
    let mut client = 0;
    let mut err = 0;
    let status = nominal_client_new(
        empty.as_ptr(),
        std::ptr::null(),
        std::ptr::null(),
        &mut client,
        &mut err,
    );
    assert_eq!(status, ErrorCode::InvalidParameter as i32);
    nominal_error_free(err);
}

#[test]
fn a_null_out_parameter_is_rejected_rather_than_written_through() {
    let token = CString::new("t").unwrap();
    let mut err = 0;
    let status = nominal_client_new(
        token.as_ptr(),
        std::ptr::null(),
        std::ptr::null(),
        std::ptr::null_mut(),
        &mut err,
    );
    assert_eq!(status, ErrorCode::InvalidParameter as i32);
    nominal_error_free(err);
}

/// Copy into a buffer of exactly `cap` bytes, returning what was copied.
fn copy_with_capacity(handle: i32, cap: usize) -> (u32, Vec<u8>) {
    let mut buf = vec![0u8; cap];
    let copied = nominal_copy_string_from_reference(handle, buf.as_mut_ptr().cast(), cap as u32);
    (copied, buf)
}

#[test]
fn every_buffer_size_is_safe_and_yields_valid_utf8() {
    let (_, client) = new_test_client();
    let mut s = 0;
    nominal_string_alloc(&mut s);
    let mut err = 0;
    assert_eq!(nominal_client_base_url(client, s, &mut err), 0);

    let len = nominal_string_length(s) as usize;
    assert!(len > 0);

    // Regression: capacity == len indexed one past the end of the string,
    // panicking through the extern "C" boundary. Every size from 0 to len+2
    // must be safe, and the bytes handed back must always be valid UTF-8.
    for cap in 0..=len + 2 {
        let (copied, buf) = copy_with_capacity(s, cap);
        assert!(
            std::str::from_utf8(&buf[..copied as usize]).is_ok(),
            "cap {cap}: truncation produced invalid UTF-8"
        );
        // Asserting the exact count, not just an upper bound: the panic guard
        // turns the out-of-bounds bug into a silent 0, which an upper-bound
        // assertion would happily accept.
        let expected = cap.min(len);
        assert_eq!(
            copied as usize, expected,
            "cap {cap}: expected {expected} bytes, got {copied}"
        );
    }

    // A buffer with room to spare gets the whole string.
    let (copied, _) = copy_with_capacity(s, len + 1);
    assert_eq!(copied as usize, len);

    nominal_string_free(s);
    nominal_client_free(client);
}

#[test]
fn multibyte_characters_are_never_split() {
    let mut s = 0;
    nominal_string_alloc(&mut s);
    // Deliberately awkward: 3-byte and 4-byte characters, so most cut points
    // land mid-character.
    let value = "\u{20AC}\u{1F600}\u{20AC}"; // euro, emoji, euro
    let err = {
        let mut e = 0;
        let token = CString::new("t").unwrap();
        let mut c = 0;
        // Reuse an error message as a vehicle for arbitrary string content.
        nominal_client_new(
            token.as_ptr(),
            std::ptr::null(),
            CString::new(value).unwrap().as_ptr(),
            &mut c,
            &mut e,
        );
        e
    };
    assert_ne!(err, 0, "expected an invalid base URL to fail");
    nominal_error_message(err, s);

    let len = nominal_string_length(s) as usize;
    for cap in 0..=len + 1 {
        let (copied, buf) = copy_with_capacity(s, cap);
        assert!(
            std::str::from_utf8(&buf[..copied as usize]).is_ok(),
            "cap {cap}: split a multi-byte character"
        );
    }

    nominal_error_free(err);
    nominal_string_free(s);
}
