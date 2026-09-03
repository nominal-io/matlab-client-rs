//! Handle registries.
//!
//! Resources are referenced across the boundary by `int32_t` handles rather
//! than pointers. A handle is a key into a registry owned by this library, so
//! its width is independent of the target's pointer size — the same value works
//! in the 32- and 64-bit builds — and a stale handle fails a lookup instead of
//! dereferencing freed memory.
//!
//! Handle 0 is never issued, so it is always safe to use as a null sentinel.

/// Generate a registry plus its `alloc` / `get` / `free` functions for one
/// resource type.
///
/// ```ignore
/// handle_registry!(ASSETS, nominal::core::Asset, alloc_asset, get_asset, free_asset);
/// ```
macro_rules! handle_registry {
    ($registry:ident, $ty:ty, $alloc:ident, $get:ident, $free:ident, $clear:ident) => {
        static $registry: once_cell::sync::Lazy<
            parking_lot::Mutex<std::collections::HashMap<i32, std::sync::Arc<$ty>>>,
        > = once_cell::sync::Lazy::new(
            || parking_lot::Mutex::new(std::collections::HashMap::new()),
        );

        /// Returns 0 if the handle space is exhausted; callers must treat 0 as
        /// a failure rather than a handle.
        pub(crate) fn $alloc(value: $ty) -> i32 {
            use std::sync::atomic::{AtomicI32, Ordering};
            static NEXT: AtomicI32 = AtomicI32::new(1);
            // Stop at i32::MAX rather than wrapping: a wrapped counter would
            // eventually reissue a live handle and silently alias two objects.
            let handle = NEXT
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
                .unwrap_or(0);
            if handle == 0 {
                return 0;
            }
            $registry.lock().insert(handle, std::sync::Arc::new(value));
            handle
        }

        pub(crate) fn $get(handle: i32) -> Option<std::sync::Arc<$ty>> {
            $registry.lock().get(&handle).cloned()
        }

        pub(crate) fn $free(handle: i32) {
            $registry.lock().remove(&handle);
        }

        /// Drop every live entry. Used by shutdown; the counter is not reset,
        /// so handles issued before a shutdown can never be confused with ones
        /// issued after.
        pub(crate) fn $clear() {
            $registry.lock().clear();
        }
    };
}
