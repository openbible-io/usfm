const std = @import("std");
const Tag = @import("./tag.zig").Tag;
const whitespace = @import("./Lexer.zig").whitespace;

pub const Element = union(enum) {
    node: Node,
    text: []const u8,

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
    };

    pub fn deinit(self: Element, allocator: std.mem.Allocator) void {
        switch (self) {
            .node => |n| n.deinit(allocator),
            .text => {},
        }
    }

    pub fn format(
        self: Element,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) (@TypeOf(writer).Error || error{Range})!void {
        _ = options;

        if (std.mem.eql(u8, "html", fmt)) {
            var formatter = HtmlFormatter{}; 
            try formatter.fmt(writer, self);
        } else {
            try writer.writeAll("Element{}");
        }
    }
};

const HtmlFormatter = struct {
    pub fn fmt(self: *HtmlFormatter, w: anytype, ele: Element) @TypeOf(w).Error!void {
        return switch (ele) {
            .node => |n| try self.fmtNode(w, n),
            .text => |t| try self.fmtText(w, t),
        };
    }

    fn fmtText(self: *HtmlFormatter, w: anytype, text: []const u8) !void {
        _ = self;
        var last_space = false;
        for (text) |c| {
            const is_whitespace = std.mem.indexOfScalar(u8, whitespace, c) != null;
            defer last_space = is_whitespace;
            if (is_whitespace and last_space) continue;

            try w.writeByte(if (is_whitespace) ' ' else c);
        }
    }

    fn fmtNode(self: *HtmlFormatter, w: anytype, node: Element.Node) !void {
        var class: ?[]const u8 = null;
        var tag: ?[]const u8 = null;

        switch (node.tag) {
            .v => {
                tag = "sup";
            },
            .w => {},
            .c => return,
            else => |t| {
                if (t.isParagraph()) tag = "p";
                if (t.isInline() or node.tag.isCharacter()) tag = "span";
                class = @tagName(t);
            }
        }

        if (tag) |t| {
            try w.print("<{s}", .{ t });
            if (class) |c| try w.print(" class=\"{s}\"", .{ c });

            if (node.attributes.len > 0) {
                try w.writeAll(" ");
                for (node.attributes, 0..) |a, i| {
                    try w.print("{s}=\"{s}\"", .{ a.key, a.value });
                    if (i != node.attributes.len - 1) try w.writeByte(' ');
                }
            }
            try w.writeAll(">");
        }

        for (node.children) |c| try self.fmt(w, c);

        if (tag) |t| {
            try w.print("</{s}>", .{ t });
            if (node.tag.isParagraph()) try w.writeByte('\n');
        }
    }
};
