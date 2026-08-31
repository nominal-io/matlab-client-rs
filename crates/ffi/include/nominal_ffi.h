#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef int32_t ErrorHandle;

typedef int32_t StringHandle;

typedef int32_t UpdateHandle;

typedef int32_t ClientHandle;

typedef int32_t AssetHandle;

/**
 * A fetched list of assets, held so that indices stay stable.
 */
typedef int32_t AssetListHandle;

typedef int32_t StreamChannelHandle;

typedef int32_t BufferHandle;

typedef int32_t ChannelMetadataHandle;

/**
 * Every channel in a dataset, as a count plus indexed access.
 *
 * Fetches the whole list and holds it until released, so the index stays
 * stable: `nominal_channelmetadata_list_free` when done.
 */
typedef int32_t ChannelListHandle;

typedef int32_t SeriesHandle;

/**
 * A fetched list of datasets, held so that indices stay stable.
 */
typedef int32_t DatasetListHandle;

typedef int32_t DatasetHandle;

typedef int32_t EventHandle;

typedef int32_t IngestJobHandle;

typedef int32_t RunHandle;

typedef int32_t QueryResultHandle;

typedef int32_t StreamHandle;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Get the error code carried by an error handle.
 *
 * Returns 0 for an unknown handle, which is indistinguishable from Success —
 * check the originating function's return value, not this, to detect failure.
 */
int32_t nominal_error_code(ErrorHandle handle);

/**
 * Write an error's message into a string handle.
 *
 * Follows the same shape as every other getter, so reading an error is not a
 * special case. Allocate one string handle at startup and reuse it:
 *
 * ```c
 * if (nominal_asset_name(asset, name, &err) != 0) {
 *     nominal_error_message(err, msg);
 *     nominal_error_free(err);
 * }
 * ```
 */
int32_t nominal_error_message(ErrorHandle handle, StringHandle out_string);

/**
 * Release an error handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_error_free(ErrorHandle handle);

/**
 * Release every resource this library holds and stop its worker threads.
 *
 * **Call this before the host unloads the library.** Without it, the runtime's
 * threads outlive the module and crash the process on unload — see the module
 * docs for why `DllMain` cannot do this for you.
 *
 * All outstanding handles are invalidated: clients, assets, datasets, and runs
 * are dropped, and any handle held across the call will report `InvalidHandle`
 * afterwards. Acquire fresh ones after a shutdown rather than reusing old.
 *
 * Safe to call more than once, and safe to call having never used the library.
 * A later call transparently builds a new runtime, so this is a pause rather
 * than a one-way door — which is what LabVIEW's repeated reserve/unreserve
 * cycle needs.
 *
 * Blocks until in-flight calls return, then waits up to five seconds for
 * background work before abandoning it.
 */
int32_t nominal_shutdown(void);

/**
 * Allocate an empty string handle.
 *
 * One handle can be reused across any number of calls; each getter overwrites
 * whatever it held. Release it with `nominal_string_free`.
 */
int32_t nominal_string_alloc(StringHandle *out_handle);

/**
 * Release a string handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_string_free(StringHandle handle);

/**
 * Byte length of the string a handle holds, excluding any NUL.
 *
 * Returns 0 for an unknown handle, which is indistinguishable from an empty
 * string — the originating call's status code is what tells you the handle is
 * valid.
 */
uint32_t nominal_string_length(StringHandle handle);

/**
 * Copy a string's bytes into a caller-provided buffer.
 *
 * Returns the number of bytes copied. If `buf_size` is smaller than the
 * string, as much as fits is copied, truncated at a UTF-8 character boundary
 * so the result is never invalid UTF-8 — compare the return value against
 * `nominal_string_length` to detect that. A NUL terminator is appended only
 * when the buffer has room beyond the copied bytes; the return value, not
 * `strlen`, is authoritative.
 */
uint32_t nominal_copy_string_from_reference(StringHandle handle, char *buf, uint32_t buf_size);

/**
 * Current time as nanoseconds since the Unix epoch, at the finest resolution
 * the host clock provides.
 */
int64_t nominal_timestamp_now(void);

/**
 * Begin accumulating an update. Release it with `nominal_update_free`;
 * committing does not consume it, so one staging object can be applied to
 * several resources.
 */
int32_t nominal_update_begin(UpdateHandle *out_update, ErrorHandle *error_out);

/**
 * Release a staging object. Freeing an unknown handle is a no-op.
 */
int32_t nominal_update_free(UpdateHandle handle);

/**
 * Stage a new name.
 */
int32_t nominal_update_set_name(UpdateHandle handle, const char *name, ErrorHandle *error_out);

/**
 * Stage a new description.
 */
int32_t nominal_update_set_description(UpdateHandle handle,
                                       const char *description,
                                       ErrorHandle *error_out);

/**
 * Add a property to the staged set.
 *
 * Calling this at all replaces the resource's entire property map on commit.
 * Repeating a key overwrites the earlier value.
 */
int32_t nominal_update_set_property(UpdateHandle handle,
                                    const char *key,
                                    const char *value,
                                    ErrorHandle *error_out);

/**
 * Add a label to the staged set.
 *
 * Calling this at all replaces the resource's entire label set on commit.
 */
