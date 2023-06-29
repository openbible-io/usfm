const std = @import("std");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;

const whitespace = &[_]u8{ ' ', '\t', '\n' };

fn getText(text: []const u8) []const u8 {
    var res = @constCast(std.mem.trim(u8, text, whitespace));
    for (res) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    return res;
}

fn getNumber(text: []const u8) []const u8 {
    for (text, 0..) |c, i| {
        if (c < '0' or c > '9') return text[0..i];
    }
    return "";
}

pub fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

fn isVerse(c: Element) bool {
    return std.mem.eql(u8, "v", c.tag);
}

pub fn isChapter(c: Element) bool {
    return std.mem.eql(u8, "c", c.tag);
}

fn isBr(c: Element) bool {
    return std.mem.eql(u8, "p", c.tag);
}

const Verse = struct {
    text: ?[]const u8 = null,
    number: ?[]const u8 = null,
    footnote: ?[]const u8 = null,
};

const Paragraph = []Verse;

fn tagName(usfm_name: []const u8) []const u8 {
    if (std.mem.eql(u8, "v", usfm_name)) return "verse";
    if (std.mem.eql(u8, "p", usfm_name)) return "br";
    return usfm_name;
}

/// Caller owns returned paragraphs.
pub fn paragraphs(allocator: std.mem.Allocator, chapter: Element) ![]Paragraph {
    var res = std.ArrayList(Paragraph).init(allocator);
    var cur = std.ArrayList(Verse).init(allocator);

    for (chapter.children) |child| {
        // We only care about verses and breaks
        if (isVerse(child)) {
            const inner = getText(try child.innerText(allocator));
            const number = getNumber(inner);
            try cur.append(Verse{
                .text = getText(inner[number.len..]),
                .number = if (std.mem.eql(u8, "v", child.tag)) number else null,
                .footnote = if (child.footnote()) |f| getText(try f.footnoteInnerText(allocator)) else null,
            });
        } else if (isBr(child) and cur.items.len > 0) {
            try res.append(try cur.toOwnedSlice());
            cur = std.ArrayList(Verse).init(allocator);
        }
    }
    if (cur.items.len > 0) try res.append(try cur.toOwnedSlice());

    return res.toOwnedSlice();
}
