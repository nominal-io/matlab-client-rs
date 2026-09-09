use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::{dataset_or_fail, DatasetHandle};
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use crate::update::{snapshot, UpdateHandle};
use nominal::core::{Asset, AssetCreate, AssetQuery, AssetUpdate};
use std::os::raw::c_char;
use std::sync::Arc;

pub type AssetHandle = i32;

handle_registry!(
    ASSETS,
    Asset,
    alloc_asset,
    get_asset,
    free_asset_entry,
    clear_assets
);

pub(crate) fn asset_or_fail(
    handle: AssetHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<Asset>, ErrorCode> {
    get_asset(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown asset handle {handle}"),
        )
    })
}

/// Store an asset and hand back its handle.
fn deliver(
    asset: Asset,
    out_asset: *mut AssetHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_asset(asset);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "asset handle space exhausted",
        ));
    }
    unsafe { *out_asset = handle };
    Ok(())
}

/// Fetch an asset by name, creating it if no asset in the workspace has that
/// name exactly.
///
/// The search is a substring match server-side, then filtered here for an exact
/// name match. If several assets share the name, the first is returned: name is
/// not unique in Nominal, so prefer `nominal_asset_get_by_rid` when you already
/// know the RID.
#[no_mangle]
pub extern "C" fn nominal_asset_get_or_create_by_name(
    client_handle: ClientHandle,
    name: *const c_char,
    out_asset: *mut AssetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_asset, error_out, "out_asset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let matches = RUNTIME
            .block_on(client.assets().search(AssetQuery::substring_match(&name)))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        let asset = match matches.into_iter().find(|a| a.name() == name) {
            Some(existing) => existing,
            None => RUNTIME
                .block_on(client.assets().create(AssetCreate::new(name)))
                .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?,
        };

        deliver(asset, out_asset, error_out)
    })
}

/// Fetch an asset by RID.
#[no_mangle]
pub extern "C" fn nominal_asset_get_by_rid(
    client_handle: ClientHandle,
    rid: *const c_char,
    out_asset: *mut AssetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_asset, error_out, "out_asset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let rid = unsafe { c_str_to_string(rid, "rid", error_out)? };

        let asset = RUNTIME
            .block_on(client.assets().get(&rid))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(asset, out_asset, error_out)
    })
}

/// Apply a staged update and return the updated asset as a new handle.
///
/// The original handle still refers to the pre-update snapshot. The staging
/// object is not consumed; free it with `nominal_update_free`.
///
/// Staged start and end times are ignored, since assets have neither.
#[no_mangle]
pub extern "C" fn nominal_asset_update_commit(
    client_handle: ClientHandle,
    asset_handle: AssetHandle,
    update_handle: UpdateHandle,
    out_asset: *mut AssetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_asset, error_out, "out_asset")?;
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let staged = snapshot(update_handle, error_out)?;

        let mut update = AssetUpdate::new();
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
            .block_on(client.assets().update(asset.rid(), update))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(updated, out_asset, error_out)
    })
}

/// Attach an existing dataset to this asset under `ref_name`.
///
/// The direct form of what `nominal_dataset_get_or_create_by_name` does as a
/// side effect: it takes a dataset you already hold rather than a name to look
/// up, so a handle obtained any way at all — by RID, from a search, from an
/// ingest — can be put on an asset.
///
/// `ref_name` addresses the dataset within the asset and must be unique among
/// its data sources. That is the only constraint the server enforces on it:
/// spaces, dots, hyphens and mixed case are all accepted. A collision comes
/// back as `Assets:DuplicateDataScopeNames`.
///
/// Returns nothing. The caller's asset handle is a snapshot and does not see
/// the new data source; re-fetch to observe it.
#[no_mangle]
pub extern "C" fn nominal_asset_add_dataset(
    client_handle: ClientHandle,
    asset_handle: AssetHandle,
    ref_name: *const c_char,
    dataset_handle: DatasetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let client = client_or_fail(client_handle, error_out)?;
        let asset = asset_or_fail(asset_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let ref_name = unsafe { c_str_to_string(ref_name, "ref_name", error_out)? };

        RUNTIME
            .block_on(
                client
                    .assets()
                    .add_dataset(asset.rid(), &ref_name, dataset.rid()),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        Ok(())
    })
}

