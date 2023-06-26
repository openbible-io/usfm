const std = @import("std");

pub const log = std.log.scoped(.usfm);
pub const TagType = u8;

pub const Token = union(enum) {
    const Self = @This();

    tag_open: TagType,
    text: []const u8,
    attribute_start: void,
    attribute: Attribute,
    tag_close: TagType,

    pub fn print(self: Self) void {
        switch (self) {
            .text => |t| log.debug("token '{s}'", .{t}),
            else => |t| log.debug("token {any}", .{t}),
        }
    }
};

pub const Element = struct {
    tag: []const u8,
    text: []const u8,
    attributes: []Attribute,
    children: []Element,

    const Self = @This();
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.attributes);
        for (self.children) |c| c.deinit(allocator);
        allocator.free(self.children);
    }

    fn print2(self: Self, writer: anytype, depth: usize) !void {
        const tab = "  ";
        for (0..depth) |_| try writer.writeAll(tab);
        try writer.print("{s} {s}", .{ self.tag, self.text });

        for (0..depth) |_| try writer.writeAll(tab);
        for (self.attributes) |a| try writer.print(" {s}={s}", .{ a.key, a.val });

        for (self.children) |c| {
            try writer.writeByte('\n');
            try c.print2(writer, depth + 1);
        }
    }

    pub fn print(self: Self, writer: anytype) !void {
        try self.print2(writer, 0);
    }
};

pub const Attribute = struct {
    key: []const u8,
    val: []const u8,
};
