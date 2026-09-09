use crate::asset::asset_or_fail;
use crate::client::{client_or_fail, ClientHandle};
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use crate::update::{snapshot, UpdateHandle};
use nominal::core::{Dataset, DatasetCreate, DatasetQuery, DatasetUpdate};
use std::os::raw::c_char;
use std::sync::Arc;

pub type DatasetHandle = i32;

handle_registry!(
    DATASETS,
    Dataset,
    alloc_dataset,
    get_dataset,
    free_dataset_entry,
    clear_datasets
);

pub(crate) fn dataset_or_fail(
    handle: DatasetHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<Dataset>, ErrorCode> {
    get_dataset(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown dataset handle {handle}"),
        )
    })
}

fn deliver(
    dataset: Dataset,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_dataset(dataset);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "dataset handle space exhausted",
        ));
    }
    unsafe { *out_dataset = handle };
    Ok(())
}

/// A fetched list of datasets, held so that indices stay stable.
pub type DatasetListHandle = i32;

handle_registry!(
    DATASET_LISTS,
    Vec<Dataset>,
    alloc_dataset_list,
    get_dataset_list,
    free_dataset_list_entry,
    clear_dataset_lists
);

fn deliver_list(
    mut datasets: Vec<Dataset>,
    out_list: *mut DatasetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    // Server order is unspecified; sort so `_at` means the same thing twice.
    datasets.sort_by(|a, b| a.name().cmp(b.name()));
    let count = datasets.len() as u32;

    let handle = alloc_dataset_list(datasets);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "dataset list handle space exhausted",
        ));
    }
    unsafe {
        *out_list = handle;
        *out_count = count;
    }
    Ok(())
}

/// Every dataset the client can see, ordered by name.
///
/// Discovery entry point, and the usual first call when no RID is known.
/// Release the list with `nominal_dataset_list_free`.
#[no_mangle]
pub extern "C" fn nominal_dataset_list(
    client_handle: ClientHandle,
    out_list: *mut DatasetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_list, error_out, "out_list")?;
        require_out(out_count, error_out, "out_count")?;
        let client = client_or_fail(client_handle, error_out)?;

        let datasets = RUNTIME
            .block_on(client.catalog().list_datasets())
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver_list(datasets, out_list, out_count, error_out)
    })
}

/// Datasets whose name contains `text`, ordered by name.
///
/// Case-insensitive substring match; see `nominal_asset_search` for why only
/// substring is exposed.
#[no_mangle]
pub extern "C" fn nominal_dataset_search(
    client_handle: ClientHandle,
    text: *const c_char,
    out_list: *mut DatasetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_list, error_out, "out_list")?;
        require_out(out_count, error_out, "out_count")?;
        let client = client_or_fail(client_handle, error_out)?;
        let text = unsafe { c_str_to_string(text, "text", error_out)? };

        let datasets = RUNTIME
            .block_on(
                client
                    .catalog()
                    .search_datasets(DatasetQuery::substring_match(text)),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver_list(datasets, out_list, out_count, error_out)
    })
}

/// The dataset at `index`, as its own handle.
///
/// Independent of the list; needs its own `nominal_dataset_free`.
#[no_mangle]
pub extern "C" fn nominal_dataset_list_at(
    client_handle: ClientHandle,
    list_handle: DatasetListHandle,
    index: u32,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        // Datasets carry their client for later calls, so it is needed here
        // even though no request is made.
        client_or_fail(client_handle, error_out)?;

        let list = get_dataset_list(list_handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown dataset list handle {list_handle}"),
            )
        })?;

        let dataset = list.get(index as usize).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "dataset index {index} out of range ({} datasets)",
                    list.len()
                ),
            )
        })?;

        deliver(dataset.clone(), out_dataset, error_out)
    })
}

/// Release a dataset list. Handles taken from it stay valid.
#[no_mangle]
pub extern "C" fn nominal_dataset_list_free(handle: DatasetListHandle) -> i32 {
    free_dataset_list_entry(handle);
    ErrorCode::Success as i32
}

/// Fetch a dataset by RID.
#[no_mangle]
pub extern "C" fn nominal_dataset_get_by_rid(
    client_handle: ClientHandle,
    rid: *const c_char,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let rid = unsafe { c_str_to_string(rid, "rid", error_out)? };

        let dataset = RUNTIME
            .block_on(client.catalog().get_dataset(&rid))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(dataset, out_dataset, error_out)
    })
}

/// What `nominal_dataset_get_or_create_by_name` actually did.
///
/// Reported rather than printed: a MEX writing to stdout from Rust fights
/// MATLAB's own output handling, so the caller decides what the user sees.
#[repr(i32)]
pub enum GetOrCreateOutcome {
    /// Already attached to the asset; nothing was changed.
    FoundAttached = 0,
    /// Existed elsewhere in the workspace and was attached to the asset.
    AttachedExisting = 1,
    /// Did not exist; created and attached.
    Created = 2,
}