/// Release an asset handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_asset_free(handle: AssetHandle) -> i32 {
    free_asset_entry(handle);
    ErrorCode::Success as i32
}

/// RID of an asset.
#[no_mangle]
pub extern "C" fn nominal_asset_rid(
    handle: AssetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        set_string(out_string, asset.rid(), error_out)
    })
}

/// Name of an asset.
#[no_mangle]
pub extern "C" fn nominal_asset_name(
    handle: AssetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        set_string(out_string, asset.name(), error_out)
    })
}

/// Description of an asset, or the empty string if it has none.
#[no_mangle]
pub extern "C" fn nominal_asset_description(
    handle: AssetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        set_string(out_string, asset.description().unwrap_or(""), error_out)
    })
}

/// Web URL for this asset in the Nominal app.
#[no_mangle]
pub extern "C" fn nominal_asset_url(
    handle: AssetHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        set_string(out_string, asset.nominal_url(), error_out)
    })
}

/// Number of labels on an asset.
#[no_mangle]
pub extern "C" fn nominal_asset_label_count(
    handle: AssetHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_count, error_out, "out_count")?;
        let asset = asset_or_fail(handle, error_out)?;
        unsafe { *out_count = asset.labels().len() as u32 };
        Ok(())
    })
}

/// Label at `index`, counting from zero.
#[no_mangle]
pub extern "C" fn nominal_asset_label_at(
    handle: AssetHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        let labels = asset.labels();
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

/// A fetched list of assets, held so that indices stay stable.
pub type AssetListHandle = i32;

handle_registry!(
    ASSET_LISTS,
    Vec<Asset>,
    alloc_asset_list,
    get_asset_list,
    free_asset_list_entry,
    clear_asset_lists
);

/// Store a fetched list and report its size.
fn deliver_list(
    mut assets: Vec<Asset>,
    out_list: *mut AssetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    // Server order is unspecified; sort so `_at` means the same thing twice.
    assets.sort_by(|a, b| a.name().cmp(b.name()));
    let count = assets.len() as u32;

    let handle = alloc_asset_list(assets);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "asset list handle space exhausted",
        ));
    }
    unsafe {
        *out_list = handle;
        *out_count = count;
    }
    Ok(())
}

/// Every asset the client can see, ordered by name.
///
/// Discovery entry point: with no RID in hand, this is how you find one. The
/// list is held behind a handle so `nominal_asset_list_at` addresses a stable
/// snapshot; release it with `nominal_asset_list_free`.
#[no_mangle]
pub extern "C" fn nominal_asset_list(
    client_handle: ClientHandle,
    out_list: *mut AssetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_list, error_out, "out_list")?;
        require_out(out_count, error_out, "out_count")?;
        let client = client_or_fail(client_handle, error_out)?;

        let assets = RUNTIME
            .block_on(client.assets().list())
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver_list(assets, out_list, out_count, error_out)
    })
}

/// Assets whose name contains `text`, ordered by name.
///
/// Case-insensitive substring match. The underlying query language also
/// supports labels, properties, and boolean composition; only substring is
/// exposed here, since flattening the rest across the ABI buys little.
#[no_mangle]
pub extern "C" fn nominal_asset_search(
    client_handle: ClientHandle,
    text: *const c_char,
    out_list: *mut AssetListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_list, error_out, "out_list")?;
        require_out(out_count, error_out, "out_count")?;
        let client = client_or_fail(client_handle, error_out)?;
        let text = unsafe { c_str_to_string(text, "text", error_out)? };

        let assets = RUNTIME
            .block_on(client.assets().search(AssetQuery::substring_match(text)))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver_list(assets, out_list, out_count, error_out)
    })
}

/// The asset at `index`, as its own handle.
///
/// Independent of the list: it outlives it and needs its own
/// `nominal_asset_free`.
#[no_mangle]
pub extern "C" fn nominal_asset_list_at(
    list_handle: AssetListHandle,
    index: u32,
    out_asset: *mut AssetHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_asset, error_out, "out_asset")?;
        let list = get_asset_list(list_handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown asset list handle {list_handle}"),
            )
        })?;

        let asset = list.get(index as usize).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("asset index {index} out of range ({} assets)", list.len()),
            )
        })?;

        deliver(asset.clone(), out_asset, error_out)
    })
}

