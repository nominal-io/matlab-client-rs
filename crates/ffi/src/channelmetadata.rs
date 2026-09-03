//! Channel metadata: units, description, and data type.
//!
//! This is the catalog side of a channel — the read/write metadata that lives
//! against `(data_source_rid, name)`. It is deliberately separate from
//! [`crate::streamchannel`], which is the write address points are sent to;
//! see that module for why the two are not one handle.
//!
//! Metadata is scoped to a single data source. Setting a unit on `rpm` in one
//! dataset does not set it on `rpm` in another, even when the channel names
//! match.
//!
//! # Setting metadata requires a data type
//!
//! Upstream `ChannelUpdate` takes the data type as a required argument, with no
//! way to say "leave it alone". So every write here names one, and this module
//! exposes the vocabulary as an `int32` enum. Get it wrong and you re-declare
//! the channel as something it is not.
//!
//! # Writes are upserts, and do not read back
//!
//! `nominal_channelmetadata_set` creates the metadata if the channel has no
//! data yet, which is how you attach units before a stream or upload has
//! written anything. It returns a handle built from what you sent, not from
//! what the server now holds — so a handle from a write that set only the unit
//! reports no description even if the server has one. Re-fetch with
//! `nominal_channelmetadata_get` when you need truth.

use crate::client::{client_or_fail, ClientHandle};
use crate::dataset::dataset_or_fail;
use crate::error::{fail, ffi_guard, require_out, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;
use crate::strings::{c_str_to_string, set_string, StringHandle};
use nominal::core::{Channel, ChannelDataType, ChannelUpdate};
use std::os::raw::c_char;
use std::sync::Arc;

pub type ChannelMetadataHandle = i32;

handle_registry!(
    CHANNEL_METADATA,
    Channel,
    alloc_metadata,
    get_metadata,
    free_metadata_entry,
    clear_channelmetadata
);

/// Data types a channel can carry, as an `int32`.
///
/// `Unknown` is what a channel reports when the server names a type this
/// client does not recognise; it cannot be written back, and attempting to is
/// an error rather than a silent substitution.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DataType {
    Double = 0,
    Int = 1,
    Uint = 2,
    String = 3,
    Log = 4,
    DoubleArray = 5,
    StringArray = 6,
    Struct = 7,
    Video = 8,
    Spatial = 9,
    Unknown = 10,
}

fn to_code(data_type: &ChannelDataType) -> DataType {
    match data_type {
        ChannelDataType::Double => DataType::Double,
        ChannelDataType::Int => DataType::Int,
        ChannelDataType::Uint => DataType::Uint,
        ChannelDataType::String => DataType::String,
        ChannelDataType::Log => DataType::Log,
        ChannelDataType::DoubleArray => DataType::DoubleArray,
        ChannelDataType::StringArray => DataType::StringArray,
        ChannelDataType::Struct => DataType::Struct,
        ChannelDataType::Video => DataType::Video,
        ChannelDataType::Spatial => DataType::Spatial,
        ChannelDataType::Unknown(_) => DataType::Unknown,
    }
}

fn from_code(code: i32, error_out: *mut ErrorHandle) -> Result<ChannelDataType, ErrorCode> {
    Ok(match code {
        0 => ChannelDataType::Double,
        1 => ChannelDataType::Int,
        2 => ChannelDataType::Uint,
        3 => ChannelDataType::String,
        4 => ChannelDataType::Log,
        5 => ChannelDataType::DoubleArray,
        6 => ChannelDataType::StringArray,
        7 => ChannelDataType::Struct,
        8 => ChannelDataType::Video,
        9 => ChannelDataType::Spatial,
        // Unknown exists so a channel can *report* a type we do not model.
        // Writing it back would ask the server to store a type we cannot name.
        10 => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                "cannot write Unknown as a data type; name a concrete one",
            ))
        }
        other => {
            return Err(fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!("unknown data type code {other}"),
            ))
        }
    })
}

pub(crate) fn metadata_or_fail(
    handle: ChannelMetadataHandle,
    error_out: *mut ErrorHandle,
) -> Result<Arc<Channel>, ErrorCode> {
    get_metadata(handle).ok_or_else(|| {
        fail(
            error_out,
            ErrorCode::InvalidHandle,
            format!("unknown channel metadata handle {handle}"),
        )
    })
}

fn deliver(
    channel: Channel,
    out_metadata: *mut ChannelMetadataHandle,
    error_out: *mut ErrorHandle,
) -> Result<(), ErrorCode> {
    let handle = alloc_metadata(channel);
    if handle == 0 {
        return Err(fail(
            error_out,
            ErrorCode::NoCapacity,
            "channel metadata handle space exhausted",
        ));
    }
    unsafe { *out_metadata = handle };
    Ok(())
}

/// Fetch a channel's metadata from a dataset by channel name.
///
/// Errors if the dataset has no channel by that name.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_get(
    client_handle: ClientHandle,
    dataset_handle: i32,
    name: *const c_char,
    out_metadata: *mut ChannelMetadataHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_metadata, error_out, "out_metadata")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let channel = RUNTIME
            .block_on(client.catalog().get_channel(dataset.rid(), &name))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(channel, out_metadata, error_out)
    })
}

