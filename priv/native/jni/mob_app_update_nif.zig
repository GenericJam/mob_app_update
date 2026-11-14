//! mob_app_update_nif — Android app-update plugin NIF (Zig).
//!
//! Bridges the app_update_* NIFs to the Kotlin io.mob.appupdate.MobAppUpdateBridge
//! (PackageManager / PackageInstaller). The bridge answers UTF-8 JSON byte
//! arrays; MobAppUpdate decodes them and decides in Elixir.
//!
//!   app_update_info/0                  {:ok, json} | {:error, :not_ready | :failed}
//!   app_update_can_request_installs/0  true | false
//!   app_update_open_install_settings/0 :ok | {:error, :not_ready | :failed}
//!   app_update_inspect/1 (path)        {:ok, json} | {:error, :not_ready | :failed}
//!   app_update_install/2 (path, pid)   :ok | {:error, :not_ready | :failed}
//!
//! install's outcome reaches `pid` later from Kotlin (nativeDeliverInstall):
//!   {:mob_app_update, {:install, :pending_user_action | :success | {:failure, status, message}}}
//!
//! Every NIF is a dirty IO job: they make binder calls, and inspect parses and
//! verifies a whole APK (~100 MB). Paths cross as UTF-8 byte arrays.
//!
//! mob-core ERTS / JNI bindings come in via the named imports @import("erts")
//! and @import("jni") that build.zig wires for plugin NIFs.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// MobAppUpdateBridge return codes for openInstallSettings / install.
const BRIDGE_OK: jni.JInt = 0;
const BRIDGE_NOT_READY: jni.JInt = 1;

// PackageInstaller.STATUS_PENDING_USER_ACTION / STATUS_SUCCESS.
const STATUS_PENDING_USER_ACTION: jni.JInt = -1;
const STATUS_SUCCESS: jni.JInt = 0;

const Methods = struct {
    info: jni.JMethodID = null,
    can_request: jni.JMethodID = null,
    open_settings: jni.JMethodID = null,
    inspect: jni.JMethodID = null,
    install: jni.JMethodID = null,
};
var g_m: Methods = .{};
var g_cls: jni.JClass = null;

fn methodId(jenv: *jni.JNIEnv, cls: jni.JClass, name: [*:0]const u8, sig: [*:0]const u8) jni.JMethodID {
    const mid = jni.getStaticMethodID(jenv, cls, name, sig);
    // A missing method leaves NoSuchMethodError pending; don't leak it.
    if (mid == null) jni.exceptionClear(jenv);
    return mid;
}

export fn Java_io_mob_appupdate_MobAppUpdateBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cls = jni.newGlobalRef(jenv, cls);
    if (g_cls == null) return;
    g_m.info = methodId(jenv, cls, "info", "()[B");
    g_m.can_request = methodId(jenv, cls, "canRequestInstalls", "()Z");
    g_m.open_settings = methodId(jenv, cls, "openInstallSettings", "()I");
    g_m.inspect = methodId(jenv, cls, "inspect", "([B)[B");
    g_m.install = methodId(jenv, cls, "install", "(J[B)I");
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return @bitCast(pid.pid);
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return .{ .pid = @bitCast(jpid) };
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = @intCast(low) };
}

inline fn errorAtom(env: ?*erts.ErlNifEnv, comptime reason: [:0]const u8) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, reason));
}

// Never leave a pending Java exception on a BEAM thread: the next JNI call
// would be undefined (CheckJNI aborts). mob_zig types ExceptionOccurred as
// opaque, so give it its JNI signature here; align(1) because a Thumb
// function pointer has bit 0 set.
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
}

// A Kotlin byte[] as a binary term.
fn bytesBinary(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, arr: jni.JByteArray) ?erts.ERL_NIF_TERM {
    if (arr == null) return null;
    const len = jni.getArrayLength(jenv, arr);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(@intCast(len), &bin) == 0) return null;
    if (len > 0) jni.getByteArrayRegion(jenv, arr, 0, len, @ptrCast(bin.data));
    return erts.enif_make_binary(env, &bin);
}

// A binary term as a new Kotlin byte[] (caller deletes the local ref).
fn binaryBytes(jenv: *jni.JNIEnv, bin: erts.ErlNifBinary) ?jni.JByteArray {
    const arr = jni.newByteArray(jenv, @intCast(bin.size));
    if (arr == null) {
        _ = clearPendingException(jenv); // OutOfMemoryError
        return null;
    }
    if (bin.size > 0) jni.setByteArrayRegion(jenv, arr, 0, @intCast(bin.size), @ptrCast(bin.data));
    return arr;
}

