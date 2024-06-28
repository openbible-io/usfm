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

    pub fn html(self: Element, writer: anytype) !void {
        var formatter = HtmlFormatter{};
        try formatter.fmt(writer, self);
    }
};

const HtmlFormatter = struct {
    pub fn fmt(self: *HtmlFormatter, w: anytype, ele: Element) (@TypeOf(w).Error || Error)!void {
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

            if (is_whitespace) {
                try w.writeByte(' ');
            } else switch (c) {
                '&' => try w.writeAll("&amp;"),
                '<' => try w.writeAll("&lt;"),
                '>' => try w.writeAll("&gt;"),
                else => |c2| try w.writeByte(c2),
            }
        }
    }

    const Error = error{InvalidHeadingLevel};

    fn fmtNode(self: *HtmlFormatter, w: anytype, node: Element.Node) !void {
        var class: ?[]const u8 = null;
        var tag: ?[]const u8 = null;
        switch (node.tag) {
            .p => tag = "p",
            .v => tag = "sup",
            .w, .root => {},
            .f, .fe => {
                // if (node.children.len < 2) return;

                // const popovertarget = "text_chapter_0";
                // const anchor_name = "anchor_" ++ popovertarget;
                // try w.print("<sup class=\"{s}\"><button popovertarget=\"{s}\">", .{ @tagName(node.tag), anchor_name, popovertarget });
                // try self.fmt(w, node.children[0]);
                // try w.print("</button></sup><span popover id=\"{s}\">", .{ popovertarget });

                // for (node.children[1..]) |c| try self.fmt(w, c);

                // try w.writeAll("</span>");

                return;
            },
            .c => return,
            inline .mt, .mte, .imt, .imte, .s, .ms => |lvl, t| {
                switch (lvl) {
                    0, 1 => tag = "h1",
                    2 => tag = "h2",
                    3 => tag = "h3",
                    4 => tag = "h4",
                    5 => tag = "h5",
                    6 => tag = "h6",
                    else => return error.InvalidHeadingLevel,
                }
                if (t != .s) class = @tagName(t);
            },
            .sr => {
                tag = "h2";
                class = "sr";
            },
            .em => tag = "em",
            .bd => tag = "b",
            .it => tag = "i",
            .sup => {
                tag = "sup";
                class = "sup";
            },
            .b => {
                try w.writeAll("<br>");
                return;
            },
            else => |t| {
                if (t.isIdentification()) {
                    return;
                } else if (t.isParagraph()) {
                    tag = "p";
                } else if (t.isInline() or node.tag.isCharacter()) {
                    tag = "span";
                }
                class = @tagName(t);
            },
        }

        if (tag) |t| {
            try w.print("<{s}", .{t});
            if (class) |c| try w.print(" class=\"{s}\"", .{c});

            // if (node.attributes.len > 0) {
            //     try w.writeAll(" ");
            //     for (node.attributes, 0..) |a, i| {
            //         try w.print("{s}=\"{s}\"", .{ a.key, a.value });
            //         if (i != node.attributes.len - 1) try w.writeByte(' ');
            //     }
            // }
            try w.writeAll(">");
        }

        for (node.children) |c| try self.fmt(w, c);

        if (tag) |t| {
            try w.print("</{s}>", .{t});
            if (node.tag.isParagraph()) try w.writeByte('\n');
        }
    }
};