/// Release an asset list. Handles taken from it stay valid.
#[no_mangle]
pub extern "C" fn nominal_asset_list_free(handle: AssetListHandle) -> i32 {
    free_asset_list_entry(handle);
    ErrorCode::Success as i32
}

/// Kind of a data source, as reported by `nominal_asset_datasource_type_at`.
///
/// Kept as a separate enum from the C side's other codes because it is data,
/// not a status: these are the variants Nominal attaches to an asset.
#[repr(i32)]
pub enum DataSourceKind {
    Dataset = 0,
    Video = 1,
    Connection = 2,
}

/// Data sources attached to an asset, ordered by reference name.
///
/// The underlying map has no order of its own, so entries are sorted by
/// reference name to give `index` a stable meaning: without that, the same
/// index could name a different source on each call.
fn sorted_data_sources(asset: &Asset) -> Vec<(&String, &nominal::core::DataSource)> {
    let mut entries: Vec<_> = asset.data_sources().iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    entries
}

fn data_source_at<'a>(
    entries: &'a [(&'a String, &'a nominal::core::DataSource)],
    index: u32,
    error_out: *mut ErrorHandle,
) -> Result<&'a (&'a String, &'a nominal::core::DataSource), ErrorCode> {
    entries.get(index as usize).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!(
                "data source index {index} out of range ({} attached)",
                entries.len()
            ),
        )
    })
}

/// Number of data sources attached to an asset.
///
/// Pair with the `_at` getters, which address them by index in reference-name
/// order.
#[no_mangle]
pub extern "C" fn nominal_asset_datasource_count(
    handle: AssetHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_count, error_out, "out_count")?;
        let asset = asset_or_fail(handle, error_out)?;
        unsafe { *out_count = asset.data_sources().len() as u32 };
        Ok(())
    })
}

/// Reference name of the data source at `index`.
///
/// The reference name is how the source is addressed within this asset, and is
/// unique among them.
#[no_mangle]
pub extern "C" fn nominal_asset_datasource_ref_name_at(
    handle: AssetHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        let entries = sorted_data_sources(&asset);
        let (ref_name, _) = data_source_at(&entries, index, error_out)?;
        set_string(out_string, ref_name.as_str(), error_out)
    })
}

/// RID of the data source at `index`, whatever its kind.
#[no_mangle]
pub extern "C" fn nominal_asset_datasource_rid_at(
    handle: AssetHandle,
    index: u32,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        let entries = sorted_data_sources(&asset);
        let (_, source) = data_source_at(&entries, index, error_out)?;
        set_string(out_string, source.rid(), error_out)
    })
}

/// Kind of the data source at `index`: 0 dataset, 1 video, 2 connection.
///
/// Knowing the kind matters because the RID alone does not tell you which API
/// to hand it to — only a dataset RID can open a stream, for instance.
#[no_mangle]
pub extern "C" fn nominal_asset_datasource_type_at(
    handle: AssetHandle,
    index: u32,
    out_kind: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_kind, error_out, "out_kind")?;
        let asset = asset_or_fail(handle, error_out)?;
        let entries = sorted_data_sources(&asset);
        let (_, source) = data_source_at(&entries, index, error_out)?;

        let kind = match source {
            nominal::core::DataSource::Dataset(_) => DataSourceKind::Dataset,
            nominal::core::DataSource::Video(_) => DataSourceKind::Video,
            nominal::core::DataSource::Connection(_) => DataSourceKind::Connection,
        };
        unsafe { *out_kind = kind as i32 };
        Ok(())
    })
}

/// Value of a property, or an error if the asset has no such key.
#[no_mangle]
pub extern "C" fn nominal_asset_property(
    handle: AssetHandle,
    key: *const c_char,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let asset = asset_or_fail(handle, error_out)?;
        let key = unsafe { c_str_to_string(key, "key", error_out)? };
        let value = asset.properties().get(&key).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("asset has no property {key:?}"),
            )
        })?;
        set_string(out_string, value.as_str(), error_out)
    })
}
