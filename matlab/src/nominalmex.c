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

/*
 * MATLAB sizes plhs to the caller's request, guaranteeing max(nlhs, 1) slots,
 * so writing plhs[1] when the caller asked for one output is out of bounds.
 * Commands with two outputs refuse the call up front: an error names the
 * problem, where skipping the write would silently drop an output and writing
 * anyway would stomp memory. Every +nominal caller requests both, so this only
 * fires on a direct nominalmex call.
 */
static void require_outputs(int nlhs, int wanted, const char *command)
{
    if (nlhs < wanted) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "%s returns %d outputs; request all of them",
                          command, wanted);
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

/*
 * Decode UTF-8 bytes into UTF-16 code units, returning how many were written.
 *
 * `out` must hold at least `length` units, which is always enough: 1-3 byte
 * sequences produce one unit and 4-byte sequences two.
 *
 * The source is a Rust String, so the bytes are valid UTF-8 in practice; the
 * malformed-input branches are defence, not an expected path. A rejected byte
 * decodes as U+FFFD and the scan resumes at the next byte, so one bad byte
 * cannot shift the interpretation of those that follow.
 */
static size_t utf8_to_utf16(const unsigned char *bytes, size_t length, mxChar *out)
{
    size_t i = 0, n = 0;

    while (i < length) {
        unsigned char lead = bytes[i];
        uint32_t cp;
        size_t need, k;
        int valid = 1;

        if (lead < 0x80)              { cp = lead;        need = 0; }
        else if ((lead & 0xE0) == 0xC0) { cp = lead & 0x1F; need = 1; }
        else if ((lead & 0xF0) == 0xE0) { cp = lead & 0x0F; need = 2; }
        else if ((lead & 0xF8) == 0xF0) { cp = lead & 0x07; need = 3; }
        else { out[n++] = 0xFFFD; i++; continue; }

        if (i + need >= length) {  /* truncated sequence at end of input */
            out[n++] = 0xFFFD;
            i++;
            continue;
        }
        for (k = 1; k <= need; ++k) {
            if ((bytes[i + k] & 0xC0) != 0x80) {
                valid = 0;
                break;
            }
            cp = (cp << 6) | (bytes[i + k] & 0x3F);
        }
        if (!valid) {
            out[n++] = 0xFFFD;
            i++;
            continue;
        }
        /* Surrogate code points and anything past U+10FFFF cannot be emitted
         * as UTF-16. Overlong encodings decode to a small cp and pass through
         * harmlessly; a Rust String never produces one. */
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            cp = 0xFFFD;
        }

        if (cp >= 0x10000) {
            cp -= 0x10000;
            out[n++] = (mxChar)(0xD800 | (cp >> 10));
            out[n++] = (mxChar)(0xDC00 | (cp & 0x3FF));
        } else {
            out[n++] = (mxChar)cp;
        }
        i += 1 + need;
    }
    return n;
}

/*
 * Build a MATLAB char array from UTF-8 bytes.
 *
 * Not mxCreateString: that interprets bytes in MATLAB's locale encoding, which
 * on Windows has historically been the ANSI codepage. The library's strings
 * are always UTF-8, so an asset named with non-ASCII characters would come
 * back as mojibake — and feeding that name back in would then miss on the
 * server. Decoding explicitly mirrors mxArrayToUTF8String on the way in, and
 * makes text handling independent of MATLAB version and codepage.
 */
static mxArray *utf8_to_mx(const char *bytes, size_t length)
{
    mwSize dims[2];
    mxArray *array;
    mxChar *units = NULL;
    size_t count = 0;

    if (length > 0) {
        units = (mxChar *)mxMalloc(length * sizeof(mxChar));
        count = utf8_to_utf16((const unsigned char *)bytes, length, units);
    }

    /* 1-by-n, matching what mxCreateString produced before. */
    dims[0] = 1;
    dims[1] = (mwSize)count;
    array = mxCreateCharArray(2, dims);
    if (count > 0) {
        memcpy(mxGetData(array), units, count * sizeof(mxChar));
    }
    if (units != NULL) {
        mxFree(units);
    }
    return array;
}

