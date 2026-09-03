//! Events: time-based annotations on assets.
//!
//! An event flags a moment or interval worth looking at — a fault, a phase
//! boundary, an anomaly. It carries a name, a type, a timestamp, a duration,
//! and attaches to one or more **assets**. Not to runs or datasets: the API
//! keys events by asset RID, and a run simply shows the events whose time falls
//! inside it.
//!
//! # Why this module builds its own client
//!
//! Every other resource here goes through the `nominal` crate. That crate does
//! not wrap events, so this one talks to `nominal-api` directly.
//!
//! It needs no new dependency to do so: `nominal-streaming`, which we already
//! depend on, re-exports both `nominal-api` and the conjure runtime. Going
//! through those re-exports also means the versions cannot drift from what the
//! rest of the build uses — we get whatever `nominal-streaming` got.
//!
//! The client is built once and cached, because constructing one sets up a
//! connection pool that would otherwise be rebuilt per call.
//!
//! When the `nominal` crate grows event support, this module should collapse
//! into a thin wrapper over it like the others.

use crate::client::{client_or_fail, ClientHandle};
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use crate::time::instant_from_nanos;

use nominal_streaming::api::clients::event::{AsyncEventService, AsyncEventServiceClient};
use nominal_streaming::api::objects::api::{Label, PropertyName, PropertyValue, Timestamp};
use nominal_streaming::api::objects::event::{CreateEvent, Event, EventType};
use nominal_streaming::api::objects::scout::rids::api::AssetRid;
use nominal_streaming::api::objects::scout::run::api::Duration;
// `AsyncService` is what provides `new` on the generated service clients.
use nominal_streaming::client::conjure::http::client::{AsyncService, ConjureRuntime};
use nominal_streaming::client::conjure::object::SafeLong;
use nominal_streaming::client::conjure::runtime::{Agent, Client, UserAgent};
use nominal_streaming::prelude::{BearerToken, ResourceIdentifier};

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::os::raw::c_char;
use std::sync::Arc;

pub type EventHandle = i32;

handle_registry!(
    EVENTS,
    Event,
    alloc_event,
    get_event,
    free_event_entry,
    clear_events
);

/// Event types, as an `int32`. Mirrors the API's own vocabulary.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Info = 0,
    Flag = 1,
    Error = 2,
    Success = 3,
}

fn kind_from_code(code: i32, error_out: *mut ErrorHandle) -> Result<EventType, ErrorCode> {
    Ok(match code {
        0 => EventType::Info,
        1 => EventType::Flag,
        2 => EventType::Error,
        3 => EventType::Success,
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("unknown event type code {other}; expected 0-3"),
            ))
        }
    })
}

fn kind_to_code(kind: &EventType) -> i32 {
    match kind {
        EventType::Info => Kind::Info as i32,
        EventType::Flag => Kind::Flag as i32,
        EventType::Error => Kind::Error as i32,
        EventType::Success => Kind::Success as i32,
        // A type this client does not model. Reported as Info rather than
        // failing: the event is real and readable, only its type is unfamiliar.
        _ => Kind::Info as i32,
    }
}

/// One event-service client per base URL.
///
/// Keyed by URL because a process may hold clients against several deployments.
/// Conjure clients are shared handles and cheap to clone, but building one sets
/// up a connection pool, so this is built once rather than per call.
static SERVICES: Lazy<Mutex<HashMap<String, AsyncEventServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached service clients. Used by shutdown.
pub(crate) fn clear_event_services() {
    SERVICES.lock().clear();
}

fn service_for(
    base_url: &str,
    error_out: *mut ErrorHandle,
) -> Result<AsyncEventServiceClient<Client>, ErrorCode> {
    if let Some(existing) = SERVICES.lock().get(base_url) {
        return Ok(existing.clone());
    }

    let uri = base_url.try_into().map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid base URL {base_url:?}: {e:?}"),
        )
    })?;

    // Building the client sets up hyper resources, which panic without an
    // ambient runtime — the same trap as NominalClient::build.
    let client = RUNTIME.in_context(|| {
        Client::builder()
            .service("nominal-ffi-events")
            .user_agent(UserAgent::new(Agent::new(
                "nominal-ffi",
                env!("CARGO_PKG_VERSION"),
            )))
            .uri(uri)
            .build()
    });
    // conjure's Error implements Debug but not Display.
    let client = client.map_err(|e| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("could not build event client: {e:?}"),
        )
    })?;

    let service = AsyncEventServiceClient::new(client, &Arc::new(ConjureRuntime::default()));
    SERVICES.lock().insert(base_url.to_owned(), service.clone());
    Ok(service)
}

pub(crate) fn event_or_fail(
    handle: EventHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<Event>, ErrorCode> {
    get_event(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown event handle {handle}"),
        )
    })
}

/// Split a nanosecond count into the seconds/nanos pair the API uses.
fn split_nanos(nanos: i64) -> (i64, i64) {
    // Euclidean, so instants before the epoch do not produce a negative
    // remainder, which the API rejects.
    (
        nanos.div_euclid(1_000_000_000),
        nanos.rem_euclid(1_000_000_000),
    )
}

fn safe_long(value: i64, what: &str, error_out: *mut ErrorHandle) -> Result<SafeLong, ErrorCode> {
    SafeLong::try_from(value).map_err(|_| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("{what} is outside the range the API can represent"),
        )
    })
}