int32_t nominal_update_add_label(UpdateHandle handle, const char *label, ErrorHandle *error_out);

/**
 * Clear the staged property set, so commit sends an empty map.
 *
 * Distinct from never touching properties, which leaves them untouched.
 */
int32_t nominal_update_clear_properties(UpdateHandle handle, ErrorHandle *error_out);

/**
 * Clear the staged label set, so commit sends an empty set.
 */
int32_t nominal_update_clear_labels(UpdateHandle handle, ErrorHandle *error_out);

/**
 * Stage a start time, in nanoseconds since the Unix epoch. `0` means now.
 *
 * Ignored by resources that have no start time.
 */
int32_t nominal_update_set_start(UpdateHandle handle, int64_t nanos, ErrorHandle *error_out);

/**
 * Stage an end time, in nanoseconds since the Unix epoch. `0` means now.
 *
 * Ignored by resources that have no end time.
 */
int32_t nominal_update_set_end(UpdateHandle handle, int64_t nanos, ErrorHandle *error_out);

/**
 * Fetch an asset by name, creating it if no asset in the workspace has that
 * name exactly.
 *
 * The search is a substring match server-side, then filtered here for an exact
 * name match. If several assets share the name, the first is returned: name is
 * not unique in Nominal, so prefer `nominal_asset_get_by_rid` when you already
 * know the RID.
 */
int32_t nominal_asset_get_or_create_by_name(ClientHandle client_handle,
                                            const char *name,
                                            AssetHandle *out_asset,
                                            ErrorHandle *error_out);

/**
 * Fetch an asset by RID.
 */
int32_t nominal_asset_get_by_rid(ClientHandle client_handle,
                                 const char *rid,
                                 AssetHandle *out_asset,
                                 ErrorHandle *error_out);

/**
 * Apply a staged update and return the updated asset as a new handle.
 *
 * The original handle still refers to the pre-update snapshot. The staging
 * object is not consumed; free it with `nominal_update_free`.
 *
 * Staged start and end times are ignored, since assets have neither.
 */
int32_t nominal_asset_update_commit(ClientHandle client_handle,
                                    AssetHandle asset_handle,
                                    UpdateHandle update_handle,
                                    AssetHandle *out_asset,
                                    ErrorHandle *error_out);

/**
 * Release an asset handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_asset_free(AssetHandle handle);

/**
 * RID of an asset.
 */
