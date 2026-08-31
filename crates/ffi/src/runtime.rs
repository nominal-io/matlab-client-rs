//! The Tokio runtime, and shutting it down before the library is unloaded.
//!
//! # Why this is not just a `Lazy<Runtime>`
//!
//! The runtime owns worker threads. A `static` is never dropped, so those
//! threads outlive everything — including the library itself. When a host
//! unloads the shared object (LabVIEW does this when a VI closes), the module
//! is unmapped while those threads are still parked inside it, and the next one
//! to wake executes freed memory. On Windows that takes the host process down.
//!
//! This cannot be handled in `DllMain`: `DLL_PROCESS_DETACH` runs while the
//! loader lock is held, and joining a thread there deadlocks. The only correct
//! shape is an explicit shutdown call the host makes from an ordinary thread
//! before it unloads us, which is what [`nominal_shutdown`] is for.
//!
//! In LabVIEW, wire it to the **Unreserve** callback on the Call Library
//! Function Node's Callbacks tab. That fires when the top-level VI stops, which
//! is exactly the moment before the library may be released, and it makes
//! cleanup structural rather than something each VI author has to remember.
//!
//! Shutting down is not terminal: the next call builds a fresh runtime. That
//! matters because LabVIEW's reserve/unreserve cycle repeats every time the VI
//! runs.

use crate::error::{guard_value, ErrorCode};
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use std::future::Future;
use std::time::Duration;
use tokio::runtime::Runtime;

/// How long shutdown waits for in-flight work before abandoning it. Requests
/// already in flight get a chance to finish; a wedged one does not hold the
/// host hostage.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// `None` between a shutdown and the next call that needs a runtime.
///
/// An `RwLock` rather than a `Mutex` so concurrent calls run in parallel:
/// readers share it, and shutdown takes the write lock, which by definition
/// waits for every in-flight call to return first.
static RUNTIME_CELL: Lazy<RwLock<Option<Runtime>>> = Lazy::new(|| RwLock::new(Some(build())));

fn build() -> Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .thread_name("nominal-ffi-worker")
        .build()
        .expect("failed to start Tokio runtime")
}

/// Accessor for the runtime, recreating it if a shutdown left it absent.
pub(crate) struct RuntimeAccess;

/// Reads like the runtime itself at call sites: `RUNTIME.block_on(..)`.
pub(crate) static RUNTIME: RuntimeAccess = RuntimeAccess;

impl RuntimeAccess {
    /// Run a future to completion on the shared runtime, blocking the calling
    /// thread. The caller is always a host thread, never a runtime worker, so
    /// this cannot hit Tokio's "block_on from within a runtime" panic.
    pub(crate) fn block_on<F: Future>(&self, future: F) -> F::Output {
        let guard = self.ensure();
        let runtime = guard
            .as_ref()
            .expect("runtime is present while the read lock is held");
        runtime.block_on(future)
    }

    /// Run a synchronous closure inside the runtime's context.
    ///
    /// Needed by code that constructs Tokio-aware resources without awaiting —
    /// `NominalClient::builder().build()` spawns a background task, and
    /// `tokio::spawn` panics with no ambient runtime.
    pub(crate) fn in_context<T>(&self, f: impl FnOnce() -> T) -> T {
        let guard = self.ensure();
        let runtime = guard
            .as_ref()
            .expect("runtime is present while the read lock is held");
        let _enter = runtime.enter();
        f()
    }

    /// Take a read guard that is guaranteed to hold a runtime, building one if
    /// a shutdown cleared it.
    fn ensure(&self) -> parking_lot::RwLockReadGuard<'static, Option<Runtime>> {
        loop {
            {
                let guard = RUNTIME_CELL.read();
                if guard.is_some() {
                    return guard;
                }
            }
            {
                let mut guard = RUNTIME_CELL.write();
                if guard.is_none() {
                    *guard = Some(build());
                }
            }
            // Re-check rather than trusting what we just wrote: a shutdown may
            // have landed between dropping the write lock and taking the read.
        }
    }
}

/// Release every resource this library holds and stop its worker threads.
///
/// **Call this before the host unloads the library.** Without it, the runtime's
/// threads outlive the module and crash the process on unload — see the module
/// docs for why `DllMain` cannot do this for you.
///
/// All outstanding handles are invalidated: clients, assets, datasets, and runs
/// are dropped, and any handle held across the call will report `InvalidHandle`
/// afterwards. Acquire fresh ones after a shutdown rather than reusing old.
///
/// Safe to call more than once, and safe to call having never used the library.
/// A later call transparently builds a new runtime, so this is a pause rather
/// than a one-way door — which is what LabVIEW's repeated reserve/unreserve
/// cycle needs.
///
/// Blocks until in-flight calls return, then waits up to five seconds for
/// background work before abandoning it.
#[no_mangle]
pub extern "C" fn nominal_shutdown() -> i32 {
    guard_value(ErrorCode::RuntimeError as i32, || {
        // Take the write lock first: it waits for every in-flight call to
        // return, so nothing is mid-request while we tear down.
        let mut guard = RUNTIME_CELL.write();

        if let Some(runtime) = guard.take() {
            // Drop resources inside the runtime context. Clients own hyper
            // connection pools whose teardown expects an ambient runtime.
            {
                let _enter = runtime.enter();
                crate::clear_all_registries();
            }
            runtime.shutdown_timeout(SHUTDOWN_GRACE);
        } else {
            // Already shut down; still clear anything allocated since.
            crate::clear_all_registries();
        }

        ErrorCode::Success as i32
    })
}