/// Create an event on one or more assets.
///
/// `asset_rids` is an array of `asset_count` NUL-terminated RID strings. At
/// least one is required — an event with no asset is not created.
///
/// `timestamp_nanos` is nanoseconds since the epoch, with `0` meaning now.
/// `duration_nanos` is how long the event spans; pass `0` for an instantaneous
/// event.
///
/// `event_type` is 0 info, 1 flag, 2 error, 3 success.
///
/// Release the result with `nominal_event_free`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nominal_event_create(
    client_handle: ClientHandle,
    asset_rids: *const *const c_char,
    asset_count: u32,
    name: *const c_char,
    event_type: i32,
    timestamp_nanos: i64,
    duration_nanos: i64,
    out_event: *mut EventHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_event, error_out, "out_event")?;
        let client = client_or_fail(client_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };
        let kind = kind_from_code(event_type, error_out)?;

        if asset_rids.is_null() || asset_count == 0 {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "at least one asset RID is required; an event with no asset is not created",
            ));
        }

        let raw = unsafe { std::slice::from_raw_parts(asset_rids, asset_count as usize) };
        let mut assets = BTreeSet::new();
        for (index, &ptr) in raw.iter().enumerate() {
            let rid = unsafe { c_str_to_string(ptr, &format!("asset_rids[{index}]"), error_out)? };
            let parsed = ResourceIdentifier::new(&rid).map_err(|e| {
                fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!("asset_rids[{index}] is not a valid RID ({rid:?}): {e}"),
                )
            })?;
            assets.insert(AssetRid(parsed));
        }

        let instant = instant_from_nanos(timestamp_nanos);
        let nanos = instant.timestamp_nanos_opt().ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                "timestamp is outside the representable range",
            )
        })?;
        let (ts_seconds, ts_nanos) = split_nanos(nanos);
        let (dur_seconds, dur_nanos) = split_nanos(duration_nanos.max(0));

        // A staged builder: the required fields must be set first, in the
        // order they are declared, before any optional one is reachable.
        let request = CreateEvent::builder()
            .timestamp(Timestamp::new(
                safe_long(ts_seconds, "timestamp seconds", error_out)?,
                safe_long(ts_nanos, "timestamp nanos", error_out)?,
            ))
            .duration(Duration::new(
                safe_long(dur_seconds, "duration seconds", error_out)?,
                safe_long(dur_nanos, "duration nanos", error_out)?,
            ))
            .name(name)
            .type_(kind)
            .extend_asset_rids(assets)
            .build();

        let token = BearerToken::new(client.token()).map_err(|e| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("invalid bearer token: {e}"),
            )
        })?;
        let service = service_for(client.base_url(), error_out)?;

        let event = RUNTIME
            .block_on(async { service.create_event(&token, &request).await })
            .map_err(|e| fail(error_out, ErrorCode::NominalError, format!("{e:?}")))?;

        let handle = alloc_event(event);
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "event handle space exhausted",
            ));
        }
        unsafe { *out_event = handle };
        Ok(())
    })
}

/// Release an event handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_event_free(handle: EventHandle) -> i32 {
    free_event_entry(handle);
    ErrorCode::Success as i32
}

/// RID of the event.
#[no_mangle]
pub extern "C" fn nominal_event_rid(
    handle: EventHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let event = event_or_fail(handle, error_out)?;
        set_string(out_string, event.rid().to_string(), error_out)
    })
}

/// Event name.
#[no_mangle]
pub extern "C" fn nominal_event_name(
    handle: EventHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let event = event_or_fail(handle, error_out)?;
        set_string(out_string, event.name(), error_out)
    })
}

/// Event type: 0 info, 1 flag, 2 error, 3 success.
#[no_mangle]
pub extern "C" fn nominal_event_type(
    handle: EventHandle,
    out_type: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_type, error_out, "out_type")?;
        let event = event_or_fail(handle, error_out)?;
        unsafe { *out_type = kind_to_code(event.type_()) };
        Ok(())
    })
}

/// When the event occurred, in nanoseconds since the epoch.
#[no_mangle]
pub extern "C" fn nominal_event_timestamp(
    handle: EventHandle,
    out_nanos: *mut i64,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_nanos, error_out, "out_nanos")?;
        let event = event_or_fail(handle, error_out)?;
        let ts = event.timestamp();
        let nanos = *ts.seconds() * 1_000_000_000 + *ts.nanos();
        unsafe { *out_nanos = nanos };
        Ok(())
    })
}

/// How long the event spans, in nanoseconds. Zero for an instant.
#[no_mangle]
pub extern "C" fn nominal_event_duration(
    handle: EventHandle,
    out_nanos: *mut i64,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_nanos, error_out, "out_nanos")?;
        let event = event_or_fail(handle, error_out)?;
        let d = event.duration();
        let nanos = *d.seconds() * 1_000_000_000 + *d.nanos();
        unsafe { *out_nanos = nanos };
        Ok(())
    })
}

/// Number of assets this event is attached to.
#[no_mangle]
pub extern "C" fn nominal_event_asset_count(
    handle: EventHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_count, error_out, "out_count")?;
        let event = event_or_fail(handle, error_out)?;
        unsafe { *out_count = event.asset_rids().len() as u32 };
        Ok(())
    })
}

/// Asset RID at `index`, in sorted order.
#[no_mangle]
pub extern "C" fn nominal_event_asset_at(
    handle: EventHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let event = event_or_fail(handle, error_out)?;
        // A BTreeSet, so iteration order is already sorted and stable.
        let rid = event
            .asset_rids()
            .iter()
            .nth(index as usize)
            .ok_or_else(|| {
                fail(
                    error_out,
                    ErrorCode::InvalidParameter,
                    format!(
                        "asset index {index} out of range ({} attached)",
                        event.asset_rids().len()
                    ),
                )
            })?;
        set_string(out_string, rid.0.as_str(), error_out)
    })
}

/// Suppress unused-import warnings for the property/label types, which are
/// wired up once event updates are exposed.
#[allow(dead_code)]
fn _reserved(_: BTreeMap<PropertyName, PropertyValue>, _: BTreeSet<Label>) {}