/* Read the scratch string handle into a MATLAB char array. */
static mxArray *scratch_to_mx(void)
{
    uint32_t length = nominal_string_length(g_scratch);
    char *buffer = (char *)mxMalloc((size_t)length + 1);
    uint32_t copied = nominal_copy_string_from_reference(g_scratch, buffer, length + 1);
    mxArray *out;

    out = utf8_to_mx(buffer, (size_t)copied);
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

/* Returns the dataset handle and, as a second output, which branch ran:
   0 already attached, 1 attached an existing dataset, 2 created one. The
   caller prints it — Rust writing to stdout from inside a MEX fights
   MATLAB's own output handling. */
static void cmd_dataset_get_or_create(mxArray *plhs[], int nlhs, int nrhs,
                                      const mxArray *prhs[])
{
    ErrorHandle err = 0;
    DatasetHandle out = 0;
    int32_t outcome = 0;
    char *name, *ref_name;
    int32_t status;

    require_args(nrhs, 5, "dataset_get_or_create");
    name = arg_string(prhs[3], "name");
    ref_name = arg_string(prhs[4], "refName");
    status = nominal_dataset_get_or_create_by_name(arg_i32(prhs[1], "client"),
                                                   arg_i32(prhs[2], "asset"),
                                                   name, ref_name,
                                                   arg_i32(prhs[5], "attachExisting"),
                                                   &out, &outcome, &err);
    mxFree(name);
    mxFree(ref_name);
    throw_if_failed(status, err);
    plhs[0] = mx_i32(out);
    if (nlhs > 1) {
        plhs[1] = mx_i32(outcome);
    }
}

static void cmd_asset_add_dataset(int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    char *ref_name;
    int32_t status;

    require_args(nrhs, 4, "asset_add_dataset");
    ref_name = arg_string(prhs[3], "refName");
    status = nominal_asset_add_dataset(arg_i32(prhs[1], "client"),
                                       arg_i32(prhs[2], "asset"),
                                       ref_name,
                                       arg_i32(prhs[4], "dataset"), &err);
    mxFree(ref_name);
    throw_if_failed(status, err);
}

static void cmd_asset_attached_dataset(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    DatasetHandle out = 0;
    char *name;
    int32_t status;

    require_args(nrhs, 3, "asset_attached_dataset");
    name = arg_string(prhs[3], "name");
    status = nominal_asset_attached_dataset_by_name(arg_i32(prhs[1], "client"),
                                                    arg_i32(prhs[2], "asset"),
                                                    name, &out, &err);
    mxFree(name);
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
static void cmd_run_end_time(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    int64_t nanos = 0;
    bool has_end = false;

    require_outputs(nlhs, 2, "run_end_time");
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

static int32_t export_format_code(const char *name)
{
    if (strcmp(name, "matfile") == 0) return 0;
    if (strcmp(name, "csv") == 0)     return 1;
    if (strcmp(name, "arrow") == 0)   return 2;
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown export format '%s'; expected matfile, csv, or arrow",
                      name);
    return -1;
}

/* "full" sends every sample; the other two pair with a resolution value. */
static int32_t export_resolution_code(const char *name)
{
    if (strcmp(name, "full") == 0)     return 0;
    if (strcmp(name, "buckets") == 0)  return 1;
    if (strcmp(name, "interval") == 0) return 2;
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown resolution '%s'; expected full, buckets, or interval",
                      name);
    return -1;
}

static int32_t timestamp_kind_code(const char *name)
{
    if (strcmp(name, "iso8601") == 0)  return 0;
    if (strcmp(name, "epoch") == 0)    return 1;
    if (strcmp(name, "relative") == 0) return 2;
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown timestamp kind '%s'; expected iso8601, epoch, "
                      "or relative", name);
    return -1;
}

static int32_t time_unit_code(const char *name)
{
    static const char *names[] = {
        "nanoseconds", "microseconds", "milliseconds", "seconds", "minutes", "hours"
    };
    int32_t i;
    for (i = 0; i < (int32_t)(sizeof(names) / sizeof(names[0])); ++i) {
        if (strcmp(name, names[i]) == 0) {
            return i;
        }
    }
    mexErrMsgIdAndTxt("nominal:invalidParameter",
                      "unknown time unit '%s'; expected nanoseconds, microseconds, "
                      "milliseconds, seconds, minutes, or hours", name);
    return -1;
}