/// Set a channel's unit and description, creating the metadata if needed.
///
/// `unit` is a UCUM symbol such as `"1/min"` or `"Cel"`; pass NULL or an empty
/// string to clear it. `description` may likewise be NULL or empty to leave it
/// untouched — unlike the unit, there is no way to clear a description.
///
/// `data_type` is required and always sent: see the module docs.
///
/// The returned handle reflects what you sent, not what the server holds.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_set(
    client_handle: ClientHandle,
    dataset_handle: i32,
    name: *const c_char,
    data_type: i32,
    unit: *const c_char,
    description: *const c_char,
    out_metadata: *mut ChannelMetadataHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_metadata, error_out, "out_metadata")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;
        let name = unsafe { c_str_to_string(name, "name", error_out)? };

        let mut update = ChannelUpdate::new(from_code(data_type, error_out)?);

        if !unit.is_null() {
            let symbol = unsafe { c_str_to_string(unit, "unit", error_out)? };
            update = if symbol.is_empty() {
                update.clear_unit()
            } else {
                update.unit(symbol)
            };
        }
        if !description.is_null() {
            let text = unsafe { c_str_to_string(description, "description", error_out)? };
            if !text.is_empty() {
                update = update.description(text);
            }
        }

        let channel = RUNTIME
            .block_on(
                client
                    .catalog()
                    .set_channel_metadata(dataset.rid(), &name, update),
            )
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        deliver(channel, out_metadata, error_out)
    })
}

/// Release a channel metadata handle. Freeing an unknown handle is a no-op.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_free(handle: ChannelMetadataHandle) -> i32 {
    free_metadata_entry(handle);
    ErrorCode::Success as i32
}

/// Channel name.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_name(
    handle: ChannelMetadataHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = metadata_or_fail(handle, error_out)?;
        set_string(out_string, channel.name(), error_out)
    })
}

/// RID of the data source this channel belongs to.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_datasource_rid(
    handle: ChannelMetadataHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = metadata_or_fail(handle, error_out)?;
        set_string(out_string, channel.data_source_rid(), error_out)
    })
}

/// Unit symbol, or the empty string if the channel has none.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_unit(
    handle: ChannelMetadataHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = metadata_or_fail(handle, error_out)?;
        set_string(out_string, channel.unit().unwrap_or(""), error_out)
    })
}

/// Description, or the empty string if the channel has none.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_description(
    handle: ChannelMetadataHandle,
    out_string: StringHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        let channel = metadata_or_fail(handle, error_out)?;
        set_string(out_string, channel.description().unwrap_or(""), error_out)
    })
}

/// Data type, as one of the `DataType` codes.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_data_type(
    handle: ChannelMetadataHandle,
    out_type: *mut i32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_type, error_out, "out_type")?;
        let channel = metadata_or_fail(handle, error_out)?;
        unsafe { *out_type = to_code(channel.data_type()) as i32 };
        Ok(())
    })
}

/// Every channel in a dataset, as a count plus indexed access.
///
/// Fetches the whole list and holds it until released, so the index stays
/// stable: `nominal_channelmetadata_list_free` when done.
pub type ChannelListHandle = i32;

handle_registry!(
    CHANNEL_LISTS,
    Vec<Channel>,
    alloc_list,
    get_list,
    free_list_entry,
    clear_channelmetadata_lists
);

/// List every channel in a dataset.
///
/// One request; the result is held so that `_at` has a stable meaning.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_list(
    client_handle: ClientHandle,
    dataset_handle: i32,
    out_list: *mut ChannelListHandle,
    out_count: *mut u32,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_list, error_out, "out_list")?;
        require_out(out_count, error_out, "out_count")?;
        let client = client_or_fail(client_handle, error_out)?;
        let dataset = dataset_or_fail(dataset_handle, error_out)?;

        let mut channels = RUNTIME
            .block_on(client.catalog().list_channels(dataset.rid()))
            .map_err(|e| fail(error_out, ErrorCode::NominalError, e.to_string()))?;

        // Server order is not specified; sort so the index is reproducible.
        channels.sort_by(|a, b| a.name().cmp(b.name()));
        let count = channels.len() as u32;

        let handle = alloc_list(channels);
        if handle == 0 {
            return Err(fail(
                error_out,
                ErrorCode::NoCapacity,
                "channel list handle space exhausted",
            ));
        }
        unsafe {
            *out_list = handle;
            *out_count = count;
        }
        Ok(())
    })
}

/// Metadata for the channel at `index` in a list, as its own handle.
///
/// The returned handle is independent: it outlives the list and needs its own
/// `nominal_channelmetadata_free`.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_list_at(
    list_handle: ChannelListHandle,
    index: u32,
    out_metadata: *mut ChannelMetadataHandle,
    error_out: *mut ErrorHandle,
) -> i32 {
    ffi_guard(error_out, || {
        require_out(out_metadata, error_out, "out_metadata")?;
        let list = get_list(list_handle).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidHandle,
                format!("unknown channel list handle {list_handle}"),
            )
        })?;

        let channel = list.get(index as usize).ok_or_else(|| {
            fail(
                error_out,
                ErrorCode::InvalidParameter,
                format!(
                    "channel index {index} out of range ({} channels)",
                    list.len()
                ),
            )
        })?;

        deliver(channel.clone(), out_metadata, error_out)
    })
}

/// Release a channel list. The metadata handles taken from it stay valid.
#[no_mangle]
pub extern "C" fn nominal_channelmetadata_list_free(handle: ChannelListHandle) -> i32 {
    free_list_entry(handle);
    ErrorCode::Success as i32
}