int32_t nominal_asset_rid(AssetHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Name of an asset.
 */
int32_t nominal_asset_name(AssetHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Description of an asset, or the empty string if it has none.
 */
int32_t nominal_asset_description(AssetHandle handle,
                                  StringHandle out_string,
                                  ErrorHandle *error_out);

/**
 * Web URL for this asset in the Nominal app.
 */
int32_t nominal_asset_url(AssetHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Number of labels on an asset.
 */
int32_t nominal_asset_label_count(AssetHandle handle, uint32_t *out_count, ErrorHandle *error_out);

/**
 * Label at `index`, counting from zero.
 */
int32_t nominal_asset_label_at(AssetHandle handle,
                               uint32_t index,
                               StringHandle out_string,
                               ErrorHandle *error_out);

/**
 * Every asset the client can see, ordered by name.
 *
 * Discovery entry point: with no RID in hand, this is how you find one. The
 * list is held behind a handle so `nominal_asset_list_at` addresses a stable
 * snapshot; release it with `nominal_asset_list_free`.
 */
int32_t nominal_asset_list(ClientHandle client_handle,
                           AssetListHandle *out_list,
                           uint32_t *out_count,
                           ErrorHandle *error_out);

/**
 * Assets whose name contains `text`, ordered by name.
 *
 * Case-insensitive substring match. The underlying query language also
 * supports labels, properties, and boolean composition; only substring is
 * exposed here, since flattening the rest across the ABI buys little.
 */
int32_t nominal_asset_search(ClientHandle client_handle,
                             const char *text,
                             AssetListHandle *out_list,
                             uint32_t *out_count,
                             ErrorHandle *error_out);

/**
 * The asset at `index`, as its own handle.
 *
 * Independent of the list: it outlives it and needs its own
 * `nominal_asset_free`.
 */
int32_t nominal_asset_list_at(AssetListHandle list_handle,
                              uint32_t index,
                              AssetHandle *out_asset,
                              ErrorHandle *error_out);

/**
 * Release an asset list. Handles taken from it stay valid.
 */
int32_t nominal_asset_list_free(AssetListHandle handle);

/**
 * Number of data sources attached to an asset.
 *
 * Pair with the `_at` getters, which address them by index in reference-name
 * order.
 */
int32_t nominal_asset_datasource_count(AssetHandle handle,
                                       uint32_t *out_count,
                                       ErrorHandle *error_out);

/**
 * Reference name of the data source at `index`.
 *
 * The reference name is how the source is addressed within this asset, and is
 * unique among them.
 */
int32_t nominal_asset_datasource_ref_name_at(AssetHandle handle,
                                             uint32_t index,
                                             StringHandle out_string,
                                             ErrorHandle *error_out);

/**
 * RID of the data source at `index`, whatever its kind.
 */
int32_t nominal_asset_datasource_rid_at(AssetHandle handle,
                                        uint32_t index,
                                        StringHandle out_string,
                                        ErrorHandle *error_out);

/**
 * Kind of the data source at `index`: 0 dataset, 1 video, 2 connection.
 *
 * Knowing the kind matters because the RID alone does not tell you which API
 * to hand it to — only a dataset RID can open a stream, for instance.
 */
int32_t nominal_asset_datasource_type_at(AssetHandle handle,
                                         uint32_t index,
                                         int32_t *out_kind,
                                         ErrorHandle *error_out);

/**
 * Value of a property, or an error if the asset has no such key.
 */
int32_t nominal_asset_property(AssetHandle handle,
                               const char *key,
                               StringHandle out_string,
                               ErrorHandle *error_out);

/**
 * Allocate a buffer holding up to `capacity` rows across `channel_count`
 * channels.
 *
 * `channels` is an array of `channel_count` stream channel handles, which must
 * all belong to the same stream — a buffer commits as one batch, so a mixture
 * would have nowhere single to go. Their descriptors are copied now, so the
 * buffer keeps working if a channel handle is later freed.
 *
 * Every row must supply one value per channel, in this order.
 *
 * Memory is reserved up front — `capacity * channel_count` doubles plus the
 * timestamps — so no allocation happens on the acquisition path.
 */
int32_t nominal_buffer_alloc(const StreamChannelHandle *channels,
                             uint32_t channel_count,
                             uint32_t capacity,
                             BufferHandle *out_buffer,
                             ErrorHandle *error_out);

/**
 * Append one row: a timestamp and one value per channel.
 *
 * `values` must hold exactly `value_count` elements, matching the channel
 * count the buffer was allocated with — a mismatch is an error rather than a
 * silent partial row, since a wrong-length row would misalign every channel.
 *
 * `out_is_full` receives true when the buffer has no room for another row.
 * Commit then, or keep storing and lose rows — a store into a full buffer
 * fails rather than overwriting.
 *
 * Timestamps are literal, including zero.
 */
int32_t nominal_buffer_store(BufferHandle handle,
                             int64_t timestamp_nanos,
                             const double *values,
                             uint32_t value_count,
                             bool *out_is_full,
                             ErrorHandle *error_out);

/**
 * Send everything the buffer holds to its stream, then empty it for reuse.
 *
 * The stream comes from the channels the buffer was allocated with, so there
 * is nothing to pass and nothing to get wrong.
 *
 * Committing an empty buffer succeeds and does nothing, so this can be called
 * unconditionally at the end of acquisition to flush a partial tail.
 *
 * **Blocks** while the stream is saturated — see the module docs. The buffer
 * is emptied only once the data has been handed over, so a failed commit
 * leaves the rows intact to retry.
 */
int32_t nominal_buffer_commit(BufferHandle buffer_handle, ErrorHandle *error_out);

/**
 * Rows currently held, and the capacity they are held against.
 */
int32_t nominal_buffer_status(BufferHandle handle,
                              uint32_t *out_rows,
                              uint32_t *out_capacity,
                              ErrorHandle *error_out);

/**
 * Release a buffer, discarding any uncommitted rows.
 *
 * Commit first if the tail matters. Freeing an unknown handle is a no-op.
 */
int32_t nominal_buffer_free(BufferHandle handle);

/**
 * Fetch a channel's metadata from a dataset by channel name.
 *
 * Errors if the dataset has no channel by that name.
 */
int32_t nominal_channelmetadata_get(ClientHandle client_handle,
                                    int32_t dataset_handle,
                                    const char *name,
                                    ChannelMetadataHandle *out_metadata,
                                    ErrorHandle *error_out);

/**
 * Set a channel's unit and description, creating the metadata if needed.
 *
 * `unit` is a UCUM symbol such as `"1/min"` or `"Cel"`; pass NULL or an empty
 * string to clear it. `description` may likewise be NULL or empty to leave it
 * untouched — unlike the unit, there is no way to clear a description.
 *
 * `data_type` is required and always sent: see the module docs.
 *
 * The returned handle reflects what you sent, not what the server holds.
 */
int32_t nominal_channelmetadata_set(ClientHandle client_handle,
                                    int32_t dataset_handle,
                                    const char *name,
                                    int32_t data_type,
                                    const char *unit,
                                    const char *description,
                                    ChannelMetadataHandle *out_metadata,
                                    ErrorHandle *error_out);

/**
 * Release a channel metadata handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_channelmetadata_free(ChannelMetadataHandle handle);

/**
 * Channel name.
 */
int32_t nominal_channelmetadata_name(ChannelMetadataHandle handle,
                                     StringHandle out_string,
                                     ErrorHandle *error_out);

/**
 * RID of the data source this channel belongs to.
 */
int32_t nominal_channelmetadata_datasource_rid(ChannelMetadataHandle handle,
                                               StringHandle out_string,
                                               ErrorHandle *error_out);

/**
 * Unit symbol, or the empty string if the channel has none.
 */
int32_t nominal_channelmetadata_unit(ChannelMetadataHandle handle,
                                     StringHandle out_string,
                                     ErrorHandle *error_out);

/**
 * Description, or the empty string if the channel has none.
 */
int32_t nominal_channelmetadata_description(ChannelMetadataHandle handle,
                                            StringHandle out_string,
                                            ErrorHandle *error_out);

/**
 * Data type, as one of the `DataType` codes.
 */
int32_t nominal_channelmetadata_data_type(ChannelMetadataHandle handle,
                                          int32_t *out_type,
                                          ErrorHandle *error_out);

/**
 * List every channel in a dataset.
 *
 * One request; the result is held so that `_at` has a stable meaning.
 */
int32_t nominal_channelmetadata_list(ClientHandle client_handle,
                                     int32_t dataset_handle,
                                     ChannelListHandle *out_list,
                                     uint32_t *out_count,
                                     ErrorHandle *error_out);

/**
 * Metadata for the channel at `index` in a list, as its own handle.
 *
 * The returned handle is independent: it outlives the list and needs its own
 * `nominal_channelmetadata_free`.
 */
int32_t nominal_channelmetadata_list_at(ChannelListHandle list_handle,
                                        uint32_t index,
                                        ChannelMetadataHandle *out_metadata,
                                        ErrorHandle *error_out);

/**
 * Release a channel list. The metadata handles taken from it stay valid.
 */
int32_t nominal_channelmetadata_list_free(ChannelListHandle handle);

/**
 * Create a client and authenticate it with a bearer token.
 *
 * `workspace_rid` and `base_url` are optional: pass NULL or an empty string to
 * leave either unset. An unset base URL defaults to Nominal production, and an
 * unset workspace means the client is not scoped to one — the API does not
 * require it.
 *
 * Surrounding whitespace is trimmed from all three, so a token carrying a
 * trailing newline from a copy-paste still authenticates.
 *
 * The token is copied; the caller's pointer is not retained. Release the
 * result with `nominal_client_free`.
 */
int32_t nominal_client_new(const char *token,
                           const char *workspace_rid,
                           const char *base_url,
                           ClientHandle *out_client,
                           ErrorHandle *error_out);

/**
 * Release a client. Freeing an unknown handle is a no-op.
 *
 * Resources obtained through this client remain valid; they hold no reference
 * back to it.
 */
int32_t nominal_client_free(ClientHandle handle);

/**
 * Workspace RID this client is scoped to, or the empty string if unscoped.
 */
int32_t nominal_client_workspace_rid(ClientHandle handle,
                                     StringHandle out_string,
                                     ErrorHandle *error_out);

/**
 * Base API URL this client targets.
 */
int32_t nominal_client_base_url(ClientHandle handle,
                                StringHandle out_string,
                                ErrorHandle *error_out);

/**
 * Display name of the authenticated user.
 *
 * Doubles as a cheap credential check: it round-trips to the API, so a bad
 * token surfaces here rather than at the first real call.
 */
int32_t nominal_client_user_display_name(ClientHandle handle,
                                         StringHandle out_string,
                                         ErrorHandle *error_out);

/**
 * Fetch a channel decimated to roughly `buckets` points.
 *
 * The server chooses which points to keep. Use this for plotting, where full
 * resolution is wasted: the cap is 10,000 points, and a few thousand is
 * usually indistinguishable on screen.
 *
 * Timestamps are nanoseconds since the epoch, and the window is inclusive at
 * both ends.
 */
int32_t nominal_compute_fetch_decimated(ClientHandle client_handle,
                                        int32_t dataset_handle,
                                        const char *channel,
                                        int64_t start_nanos,
                                        int64_t end_nanos,
                                        uint32_t buckets,
                                        SeriesHandle *out_series,
                                        ErrorHandle *error_out);

/**
 * Fetch every sample of a channel in the window.
 *
 * Pages internally at the server's limit of 5,000 points and stitches the
 * result together, so one call returns the whole series. A wide window
 * therefore costs many round trips — [`crate::export`] moves the same data in
 * one request when the destination is a file.
 *
 * Gives up after 5,000 pages, about 25 million points, on the grounds that
 * anything larger does not belong in memory.
 */
int32_t nominal_compute_fetch(ClientHandle client_handle,
                              int32_t dataset_handle,
                              const char *channel,
                              int64_t start_nanos,
                              int64_t end_nanos,
                              SeriesHandle *out_series,
                              ErrorHandle *error_out);

/**
 * Release a fetched series. Freeing an unknown handle is a no-op.
 */
int32_t nominal_series_free(SeriesHandle handle);

/**
 * Number of points in a fetched series.
 */
int32_t nominal_series_length(SeriesHandle handle, uint32_t *out_length, ErrorHandle *error_out);

/**
 * Copy the timestamps into a caller-provided buffer, in nanoseconds.
 */
int32_t nominal_series_timestamps(SeriesHandle handle,
                                  int64_t *buffer,
                                  uint32_t capacity,
                                  uint32_t *out_written,
                                  ErrorHandle *error_out);

/**
 * Copy the values into a caller-provided buffer.
 */
int32_t nominal_series_values(SeriesHandle handle,
                              double *buffer,
                              uint32_t capacity,
                              uint32_t *out_written,
                              ErrorHandle *error_out);

/**
 * Every dataset the client can see, ordered by name.
 *
 * Discovery entry point, and the usual first call when no RID is known.
 * Release the list with `nominal_dataset_list_free`.
 */
int32_t nominal_dataset_list(ClientHandle client_handle,
                             DatasetListHandle *out_list,
                             uint32_t *out_count,
                             ErrorHandle *error_out);

/**
 * Datasets whose name contains `text`, ordered by name.
 *
 * Case-insensitive substring match; see `nominal_asset_search` for why only
 * substring is exposed.
 */
int32_t nominal_dataset_search(ClientHandle client_handle,
                               const char *text,
                               DatasetListHandle *out_list,
                               uint32_t *out_count,
                               ErrorHandle *error_out);

/**
 * The dataset at `index`, as its own handle.
 *
 * Independent of the list; needs its own `nominal_dataset_free`.
 */
int32_t nominal_dataset_list_at(ClientHandle client_handle,
                                DatasetListHandle list_handle,
                                uint32_t index,
                                DatasetHandle *out_dataset,
                                ErrorHandle *error_out);

/**
 * Release a dataset list. Handles taken from it stay valid.
 */
int32_t nominal_dataset_list_free(DatasetListHandle handle);

/**
 * Fetch a dataset by RID.
 */
int32_t nominal_dataset_get_by_rid(ClientHandle client_handle,
                                   const char *rid,
                                   DatasetHandle *out_dataset,
                                   ErrorHandle *error_out);

/**
 * Fetch a dataset by name, creating it and attaching it to `asset_handle` if
 * no dataset with that exact name exists.
 *
 * The dataset is attached to the asset under `ref_name`, which is how it is
 * addressed within that asset and must be unique among the asset's data
 * sources. An existing dataset is returned as-is and is not re-attached.
 */
int32_t nominal_dataset_get_or_create_by_name(ClientHandle client_handle,
                                              int32_t asset_handle,
                                              const char *name,
                                              const char *ref_name,
                                              DatasetHandle *out_dataset,
                                              ErrorHandle *error_out);

/**
 * Apply a staged update and return the updated dataset as a new handle.
 *
 * Staged start and end times are ignored, since datasets have neither. The
 * staging object is not consumed; free it with `nominal_update_free`.
 */
int32_t nominal_dataset_update_commit(ClientHandle client_handle,
                                      DatasetHandle dataset_handle,
                                      UpdateHandle update_handle,
                                      DatasetHandle *out_dataset,
                                      ErrorHandle *error_out);

/**
 * Release a dataset handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_dataset_free(DatasetHandle handle);

/**
 * RID of a dataset.
 */
int32_t nominal_dataset_rid(DatasetHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Name of a dataset.
 */
int32_t nominal_dataset_name(DatasetHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Create an event on one or more assets.
 *
 * `asset_rids` is an array of `asset_count` NUL-terminated RID strings. At
 * least one is required — an event with no asset is not created.
 *
 * `timestamp_nanos` is nanoseconds since the epoch, with `0` meaning now.
 * `duration_nanos` is how long the event spans; pass `0` for an instantaneous
 * event.
 *
 * `event_type` is 0 info, 1 flag, 2 error, 3 success.
 *
 * Release the result with `nominal_event_free`.
 */
int32_t nominal_event_create(ClientHandle client_handle,
                             const char *const *asset_rids,
                             uint32_t asset_count,
                             const char *name,
                             int32_t event_type,
                             int64_t timestamp_nanos,
                             int64_t duration_nanos,
                             EventHandle *out_event,
                             ErrorHandle *error_out);

/**
 * Release an event handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_event_free(EventHandle handle);

/**
 * RID of the event.
 */
int32_t nominal_event_rid(EventHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Event name.
 */
int32_t nominal_event_name(EventHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Event type: 0 info, 1 flag, 2 error, 3 success.
 */
int32_t nominal_event_type(EventHandle handle, int32_t *out_type, ErrorHandle *error_out);

/**
 * When the event occurred, in nanoseconds since the epoch.
 */
int32_t nominal_event_timestamp(EventHandle handle, int64_t *out_nanos, ErrorHandle *error_out);

/**
 * How long the event spans, in nanoseconds. Zero for an instant.
 */
int32_t nominal_event_duration(EventHandle handle, int64_t *out_nanos, ErrorHandle *error_out);

/**
 * Number of assets this event is attached to.
 */
int32_t nominal_event_asset_count(EventHandle handle, uint32_t *out_count, ErrorHandle *error_out);

/**
 * Asset RID at `index`, in sorted order.
 */
int32_t nominal_event_asset_at(EventHandle handle,
                               uint32_t index,
                               StringHandle out_string,
                               ErrorHandle *error_out);

/**
 * Export channel data to a file on disk.
 *
 * `channels` is an array of `channel_count` NUL-terminated channel names.
 * `start_nanos` and `end_nanos` bound the window, inclusive, in nanoseconds
 * since the epoch.
 *
 * `format` is 0 matfile, 1 csv, 2 arrow. `resolution` is 0 undecimated,
 * 1 buckets, 2 nanoseconds — with `resolution_value` supplying the count or
 * interval for the latter two, and ignored for undecimated.
 *
 * The file is written to `out_path`, replacing anything already there. Blocks
 * until the whole export has been received.
 */
int32_t nominal_export_to_file(ClientHandle client_handle,
                               int32_t dataset_handle,
                               const char *const *channels,
                               uint32_t channel_count,
                               int64_t start_nanos,
                               int64_t end_nanos,
                               int32_t resolution,
                               int64_t resolution_value,
                               int32_t format,
                               const char *out_path,
                               ErrorHandle *error_out);

/**
 * Ask for a download URL instead of the bytes.
 *
 * The server renders the file to object storage and returns a time-limited
 * presigned URL. Useful when the caller would rather hand the link to
 * something else — a browser, another process — than receive the bytes here.
 */
int32_t nominal_export_presigned_url(ClientHandle client_handle,
                                     int32_t dataset_handle,
                                     const char *const *channels,
                                     uint32_t channel_count,
                                     int64_t start_nanos,
                                     int64_t end_nanos,
                                     int32_t resolution,
                                     int64_t resolution_value,
                                     int32_t format,
                                     StringHandle out_string,
                                     ErrorHandle *error_out);

/**
 * Upload a CSV and start ingesting it.
 *
 * `timestamp_column` names the column holding time; `timestamp_kind` and
 * `timestamp_unit` say how to read it — see [`TimestampKind`] and [`Unit`].
 * The unit is ignored for ISO 8601.
 *
 * Pass `dataset_handle` to add to an existing dataset, or 0 with
 * `new_dataset_name` set to create one. `out_dataset_rid` receives the RID the
 * data is landing in, which is how you find a freshly-created dataset.
 *
 * Blocks while the file uploads, which for a large file is a long time. The
 * ingest itself continues afterwards — see [`nominal_ingest_wait`].
 */
int32_t nominal_ingest_csv(ClientHandle client_handle,
                           const char *path,
                           int32_t dataset_handle,
                           const char *new_dataset_name,
                           const char *timestamp_column,
                           int32_t timestamp_kind,
                           int32_t timestamp_unit,
                           IngestJobHandle *out_job,
                           StringHandle out_dataset_rid,
                           ErrorHandle *error_out);

/**
 * Upload a Parquet file and start ingesting it.
 *
 * Arguments match [`nominal_ingest_csv`].
 */
int32_t nominal_ingest_parquet(ClientHandle client_handle,
                               const char *path,
                               int32_t dataset_handle,
                               const char *new_dataset_name,
                               const char *timestamp_column,
                               int32_t timestamp_kind,
                               int32_t timestamp_unit,
                               IngestJobHandle *out_job,
                               StringHandle out_dataset_rid,
                               ErrorHandle *error_out);

/**
 * RID of an ingest job.
 */
int32_t nominal_ingest_job_rid(IngestJobHandle handle,
                               StringHandle out_string,
                               ErrorHandle *error_out);

/**
 * Re-read a job's status from the server.
 *
 * The handle holds the status as of when it was created, so this fetches a
 * fresh one rather than reporting a stale value. `out_status` receives a
 * [`JobStatus`] code.
 */
int32_t nominal_ingest_job_status(ClientHandle client_handle,
                                  IngestJobHandle handle,
                                  int32_t *out_status,
                                  ErrorHandle *error_out);

/**
 * Block until a job reaches a terminal state.
 *
 * Returns once the job has succeeded or failed. A failed job is reported
 * through `out_status` rather than as an error — the call did what it was
 * asked, and the ingest failing is a result, not a fault in the request.
 *
 * Polls server-side; there is no timeout, so a wedged job blocks indefinitely.
 * Use [`nominal_ingest_job_status`] in a loop of your own if you need one.
 */
int32_t nominal_ingest_wait(ClientHandle client_handle,
                            IngestJobHandle handle,
                            int32_t *out_status,
                            ErrorHandle *error_out);

/**
 * Release an ingest job handle. Freeing an unknown handle is a no-op.
 *
 * Does not cancel the ingest.
 */
int32_t nominal_ingest_job_free(IngestJobHandle handle);

/**
 * Create a run on an asset.
 *
 * `start_nanos` is nanoseconds since the Unix epoch; pass `0` to start the run
 * now. The run is left open: set its end with `nominal_run_set_end_time`, or
 * through a staged update.
 */
int32_t nominal_run_create(ClientHandle client_handle,
                           int32_t asset_handle,
                           const char *name,
                           int64_t start_nanos,
                           RunHandle *out_run,
                           ErrorHandle *error_out);

/**
 * Fetch a run by RID.
 */
int32_t nominal_run_get_by_rid(ClientHandle client_handle,
                               const char *rid,
                               RunHandle *out_run,
                               ErrorHandle *error_out);

/**
 * Close a run by setting its end time, returning the updated run as a new
 * handle.
 *
 * `end_nanos` is nanoseconds since the Unix epoch; pass `0` to end the run
 * now, which is the common case at the end of a test.
 */
int32_t nominal_run_set_end_time(ClientHandle client_handle,
                                 RunHandle run_handle,
                                 int64_t end_nanos,
                                 RunHandle *out_run,
                                 ErrorHandle *error_out);

/**
 * Attach a dataset to a run under a reference name.
 *
 * The reference name is how the dataset is addressed within the run, and must
 * be unique among that run's data sources.
 */
int32_t nominal_run_add_dataset(ClientHandle client_handle,
                                RunHandle run_handle,
                                const char *ref_name,
                                int32_t dataset_handle,
                                RunHandle *out_run,
                                ErrorHandle *error_out);

/**
 * Apply a staged update and return the updated run as a new handle.
 *
 * Honours every staged field, including start and end times. The staging
 * object is not consumed; free it with `nominal_update_free`.
 */
int32_t nominal_run_update_commit(ClientHandle client_handle,
                                  RunHandle run_handle,
                                  UpdateHandle update_handle,
                                  RunHandle *out_run,
                                  ErrorHandle *error_out);

/**
 * Release a run handle. Freeing an unknown handle is a no-op.
 */
int32_t nominal_run_free(RunHandle handle);

/**
 * RID of a run.
 */
int32_t nominal_run_rid(RunHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Name of a run.
 */
int32_t nominal_run_name(RunHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Description of a run.
 */
int32_t nominal_run_description(RunHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Sequential run number within the workspace.
 */
int32_t nominal_run_number(RunHandle handle, uint32_t *out_number, ErrorHandle *error_out);

/**
 * Start time, in nanoseconds since the Unix epoch.
 */
int32_t nominal_run_start_time(RunHandle handle, int64_t *out_nanos, ErrorHandle *error_out);

/**
 * End time, in nanoseconds since the Unix epoch.
 *
 * An open run has no end time: `out_has_end` receives false and `out_nanos`
 * receives 0. Check `out_has_end` before reading the timestamp, since 0 is
 * also a representable instant.
 */
int32_t nominal_run_end_time(RunHandle handle,
                             int64_t *out_nanos,
                             bool *out_has_end,
                             ErrorHandle *error_out);

/**
 * Web URL for this run in the Nominal app.
 */
int32_t nominal_run_url(RunHandle handle, StringHandle out_string, ErrorHandle *error_out);

/**
 * Number of labels on a run.
 */
int32_t nominal_run_label_count(RunHandle handle, uint32_t *out_count, ErrorHandle *error_out);

/**
 * Label at `index`, counting from zero.
 */
int32_t nominal_run_label_at(RunHandle handle,
                             uint32_t index,
                             StringHandle out_string,
                             ErrorHandle *error_out);

/**
 * Value of a property, or an error if the run has no such key.
 */
int32_t nominal_run_property(RunHandle handle,
                             const char *key,
                             StringHandle out_string,
                             ErrorHandle *error_out);

/**
 * Run a query and hold the result.
 *
 * `workspace_rid` may be NULL or empty, in which case the client's own
 * workspace is used. One or the other is required: the SQL service always
 * needs a workspace, even though the rest of the API does not.
 *
 * Release the result with `nominal_sql_free`.
 */
int32_t nominal_sql_query(ClientHandle client_handle,
                          const char *query,
                          const char *workspace_rid,
                          QueryResultHandle *out_result,
                          ErrorHandle *error_out);

/**
 * Release a query result. Freeing an unknown handle is a no-op.
 */
int32_t nominal_sql_free(QueryResultHandle handle);

/**
 * Number of rows in the result.
 */
int32_t nominal_sql_row_count(QueryResultHandle handle, uint32_t *out_rows, ErrorHandle *error_out);

/**
 * Number of columns in the result.
 */
int32_t nominal_sql_column_count(QueryResultHandle handle,
                                 uint32_t *out_columns,
                                 ErrorHandle *error_out);

/**
 * Name of the column at `index`, as the query selected it.
 */
int32_t nominal_sql_column_name(QueryResultHandle handle,
                                uint32_t index,
                                StringHandle out_string,
                                ErrorHandle *error_out);

/**
 * Type of the column at `index`, as a `ColumnType` code.
 */
int32_t nominal_sql_column_type(QueryResultHandle handle,
                                uint32_t index,
                                int32_t *out_type,
                                ErrorHandle *error_out);

/**
 * Copy a floating-point column into a caller-provided buffer.
 *
 * Nulls become NaN — distinguishable from a real value, since the warehouse
 * does not produce NaN itself. `out_written` receives the number of elements
 * copied, which is the lesser of the row count and `capacity`.
 */
int32_t nominal_sql_column_doubles(QueryResultHandle handle,
                                   uint32_t index,
                                   double *buffer,
                                   uint32_t capacity,
                                   uint32_t *out_written,
                                   ErrorHandle *error_out);

/**
 * Copy an integer or timestamp column into a caller-provided buffer.
 *
 * Timestamps are converted to **nanoseconds since the Unix epoch**, whatever
 * resolution the server sent — the warehouse has been observed emitting both
 * microsecond and nanosecond columns, and normalising here means callers do
 * not have to inspect the schema to know the scale.
 *
 * Nulls become 0. Use `nominal_sql_column_is_null` where that matters.
 */
int32_t nominal_sql_column_int64(QueryResultHandle handle,
                                 uint32_t index,
                                 int64_t *buffer,
                                 uint32_t capacity,
                                 uint32_t *out_written,
                                 ErrorHandle *error_out);

/**
 * Read one cell of a string column.
 *
 * A null cell yields the empty string; use `nominal_sql_column_is_null` to
 * tell that apart from a stored empty string.
 */
int32_t nominal_sql_column_string_at(QueryResultHandle handle,
                                     uint32_t index,
                                     uint32_t row,
                                     StringHandle out_string,
                                     ErrorHandle *error_out);

/**
 * Whether the cell at (`index`, `row`) is null.
 */
int32_t nominal_sql_column_is_null(QueryResultHandle handle,
                                   uint32_t index,
                                   uint32_t row,
                                   bool *out_is_null,
                                   ErrorHandle *error_out);

/**
 * Run a query and get a download URL for the full result as CSV.
 *
 * For results too large for `nominal_sql_query`, which is bounded at 1 GiB.
 * Export runs without that cap, writes to object storage, and returns a
 * time-limited presigned URL.
 *
 * CSV only, and only for queries reading telemetry tables — a query touching
 * `assets`, `runs`, or `datasets` cannot be exported this way. Some
 * deployments have no export bucket configured, in which case this fails.
 */
int32_t nominal_sql_export_url(ClientHandle client_handle,
                               const char *query,
                               const char *workspace_rid,
                               StringHandle out_string,
                               ErrorHandle *error_out);

/**
 * Open a stream that writes into a dataset.
 *
 * Data is buffered and shipped in the background; nothing is durable until it
 * reaches Core. Close the stream with `nominal_stream_free`, which flushes
 * what is still buffered.
 */
int32_t nominal_stream_create(ClientHandle client_handle,
                              int32_t dataset_handle,
                              StreamHandle *out_stream,
                              ErrorHandle *error_out);

/**
 * Close a stream, flushing whatever is still buffered.
 *
 * Blocks until the flush completes. Freeing an unknown handle is a no-op.
 *
 * Channels created against this stream are not freed, but stop working: a push
 * through one afterwards reports `InvalidHandle` rather than writing into a
 * stream nothing else can reach.
 */
int32_t nominal_stream_free(StreamHandle handle);

/**
 * Create a write address for `name` on `stream`, with no tags.
 *
 * Performs no API call — nothing exists in Nominal until points are written.
 * Release with `nominal_streamchannel_free`.
 */
int32_t nominal_streamchannel_create(StreamHandle stream_handle,
                                     const char *name,
                                     StreamChannelHandle *out_channel,
                                     ErrorHandle *error_out);

/**
 * Add a tag that will be stamped on every point written through this address.
 *
 * Tags belong to points, not to the channel, so changing them partway through
 * acquisition is legal: earlier points keep the tags they were sent with and
 * later ones carry the new set. All of them land in the same channel. That is
 * exactly how a multiplexed channel is written — one address per tag set, all
 * sharing a name.
 *
 * Keep the number of distinct tag values small. Tags are for grouping, so
 * anything that changes every point — a measurement, a timestamp, a UUID —
 * belongs in its own channel instead and will degrade queries if used here.
 */
int32_t nominal_streamchannel_set_tag(StreamChannelHandle handle,
                                      const char *key,
                                      const char *value,
                                      ErrorHandle *error_out);

/**
 * Channel name this address writes under.
 */
int32_t nominal_streamchannel_name(StreamChannelHandle handle,
                                   StringHandle out_string,
                                   ErrorHandle *error_out);

/**
 * Stream this address writes to.
 */
int32_t nominal_streamchannel_stream(StreamChannelHandle handle,
                                     StreamHandle *out_stream,
                                     ErrorHandle *error_out);

/**
 * Push a batch of floating-point samples.
 *
 * `timestamps_nanos` and `values` are parallel arrays of `count` elements.
 * Timestamps are nanoseconds since the Unix epoch, taken literally, zero
 * included.
 *
 * Blocks if the stream's buffers are full — see [`crate::stream`].
 */
int32_t nominal_streamchannel_push_doubles(StreamChannelHandle handle,
                                           const int64_t *timestamps_nanos,
                                           const double *values,
                                           uint32_t count,
                                           ErrorHandle *error_out);

/**
 * Push a batch of string samples.
 *
 * `timestamps_nanos` holds `count` elements; `values` holds `count`
 * NUL-terminated C strings.
 */
int32_t nominal_streamchannel_push_strings(StreamChannelHandle handle,
                                           const int64_t *timestamps_nanos,
                                           const char *const *values,
                                           uint32_t count,
                                           ErrorHandle *error_out);

/**
 * Release a write address. Freeing an unknown handle is a no-op.
 *
 * Does not affect points already sent, nor the channel in Nominal.
 */
int32_t nominal_streamchannel_free(StreamChannelHandle handle);

/**
 * Write a block of samples across several channels in one call.
 *
 * `channels` is an array of `channel_count` NUL-terminated channel names.
 * `timestamps` holds `row_count` nanosecond instants, shared by every channel.
 * `values` is column-major with `row_count * channel_count` elements: channel
 * `c` occupies `values[c * row_count .. (c + 1) * row_count]`, which is how
 * MATLAB already lays out an N-by-C matrix.
 *
 * Timestamps are literal, including zero — a stream may carry times relative
 * to an epoch the caller chose.
 *
 * Returns once the write has been accepted. Blocks for the duration.
 */
int32_t nominal_write_doubles(ClientHandle client_handle,
                              int32_t dataset_handle,
                              const char *const *channels,
                              uint32_t channel_count,
                              const int64_t *timestamps_nanos,
                              const double *values,
                              uint32_t row_count,
                              ErrorHandle *error_out);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus
