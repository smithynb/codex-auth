const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const me_api = @import("../api/me.zig");
const coordinateAfterActivation = @import("active_auth.zig").coordinateAfterActivation;
const account_names = @import("account_names.zig");
const app_runtime = @import("../core/runtime.zig");

const defaultAccountFetcher = account_names.defaultAccountFetcher;

fn loginScratchCodexHomeAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const stamp = std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
    const name = try allocator.print("login-{d}", .{stamp});
    defer allocator.free(name);
    return try std.Io.Dir.path.join(allocator, &[_][]const u8{ codex_home, "accounts", name });
}

pub fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LoginOptions) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    const login_codex_home = try loginScratchCodexHomeAlloc(allocator, codex_home);
    defer allocator.free(login_codex_home);
    defer std.Io.Dir.cwd().deleteTree(app_runtime.io(), login_codex_home) catch {};
    try registry.ensurePrivateDir(login_codex_home);

    try cli.login.runCodexLogin(opts, login_codex_home);
    const login_auth_path = try registry.activeAuthPath(allocator, login_codex_home);
    defer allocator.free(login_auth_path);

    const info = try auth.parseAuthInfo(allocator, login_auth_path);
    defer info.deinit(allocator);
    var record = if (info.auth_mode == .apikey) blk: {
        const api_key = info.openai_api_key orelse return error.MissingOpenAIAPIKey;
        var me = try me_api.fetchMeForApiKey(allocator, api_key);
        defer me.deinit(allocator);
        break :blk try registry.accountFromApiKeyMe(allocator, "", &info, &me);
    } else try registry.accountFromAuth(allocator, "", &info);
    var record_owned = true;
    defer if (record_owned) registry.freeAccountRecord(allocator, &record);

    // A browser login can take minutes. Sync the credentials and registry
    // that are current when it finishes, including switches made meanwhile.
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (reg.accounts.items.len > 0) {
        _ = try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg);
    }

    const dest = try registry.accountAuthPath(allocator, codex_home, record.account_key);
    defer allocator.free(dest);
    const key = try allocator.dupe(u8, record.account_key);
    defer allocator.free(key);
    try registry.upsertAccount(allocator, &reg, record);
    record_owned = false;
    try registry.setActiveAccountKey(allocator, &reg, key);

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    try registry.copyManagedFile(login_auth_path, auth_path);
    try registry.copyManagedFile(login_auth_path, dest);
    try registry.saveRegistry(allocator, codex_home, &reg);
    const outcome = try coordinateAfterActivation(allocator, codex_home, opts.no_restart_daemon);
    if (outcome == .restart_failed or outcome == .timed_out)
        return error.CodexDaemonRestartFailed;

    const names = (try account_names.fetchWorkspaceNames(allocator, &reg, &info, defaultAccountFetcher, reg.api.account)) orelse return;
    defer names.deinit(allocator);
    const entries = names.entries orelse return;
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);
    if (latest.api.account and try registry.applyAccountNamesForUser(allocator, &latest, info.chatgpt_user_id.?, entries))
        try registry.saveRegistry(allocator, codex_home, &latest);
}
