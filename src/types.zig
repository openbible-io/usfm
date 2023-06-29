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

    // Caller owns returned string
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .text => |t| std.fmt.allocPrint(allocator, "Token {{ .text = {s} }}", .{t}),
            else => |t| std.fmt.allocPrint(allocator, "{any}", .{t}),
        };
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
        try writer.writeByte('\n');
    }

    pub fn print(self: Self, writer: anytype) !void {
        try self.print2(writer, 0);
    }

    pub fn isFootnote(self: Self) bool {
        return std.mem.eql(u8, self.tag, "f");
    }

    fn innerText2(
        self: Self,
        allocator: std.mem.Allocator,
        acc: *std.ArrayList(u8),
        comptime include_footnotes: bool,
    ) !void {
        if (self.isFootnote() and !include_footnotes) return;
        try acc.appendSlice(self.text);
        for (self.children) |c| try c.innerText2(allocator, acc, include_footnotes);
    }

    // Caller owns returned string.
    pub fn innerText(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var acc = std.ArrayList(u8).init(allocator);
        try self.innerText2(allocator, &acc, false);
        return acc.toOwnedSlice();
    }

    // Caller owns returned string.
    pub fn footnoteInnerText(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var acc = std.ArrayList(u8).init(allocator);
        try self.innerText2(allocator, &acc, true);
        return acc.toOwnedSlice();
    }

    pub fn footnote(self: Self) ?Element {
        if (self.isFootnote()) return self;
        for (self.children) |c| if (c.footnote()) |f| return f;
        return null;
    }
};

pub const Attribute = struct {
    key: []const u8,
    val: []const u8,
};
