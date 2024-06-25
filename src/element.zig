const std = @import("std");
const Tag = @import("./tag.zig").Tag;
const whitespace = @import("./Lexer.zig").whitespace;
const tab = "\t";

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
    depth: usize = 0,
    cur: ?Element.Node = null,
    prev_sibling: ?Element = null,
    next_sibling: ?Element = null,

    pub fn fmt(self: *HtmlFormatter, w: anytype, ele: Element) @TypeOf(w).Error!void {
        return switch (ele) {
            .node => |n| try self.fmtNode(w, n),
            .text => |t| try self.fmtText(w, t),
        };
    }

    fn fmtText(self: *HtmlFormatter, w: anytype, text: []const u8) !void {
        for (0..self.depth) |_| try w.writeAll(tab);

        var to_dedupe_whitespace = text;
        if (self.prev_sibling) |p| switch (p) {
            .node => |n| {
                if (n.tag.isParagraph()) {
                    to_dedupe_whitespace = std.mem.trimLeft(u8, text, whitespace);
                    if (to_dedupe_whitespace.len != text.len) try w.writeByte('\n');
                }
            },
            else => {},
        };
        // if (self.next_sibling) |n| switch (n) {
        //     .node => |n| {
        //     },
        //     else => {},
        // };

        var last_space = false;
        for (text) |c| {
            const is_whitespace = std.mem.indexOfScalar(u8, whitespace, c) != null;
            defer last_space = is_whitespace;
            if (is_whitespace and last_space) continue;

            try w.writeByte(if (is_whitespace) ' ' else c);
        }
    }

    fn fmtNode(self: *HtmlFormatter, w: anytype, node: Element.Node) !void {
        self.cur = node;
        if (node.tag == .root) {
            try self.fmtChildren(w, node.children);
            return;
        }
        try w.writeBytesNTimes(tab, self.depth);

        const tag: []const u8 = if (node.tag.isParagraph())
            "p"
        else if (node.tag == .v)
            "sup"
        else if (node.tag.isInline() or node.tag.isCharacter())
            "span"
        else if (node.tag.isMilestoneStart())
            "div"
        else {
            try self.fmtChildren(w, node.children);
            return;
        };

        switch (node.tag) {
            .p => try w.writeAll("<p"),
            else => |t| try w.print("<{s} class=\"{s}\"", .{ tag, @tagName(t) }),
        }
        if (node.attributes.len > 0) {
            try w.writeAll(" ");
            for (node.attributes, 0..) |a, i| {
                try w.print("{s}=\"{s}\"", .{ a.key, a.value });
                if (i != node.attributes.len - 1) try w.writeByte(' ');
            }
        }
        try w.writeAll(">");

        try self.fmtChildren(w, node.children);

        try w.writeByte('\n');
        try w.writeBytesNTimes(tab, self.depth);
        try w.print("</{s}>", .{ tag });
    }

    fn fmtChildren(self: *HtmlFormatter, w: anytype, children: []const Element) !void {
        const is_root = self.cur != null and self.cur.?.tag == .root;
        if (!is_root) self.depth += 1;

        for (children, 0..) |c, i| {
            self.next_sibling = children[@min(i + 1, children.len - 1)];
            if (!is_root or i > 0) try w.writeByte('\n');
            try self.fmt(w, c);
            self.prev_sibling = c;
        }
        if (!is_root) self.depth -= 1;
    }
};
