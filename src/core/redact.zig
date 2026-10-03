const std = @import("std");

pub fn redactEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeRedactedEmail(&out.writer, email) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// Preserve surrounding labels while masking email-shaped identities within them.
pub fn writeRedactedText(out: *std.Io.Writer, value: []const u8) !void {
    var written: usize = 0;
    var scan: usize = 0;
    while (scan < value.len) {
        var at = scan;
        var start = scan;
        if (value[scan] == '"') {
            if (isEscapedQuote(value, scan)) {
                scan += 1;
                continue;
            }
            const closing_quote = quotedLocalEnd(value, scan + 1);
            if (closing_quote != null and closing_quote.? + 1 < value.len and value[closing_quote.? + 1] == '@') {
                at = closing_quote.? + 1;
            } else {
                scan += 1;
                continue;
            }
        } else if (value[scan] == '@') {
            while (start > written and isLocalByte(value[start - 1])) : (start -= 1) {}
        } else {
            scan += 1;
            continue;
        }
        const end = domainEnd(value, at);
        scan = @max(end, at + 1);
        if (start == at or end == at + 1) continue;
        try out.writeAll(value[written..start]);
        try writeRedactedEmail(out, value[start..end]);
        written = end;
    }
    try out.writeAll(value[written..]);
}

pub fn writeRedactedEmail(out: *std.Io.Writer, email: []const u8) !void {
    const at = std.mem.lastIndexOfScalar(u8, email, '@') orelse return out.writeAll(email);
    const local = email[0..at];
    const domain = email[at + 1 ..];
    if (local.len == 0 or domain.len == 0) return out.writeAll("***@***");
    const quoted_local = local.len >= 2 and local[0] == '"' and local[local.len - 1] == '"';
    const local_value = if (quoted_local) local[1 .. local.len - 1] else local;
    const quote = if (quoted_local) "\"" else "";
    const literal_domain = domain.len >= 2 and domain[0] == '[' and domain[domain.len - 1] == ']';
    const suffix_start = std.mem.lastIndexOfScalar(u8, domain, '.') orelse domain.len;
    const suffix = if (literal_domain) "]" else if (suffix_start > 0 and suffix_start + 1 < domain.len) domain[suffix_start..] else "";
    try out.print("{s}{s}***{s}@{s}***{s}", .{
        quote,                                       characterPrefix(local_value, 3), quote,
        characterPrefix(domain[0..suffix_start], 1), suffix,
    });
}

fn domainEnd(value: []const u8, at: usize) usize {
    var end = at + 1;
    if (end < value.len and value[end] == '[') {
        end += 1;
        while (end < value.len and (isDomainByte(value[end]) or value[end] == ':')) : (end += 1) {}
        return if (end < value.len and value[end] == ']') end + 1 else at + 1;
    }
    while (end < value.len and isDomainByte(value[end])) : (end += 1) {}
    while (end > at + 1 and value[end - 1] == '.') : (end -= 1) {}
    return end;
}

fn quotedLocalEnd(value: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < value.len) : (pos += 1) {
        if (value[pos] == '"' and !isEscapedQuote(value, pos)) return pos;
    }
    return null;
}

fn isEscapedQuote(value: []const u8, pos: usize) bool {
    var slash_start = pos;
    while (slash_start > 0 and value[slash_start - 1] == '\\') : (slash_start -= 1) {}
    return (pos - slash_start) % 2 != 0;
}

fn isLocalByte(byte: u8) bool {
    return isDomainByte(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+/=?^_`{|}~", byte) != null;
}

fn isDomainByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.';
}

fn characterPrefix(value: []const u8, count: usize) []const u8 {
    var end: usize = 0;
    var characters: usize = 0;
    while (end < value.len) : (end += 1) {
        if (value[end] & 0xc0 != 0x80) {
            if (characters == count) break;
            characters += 1;
        }
    }
    return value[0..end];
}
