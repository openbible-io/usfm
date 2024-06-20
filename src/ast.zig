const std = @import("std");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;

const Allocator = std.mem.Allocator;
const whitespace = &[_]u8{ ' ', '\t', '\n' };

fn getText(text: []const u8) []const u8 {
    const res = @constCast(std.mem.trim(u8, text, whitespace));
    for (res) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    return res;
}

pub fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

pub fn isChapter(c: Element) bool {
    return std.mem.eql(u8, "c", c.tag);
}
