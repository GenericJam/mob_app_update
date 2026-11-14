%% mob_app_update_nif — Erlang NIF module for the mob_app_update plugin.
%%
%% Android only: priv/native/jni/mob_app_update_nif.zig registers these NIFs
%% and bridges them to the Kotlin io.mob.appupdate.MobAppUpdateBridge
%% (PackageManager / PackageInstaller). On device the NIF is statically linked
%% into the host binary; on iOS and on a host dev build it isn't, so on_load
%% tolerates the failure and the stubs fall back to nif_error. MobAppUpdate
%% only calls them on Android.
%%
%% The surface is thin: the bridge answers JSON (UTF-8 binaries) and MobAppUpdate
%% decodes and decides in Elixir, where it is testable on the host.
-module(mob_app_update_nif).
-export([
    app_update_info/0,
    app_update_can_request_installs/0,
    app_update_open_install_settings/0,
    app_update_inspect/1,
    app_update_install/2,
    app_update_free_space/1
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_app_update_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

%% {ok, Json} — the installed package, its versions, signers and cache dir.
app_update_info() ->
    erlang:nif_error(nif_not_loaded).

%% true | false — PackageManager.canRequestPackageInstalls().
app_update_can_request_installs() ->
    erlang:nif_error(nif_not_loaded).

%% ok | {error, Reason} — opens Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES.
app_update_open_install_settings() ->
    erlang:nif_error(nif_not_loaded).

%% {ok, Json} | {error, Reason} — getPackageArchiveInfo of the APK at Path.
app_update_inspect(_Path) ->
    erlang:nif_error(nif_not_loaded).

%% ok | {error, Reason} — starts a PackageInstaller session for Path; the
%% outcome is sent to Pid as {mob_app_update, {install, Status}}.
app_update_install(_Path, _Pid) ->
    erlang:nif_error(nif_not_loaded).

%% {ok, Json} | {error, Reason} — {"free_bytes": N}, the usable space of the
%% file system holding Path.
app_update_free_space(_Path) ->
    erlang:nif_error(nif_not_loaded).
