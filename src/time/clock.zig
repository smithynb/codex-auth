const std = @import("std");

pub const TimeFormat = enum { @"12h", @"24h" };

pub fn parseTimeFormat(text: []const u8) ?TimeFormat {
    if (std.mem.eql(u8, text, "12h")) return .@"12h";
    if (std.mem.eql(u8, text, "24h")) return .@"24h";
    return null;
}

pub fn formatClockAlloc(allocator: std.mem.Allocator, hour: u32, minute: u32, format: TimeFormat) ![]u8 {
    return switch (format) {
        .@"24h" => std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hour, minute }),
        .@"12h" => std.fmt.allocPrint(allocator, "{d}:{d:0>2} {s}", .{
            if (hour % 12 == 0) @as(u32, 12) else hour % 12,
            minute,
            if (hour < 12) "AM" else "PM",
        }),
    };
}