static const char *job_status_name(int32_t code)
{
    static const char *names[] = {
        "submitted", "queued", "inProgress", "completed", "failed", "cancelled", "unknown"
    };
    if (code >= 0 && code < (int32_t)(sizeof(names) / sizeof(names[0]))) {
        return names[code];
    }
    return "unknown";
}

/* ------------------------------------------------------------------ */
/* Cell array of strings -> char**                                     */
/* ------------------------------------------------------------------ */

/*
 * Borrow a MATLAB cell array of char vectors as the `const char *const *` the
 * C ABI takes.
 *
 * Three commands need this — write, export, and event creation — so it lives
 * here rather than being spelled out at each. Everything comes from mxCalloc
 * and mxArrayToUTF8String, which MATLAB reclaims on error unwind as well as on
 * return, so `release` is tidiness rather than the only thing standing between
 * this and a leak.
 */
typedef struct {
    char **owned;
    const char **ptrs;
    mwSize count;
} StringArray;

static StringArray borrow_string_array(const mxArray *cell, const char *what)
{
    StringArray array;
    mwSize i;

    if (!mxIsCell(cell)) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "%s must be a cell array of character vectors", what);
    }
    array.count = mxGetNumberOfElements(cell);
    /* mxCalloc(0, ...) is not useful; ask for one slot so the pointers are
     * always valid even when the caller passed an empty cell. */
    array.owned = (char **)mxCalloc(array.count ? array.count : 1, sizeof(char *));
    array.ptrs = (const char **)mxCalloc(array.count ? array.count : 1, sizeof(char *));
    for (i = 0; i < array.count; ++i) {
        array.owned[i] = arg_string(mxGetCell(cell, i), what);
        array.ptrs[i] = array.owned[i];
    }
    return array;
}

