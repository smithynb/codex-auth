const std = @import("std");
const display_rows = @import("codex_auth").tui.display;
const registry = @import("codex_auth").registry;

test "email display masks identity and domain but preserves the final suffix" {
    const cases = [_][2][]const u8{
        .{ "benny@gmail.com", "ben***@g***.com" },
        .{ "student@oregonstate.edu", "stu***@o***.edu" },
        .{ "longname@dept.school.edu", "lon***@d***.edu" },
        .{ "a@b.co.uk", "a***@b***.uk" },
        .{ "ab@localhost", "ab***@l***" },
        .{ "éééé@école.edu", "ééé***@é***.edu" },
        .{ "@example.com", "***@***" },
        .{ "user@", "***@***" },
        .{ "API key", "API key" },
        .{ "fixture!@example.com", "fix***@e***.com" },
        .{ "o'brien@example.com", "o'b***@e***.com" },
        .{ "\"private user\"@example.com", "\"pri***\"@e***.com" },
        .{ "\"private\\\" user\"@example.com", "\"pri***\"@e***.com" },
        .{ "\"private@user\"@example.com", "\"pri***\"@e***.com" },
        .{ "\"private@ user\"@example.com", "\"pri***\"@e***.com" },
        .{ "\"private@user\\\" name\"@example.com", "\"pri***\"@e***.com" },
        .{ "private@[192.168.1.10]", "pri***@[***]" },
        .{ "private@[IPv6:2001:db8::1]", "pri***@[***]" },
    };
    for (cases) |case| {
        const label = try display_rows.redactEmailAlloc(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(label);
        try std.testing.expectEqualStrings(case[1], label);
    }
}

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
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

fn appendApiKeyAccount(
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

test "Scenario: Given same email with two team accounts and one plus account when building display rows then they are grouped and numbered" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .business);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .business);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);
    try registry.setActiveAccountKey(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960");

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 4);
    try std.testing.expect(rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "use***@e***.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business #1"));
    try std.testing.expect(rows.rows[1].is_active);
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Business #2"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
    try std.testing.expect(rows.selectable_row_indices.len == 3);
}

test "Scenario: Given grouped accounts with aliases when building display rows then aliases override numbered plan labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .business);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "backup", .business);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 3);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "backup") or std.mem.eql(u8, rows.rows[1].account_cell, "work"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "backup") or std.mem.eql(u8, rows.rows[2].account_cell, "work"));
}

test "Scenario: Given grouped accounts with a prolite record when building display rows then labels use Pro Lite wording" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .prolite);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .business);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "use***@e***.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Pro Lite"));
}

test "Scenario: Given a grouped account with a fresher usage plan when building display rows then labels and ordering prefer the usage plan" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .business,
    };
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .free);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "use***@e***.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Free"));
}

test "Scenario: Given same-email accounts filtered down to one row when building display rows then singleton is decided from the rendered subset" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var grouped_rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer grouped_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), grouped_rows.rows.len);
    try std.testing.expect(grouped_rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, grouped_rows.rows[0].account_cell, "use***@e***.com"));

    const indices = [_]usize{0};
    var singleton_rows = try display_rows.buildDisplayRows(gpa, &reg, &indices);
    defer singleton_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), singleton_rows.rows.len);
    try std.testing.expect(singleton_rows.rows[0].account_index != null);
    try std.testing.expect(std.mem.eql(u8, singleton_rows.rows[0].account_cell, "work(Primary Workspace, use***@e***.com)"));
}

test "Scenario: Given singleton accounts with alias and account name combinations when building display rows then preferred labels render before emails" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-4QmYj7PkN2sLx8AcVbR3TwHd::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "alias-name@example.com", "work", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-8LnCq5VzR1mHx9SfKpT4JdWe::518a44d9-ba75-4bad-87e5-ae9377042960", "alias-only@example.com", "backup", .business);
    try appendAccount(gpa, &reg, "user-2RbFk6NsQ8vLp3XtJmW7CyHa::a4021fa5-998b-4774-989f-784fa69c367b", "name-only@example.com", "", .business);
    reg.accounts.items[2].account_name = try gpa.dupe(u8, "Sandbox");
    try appendAccount(gpa, &reg, "user-9TwHs4KmP7xNc2LdVrQ6BjYe::d8f0f19d-7b6f-4db8-b7a8-07b9fbf5774a", "fallback@example.com", "", .business);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "work(Primary Workspace, ali***@e***.com)"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "backup(ali***@e***.com)"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "fal***@e***.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Sandbox(nam***@e***.com)"));
}

test "human account labels mask emails embedded in aliases and workspace names" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, "user::workspace", "owner@example.com", "Work <contact@example.net>", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Workspace for éééé@école.edu, backup@office.com.");
    const rec = &reg.accounts.items[0];

    const preferred = try display_rows.buildPreferredAccountLabelAlloc(gpa, rec, "Business");
    defer gpa.free(preferred);
    try std.testing.expectEqualStrings(
        "Work <con***@e***.net>(Workspace for ééé***@é***.edu, bac***@o***.com.)",
        preferred,
    );
    const identity = try display_rows.buildAccountIdentityLabelAlloc(gpa, rec);
    defer gpa.free(identity);
    try std.testing.expectEqualStrings(
        "Work <con***@e***.net>(Workspace for ééé***@é***.edu, bac***@o***.com., own***@e***.com)",
        identity,
    );
    try std.testing.expectEqualStrings("Work <contact@example.net>", rec.alias);
    try std.testing.expectEqualStrings("Workspace for éééé@école.edu, backup@office.com.", rec.account_name.?);
    try std.testing.expectEqualStrings("owner@example.com", rec.email);
}

