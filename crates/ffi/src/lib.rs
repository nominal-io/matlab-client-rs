//! C ABI bindings for the Nominal API.
//!
//! # Conventions
//!
//! **Every function returns `int32_t`**, where 0 is success and non-zero is an
//! `ErrorCode`. Results come back through out-parameters, never the return
//! value.
//!
//! **Failures also deposit an error handle** in the trailing `error_out`
//! parameter, carrying a human-readable message. Read it with
//! `nominal_error_message` and release it with `nominal_error_free` — errors
//! are not freed for you, and a caller that only checks status codes will leak
//! them.
//!
//! On success `error_out` is set to 0, and 0 is never a valid error handle. So
//! `if (err != 0) { ...; nominal_error_free(err); }` is always correct, with no
//! free needed on the success path and no need to consult the return value
//! first.
//!
//! **Resources are `int32_t` handles**, not pointers: keys into registries
//! owned by this library. Handle 0 is never issued. Every handle needs a
//! matching `_free`; freeing an unknown handle is a no-op and using one fails
//! cleanly with `InvalidHandle` rather than corrupting memory.
//!
//! **Strings out** are string handles — see [`strings`]. **Strings in** are
//! ordinary NUL-terminated C strings, copied on arrival.
//!
//! **Timestamps** are `int64_t` nanoseconds since the Unix epoch, with `0`
//! meaning "now" for single instants. See [`time`].
//!
//! Every exported function catches panics, since unwinding across an
//! `extern "C"` boundary is undefined behavior.
//!
//! **Call `nominal_shutdown` before unloading the library.** The Tokio runtime
//! owns worker threads that would otherwise outlive the unmapped module and
//! crash the host. See [`runtime`].

// Exported functions take raw pointers because that is the C ABI. They are
// never called from Rust, and every pointer is checked before use, so marking
// them `unsafe` would add noise at call sites without adding safety.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod error;
pub mod runtime;
pub mod strings;
pub mod time;
pub mod update;

#[macro_use]
mod handles;

pub mod asset;
pub mod buffer;
pub mod channelmetadata;
pub mod client;
pub mod compute;
pub mod dataset;
pub mod event;
pub mod export;
pub mod ingest;
pub mod run;
pub mod sql;
pub mod stream;
pub mod streamchannel;
pub mod write;

/// Drop every live resource handle.
///
/// Kept here rather than in `runtime` so that adding a resource module means
/// adding one line in the one place that enumerates them, instead of a
/// silently-missed registry that leaks across a shutdown.
pub(crate) fn clear_all_registries() {
    // Buffers then streams: uncommitted rows are dropped, then dropping a
    // stream flushes what it holds, which needs the runtime still standing.
    buffer::clear_buffers();
    stream::clear_streams();
    streamchannel::clear_streamchannels();
    client::clear_clients();
    asset::clear_assets();
    asset::clear_asset_lists();
    dataset::clear_datasets();
    dataset::clear_dataset_lists();
    run::clear_runs();
    event::clear_events();
    event::clear_event_services();
    write::clear_write_services();
    export::clear_export_services();
    sql::clear_sql_results();
    sql::clear_sql_channels();
    compute::clear_compute_series();
    compute::clear_compute_services();
    ingest::clear_ingest_jobs();
    channelmetadata::clear_channelmetadata();
    channelmetadata::clear_channelmetadata_lists();
    update::clear_updates();
    strings::clear_strings();
    error::clear_errors();
}
