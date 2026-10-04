const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const format = codex_auth.tui.table;
const registry = codex_auth.registry;
const printTableRow = format.printTableRow;
const truncateAlloc = format.truncateAlloc;
const formatRateLimitFullAlloc = format.formatRateLimitFullAlloc;
const writeAccountsTable = format.writeAccountsTable;
const writeAccountsTableWithUsageOverrides = format.writeAccountsTableWithUsageOverrides;
const ansi = struct {
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

fn makeTestRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn appendApiKeyTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    email: []const u8,
) !void {
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = try allocator.dupe(u8, ""),
        .chatgpt_user_id = try allocator.dupe(u8, "user_api"),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, ""),
        .account_name = null,
        .plan = null,
        .auth_mode = .apikey,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

test "printTableRow handles long cells without underflow" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const widths = [_]usize{3};
    const cells = [_][]const u8{"abcdef"};
    try printTableRow(&writer, &widths, &cells);
    try writer.flush();
}

test "truncateAlloc respects max_len" {
    const out1 = try truncateAlloc("abcdef", 3);
    defer std.heap.page_allocator.free(out1);
    try std.testing.expect(out1.len == 3);
    const out2 = try truncateAlloc("abcdef", 1);
    defer std.heap.page_allocator.free(out2);
    try std.testing.expect(out2.len == 1);
}

test "formatRateLimitFullAlloc shows 100% after reset instead of dash-prefixed value" {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const window = registry.RateLimitWindow{
        .used_percent = 100.0,
        .window_minutes = 300,
        .resets_at = now - 60,
    };

    const formatted = try formatRateLimitFullAlloc(window);
    defer std.heap.page_allocator.free(formatted);

    try std.testing.expectEqualStrings("100%", formatted);
}

test "writeAccountsTable shows zero-padded row numbers for selectable accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01   Als's Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02   Free") != null);
}

test "writeAccountsTable keeps usage headers short" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "5H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "WEEKLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE") == null);
}

test "writeAccountsTable shows integer credits balance column" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = .{
            .has_credits = true,
            .unlimited = false,
            .balance = try gpa.dupe(u8, "5.3900"),
        },
        .reset_credits = 2,
        .plan_type = .plus,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus  5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "5.39") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
}

test "writeAccountsTable shows reset credits independently" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .reset_credits = 2,
        .plan_type = .plus,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus  -") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
}

test "writeAccountsTable shows earliest reset credit expiry beside count" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .reset_credits = 3,
        .reset_credits_expires_at = 4070908800,
        .plan_type = .plus,
    };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "3 (exp ") != null);

    // Unknown or stale expiry retains the credit count without inventing a date.
    reg.accounts.items[0].last_usage.?.reset_credits_expires_at = 1;
    writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "(exp ") == null);
}

test "writeAccountsTable shows usage override statuses for failed refreshes" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, false, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "403") >= 3);
}

test "writeAccountsTable highlights usage override rows in red when color is enabled" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, true, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "writeAccountsTable uses cyan headers green active rows and default normal rows" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "normal@example.com", "", .free);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.cyan ++ "     ACCOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "* 01 act***@e***.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m  02 nor***@e***.com") == null);
}

test "writeAccountsTable prefers usage snapshot plan labels over stored auth plan" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .business,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus") == null);
}

test "writeAccountsTable shows API_KEY in the plan column for API key auth" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendApiKeyTestAccount(gpa, &reg, "apikey::user_api::7f3c1d9a2b4e8c2042ce", "user@example.com");

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "use***@e***.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "API_KEY") != null);
}

test "configured time format reaches list, picker, live copies, and credit expiry" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 25, .window_minutes = 300, .resets_at = 4102444800 },
        .secondary = .{ .used_percent = 50, .window_minutes = 10080, .resets_at = 4103049600 },
        .credits = null,
        .reset_credits = 3,
        .reset_credits_expires_at = 4102444800,
        .plan_type = .plus,
    };
    for ([_]codex_auth.time.clock.TimeFormat{ .@"12h", .@"24h" }) |time_format| {
        reg.time_format = time_format;
        var live_display = try codex_auth.workflows.buildSwitchLiveActionDisplay(gpa, .{ .reg = &reg, .usage_overrides = null }, &reg);
        defer live_display.deinit(gpa);
        try std.testing.expectEqual(time_format, live_display.reg.time_format);
        var rows = try codex_auth.cli.rows.buildSwitchRows(gpa, &live_display.reg);
        defer rows.deinit(gpa);
        const row = rows.items[rows.selectable_row_indices[0]];
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeAccountsTable(&aw.writer, &reg, false);
        for ([_][]const u8{ row.rate_5h, row.rate_week }) |cell| {
            try std.testing.expect(std.mem.indexOf(u8, aw.written(), cell) != null);
            const has_meridiem = std.mem.indexOf(u8, cell, " AM") != null or std.mem.indexOf(u8, cell, " PM") != null;
            try std.testing.expectEqual(time_format == .@"12h", has_meridiem);
        }
        const expiry_start = std.mem.indexOf(u8, aw.written(), "3 (exp ") orelse return error.TestExpectedEqual;
        const expiry_tail = aw.written()[expiry_start..];
        const expiry_end = std.mem.indexOfScalar(u8, expiry_tail, ')') orelse return error.TestExpectedEqual;
        const expiry = expiry_tail[0..expiry_end];
        const has_meridiem = std.mem.indexOf(u8, expiry, " AM") != null or std.mem.indexOf(u8, expiry, " PM") != null;
        try std.testing.expectEqual(time_format == .@"12h", has_meridiem);
    }
}
