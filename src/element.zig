const std = @import("std");
const Tag = @import("./tag.zig").Tag;
const whitespace = @import("./Lexer.zig").whitespace;

pub const Element = union(enum) {
    node: Node,
    text: []const u8,

    const tab = "  ";
    pub const Node = struct {
        pub const Attribute = struct {
            key: []const u8,
            value: []const u8,
        };

        tag: Tag,
        attributes: []const Attribute = &.{},
        children: []const Element = &.{},

        const Self = @This();

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.attributes);
            for (self.children) |c| c.deinit(allocator);
            allocator.free(self.children);
        }

        fn html2(self: Self, writer: anytype, depth: usize) @TypeOf(writer).Error!void {
            for (0..depth) |_| try writer.writeAll(tab);
            try writer.print("<{s}", .{@tagName(self.tag)});
            for (self.attributes) |a| try writer.print(" {s}=\"{s}\"", .{ a.key, a.value });
            try writer.writeByte('>');
            for (self.children) |c| {
                try writer.writeByte('\n');
                try c.html2(writer, depth + 1);
            }
            if (self.children.len > 0) {
                try writer.writeByte('\n');
                for (0..depth) |_| try writer.writeAll(tab);
            }
            try writer.print("</{s}>", .{@tagName(self.tag)});
        }

        pub fn html(self: Self, writer: anytype) !void {
            try self.html2(writer, 0);
        }
    };

    pub fn deinit(self: Element, allocator: std.mem.Allocator) void {
        switch (self) {
            .node => |n| n.deinit(allocator),
            .text => {},
        }
    }

    pub fn html2(self: Element, writer: anytype, depth: usize) !void {
        return switch (self) {
            .node => |n| try n.html2(writer, depth),
            .text => |t| {
                for (0..depth) |_| try writer.writeAll(tab);
                const trimmed = std.mem.trim(u8, t, whitespace);
                if (trimmed.len != t.len) {
                    try writer.print("\"{s}\"", .{ t });
                } else {
                    try writer.writeAll(t);
                }
            },
        };
    }

    pub fn html(self: Element, writer: anytype) !void {
        return self.html2(writer, 0);
    }
};
