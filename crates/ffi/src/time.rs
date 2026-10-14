//! Timestamps.
//!
//! Every timestamp crossing the boundary is an `int64_t` count of nanoseconds
//! since the Unix epoch, taken literally: `0` is 1970-01-01T00:00:00Z.
//!
//! There is no "now" sentinel. Simulation output is commonly stored at a
//! shared time zero, so a run or event at the epoch is a real request, and a
//! sentinel of 0 silently turned it into the current time. A caller wanting
//! now reads [`nominal_timestamp_now`] and passes that.

use crate::error::{fail, ErrorCode, ErrorHandle};
use chrono::{DateTime, Utc};

/// Current time as nanoseconds since the Unix epoch, at the finest resolution
/// the host clock provides.
#[no_mangle]
pub extern "C" fn nominal_timestamp_now() -> i64 {
    crate::error::guard_value(0, || Utc::now().timestamp_nanos_opt().unwrap_or(0))
}

/// Convert nanoseconds since the epoch into a `DateTime`.
pub(crate) fn instant_from_nanos(nanos: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_nanos(nanos)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_is_the_epoch_not_now() {
        assert_eq!(instant_from_nanos(0), DateTime::UNIX_EPOCH);
    }

    #[test]
    fn nanoseconds_round_trip() {
        let mut err = 0;
        let nanos = 1_791_285_485_599_200_123;
        assert_eq!(
            nanos_from_instant(&instant_from_nanos(nanos), &mut err),
            Ok(nanos)
        );
    }
}