test "API key preferred labels mask email aliases while preserving the fingerprint" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendApiKeyAccount(gpa, &reg, "apikey::user_api::0123456789abcdef", "owner@example.com");
    gpa.free(reg.accounts.items[0].alias);
    reg.accounts.items[0].alias = try gpa.dupe(u8, "contact@example.net");

    const label = try display_rows.buildPreferredAccountLabelAlloc(gpa, &reg.accounts.items[0], "API key");
    defer gpa.free(label);
    try std.testing.expectEqualStrings("con***@e***.net(sk-01234***cdef)", label);
}

test "email punctuation in aliases cannot bypass masking" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, "user::workspace", "fixture!@example.com", "Contact fixture!@example.com or o'brien@example.net", .business);
    const label = try display_rows.buildAccountIdentityLabelAlloc(gpa, &reg.accounts.items[0]);
    defer gpa.free(label);
    try std.testing.expectEqualStrings("Contact fix***@e***.com or o'b***@e***.net(fix***@e***.com)", label);
}

test "quoted email identities and domain literals are masked inside labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    const alias = "Contact \"private user\"@example.com or \"private\\\" user\"@office.net; private@[192.168.1.10]; \"private@ user\\\" name\"@office.org";
    try appendAccount(gpa, &reg, "user::workspace", "owner@example.com", alias, .business);
    const label = try display_rows.buildAccountIdentityLabelAlloc(gpa, &reg.accounts.items[0]);
    defer gpa.free(label);
    try std.testing.expectEqualStrings(
        "Contact \"pri***\"@e***.com or \"pri***\"@o***.net; pri***@[***]; \"pri***\"@o***.org(own***@e***.com)",
        label,
    );
    try std.testing.expectEqualStrings(alias, reg.accounts.items[0].alias);
}

test "ordinary quoted labels preserve text around masked emails" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, "user::workspace", "owner@example.com", "Notes \"contact@example.net mentions @handle\" then \"private@user\"@office.com", .business);
    const label = try display_rows.buildPreferredAccountLabelAlloc(gpa, &reg.accounts.items[0], "Business");
    defer gpa.free(label);
    try std.testing.expectEqualStrings("Notes \"con***@e***.net mentions @handle\" then \"pri***\"@o***.com", label);
}

test "surrounding quotes cannot hide a quoted email in account labels" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Notes \"Contact \"private user\"@example.com\"", "Notes \"Contact \"pri***\"@e***.com\"" },
        .{ "Notes \"unfinished text then \"private user\"@example.com", "Notes \"unfinished text then \"pri***\"@e***.com" },
    };
    for (cases) |case| {
        var reg = makeRegistry();
        defer reg.deinit(gpa);
        try appendAccount(gpa, &reg, "user::workspace", "owner@example.com", case[0], .business);
        const label = try display_rows.buildPreferredAccountLabelAlloc(gpa, &reg.accounts.items[0], "Business");
        defer gpa.free(label);
        try std.testing.expectEqualStrings(case[1], label);
        try std.testing.expectEqualStrings(case[0], reg.accounts.items[0].alias);
    }
}

test "long unmatched email markers remain unchanged in account labels" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "@", "@[" }) |pattern| {
        const alias = try gpa.alloc(u8, 32_768 * pattern.len);
        defer gpa.free(alias);
        for (0..32_768) |idx| @memcpy(alias[idx * pattern.len ..][0..pattern.len], pattern);
        var reg = makeRegistry();
        defer reg.deinit(gpa);
        try appendAccount(gpa, &reg, "user::workspace", "owner@example.com", alias, .business);
        const label = try display_rows.buildPreferredAccountLabelAlloc(gpa, &reg.accounts.items[0], "Business");
        defer gpa.free(label);
        try std.testing.expectEqualStrings(alias, label);
    }
}

test "Scenario: Given mixed singleton and grouped accounts when building display rows then singleton rows include preferred labels while grouped rows keep child labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-6JpMv8XrT3nLc9QsHbW4DyKa::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "solo@example.com", "solo", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Solo Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "work", .business);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "solo(Solo Workspace, sol***@e***.com)"));
    try std.testing.expect(rows.rows[1].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "use***@e***.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "work(Primary Workspace)"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
}

test "Scenario: Given grouped accounts with account names when building display rows then child labels use the same precedence" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .business);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Backup Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(
        (std.mem.eql(u8, rows.rows[1].account_cell, "work(Primary Workspace)") and
            std.mem.eql(u8, rows.rows[2].account_cell, "Backup Workspace")) or
            (std.mem.eql(u8, rows.rows[1].account_cell, "Backup Workspace") and
                std.mem.eql(u8, rows.rows[2].account_cell, "work(Primary Workspace)")),
    );
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
}

test "Scenario: Given a single API key account when building display rows then the row stays as the email" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendApiKeyAccount(gpa, &reg, "apikey::user_api::7f3c1d9a2b4e8c2042ce", "user@example.com");

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("use***@e***.com", rows.rows[0].account_cell);
}

test "Scenario: Given two API key accounts for one email when building display rows then child labels are masked fingerprints" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendApiKeyAccount(gpa, &reg, "apikey::user_api::7f3c1d9a2b4e8c2042ce", "user@example.com");
    try appendApiKeyAccount(gpa, &reg, "apikey::user_api::12345abcdeffedc67890", "user@example.com");

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expectEqualStrings("use***@e***.com", rows.rows[0].account_cell);
    try std.testing.expectEqualStrings("sk-12345***7890", rows.rows[1].account_cell);
    try std.testing.expectEqualStrings("sk-7f3c1***42ce", rows.rows[2].account_cell);
}