static void release_string_array(StringArray *array)
{
    mwSize i;
    for (i = 0; i < array->count; ++i) {
        mxFree(array->owned[i]);
    }
    mxFree(array->owned);
    mxFree((void *)array->ptrs);
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
    StringArray channels;
    mwSize cols;
    size_t n_times = 0, rows;
    const int64_t *times;
    const double *values;
    int32_t status;

    require_args(nrhs, 5, "dataset_write");

    channels = borrow_string_array(prhs[3], "channels");
    cols = channels.count;

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

    status = nominal_write_doubles(arg_i32(prhs[1], "client"),
                                   arg_i32(prhs[2], "dataset"),
                                   channels.ptrs, (uint32_t)cols,
                                   times, values, (uint32_t)rows, &err);

    release_string_array(&channels);
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

    if (strcmp(command, "dataset_search") == 0) {
        require_args(nrhs, 2, command);
        client = arg_i32(prhs[1], "client");
        text = arg_string(prhs[2], "text");
        status = nominal_dataset_search(client, text, &list, &count, &err);
        mxFree(text);
    } else {
        require_args(nrhs, 1, command);
        client = arg_i32(prhs[1], "client");
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
    StringArray rids;
    char *name, *type_name;
    int32_t status;

    require_args(nrhs, 6, "event_create");

    rids = borrow_string_array(prhs[2], "assetRids");
    if (rids.count == 0) {
        mexErrMsgIdAndTxt("nominal:invalidParameter",
                          "at least one asset RID is required");
    }

    name = arg_string(prhs[3], "name");
    type_name = arg_string(prhs[4], "type");

    status = nominal_event_create(arg_i32(prhs[1], "client"),
                                  rids.ptrs, (uint32_t)rids.count,
                                  name, event_type_code(type_name),
                                  arg_i64(prhs[5], "timestamp"),
                                  arg_i64(prhs[6], "duration"),
                                  &out, &err);

    release_string_array(&rids);
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
/* Fetch                                                               */
/*                                                                     */
/* The C ABI hands back a series behind a handle, then copies out of it */
/* on demand. MATLAB wants the whole channel as two vectors, so the     */
/* handle is created and released entirely within this call and never   */
/* reaches MATLAB — one less thing for a caller to forget to free.      */
/* ------------------------------------------------------------------ */

static void cmd_dataset_fetch(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[],
                              const char *command)
{
    ErrorHandle err = 0;
    SeriesHandle series = 0;
    char *channel;
    int32_t status;
    uint32_t length = 0, written = 0;
    mxArray *times = NULL, *values = NULL;
    int decimated = (strcmp(command, "dataset_fetch_decimated") == 0);

    require_outputs(nlhs, 2, command);
    require_args(nrhs, decimated ? 6 : 5, command);
    channel = arg_string(prhs[3], "channel");

    if (decimated) {
        status = nominal_compute_fetch_decimated(
            arg_i32(prhs[1], "client"), arg_i32(prhs[2], "dataset"), channel,
            arg_i64(prhs[4], "startNanos"), arg_i64(prhs[5], "endNanos"),
            (uint32_t)arg_i32(prhs[6], "buckets"), &series, &err);
    } else {
        status = nominal_compute_fetch(
            arg_i32(prhs[1], "client"), arg_i32(prhs[2], "dataset"), channel,
            arg_i64(prhs[4], "startNanos"), arg_i64(prhs[5], "endNanos"),
            &series, &err);
    }
    mxFree(channel);
    /* No series exists on failure, so there is nothing to release yet. */
    throw_if_failed(status, err);

    /* From here the series must be released before anything can throw. */
    status = nominal_series_length(series, &length, &err);
    if (status == NOMINAL_SUCCESS) {
        times = mxCreateNumericMatrix((mwSize)length, 1, mxINT64_CLASS, mxREAL);
        values = mxCreateDoubleMatrix((mwSize)length, 1, mxREAL);
        if (length > 0) {
            status = nominal_series_timestamps(series, mxGetInt64s(times),
                                               length, &written, &err);
            if (status == NOMINAL_SUCCESS) {
                status = nominal_series_values(series, mxGetDoubles(values),
                                               length, &written, &err);
            }
        }
    }
    nominal_series_free(series);
    throw_if_failed(status, err);

    plhs[0] = times;
    plhs[1] = values;
}

/* ------------------------------------------------------------------ */
/* Export                                                              */
/* ------------------------------------------------------------------ */

static void cmd_dataset_export(mxArray *plhs[], int nrhs, const mxArray *prhs[],
                               const char *command)
{
    ErrorHandle err = 0;
    StringArray channels;
    char *resolution, *format, *path = NULL;
    int32_t status, resolution_code, format_code;
    int to_file = (strcmp(command, "dataset_export") == 0);

    require_args(nrhs, to_file ? 9 : 8, command);

    channels = borrow_string_array(prhs[3], "channels");
    resolution = arg_string(prhs[6], "resolution");
    format = arg_string(prhs[8], "format");

    /* Decode before the call so a bad name is rejected by us, with a message
     * naming the alternatives, rather than by the server. */
    resolution_code = export_resolution_code(resolution);
    format_code = export_format_code(format);

    if (to_file) {
        path = arg_string(prhs[9], "path");
        status = nominal_export_to_file(
            arg_i32(prhs[1], "client"), arg_i32(prhs[2], "dataset"),
            channels.ptrs, (uint32_t)channels.count,
            arg_i64(prhs[4], "startNanos"), arg_i64(prhs[5], "endNanos"),
            resolution_code, arg_i64(prhs[7], "resolutionValue"),
            format_code, path, &err);
    } else {
        status = nominal_export_presigned_url(
            arg_i32(prhs[1], "client"), arg_i32(prhs[2], "dataset"),
            channels.ptrs, (uint32_t)channels.count,
            arg_i64(prhs[4], "startNanos"), arg_i64(prhs[5], "endNanos"),
            resolution_code, arg_i64(prhs[7], "resolutionValue"),
            format_code, g_scratch, &err);
    }

    release_string_array(&channels);
    mxFree(resolution);
    mxFree(format);
    if (path != NULL) {
        mxFree(path);
    }
    throw_if_failed(status, err);

    if (!to_file) {
        plhs[0] = scratch_to_mx();
    }
}

/* ------------------------------------------------------------------ */
/* Ingest                                                              */
/* ------------------------------------------------------------------ */

static void cmd_ingest_file(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[],
                            const char *command)
{
    ErrorHandle err = 0;
    IngestJobHandle job = 0;
    char *path, *new_name, *column, *kind, *unit;
    int32_t status, kind_code, unit_code;
    int parquet = (strcmp(command, "ingest_parquet") == 0);

    require_outputs(nlhs, 2, command);
    require_args(nrhs, 7, command);

    path = arg_string(prhs[2], "path");
    new_name = arg_string(prhs[4], "newDatasetName");
    column = arg_string(prhs[5], "timestampColumn");
    kind = arg_string(prhs[6], "timestampKind");
    unit = arg_string(prhs[7], "timestampUnit");

    kind_code = timestamp_kind_code(kind);
    unit_code = time_unit_code(unit);

    /* The RID lands in the scratch handle: it is how a caller finds a dataset
     * that this call just created. */
    status = (parquet ? nominal_ingest_parquet : nominal_ingest_csv)(
        arg_i32(prhs[1], "client"), path, arg_i32(prhs[3], "dataset"),
        new_name, column, kind_code, unit_code, &job, g_scratch, &err);

    mxFree(path);
    mxFree(new_name);
    mxFree(column);
    mxFree(kind);
    mxFree(unit);
    throw_if_failed(status, err);

    plhs[0] = mx_i32(job);
    plhs[1] = scratch_to_mx();
}

/* Both status and wait report through the same JobStatus code. */
static void cmd_ingest_status(mxArray *plhs[], int nrhs, const mxArray *prhs[],
                              const char *command)
{
    ErrorHandle err = 0;
    int32_t code = 0;
    int wait = (strcmp(command, "ingest_wait") == 0);

    require_args(nrhs, 2, command);
    throw_if_failed((wait ? nominal_ingest_wait : nominal_ingest_job_status)(
        arg_i32(prhs[1], "client"), arg_i32(prhs[2], "job"), &code, &err), err);
    plhs[0] = mxCreateString(job_status_name(code));
}

/* ------------------------------------------------------------------ */
/* SQL                                                                 */
/*                                                                     */
/* One call returns the whole result: column names and a cell of column */
/* vectors, which MATLAB assembles into a table. The result handle is    */
/* created and released here, so no cursor escapes into MATLAB.          */
/* ------------------------------------------------------------------ */

static void cmd_sql_query(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    QueryResultHandle result = 0;
    char *query, *workspace;
    int32_t status;
    uint32_t rows = 0, cols = 0, i, r, written = 0;
    /* Only assigned once the row and column counts are known, and only read
     * after throw_if_failed has confirmed that happened. */
    mxArray *names = NULL, *columns = NULL;

    require_outputs(nlhs, 2, "sql_query");
    require_args(nrhs, 3, "sql_query");
    query = arg_string(prhs[2], "query");
    workspace = arg_string(prhs[3], "workspaceRid");
    status = nominal_sql_query(arg_i32(prhs[1], "client"), query, workspace,
                               &result, &err);
    mxFree(query);
    mxFree(workspace);
    throw_if_failed(status, err);

    /*
     * Nothing between here and the free may throw. A query result is capped at
     * a gigabyte and lives in a registry until shutdown, so abandoning one is a
     * real leak rather than a rounding error — unlike the small metadata lists
     * elsewhere in this file, which is why this path collects failures and
     * raises them after releasing the handle instead of throwing where it
     * fails.
     */
    status = nominal_sql_row_count(result, &rows, &err);
    if (status == NOMINAL_SUCCESS) {
        status = nominal_sql_column_count(result, &cols, &err);
    }

    if (status == NOMINAL_SUCCESS) {
        names = mxCreateCellMatrix(1, (mwSize)cols);
        columns = mxCreateCellMatrix(1, (mwSize)cols);

        for (i = 0; i < cols; ++i) {
            int32_t type = 0;
            mxArray *column = NULL;

            status = nominal_sql_column_name(result, i, g_scratch, &err);
            if (status != NOMINAL_SUCCESS) {
                break;
            }
            mxSetCell(names, i, scratch_to_mx());

            status = nominal_sql_column_type(result, i, &type, &err);
            if (status != NOMINAL_SUCCESS) {
                break;
            }

            switch (type) {
                case 0:  /* Double */
                    column = mxCreateDoubleMatrix((mwSize)rows, 1, mxREAL);
                    if (rows > 0) {
                        status = nominal_sql_column_doubles(
                            result, i, mxGetDoubles(column), rows, &written, &err);
                    }
                    break;

                case 1:  /* Int64 */
                case 3:  /* Timestamp, already normalised to epoch nanoseconds */
                    column = mxCreateNumericMatrix((mwSize)rows, 1, mxINT64_CLASS, mxREAL);
                    if (rows > 0) {
                        status = nominal_sql_column_int64(
                            result, i, mxGetInt64s(column), rows, &written, &err);
                    }
                    break;

                case 2:  /* String */
                    column = mxCreateCellMatrix((mwSize)rows, 1);
                    for (r = 0; r < rows; ++r) {
                        status = nominal_sql_column_string_at(result, i, r, g_scratch, &err);
                        if (status != NOMINAL_SUCCESS) {
                            break;
                        }
                        mxSetCell(column, r, scratch_to_mx());
                    }
                    break;

                default: /* Unsupported: present in the result, not readable here. */
                    column = mxCreateCellMatrix((mwSize)rows, 1);
                    for (r = 0; r < rows; ++r) {
                        mxSetCell(column, r, mxCreateString(""));
                    }
                    break;
            }

            if (status != NOMINAL_SUCCESS) {
                break;
            }
            mxSetCell(columns, i, column);
        }
    }

    nominal_sql_free(result);
    throw_if_failed(status, err);

    plhs[0] = names;
    plhs[1] = columns;
}

static void cmd_sql_export_url(mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    ErrorHandle err = 0;
    char *query, *workspace;
    int32_t status;

    require_args(nrhs, 3, "sql_export_url");
    query = arg_string(prhs[2], "query");
    workspace = arg_string(prhs[3], "workspaceRid");
    status = nominal_sql_export_url(arg_i32(prhs[1], "client"), query, workspace,
                                    g_scratch, &err);
    mxFree(query);
    mxFree(workspace);
    throw_if_failed(status, err);
    plhs[0] = scratch_to_mx();
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
    if (IS("dataset_get_or_create"))  { cmd_dataset_get_or_create(plhs, nlhs, nrhs, prhs); return; }
    if (IS("asset_attached_dataset")) { cmd_asset_attached_dataset(plhs, nrhs, prhs); return; }
    if (IS("asset_add_dataset"))      { cmd_asset_add_dataset(nrhs, prhs); return; }
    if (IS("dataset_update_commit"))  { cmd_dataset_update_commit(plhs, nrhs, prhs); return; }
    if (IS("dataset_free"))           { do_free(nominal_dataset_free, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_rid"))            { do_getter_string(nominal_dataset_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_name"))           { do_getter_string(nominal_dataset_name, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_description"))    { do_getter_string(nominal_dataset_description, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_label_count"))    { do_getter_u32(nominal_dataset_label_count, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_label_at"))       { cmd_label_at(nominal_dataset_label_at, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_property"))       { cmd_property(nominal_dataset_property, plhs, nrhs, prhs, command); return; }

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
    if (IS("run_end_time"))       { cmd_run_end_time(nlhs, plhs, nrhs, prhs); return; }
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

    /* --- reading data back --- */
    if (IS("dataset_fetch") || IS("dataset_fetch_decimated")) { cmd_dataset_fetch(nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("dataset_export") || IS("dataset_export_url"))     { cmd_dataset_export(plhs, nrhs, prhs, command); return; }

    /* --- ingest --- */
    if (IS("ingest_csv") || IS("ingest_parquet"))  { cmd_ingest_file(nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("ingest_status") || IS("ingest_wait"))  { cmd_ingest_status(plhs, nrhs, prhs, command); return; }
    if (IS("ingest_job_rid")) { do_getter_string(nominal_ingest_job_rid, nlhs, plhs, nrhs, prhs, command); return; }
    if (IS("ingest_job_free")) { do_free(nominal_ingest_job_free, nlhs, plhs, nrhs, prhs, command); return; }

    /* --- sql --- */
    if (IS("sql_query"))      { cmd_sql_query(nlhs, plhs, nrhs, prhs); return; }
    if (IS("sql_export_url")) { cmd_sql_export_url(plhs, nrhs, prhs); return; }

    mexErrMsgIdAndTxt("nominal:invalidParameter", "unknown command '%s'", command);
}
