//! Timestamps.
//!
//! Every timestamp crossing the boundary is an `int64_t` count of nanoseconds
//! since the Unix epoch.
//!
//! For single-instant parameters — a run's start or end, an event's timestamp —
//! the value `0` means "now", resolved inside the library at the moment of the
//! call. A literal epoch instant is not a meaningful value for those fields, so
//! the sentinel costs nothing and spares callers from having to fetch the clock
//! themselves.
//!
//! Streaming data points are the deliberate exception: there, `0` is the
//! literal instant, because a stream may legitimately carry timestamps relative
//! to an epoch the caller chose.

use crate::error::{fail, ErrorCode, ErrorHandle};
use chrono::{DateTime, Utc};

/// Current time as nanoseconds since the Unix epoch, at the finest resolution
/// the host clock provides.
#[no_mangle]
pub extern "C" fn nominal_timestamp_now() -> i64 {
    crate::error::guard_value(0, || Utc::now().timestamp_nanos_opt().unwrap_or(0))
}

/// Convert nanoseconds since the epoch into a `DateTime`, treating `0` as now.
pub(crate) fn instant_from_nanos(nanos: i64) -> DateTime<Utc> {
    if nanos == 0 {
        Utc::now()
    } else {
        DateTime::from_timestamp_nanos(nanos)
    }
}

/// Convert a `DateTime` back to nanoseconds since the epoch.
///
/// Fails only for instants outside roughly 1677–2262, which the API cannot
/// represent in this form.
pub(crate) fn nanos_from_instant(
    instant: &DateTime<Utc>,
    error_out: *mut ErrorHandle,
) -> Result<i64, ErrorCode> {
    instant.timestamp_nanos_opt().ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::NominalError,
            format!("timestamp {instant} is out of nanosecond range"),
        )
    })
}
