const std = @import("std");
const clock = @import("codex_auth").time.clock;

test "clock formats cover midnight, noon, and AM/PM transitions" {
    const cases = [_]struct { hour: u32, minute: u32, h12: []const u8, h24: []const u8 }{
        .{ .hour = 0, .minute = 0, .h12 = "12:00 AM", .h24 = "00:00" },
        .{ .hour = 9, .minute = 5, .h12 = "9:05 AM", .h24 = "09:05" },
        .{ .hour = 11, .minute = 59, .h12 = "11:59 AM", .h24 = "11:59" },
        .{ .hour = 12, .minute = 0, .h12 = "12:00 PM", .h24 = "12:00" },
        .{ .hour = 14, .minute = 5, .h12 = "2:05 PM", .h24 = "14:05" },
        .{ .hour = 23, .minute = 59, .h12 = "11:59 PM", .h24 = "23:59" },
    };
    for (cases) |case| {
        const h12 = try clock.formatClockAlloc(std.testing.allocator, case.hour, case.minute, .@"12h");
        defer std.testing.allocator.free(h12);
        const h24 = try clock.formatClockAlloc(std.testing.allocator, case.hour, case.minute, .@"24h");
        defer std.testing.allocator.free(h24);
        try std.testing.expectEqualStrings(case.h12, h12);
        try std.testing.expectEqualStrings(case.h24, h24);
    }
}
