/*
 * nominalmex — the single MEX gateway to the Nominal C ABI.
 *
 * One binary rather than one per function, for two reasons: `mexAtExit` has to
 * be registered exactly once, and a .mexw64 per command would mean dozens of
 * files each carrying their own copy of the shutdown plumbing.
 *
 * The Rust library is linked in statically, so this file *is* the client as far
 * as MATLAB is concerned — there is no accompanying DLL to locate at load time.
 *
 * Called as nominalmex('command', args...). Nothing here is meant to be used
 * directly from MATLAB code — the +nominal classes wrap it. In particular this
 * layer takes and returns char arrays, not strings; the classes convert.
 *
 * Two C-level warts are absorbed here so MATLAB never sees them:
 *
 *   Status codes become exceptions. Every call that can fail is checked, and a
 *   non-zero status is raised as an MException carrying the library's own
 *   message, with an identifier derived from the error code.
 *
 *   String handles are invisible. Getters write into a scratch handle owned by
 *   this file, which immediately copies the bytes into a MATLAB char array.
 *
 * Build with build.m, which passes -R2018a for the interleaved-complex API.
 */

#include "mex.h"
#include "nominal_ffi.h"

#include <stdlib.h>
#include <string.h>

/* Mirrors ErrorCode in the Rust crate. */
#define NOMINAL_SUCCESS           0
#define NOMINAL_INVALID_HANDLE    1
#define NOMINAL_INVALID_PARAMETER 2
#define NOMINAL_API_ERROR         3
#define NOMINAL_RUNTIME_ERROR     4
#define NOMINAL_BUFFER_TOO_SMALL  5
#define NOMINAL_NO_CAPACITY       6

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

/* Reused across every string-returning call rather than allocated per call. */
static StringHandle g_scratch = 0;
static int g_registered = 0;

/*
 * Runs before MATLAB unloads this MEX file — on `clear mex`, `clear all`, or
 * exit. It is not optional: the library's Tokio worker threads would otherwise
 * outlive the unmapped module and take the process down.
 */
static void on_exit_cleanup(void)
{
    if (g_scratch != 0) {
        nominal_string_free(g_scratch);
        g_scratch = 0;
    }
    nominal_shutdown();
    g_registered = 0;
}

/*
 * Called once per MATLAB call, at the top of mexFunction and nowhere else.
 * Every handler below therefore runs with `g_scratch` already allocated and the
 * exit hook already installed, and none of them need to ask again.
 *
 * Re-entrant across calls rather than once-ever: `shutdown` releases the scratch
 * handle mid-session, so the next call has to allocate a fresh one. That is why
 * this tests `g_scratch` rather than relying on `g_registered` alone.
 */
static void ensure_registered(void)
{
    if (!g_registered) {
        mexAtExit(on_exit_cleanup);
        g_registered = 1;
    }
    if (g_scratch == 0) {
        if (nominal_string_alloc(&g_scratch) != NOMINAL_SUCCESS) {
            mexErrMsgIdAndTxt("nominal:runtimeError",
                              "could not allocate a string handle");
        }
    }
}

/* ------------------------------------------------------------------ */
/* Errors                                                              */
/* ------------------------------------------------------------------ */

static const char *identifier_for(int32_t status)
{
    switch (status) {
        case NOMINAL_INVALID_HANDLE:    return "nominal:invalidHandle";
        case NOMINAL_INVALID_PARAMETER: return "nominal:invalidParameter";
        case NOMINAL_API_ERROR:         return "nominal:apiError";
        case NOMINAL_RUNTIME_ERROR:     return "nominal:runtimeError";
        case NOMINAL_BUFFER_TOO_SMALL:  return "nominal:bufferTooSmall";
        case NOMINAL_NO_CAPACITY:       return "nominal:noCapacity";
        default:                        return "nominal:error";
    }
}

/*
 * Raise a non-zero status as an MException, carrying the library's message.
 *
 * Frees the error handle before throwing. `mexErrMsgIdAndTxt` does not return,
 * so anything not released first would leak on every failure.
 */
static void throw_if_failed(int32_t status, ErrorHandle err)
{
    char message[2048];
    uint32_t copied = 0;

    if (status == NOMINAL_SUCCESS) {
        if (err != 0) {
            nominal_error_free(err);  /* defensive; should already be 0 */
        }
        return;
    }

    message[0] = '\0';
    if (err != 0) {
        if (nominal_error_message(err, g_scratch) == NOMINAL_SUCCESS) {
            copied = nominal_copy_string_from_reference(
                g_scratch, message, (uint32_t)sizeof(message));
            message[copied < sizeof(message) ? copied : sizeof(message) - 1] = '\0';
        }
        nominal_error_free(err);
    }

    mexErrMsgIdAndTxt(identifier_for(status), "%s",
                      message[0] ? message : "the Nominal library reported a failure");
}

/* ------------------------------------------------------------------ */
/* Argument conversion                                                 */
/* ------------------------------------------------------------------ */

static void require_args(int nrhs, int wanted, const char *command)
{
    /* nrhs counts the command itself. */
    if (nrhs != wanted + 1) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "%s expects %d argument(s), got %d",
                          command, wanted, nrhs - 1);
    }
}

static int32_t arg_i32(const mxArray *a, const char *what)
{
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "%s must be a numeric scalar", what);
    }
    return (int32_t)mxGetScalar(a);
}