/// Every dataset attached to `asset_rid`, fetched in one round trip.
///
/// The asset is re-fetched rather than read from the caller's handle, which is
/// a snapshot taken when the asset was last fetched and does not see its own
/// attachments. `get_dataset_batch` then costs one request however many data
/// sources the asset has, so this is two requests flat.
fn attached_datasets(
    client: &nominal::core::NominalClient,
    asset_rid: &str,
    error_out: *mut ErrorHandle,
) -> Result<Vec<Dataset>, ErrorCode> {
    let asset = RUNTIME
        .block_on(client.assets().get(asset_rid))
        .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

    // Videos and connections are data sources too, and only datasets can be
    // fetched from the catalog.
    let rids: Vec<String> = asset
        .data_sources()
        .values()
        .filter_map(|source| match source {
            nominal::core::DataSource::Dataset(_) => Some(source.rid().to_string()),
            _ => None,
        })
        .collect();

    if rids.is_empty() {
        return Ok(Vec::new());
    }

    let by_rid = RUNTIME
        .block_on(client.catalog().get_dataset_batch(&rids))
        .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

    Ok(by_rid.into_values().collect())
}

/// Pick the one dataset named exactly `name`, or fail if several are.
///
/// Duplicate names are refused rather than resolved by picking the first: the
/// choice would be arbitrary, and both silently returning and silently
/// attaching the wrong dataset are worse than an error naming the candidates.
fn exactly_one_named(
    mut candidates: Vec<Dataset>,
    name: &str,
    where_: &str,
    error_out: *mut ErrorHandle,
) -> Result<Option<Dataset>, ErrorCode> {
    candidates.retain(|d| d.name() == name);

    match candidates.len() {
        0 => Ok(None),
        1 => Ok(Some(candidates.remove(0))),
        n => {
            let rids: Vec<&str> = candidates.iter().map(|d| d.rid()).collect();
            Err(fail(
                error_out,
                ErrorCode::NominalError,
                format!(
                    "{n} datasets named \"{name}\" {where_}: {}. \
                     Fetch the one you mean by RID instead.",
                    rids.join(", ")
                ),
            ))
        }
    }
}

/// Fetch the dataset named `name` on this asset, attaching or creating it.
///
/// Resolution order, which exists because a bare name is not unique in Nominal:
///
/// 1. A dataset of that name already attached to the asset — returned as-is.
/// 2. Otherwise, when `attach_existing` is non-zero, a dataset of that exact
///    name anywhere in the workspace — attached to the asset and returned.
/// 3. Otherwise created and attached.
///
/// Step 2 is what makes "the dataset for serial 12345678" resolve to the
/// dataset someone else already made, which is usually what was meant. It is
/// also a mutation driven by a name match, so it is defeatable: pass
/// `attach_existing = 0` to go straight from step 1 to step 3.
///
/// `ref_name` addresses the dataset within the asset and must be unique among
/// its data sources; it is used only when attaching, never to decide identity.
///
/// `out_outcome` reports which branch ran — see `GetOrCreateOutcome`.
#[no_mangle]
pub extern "C" fn nominal_dataset_get_or_create_by_name(
    client_handle: ClientHandle,
    asset_handle: i32,
    name: *const c_char,
    ref_name: *const c_char,
    attach_existing: i32,
    out_dataset: *mut DatasetHandle,
    out_outcome: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        require_out(out_outcome, error_out, "out_outcome")?;
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };
        let ref_name = unsafe { c_str_to_string(ref_name, "ref_name", error_out)? };

        // 1 — already on the asset.
        let attached = attached_datasets(&client, asset.rid(), error_out)?;
        if let Some(existing) =
            exactly_one_named(attached, &name, "attached to this asset", error_out)?
        {
            unsafe { *out_outcome = GetOrCreateOutcome::FoundAttached as i32 };
            return deliver(existing, out_dataset, error_out);
        }

        // 2 — exists in the workspace, attach it.
        if attach_existing != 0 {
            let matches = RUNTIME
                .block_on(
                    client
                        .catalog()
                        .search_datasets(DatasetQuery::substring_match(&name)),
                )
                .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

            if let Some(existing) =
                exactly_one_named(matches, &name, "in this workspace", error_out)?
            {
                RUNTIME
                    .block_on(
                        client
                            .assets()
                            .add_dataset(asset.rid(), &ref_name, existing.rid()),
                    )
                    .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

                unsafe { *out_outcome = GetOrCreateOutcome::AttachedExisting as i32 };
                return deliver(existing, out_dataset, error_out);
            }
        }

        // 3 — create it.
        let dataset = RUNTIME
            .block_on(client.catalog().create_dataset(DatasetCreate::new(name)))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        RUNTIME
            .block_on(
                client
                    .assets()
                    .add_dataset(asset.rid(), &ref_name, dataset.rid()),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        unsafe { *out_outcome = GetOrCreateOutcome::Created as i32 };
        deliver(dataset, out_dataset, error_out)
    })
}

