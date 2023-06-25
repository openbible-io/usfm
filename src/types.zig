const std = @import("std");

pub const log = std.log.scoped(.usfm);
pub const TagType = u8;

pub const Token = union(enum) {
    const Self = @This();

    tag_open: TagType,
    text: []u8,
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
    inline_elements: []InlineElement,

    const Self = @This();
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        // This is needed because there are really two places text can appear.
        // \element text1 \w word\w* text2
        allocator.free(self.text);
        allocator.free(self.inline_elements);
    }
};
pub const InlineElement = struct {
    tag: []const u8,
    text: []const u8,
    attributes: []Attribute,
    inline_elements: []InlineElement,

    const Self = @This();
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        // This is needed because there are really two places text can appear.
        // \w word \zaln-s\* word2 \w*
        allocator.free(self.text);
        allocator.free(self.attributes);
        allocator.free(self.inline_elements);
    }
};
pub const Attribute = struct {
    key: []const u8,
    val: []const u8,
};