static int64_t arg_i64(const mxArray *a, const char *what)
{
    if (mxIsInt64(a) && mxGetNumberOfElements(a) == 1) {
        return *mxGetInt64s(a);
    }
    if (mxIsDouble(a) && !mxIsComplex(a) && mxGetNumberOfElements(a) == 1) {
        /* Doubles lose integer precision past 2^53, which for nanoseconds is
         * about 1970 + 104 days. Refuse rather than silently round a timestamp. */
        double v = mxGetScalar(a);
        if (v != 0.0) {
            mexErrMsgIdAndTxt("nominal:invalidParameter",
                              "%s must be int64; a double cannot hold a "
                              "nanosecond timestamp exactly (only 0 is accepted)",
                              what);
        }
        return 0;
    }
    mexErrMsgIdAndTxt("nominal:invalidParameter", "%s must be an int64 scalar", what);
    return 0;
}

/* Caller frees with mxFree. */
static char *arg_string(const mxArray *a, const char *what)
{
    char *s;
    if (!mxIsChar(a)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "%s must be a character vector", what);
    }
    s = mxArrayToUTF8String(a);
    if (s == NULL) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "%s is not valid text", what);
    }
    return s;
}

static const int64_t *arg_i64_vector(const mxArray *a, size_t *count, const char *what)
{
    if (!mxIsInt64(a) || mxIsComplex(a)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "%s must be an int64 vector", what);
    }
    *count = mxGetNumberOfElements(a);
    return (const int64_t *)mxGetInt64s(a);
}

static const double *arg_double_vector(const mxArray *a, size_t *count, const char *what)
{
    if (!mxIsDouble(a) || mxIsComplex(a)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "%s must be a double vector", what);
    }
    *count = mxGetNumberOfElements(a);
    return mxGetDoubles(a);
}

/* ------------------------------------------------------------------ */
/* Result conversion                                                   */
/* ------------------------------------------------------------------ */

/* Read the scratch string handle into a MATLAB char array. */
static mxArray *scratch_to_mx(void)
{
    uint32_t length = nominal_string_length(g_scratch);
    char *buffer = (char *)mxMalloc((size_t)length + 1);
    uint32_t copied = nominal_copy_string_from_reference(g_scratch, buffer, length + 1);
    mxArray *out;

    buffer[copied] = '\0';
    out = mxCreateString(buffer);
    mxFree(buffer);
    return out;
}

static mxArray *mx_i32(int32_t v)
{
    mxArray *a = mxCreateNumericMatrix(1, 1, mxINT32_CLASS, mxREAL);
    *mxGetInt32s(a) = v;
    return a;
}

static mxArray *mx_i64(int64_t v)
{
    mxArray *a = mxCreateNumericMatrix(1, 1, mxINT64_CLASS, mxREAL);
    *mxGetInt64s(a) = v;
    return a;
}

static mxArray *mx_u32(uint32_t v)
{
    mxArray *a = mxCreateNumericMatrix(1, 1, mxUINT32_CLASS, mxREAL);
    *mxGetUint32s(a) = v;
    return a;
}

/* ------------------------------------------------------------------ */
/* Shape helpers                                                       */
/*                                                                     */
/* Most of the C surface falls into a handful of shapes. These collapse */
/* the repetition without hiding what each command actually calls.      */
/* ------------------------------------------------------------------ */

typedef int32_t (*getter_string_fn)(int32_t, StringHandle, ErrorHandle *);
typedef int32_t (*getter_u32_fn)(int32_t, uint32_t *, ErrorHandle *);
typedef int32_t (*free_fn)(int32_t);
typedef int32_t (*lookup_fn)(ClientHandle, const char *, int32_t *, ErrorHandle *);

static void do_getter_string(getter_string_fn fn, int nlhs, mxArray *plhs[],
                             int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    int32_t handle;
    (void)nlhs;

    require_args(nrhs, 1, command);
    handle = arg_i32(prhs[1], "handle");
    throw_if_failed(fn(handle, g_scratch, &err), err);
    plhs[0] = scratch_to_mx();
}

static void do_getter_u32(getter_u32_fn fn, int nlhs, mxArray *plhs[],
                          int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    uint32_t value = 0;
    int32_t handle;
    (void)nlhs;

    require_args(nrhs, 1, command);
    handle = arg_i32(prhs[1], "handle");
    throw_if_failed(fn(handle, &value, &err), err);
    plhs[0] = mx_u32(value);
}

static void do_free(free_fn fn, int nlhs, mxArray *plhs[],
                    int nrhs, const mxArray *prhs[], const char *command)
{
    (void)nlhs; (void)plhs;
    require_args(nrhs, 1, command);
    fn(arg_i32(prhs[1], "handle"));  /* freeing an unknown handle is a no-op */
}

static void do_lookup(lookup_fn fn, int nlhs, mxArray *plhs[],
                      int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    int32_t out = 0;
    int32_t client;
    char *text;
    int32_t status;
    (void)nlhs;

    require_args(nrhs, 2, command);
    client = arg_i32(prhs[1], "client");
    text = arg_string(prhs[2], "name or rid");
    status = fn(client, text, &out, &err);
    mxFree(text);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

/* A staged-update setter taking one string. */
static void do_update_set1(int32_t (*fn)(UpdateHandle, const char *, ErrorHandle *),
                           int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    int32_t handle;
    char *text;
    int32_t status;

    require_args(nrhs, 2, command);
    handle = arg_i32(prhs[1], "update");
    text = arg_string(prhs[2], "value");
    status = fn(handle, text, &err);
    mxFree(text);
    throw_if_failed(status, err);
}

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

static void cmd_shutdown(int nrhs, const mxArray *prhs[])
{
    (void)prhs;
    require_args(nrhs, 0, "shutdown");
    if (g_scratch != 0) {
        nominal_string_free(g_scratch);
        g_scratch = 0;
    }
    nominal_shutdown();
}

static void cmd_timestamp_now(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)prhs;
    require_args(nrhs, 0, "timestamp_now");
    plhs[0] = mx_i64(nominal_timestamp_now());
}