// {:ok, binary} for a returned byte[], {:error, :not_ready} for null.
fn bytesResult(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, result: jni.JObject) erts.ERL_NIF_TERM {
    if (clearPendingException(jenv)) return errorAtom(env, "failed");
    if (result == null) return errorAtom(env, "not_ready");
    defer jni.deleteLocalRef(jenv, result);
    const bin = bytesBinary(env, jenv, result) orelse return errorAtom(env, "failed");
    return erts.makeTuple(env, .{ erts.atom(env, "ok"), bin });
}

fn codeResult(env: ?*erts.ErlNifEnv, code: jni.JInt) erts.ERL_NIF_TERM {
    return switch (code) {
        BRIDGE_OK => erts.ok(env),
        BRIDGE_NOT_READY => errorAtom(env, "not_ready"),
        else => errorAtom(env, "failed"),
    };
}

// ── NIFs ─────────────────────────────────────────────────────────────────

fn nif_info(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_cls == null or g_m.info == null) return errorAtom(env, "not_ready");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return errorAtom(env, "failed");
    defer detachIfAttached(attached);
    const result = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_m.info);
    return bytesResult(env, jenv, result);
}

fn nif_can_request_installs(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    const no = erts.atom(env, "false");
    if (g_cls == null or g_m.can_request == null) return no;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return no;
    defer detachIfAttached(attached);
    const allowed = jenv.*.CallStaticBooleanMethod.?(jenv, g_cls, g_m.can_request);
    if (clearPendingException(jenv)) return no;
    return if (allowed != 0) erts.atom(env, "true") else no;
}

fn nif_open_install_settings(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_cls == null or g_m.open_settings == null) return errorAtom(env, "not_ready");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return errorAtom(env, "failed");
    defer detachIfAttached(attached);
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_cls, g_m.open_settings);
    if (clearPendingException(jenv)) return errorAtom(env, "failed");
    return codeResult(env, code);
}

fn nif_inspect(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var path: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &path) == 0) return erts.badarg(env);
    if (g_cls == null or g_m.inspect == null) return errorAtom(env, "not_ready");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return errorAtom(env, "failed");
    defer detachIfAttached(attached);
    const jpath = binaryBytes(jenv, path) orelse return errorAtom(env, "failed");
    defer jni.deleteLocalRef(jenv, jpath);
    const result = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_m.inspect, jpath);
    return bytesResult(env, jenv, result);
}

fn nif_install(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var path: erts.ErlNifBinary = undefined;
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &path) == 0 or
        erts.enif_get_local_pid(env, argv[1], &pid) == 0) return erts.badarg(env);
    if (g_cls == null or g_m.install == null) return errorAtom(env, "not_ready");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return errorAtom(env, "failed");
    defer detachIfAttached(attached);
    const jpath = binaryBytes(jenv, path) orelse return errorAtom(env, "failed");
    defer jni.deleteLocalRef(jenv, jpath);
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_cls, g_m.install, pidToJlong(pid), jpath);
    if (clearPendingException(jenv)) return errorAtom(env, "failed");
    return codeResult(env, code);
}

// ── Delivery thunk (called from MobAppUpdateBridge.kt) ────────────────────

pub export fn Java_io_mob_appupdate_MobAppUpdateBridge_nativeDeliverInstall(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, status: jni.JInt, message: jni.JByteArray) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const outcome = switch (status) {
        STATUS_PENDING_USER_ACTION => erts.atom(env, "pending_user_action"),
        STATUS_SUCCESS => erts.atom(env, "success"),
        else => blk: {
            // Kotlin always passes a (possibly empty) message with a failure.
            const text = bytesBinary(env, jenv, message) orelse return;
            break :blk erts.makeTuple(env, .{ erts.atom(env, "failure"), erts.enif_make_int(env, @intCast(status)), text });
        },
    };
    var pid = pidFromLong(pid_long);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_app_update"),
        erts.makeTuple(env, .{ erts.atom(env, "install"), outcome }),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIF table + init ─────────────────────────────────────────────────────

const dirty_io = erts.ERL_NIF_DIRTY_JOB_IO_BOUND;

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "app_update_info", .arity = 0, .fptr = nif_info, .flags = dirty_io },
    .{ .name = "app_update_can_request_installs", .arity = 0, .fptr = nif_can_request_installs, .flags = dirty_io },
    .{ .name = "app_update_open_install_settings", .arity = 0, .fptr = nif_open_install_settings, .flags = dirty_io },
    .{ .name = "app_update_inspect", .arity = 1, .fptr = nif_inspect, .flags = dirty_io },
    .{ .name = "app_update_install", .arity = 2, .fptr = nif_install, .flags = dirty_io },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_app_update_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_app_update_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
