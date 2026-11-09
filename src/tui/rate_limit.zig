const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const localtime = @import("../time/localtime.zig");
const clock = @import("../time/clock.zig");

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts, allocator: std.mem.Allocator) void {
        allocator.free(self.time);
        allocator.free(self.date);
    }
};

/// Single source of truth is `registry.resolveRateWindow`; this alias keeps
/// the TUI call sites on the same resolution without a second implementation.
pub const resolveRateWindow = registry.resolveRateWindow;

pub fn formatRateLimitFullAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    return formatRateLimitFullWithFormatAlloc(allocator, window, .@"24h");
}

pub fn formatRateLimitFullWithFormatAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow, time_format: clock.TimeFormat) ![]u8 {
    if (window == null) return try allocator.print("-", .{});
    if (window.?.resets_at == null) return try allocator.print("-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try allocator.print("100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now, time_format);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return allocator.print("{d}% ({s})", .{ remaining, parts.time });
    }
    return allocator.print("{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64, time_format: clock.TimeFormat) !ResetParts {
    var tm: localtime.struct_tm = undefined;
    if (!localtime.compat(reset_at, &tm)) {
        return unknownResetPartsAlloc(allocator);
    }
    var now_tm: localtime.struct_tm = undefined;
    if (!localtime.compat(now, &now_tm)) {
        return unknownResetPartsAlloc(allocator);
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    const time = try clock.formatClockAlloc(allocator, hour, min, time_format);
    errdefer allocator.free(time);
    return ResetParts{
        .time = time,
        .date = try allocator.print("{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn unknownResetPartsAlloc(allocator: std.mem.Allocator) !ResetParts {
    const time = try allocator.dupe(u8, "-");
    errdefer allocator.free(time);
    return .{ .time = time, .date = try allocator.dupe(u8, "-"), .same_day = true };
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}