static void cmd_client_new(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    ClientHandle client = 0;
    char *token, *workspace, *base_url;
    int32_t status;

    require_args(nrhs, 3, "client_new");
    token = arg_string(prhs[1], "token");
    workspace = arg_string(prhs[2], "workspace");
    base_url = arg_string(prhs[3], "baseUrl");

    status = nominal_client_new(token, workspace, base_url, &client, &err);

    mxFree(token);
    mxFree(workspace);
    mxFree(base_url);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(client);
}

static void cmd_asset_update_commit(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    AssetHandle out = 0;
    require_args(nrhs, 3, "asset_update_commit");
    throw_if_failed(nominal_asset_update_commit(arg_i32(prhs[1], "client"),
                                                arg_i32(prhs[2], "asset"),
                                                arg_i32(prhs[3], "update"),
                                                &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_dataset_update_commit(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    DatasetHandle out = 0;
    require_args(nrhs, 3, "dataset_update_commit");
    throw_if_failed(nominal_dataset_update_commit(arg_i32(prhs[1], "client"),
                                                  arg_i32(prhs[2], "dataset"),
                                                  arg_i32(prhs[3], "update"),
                                                  &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_run_update_commit(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    RunHandle out = 0;
    require_args(nrhs, 3, "run_update_commit");
    throw_if_failed(nominal_run_update_commit(arg_i32(prhs[1], "client"),
                                              arg_i32(prhs[2], "run"),
                                              arg_i32(prhs[3], "update"),
                                              &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_dataset_get_or_create(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    DatasetHandle out = 0;
    char *name, *ref_name;
    int32_t status;

    require_args(nrhs, 4, "dataset_get_or_create");
    name = arg_string(prhs[3], "name");
    ref_name = arg_string(prhs[4], "refName");
    status = nominal_dataset_get_or_create_by_name(arg_i32(prhs[1], "client"),
                                                   arg_i32(prhs[2], "asset"),
                                                   name, ref_name, &out, &err);
    mxFree(name);
    mxFree(ref_name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_run_create(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    RunHandle out = 0;
    char *name;
    int32_t status;

    require_args(nrhs, 4, "run_create");
    name = arg_string(prhs[3], "name");
    status = nominal_run_create(arg_i32(prhs[1], "client"),
                                arg_i32(prhs[2], "asset"),
                                name,
                                arg_i64(prhs[4], "startNanos"),
                                &out, &err);
    mxFree(name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_run_set_end_time(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    RunHandle out = 0;
    require_args(nrhs, 3, "run_set_end_time");
    throw_if_failed(nominal_run_set_end_time(arg_i32(prhs[1], "client"),
                                             arg_i32(prhs[2], "run"),
                                             arg_i64(prhs[3], "endNanos"),
                                             &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_run_add_dataset(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    RunHandle out = 0;
    char *ref_name;
    int32_t status;

    require_args(nrhs, 4, "run_add_dataset");
    ref_name = arg_string(prhs[3], "refName");
    status = nominal_run_add_dataset(arg_i32(prhs[1], "client"),
                                     arg_i32(prhs[2], "run"),
                                     ref_name,
                                     arg_i32(prhs[4], "dataset"),
                                     &out, &err);
    mxFree(ref_name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

/* Returns [nanos, hasEnd]; an open run reports hasEnd false and nanos 0. */
static void cmd_run_end_time(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    int64_t nanos = 0;
    bool has_end = false;

    require_args(nrhs, 1, "run_end_time");
    throw_if_failed(nominal_run_end_time(arg_i32(prhs[1], "run"),
                                         &nanos, &has_end, &err), err);
    plhs[0] = mx_i64(nanos);
    plhs[1] = mxCreateLogicalScalar(has_end);
}

static void cmd_run_start_time(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    int64_t nanos = 0;
    require_args(nrhs, 1, "run_start_time");
    throw_if_failed(nominal_run_start_time(arg_i32(prhs[1], "run"), &nanos, &err), err);
    plhs[0] = mx_i64(nanos);
}

static void cmd_property(int32_t (*fn)(int32_t, const char *, StringHandle, ErrorHandle *),
                         mxArray *plhs[], int nrhs, const mxArray *prhs[],
                         const char *command)
{
    ErrorHandle err = 0;
    char *key;
    int32_t status;

    require_args(nrhs, 2, command);
    key = arg_string(prhs[2], "key");
    status = fn(arg_i32(prhs[1], "handle"), key, g_scratch, &err);
    mxFree(key);
    throw_if_failed(status, err);
    plhs[0] = scratch_to_mx();
}

static void cmd_label_at(int32_t (*fn)(int32_t, uint32_t, StringHandle, ErrorHandle *),
                         mxArray *plhs[], int nrhs, const mxArray *prhs[],
                         const char *command)
{
    ErrorHandle err = 0;
    require_args(nrhs, 2, command);
    throw_if_failed(fn(arg_i32(prhs[1], "handle"),
                       (uint32_t)arg_i32(prhs[2], "index"),
                       g_scratch, &err), err);
    plhs[0] = scratch_to_mx();
}

static void cmd_stream_create(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    StreamHandle out = 0;
    require_args(nrhs, 2, "stream_create");
    throw_if_failed(nominal_stream_create(arg_i32(prhs[1], "client"),
                                          arg_i32(prhs[2], "dataset"),
                                          &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_channel_create(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    StreamChannelHandle out = 0;
    char *name;
    int32_t status;

    require_args(nrhs, 2, "channel_create");
    name = arg_string(prhs[2], "name");
    status = nominal_streamchannel_create(arg_i32(prhs[1], "stream"), name, &out, &err);
    mxFree(name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_channel_set_tag(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    char *key, *value;
    int32_t status;

    require_args(nrhs, 3, "channel_set_tag");
    key = arg_string(prhs[2], "key");
    value = arg_string(prhs[3], "value");
    status = nominal_streamchannel_set_tag(arg_i32(prhs[1], "channel"), key, value, &err);
    mxFree(key);
    mxFree(value);
    throw_if_failed(status, err);
}

static void cmd_channel_push(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    size_t n_times = 0, n_values = 0;
    const int64_t *times;
    const double *values;

    require_args(nrhs, 3, "channel_push");
    times = arg_i64_vector(prhs[2], &n_times, "timestamps");
    values = arg_double_vector(prhs[3], &n_values, "values");

    if (n_times != n_values) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "timestamps and values must be the same length "
                          "(%llu vs %llu)",
                          (unsigned long long)n_times, (unsigned long long)n_values);
    }

    throw_if_failed(nominal_streamchannel_push_doubles(
        arg_i32(prhs[1], "channel"), times, values, (uint32_t)n_times, &err), err);
}

/*
 * Push an N-by-C matrix: one column per channel, sharing one timestamp column.
 *
 * MATLAB stores matrices column-major, so each channel's samples are already
 * contiguous — column c starts at `values + c*rows` and can be handed straight
 * to the library with no copy or transpose. That is why this exists rather than
 * a MATLAB-side loop: the loop would be identical, but would cross the MEX
 * boundary once per channel.
 */
static void cmd_channel_push_matrix(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    size_t n_times = 0, rows, cols, c;
    const int64_t *times;
    const double *values;
    const mxArray *channels_arg;
    const int32_t *channels;

    require_args(nrhs, 3, "channel_push_matrix");

    channels_arg = prhs[1];
    if (!mxIsInt32(channels_arg)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "channels must be an int32 vector");
    }
    channels = (const int32_t *)mxGetInt32s(channels_arg);
    cols = mxGetNumberOfElements(channels_arg);

    times = arg_i64_vector(prhs[2], &n_times, "timestamps");

    if (!mxIsDouble(prhs[3]) || mxIsComplex(prhs[3])) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "values must be a double matrix");
    }
    rows = mxGetM(prhs[3]);
    values = mxGetDoubles(prhs[3]);

    if (mxGetN(prhs[3]) != cols) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "values has %llu columns but %llu channels were given",
                          (unsigned long long)mxGetN(prhs[3]),
                          (unsigned long long)cols);
    }
    if (rows != n_times) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "values has %llu rows but %llu timestamps were given",
                          (unsigned long long)rows, (unsigned long long)n_times);
    }

    for (c = 0; c < cols; ++c) {
        int32_t status = nominal_streamchannel_push_doubles(
            channels[c], times, values + c * rows, (uint32_t)rows, &err);
        if (status != NOMINAL_SUCCESS) {
            /* Columns are pushed one at a time and the stream has no rollback,
             * so a failure part-way leaves earlier channels already sent. Say
             * so before throwing: the exception itself carries the library's
             * message but not the position, and "which channel" is what tells
             * the caller how much of the block landed. */
            if (c > 0) {
                mexWarnMsgIdAndTxt("nominal:partialPush",
                                   "push failed on channel %llu of %llu; "
                                   "channels 1 to %llu were already sent",
                                   (unsigned long long)(c + 1),
                                   (unsigned long long)cols,
                                   (unsigned long long)c);
            }
            throw_if_failed(status, err);
        }
    }
}

static void cmd_channel_stream(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    StreamHandle out = 0;
    require_args(nrhs, 1, "channel_stream");
    throw_if_failed(nominal_streamchannel_stream(arg_i32(prhs[1], "channel"), &out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_update_begin(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    UpdateHandle out = 0;
    (void)prhs;
    require_args(nrhs, 0, "update_begin");
    throw_if_failed(nominal_update_begin(&out, &err), err);
    plhs[0] = mx_i32(out);
}

static void cmd_update_set_property(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    char *key, *value;
    int32_t status;

    require_args(nrhs, 3, "update_set_property");
    key = arg_string(prhs[2], "key");
    value = arg_string(prhs[3], "value");
    status = nominal_update_set_property(arg_i32(prhs[1], "update"), key, value, &err);
    mxFree(key);
    mxFree(value);
    throw_if_failed(status, err);
}

static void cmd_update_set_time(int32_t (*fn)(UpdateHandle, int64_t, ErrorHandle *),
                                int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    require_args(nrhs, 2, command);
    throw_if_failed(fn(arg_i32(prhs[1], "update"),
                       arg_i64(prhs[2], "nanos"), &err), err);
}

static void cmd_update_clear(int32_t (*fn)(UpdateHandle, ErrorHandle *),
                             int nrhs, const mxArray *prhs[], const char *command)
{
    ErrorHandle err = 0;
    require_args(nrhs, 1, command);
    throw_if_failed(fn(arg_i32(prhs[1], "update"), &err), err);
}

/* ------------------------------------------------------------------ */
/* Enumerations                                                        */
/*                                                                     */
/* Crossing as text rather than as integer codes. MATLAB has no enum    */
/* type worth using here, and "dataset" reads better in a table than 0. */
/* ------------------------------------------------------------------ */

static const char *datasource_kind_name(int32_t kind)
{
    switch (kind) {
        case 0:  return "dataset";
        case 1:  return "video";
        case 2:  return "connection";
        default: return "unknown";
    }
}

static const char *data_type_name(int32_t code)
{
    static const char *names[] = {
        "double", "int", "uint", "string", "log",
        "doubleArray", "stringArray", "struct", "video", "spatial", "unknown"
    };
    if (code >= 0 && code < (int32_t)(sizeof(names) / sizeof(names[0]))) {
        return names[code];
    }
    return "unknown";
}

static int32_t data_type_code(const char *name)
{
    static const char *names[] = {
        "double", "int", "uint", "string", "log",
        "doubleArray", "stringArray", "struct", "video", "spatial", "unknown"
    };
    int32_t i;
    for (i = 0; i < (int32_t)(sizeof(names) / sizeof(names[0])); ++i) {
        if (strcmp(name, names[i]) == 0) {
            return i;
        }
    }
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown data type '%s'; expected one of double, int, "
                      "uint, string, log, doubleArray, stringArray, struct, "
                      "video, spatial", name);
    return -1;
}

static const char *event_type_name(int32_t code)
{
    switch (code) {
        case 0:  return "info";
        case 1:  return "flag";
        case 2:  return "error";
        case 3:  return "success";
        default: return "info";
    }
}

static int32_t event_type_code(const char *name)
{
    if (strcmp(name, "info") == 0)    return 0;
    if (strcmp(name, "flag") == 0)    return 1;
    if (strcmp(name, "error") == 0)   return 2;
    if (strcmp(name, "success") == 0) return 3;
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown event type '%s'; expected info, flag, error, "
                      "or success", name);
    return -1;
}

/* ------------------------------------------------------------------ */
/* Data sources                                                        */
/* ------------------------------------------------------------------ */

/*
 * Return every data source on an asset as a struct array.
 *
 * Assembled here rather than in MATLAB so the whole table costs one MEX call
 * instead of three per row. The library orders entries by reference name, so
 * the result is reproducible.
 */
static void cmd_asset_datasources(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    static const char *fields[] = { "RefName", "Rid", "Type" };
    ErrorHandle err = 0;
    AssetHandle asset;
    uint32_t count = 0, i;
    mxArray *out;

    require_args(nrhs, 1, "asset_datasources");
    asset = arg_i32(prhs[1], "asset");

    throw_if_failed(nominal_asset_datasource_count(asset, &count, &err), err);

    out = mxCreateStructMatrix((mwSize)count, 1, 3, fields);
    for (i = 0; i < count; ++i) {
        int32_t kind = 0;

        throw_if_failed(nominal_asset_datasource_ref_name_at(asset, i, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 0, scratch_to_mx());

        throw_if_failed(nominal_asset_datasource_rid_at(asset, i, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 1, scratch_to_mx());

        throw_if_failed(nominal_asset_datasource_type_at(asset, i, &kind, &err), err);
        mxSetFieldByNumber(out, i, 2, mxCreateString(datasource_kind_name(kind)));
    }

    plhs[0] = out;
}

/* ------------------------------------------------------------------ */
/* One-shot write                                                      */
/* ------------------------------------------------------------------ */

/*
 * Write an N-by-C matrix in a single call, no stream involved.
 *
 * Column-major throughout: MATLAB already stores the matrix that way, and the
 * C API expects channel c at values[c*rows .. (c+1)*rows], so the buffer goes
 * across untouched.
 */
static void cmd_dataset_write(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    const mxArray *channels_arg;
    char **names;
    const char **name_ptrs;
    mwSize cols, i;
    size_t n_times = 0, rows;
    const int64_t *times;
    const double *values;
    int32_t status;

    require_args(nrhs, 4, "dataset_write");

    channels_arg = prhs[3];
    if (!mxIsCell(channels_arg)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "channels must be a cell array of character vectors");
    }
    cols = mxGetNumberOfElements(channels_arg);

    times = arg_i64_vector(prhs[4], &n_times, "timestamps");

    if (!mxIsDouble(prhs[5]) || mxIsComplex(prhs[5])) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "values must be a double matrix");
    }
    rows = mxGetM(prhs[5]);
    values = mxGetDoubles(prhs[5]);

    if (mxGetN(prhs[5]) != cols) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "values has %llu columns but %llu channels were given",
                          (unsigned long long)mxGetN(prhs[5]),
                          (unsigned long long)cols);
    }
    if (rows != n_times) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "values has %llu rows but %llu timestamps were given",
                          (unsigned long long)rows, (unsigned long long)n_times);
    }

    names = (char **)mxCalloc(cols, sizeof(char *));
    name_ptrs = (const char **)mxCalloc(cols, sizeof(char *));
    for (i = 0; i < cols; ++i) {
        names[i] = arg_string(mxGetCell(channels_arg, i), "channel name");
        name_ptrs[i] = names[i];
    }

    status = nominal_write_doubles(arg_i32(prhs[1], "client"),
                                   arg_i32(prhs[2], "dataset"),
                                   name_ptrs, (uint32_t)cols,
                                   times, values, (uint32_t)rows, &err);

    for (i = 0; i < cols; ++i) {
        mxFree(names[i]);
    }
    mxFree(names);
    mxFree((void *)name_ptrs);

    throw_if_failed(status, err);
}

/* ------------------------------------------------------------------ */
/* Discovery                                                           */
/*                                                                     */
/* Listing returns a struct array in one call. The C API hands back a   */
/* list handle plus indexed access so that indices stay stable; MATLAB  */
/* wants the whole table at once, so the handle is created and released */
/* entirely within these functions.                                     */
/* ------------------------------------------------------------------ */

static void cmd_asset_list(mxArray *plhs[], int nrhs, const mxArray *prhs[],
                           const char *command)
{
    static const char *fields[] = { "Name", "Rid", "Description" };
    ErrorHandle err = 0;
    int32_t list = 0, status;
    uint32_t count = 0, i;
    mxArray *out;
    char *text = NULL;

    if (strcmp(command, "asset_search") == 0) {
        require_args(nrhs, 2, command);
        text = arg_string(prhs[2], "text");
        status = nominal_asset_search(arg_i32(prhs[1], "client"), text,
                                      &list, &count, &err);
        mxFree(text);
    } else {
        require_args(nrhs, 1, command);
        status = nominal_asset_list(arg_i32(prhs[1], "client"), &list, &count, &err);
    }
    throw_if_failed(status, err);

    out = mxCreateStructMatrix((mwSize)count, 1, 3, fields);
    for (i = 0; i < count; ++i) {
        AssetHandle asset = 0;
        throw_if_failed(nominal_asset_list_at(list, i, &asset, &err), err);

        throw_if_failed(nominal_asset_name(asset, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 0, scratch_to_mx());

        throw_if_failed(nominal_asset_rid(asset, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 1, scratch_to_mx());

        throw_if_failed(nominal_asset_description(asset, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 2, scratch_to_mx());

        nominal_asset_free(asset);
    }

    nominal_asset_list_free(list);
    plhs[0] = out;
}

static void cmd_dataset_list(mxArray *plhs[], int nrhs, const mxArray *prhs[],
                             const char *command)
{
    static const char *fields[] = { "Name", "Rid" };
    ErrorHandle err = 0;
    int32_t client, list = 0, status;
    uint32_t count = 0, i;
    mxArray *out;
    char *text = NULL;

    client = arg_i32(prhs[1], "client");

    if (strcmp(command, "dataset_search") == 0) {
        require_args(nrhs, 2, command);
        text = arg_string(prhs[2], "text");
        status = nominal_dataset_search(client, text, &list, &count, &err);
        mxFree(text);
    } else {
        require_args(nrhs, 1, command);
        status = nominal_dataset_list(client, &list, &count, &err);
    }
    throw_if_failed(status, err);

    out = mxCreateStructMatrix((mwSize)count, 1, 2, fields);
    for (i = 0; i < count; ++i) {
        DatasetHandle dataset = 0;
        throw_if_failed(nominal_dataset_list_at(client, list, i, &dataset, &err), err);

        throw_if_failed(nominal_dataset_name(dataset, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 0, scratch_to_mx());

        throw_if_failed(nominal_dataset_rid(dataset, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 1, scratch_to_mx());

        nominal_dataset_free(dataset);
    }

    nominal_dataset_list_free(list);
    plhs[0] = out;
}

/* ------------------------------------------------------------------ */
/* Channel metadata                                                    */
/* ------------------------------------------------------------------ */

static void cmd_meta_get(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    ChannelMetadataHandle out = 0;
    char *name;
    int32_t status;

    require_args(nrhs, 3, "meta_get");
    name = arg_string(prhs[3], "name");
    status = nominal_channelmetadata_get(arg_i32(prhs[1], "client"),
                                         arg_i32(prhs[2], "dataset"),
                                         name, &out, &err);
    mxFree(name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_meta_set(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    ChannelMetadataHandle out = 0;
    char *name, *type_name, *unit, *description;
    int32_t status;

    require_args(nrhs, 6, "meta_set");
    name = arg_string(prhs[3], "name");
    type_name = arg_string(prhs[4], "dataType");
    unit = arg_string(prhs[5], "unit");
    description = arg_string(prhs[6], "description");

    status = nominal_channelmetadata_set(arg_i32(prhs[1], "client"),
                                         arg_i32(prhs[2], "dataset"),
                                         name, data_type_code(type_name),
                                         unit, description, &out, &err);
    mxFree(name);
    mxFree(type_name);
    mxFree(unit);
    mxFree(description);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_meta_data_type(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    int32_t code = 0;
    require_args(nrhs, 1, "meta_data_type");
    throw_if_failed(nominal_channelmetadata_data_type(arg_i32(prhs[1], "handle"),
                                                      &code, &err), err);
    plhs[0] = mxCreateString(data_type_name(code));
}

/*
 * Every channel in a dataset, as a struct array.
 *
 * The library holds the list behind a handle so indices stay stable; that
 * handle is created and released entirely within this call, since MATLAB gets
 * the whole table at once and has no use for it afterwards.
 */
static void cmd_meta_list(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    static const char *fields[] = { "Name", "Unit", "Description", "DataType" };
    ErrorHandle err = 0;
    ChannelListHandle list = 0;
    uint32_t count = 0, i;
    mxArray *out;

    require_args(nrhs, 2, "meta_list");
    throw_if_failed(nominal_channelmetadata_list(arg_i32(prhs[1], "client"),
                                                 arg_i32(prhs[2], "dataset"),
                                                 &list, &count, &err), err);

    out = mxCreateStructMatrix((mwSize)count, 1, 4, fields);
    for (i = 0; i < count; ++i) {
        ChannelMetadataHandle meta = 0;
        int32_t code = 0;

        throw_if_failed(nominal_channelmetadata_list_at(list, i, &meta, &err), err);

        throw_if_failed(nominal_channelmetadata_name(meta, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 0, scratch_to_mx());

        throw_if_failed(nominal_channelmetadata_unit(meta, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 1, scratch_to_mx());

        throw_if_failed(nominal_channelmetadata_description(meta, g_scratch, &err), err);
        mxSetFieldByNumber(out, i, 2, scratch_to_mx());

        throw_if_failed(nominal_channelmetadata_data_type(meta, &code, &err), err);
        mxSetFieldByNumber(out, i, 3, mxCreateString(data_type_name(code)));

        nominal_channelmetadata_free(meta);
    }

    nominal_channelmetadata_list_free(list);
    plhs[0] = out;
}

/* ------------------------------------------------------------------ */
/* Events                                                              */
/* ------------------------------------------------------------------ */

static void cmd_event_create(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    EventHandle out = 0;
    const mxArray *rids_arg;
    char **rids;
    const char **rid_ptrs;
    mwSize count, i;
    char *name, *type_name;
    int32_t status;

    require_args(nrhs, 6, "event_create");

    rids_arg = prhs[2];
    if (!mxIsCell(rids_arg)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "assetRids must be a cell array of character vectors");
    }
    count = mxGetNumberOfElements(rids_arg);
    if (count == 0) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "at least one asset RID is required");
    }

    rids = (char **)mxCalloc(count, sizeof(char *));
    rid_ptrs = (const char **)mxCalloc(count, sizeof(char *));
    for (i = 0; i < count; ++i) {
        rids[i] = arg_string(mxGetCell(rids_arg, i), "assetRids element");
        rid_ptrs[i] = rids[i];
    }

    name = arg_string(prhs[3], "name");
    type_name = arg_string(prhs[4], "type");

    status = nominal_event_create(arg_i32(prhs[1], "client"),
                                  rid_ptrs, (uint32_t)count,
                                  name, event_type_code(type_name),
                                  arg_i64(prhs[5], "timestamp"),
                                  arg_i64(prhs[6], "duration"),
                                  &out, &err);

    for (i = 0; i < count; ++i) {
        mxFree(rids[i]);
    }
    mxFree(rids);
    mxFree((void *)rid_ptrs);
    mxFree(name);
    mxFree(type_name);

    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
}

static void cmd_event_type(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    int32_t code = 0;
    require_args(nrhs, 1, "event_type");
    throw_if_failed(nominal_event_type(arg_i32(prhs[1], "event"), &code, &err), err);
    plhs[0] = mxCreateString(event_type_name(code));
}

static void cmd_event_i64(int32_t (*fn)(EventHandle, int64_t *, ErrorHandle *),
                          mxArray *plhs[], int nrhs, const mxArray *prhs[],
                          const char *command)
{
    ErrorHandle err = 0;
    int64_t nanos = 0;
    require_args(nrhs, 1, command);
    throw_if_failed(fn(arg_i32(prhs[1], "event"), &nanos, &err), err);
    plhs[0] = mx_i64(nanos);
}

/* Asset RIDs an event is attached to, as a cell array of char vectors. */
static void cmd_event_assets(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    EventHandle event;
    uint32_t count = 0, i;
    mxArray *out;

    require_args(nrhs, 1, "event_assets");
    event = arg_i32(prhs[1], "event");

    throw_if_failed(nominal_event_asset_count(event, &count, &err), err);
    out = mxCreateCellMatrix((mwSize)count, 1);
    for (i = 0; i < count; ++i) {
        throw_if_failed(nominal_event_asset_at(event, i, g_scratch, &err), err);
        mxSetCell(out, i, scratch_to_mx());
    }
    plhs[0] = out;
}

/* ------------------------------------------------------------------ */
/* Dispatch                                                            */
/* ------------------------------------------------------------------ */

#define IS(name) (strcmp(command, name) == 0)

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    char command[64];

    if (nrhs < 1 || !mxIsChar(prhs[0])) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "first argument must be a command name");
    }
    if (mxGetString(prhs[0], command, sizeof(command)) != 0) {
        mexErrMsgIdAndTxt("nominal:invalidParameter", "command name is too long");
    }

    ensure_registered();

    /* --- lifecycle --- */
    if (IS("shutdown"))       { cmd_shutdown(nrhs, prhs); return; }
    if (IS("timestamp_now"))  { cmd_timestamp_now(plhs, nrhs, prhs); return; }

    /* --- client --- */
    if (IS("client_new"))     { cmd_client_new(plhs, nrhs, prhs); return; }
    if (IS("client_free"))    { do_free(nominal_client_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("client_workspace_rid")) { do_getter_string(nominal_client_workspace_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("client_base_url"))      { do_getter_string(nominal_client_base_url, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("client_user"))          { do_getter_string(nominal_client_user_display_name, nlhs, plhs, nrhs, prhs, command); return; }

    /* --- asset --- */
    if (IS("asset_get_or_create")) { do_lookup(nominal_asset_get_or_create_by_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_get_by_rid"))    { do_lookup(nominal_asset_get_by_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_update_commit")) { cmd_asset_update_commit(plhs, nrhs, prhs); return; }
    if (IS("asset_free"))          { do_free(nominal_asset_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_rid"))           { do_getter_string(nominal_asset_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_name"))          { do_getter_string(nominal_asset_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_description"))   { do_getter_string(nominal_asset_description, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_url"))           { do_getter_string(nominal_asset_url, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_label_count"))   { do_getter_u32(nominal_asset_label_count, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("asset_label_at"))      { cmd_label_at(nominal_asset_label_at, plhs, nrhs, prhs, command); return; }
    if (IS("asset_property"))      { cmd_property(nominal_asset_property, plhs, nrhs, prhs, command); return; }
    if (IS("asset_datasources"))   { cmd_asset_datasources(plhs, nrhs, prhs); return; }
    if (IS("asset_list") || IS("asset_search")) { cmd_asset_list(plhs, nrhs, prhs, command); return; }

    /* --- dataset --- */
    if (IS("dataset_get_by_rid"))     { do_lookup(nominal_dataset_get_by_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_list") || IS("dataset_search")) { cmd_dataset_list(plhs, nrhs, prhs, command); return; }
    if (IS("dataset_write"))          { cmd_dataset_write(nrhs, prhs); return; }
    if (IS("dataset_get_or_create"))  { cmd_dataset_get_or_create(plhs, nrhs, prhs); return; }
    if (IS("dataset_update_commit"))  { cmd_dataset_update_commit(plhs, nrhs, prhs); return; }
    if (IS("dataset_free"))           { do_free(nominal_dataset_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_rid"))            { do_getter_string(nominal_dataset_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_name"))           { do_getter_string(nominal_dataset_name, nlhs, plhs, nrhs, prhs, command); return; }

    /* --- run --- */
    if (IS("run_create"))         { cmd_run_create(plhs, nrhs, prhs); return; }
    if (IS("run_get_by_rid"))     { do_lookup(nominal_run_get_by_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_set_end_time"))   { cmd_run_set_end_time(plhs, nrhs, prhs); return; }
    if (IS("run_add_dataset"))    { cmd_run_add_dataset(plhs, nrhs, prhs); return; }
    if (IS("run_update_commit"))  { cmd_run_update_commit(plhs, nrhs, prhs); return; }
    if (IS("run_free"))           { do_free(nominal_run_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_rid"))            { do_getter_string(nominal_run_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_name"))           { do_getter_string(nominal_run_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_description"))    { do_getter_string(nominal_run_description, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_url"))            { do_getter_string(nominal_run_url, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_number"))         { do_getter_u32(nominal_run_number, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_start_time"))     { cmd_run_start_time(plhs, nrhs, prhs); return; }
    if (IS("run_end_time"))       { cmd_run_end_time(plhs, nrhs, prhs); return; }
    if (IS("run_label_count"))    { do_getter_u32(nominal_run_label_count, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("run_label_at"))       { cmd_label_at(nominal_run_label_at, plhs, nrhs, prhs, command); return; }
    if (IS("run_property"))       { cmd_property(nominal_run_property, plhs, nrhs, prhs, command); return; }

    /* --- staged updates --- */
    if (IS("update_begin"))            { cmd_update_begin(plhs, nrhs, prhs); return; }
    if (IS("update_free"))             { do_free(nominal_update_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("update_set_name"))         { do_update_set1(nominal_update_set_name, nrhs, prhs, command); return; }
    if (IS("update_set_description"))  { do_update_set1(nominal_update_set_description, nrhs, prhs, command); return; }
    if (IS("update_add_label"))        { do_update_set1(nominal_update_add_label, nrhs, prhs, command); return; }
    if (IS("update_set_property"))     { cmd_update_set_property(nrhs, prhs); return; }
    if (IS("update_clear_properties")) { cmd_update_clear(nominal_update_clear_properties, nrhs, prhs, command); return; }
    if (IS("update_clear_labels"))     { cmd_update_clear(nominal_update_clear_labels, nrhs, prhs, command); return; }
    if (IS("update_set_start"))        { cmd_update_set_time(nominal_update_set_start, nrhs, prhs, command); return; }
    if (IS("update_set_end"))          { cmd_update_set_time(nominal_update_set_end, nrhs, prhs, command); return; }

    /* --- streaming --- */
    if (IS("stream_create"))        { cmd_stream_create(plhs, nrhs, prhs); return; }
    if (IS("stream_free"))          { do_free(nominal_stream_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("channel_create"))       { cmd_channel_create(plhs, nrhs, prhs); return; }
    if (IS("channel_set_tag"))      { cmd_channel_set_tag(nrhs, prhs); return; }
    if (IS("channel_name"))         { do_getter_string(nominal_streamchannel_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("channel_stream"))       { cmd_channel_stream(plhs, nrhs, prhs); return; }
    if (IS("channel_push"))         { cmd_channel_push(nrhs, prhs); return; }
    if (IS("channel_push_matrix"))  { cmd_channel_push_matrix(nrhs, prhs); return; }
    if (IS("channel_free"))         { do_free(nominal_streamchannel_free, nlhs, plhs, nrhs, prhs, command); return; }

    /* --- channel metadata (catalog side) --- */
    if (IS("meta_get"))            { cmd_meta_get(plhs, nrhs, prhs); return; }
    if (IS("meta_set"))            { cmd_meta_set(plhs, nrhs, prhs); return; }
    if (IS("meta_list"))           { cmd_meta_list(plhs, nrhs, prhs); return; }
    if (IS("meta_free"))           { do_free(nominal_channelmetadata_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("meta_name"))           { do_getter_string(nominal_channelmetadata_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("meta_datasource_rid")) { do_getter_string(nominal_channelmetadata_datasource_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("meta_unit"))           { do_getter_string(nominal_channelmetadata_unit, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("meta_description"))    { do_getter_string(nominal_channelmetadata_description, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("meta_data_type"))      { cmd_meta_data_type(plhs, nrhs, prhs); return; }

    /* --- events --- */
    if (IS("event_create"))    { cmd_event_create(plhs, nrhs, prhs); return; }
    if (IS("event_free"))      { do_free(nominal_event_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("event_rid"))       { do_getter_string(nominal_event_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("event_name"))      { do_getter_string(nominal_event_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("event_type"))      { cmd_event_type(plhs, nrhs, prhs); return; }
    if (IS("event_timestamp")) { cmd_event_i64(nominal_event_timestamp, plhs, nrhs, prhs, command); return; }
    if (IS("event_duration"))  { cmd_event_i64(nominal_event_duration, plhs, nrhs, prhs, command); return; }
    if (IS("event_assets"))    { cmd_event_assets(plhs, nrhs, prhs); return; }

    mexErrMsgIdAndTxt("nominal:invalidParameter", "unknown command '%s'", command);
}
