const std = @import("std");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;

const Allocator = std.mem.Allocator;
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

const Verse = struct {
    text: ?[]const u8 = null,
    number: ?[]const u8 = null,
    footnote: ?[]const u8 = null,

    const Self = @This();

    pub fn isEmpty(self: Self) bool {
        return self.text == null and self.number == null and self.footnote == null;
    }
};

const Paragraph = struct {
    tag: []const u8,
    verses: []Verse,
};
const ParagraphBuilder = struct {
    tag: []const u8,
    verses: std.ArrayList(Verse),

    const Self = @This();

    pub fn toParagraph(self: *Self) !Paragraph {
        return Paragraph{
            .tag = self.tag,
            .verses = try self.verses.toOwnedSlice(),
        };
    }
};

fn tagName(usfm_name: []const u8) []const u8 {
    if (std.mem.eql(u8, "v", usfm_name)) return "verse";
    if (std.mem.eql(u8, "p", usfm_name)) return "br";
    return usfm_name;
}

fn verse(allocator: Allocator, element: Element) !Verse {
    const inner = getText(try element.innerText(allocator));
    const number = getNumber(inner);
    const text = getText(inner[number.len..]);
    const footnote = if (element.footnote()) |f| getText(try f.footnoteInnerText(allocator)) else "";
    return Verse{
        .text = if (text.len > 0) text else null,
        .number = if (number.len > 0) number else null,
        .footnote = if (footnote.len > 0) footnote else null,
    };
}

/// Caller owns returned paragraphs.
pub fn paragraphs(allocator: Allocator, chapter: Element) ![]Paragraph {
    if (chapter.children.len == 0) return &.{};

    var res = std.ArrayList(Paragraph).init(allocator);
    var paragraph: ?ParagraphBuilder = null;

    for (chapter.children) |child| {
        if (Parser.isParagraph(child.tag)) {
            if (paragraph) |*p| try res.append(try p.toParagraph());
            paragraph = ParagraphBuilder{
                .tag = tagName(child.tag),
                .verses = std.ArrayList(Verse).init(allocator),
            };
        }
        if (paragraph) |*p| {
            const paragraph_verse = try verse(allocator, child);
            if (!paragraph_verse.isEmpty()) try p.verses.append(paragraph_verse);
        }
    }
    if (paragraph) |*p| try res.append(try p.toParagraph());

    return res.toOwnedSlice();
}