/// Fetch a dataset already attached to this asset, by name. Never mutates.
///
/// Step 1 of `nominal_dataset_get_or_create_by_name` on its own, for callers
/// who want to know whether the asset has the dataset rather than to ensure
/// that it does. Fails when it does not, and when several attached datasets
/// share the name.
#[no_mangle]
pub extern "C" fn nominal_asset_attached_dataset_by_name(
    client_handle: ClientHandle,
    asset_handle: i32,
    name: *const c_char,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let attached = attached_datasets(&client, asset.rid(), error_out)?;
        match exactly_one_named(attached, &name, "attached to this asset", error_out)? {
            Some(dataset) => deliver(dataset, out_dataset, error_out),
            None => Err(fail(
                error_out,
                ErrorCode::NominalError,
                format!("no dataset named \"{name}\" is attached to this asset"),
            )),
        }
    })
}

/// Apply a staged update and return the updated dataset as a new handle.
///
/// Staged start and end times are ignored, since datasets have neither. The
/// staging object is not consumed; free it with `nominal_update_free`.
#[no_mangle]
pub extern "C" fn nominal_dataset_update_commit(
    client_handle: ClientHandle,
    dataset_handle: DatasetHandle,
    update_handle: UpdateHandle,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let staged = snapshot(update_handle, error_out)?;

        let mut update = DatasetUpdate::new();
        if let Some(name) = staged.name {
            update = update.name(name);
        }
        if let Some(description) = staged.description {
            update = update.description(description);
        }
        if let Some(properties) = staged.properties {
            update = update.properties(properties);
        }
        if let Some(labels) = staged.labels {
            update = update.labels(labels);
        }

        let updated = RUNTIME
            .block_on(client.catalog().update_dataset(dataset.rid(), update))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(updated, out_dataset, error_out)
    })
}

/// Release a dataset handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_dataset_free(handle: DatasetHandle) -> i32 {
    free_dataset_entry(handle);
    ErrorCode::Success as i32
}

/// RID of a dataset.
#[no_mangle]
pub extern "C" fn nominal_dataset_rid(
    handle: DatasetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let dataset = dataset_or_fail(handle, error_out)?;
        set_string(out_string, dataset.rid(), error_out)
    })
}

/// Name of a dataset.
#[no_mangle]
pub extern "C" fn nominal_dataset_name(
    handle: DatasetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let dataset = dataset_or_fail(handle, error_out)?;
        set_string(out_string, dataset.name(), error_out)
    })
}

// The three getters below mirror their asset equivalents. They exist because
// `nominal_dataset_update_commit` accepts a description, labels and properties:
// a resource that can have a field set but not read back is a gap, not a
// design.

/// Description of a dataset, or the empty string if it has none.
#[no_mangle]
pub extern "C" fn nominal_dataset_description(
    handle: DatasetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let dataset = dataset_or_fail(handle, error_out)?;
        set_string(out_string, dataset.description().unwrap_or(""), error_out)
    })
}

/// Number of labels on a dataset.
#[no_mangle]
pub extern "C" fn nominal_dataset_label_count(
    handle: DatasetHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_count, error_out, "out_count")?;
        let dataset = dataset_or_fail(handle, error_out)?;
        unsafe { *out_count = dataset.labels().len() as u32 };
        Ok(())
    })
}

/// Label at `index`, counting from zero.
#[no_mangle]
pub extern "C" fn nominal_dataset_label_at(
    handle: DatasetHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let dataset = dataset_or_fail(handle, error_out)?;
        let labels = dataset.labels();
        let label = labels.get(index as usize).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("label index {index} out of range ({} labels)", labels.len()),
            )
        })?;
        set_string(out_string, label.as_str(), error_out)
    })
}

/// Value of a property, or an error if the dataset has no such key.
#[no_mangle]
pub extern "C" fn nominal_dataset_property(
    handle: DatasetHandle,
    key: *const c_char,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let dataset = dataset_or_fail(handle, error_out)?;
        let key = unsafe { c_str_to_string(key, "key", error_out)? };
        let value = dataset.properties().get(&key).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("dataset has no property {key:?}"),
            )
        })?;
        set_string(out_string, value.as_str(), error_out)
    })
}
