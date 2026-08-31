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

/// Fetch a dataset by name, creating it and attaching it to `asset_handle` if
/// no dataset with that exact name exists.
///
/// The dataset is attached to the asset under `ref_name`, which is how it is
/// addressed within that asset and must be unique among the asset's data
/// sources. An existing dataset is returned as-is and is not re-attached.
#[no_mangle]
pub extern "C" fn nominal_dataset_get_or_create_by_name(
    client_handle: ClientHandle,
    asset_handle: i32,
    name: *const c_char,
    ref_name: *const c_char,
    out_dataset: *mut DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_dataset, error_out, "out_dataset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };
        let ref_name = unsafe { c_str_to_string(ref_name, "ref_name", error_out)? };

        let matches = RUNTIME
            .block_on(
                client
                    .catalog()
                    .search_datasets(DatasetQuery::substring_match(&name)),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        if let Some(existing) = matches.into_iter().find(|d| d.name() == name) {
            return deliver(existing, out_dataset, error_out);
        }

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

        deliver(dataset, out_dataset, error_out)
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
