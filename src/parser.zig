const std = @import("std");
const types = @import("./types.zig");
const Lexer = @import("./lexer.zig").Lexer;

const Allocator = std.mem.Allocator;
const TagType = types.TagType;
const Token = types.Token;
const Element = types.Element;
const Attribute = types.Attribute;
const log = types.log;
pub const Error = error{
    InvalidClosingTag,
    MissingClosingTag,
};
const testing = std.testing;

pub const Parser = struct {
    const Self = @This();
    const Stack = std.ArrayList(TagType);

    allocator: Allocator,
    lexer: Lexer,
    stack: Stack,

    pub fn init(allocator: Allocator, buffer: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .lexer = try Lexer.init(allocator, buffer),
            .stack = Stack.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.lexer.deinit();
        self.stack.deinit();
    }

    fn maybeParseText(self: *Self, text: *std.ArrayList(u8)) !void {
        // This is needed because there are multiple places text can appear.
        // \element text1 \w word\w* text2 \zaln-s\* text3
        if (try self.lexer.peek()) |maybe_text| {
            if (maybe_text == .text) {
                try text.appendSlice(maybe_text.text);
                log.debug("text {s}", .{text.items});
                _ = try self.lexer.next();
            }
        }
    }

    // Otherwise we'll need a decent bit of look-ahead to support multiline inline tags
    // \v 1 Hello
    // \f this an inline child of v1 or a sibling? idk unless i parse all this \f*
    fn isInline(self: Self, tag_id: TagType) bool {
        const tag = self.lexer.tokens.items[tag_id];
        for ([_][]const u8{
            // # Words and characters
            // ## Special text
            "add",
            "bk",
            "dc",
            "k",
            "lit",
            "nd",
            "ord",
            "pn",
            "png",
            "addpn",
            "qt",
            "sig",
            "sls",
            "tl",
            "wj",
            // ## Character styling
            "em",
            "bd",
            "it",
            "bdit",
            "no",
            "sc",
            "sup",
            // ## Special features
            "fig",
            "ndx",
            "rb",
            "pro",
            "w",
            "wg",
            "wh",
            "wa",
            // # Footnotes
            "f",
            "fe",
            // ## Footnote content elements
            "fv",
            "fdc",
            "fm",
            // # Cross references
            "x",
            "xop",
            "xot",
            "xnt",
            "xdc",
            "rq",
            // # Misc
            "cat",
            "ef",
            "ex",
            "jmp",
            // # Lists
            "litl",
            // # Poetry
            "qs",
            "qac",
            // Chapters and verses
            "ca",
            "va",
            "vp",
            // Titles
            "rq",
            // Introductions
            "ior",
            "iqt",
        }) |t| if (std.mem.eql(u8, tag, t)) return true;

        // We should check for \d+-[se], but I'm lazy
        for ([_][]const u8{
            "qt",
            "ts",
            "z",
        }) |t| if (std.mem.startsWith(u8, tag, t)) return true;

        return false;
    }

    fn printErr(self: *Self, pos: usize, comptime fmt: []const u8, args: anytype) void {
        var lineno: usize = 0;
        var lineno_pos: usize = 0;
        for (0..pos) |i| {
            if (self.lexer.buffer[i] == '\n') {
                lineno += 1;
                lineno_pos = i;
            }
        }
        const charno = pos - lineno_pos;
        const context = self.lexer.buffer[lineno_pos..pos];

        const args2 = args ++ .{ lineno + 1, charno, context };
        std.debug.print("\n", .{});
        log.err(fmt ++ " at {d}:{d}{s}", args2);
    }

    fn expectTag(self: *Self, comptime is_open: bool) !?TagType {
        const err_pos = self.lexer.pos;
        if (try self.lexer.next()) |maybe_tag| {
            if (maybe_tag != if (comptime is_open) .tag_open else .tag_close) {
                self.printErr(err_pos, "expected {s}ing tag, got {any}", .{ if (comptime is_open) "open" else "clos", maybe_tag });
                return null;
            }
            return if (comptime is_open) maybe_tag.tag_open else maybe_tag.tag_close;
        }
        return null;
    }

    // Caller owns returned element and should call `.deinit`
    pub fn next(self: *Self) !?Element {
        var text = std.ArrayList(u8).init(self.allocator);
        errdefer text.deinit();
        const allocator = self.allocator;
        var attributes = std.ArrayList(Attribute).init(allocator);
        errdefer attributes.deinit();
        var children = std.ArrayList(Element).init(allocator);
        errdefer children.deinit();

        const tag = try self.expectTag(true) orelse return null;
        try self.stack.append(tag);

        try self.maybeParseText(&text);

        while (try self.lexer.peek()) |maybe_inline| {
            if (maybe_inline != .tag_open or !self.isInline(maybe_inline.tag_open)) break;
            try children.append((try self.next()).?);
            try self.maybeParseText(&text);
        }

        if (self.isInline(tag)) brk: {
            if (try self.lexer.peek()) |maybe_attributes| {
                if (maybe_attributes == .attribute_start) {
                    _ = try self.lexer.next();
                    while (try self.lexer.peek()) |maybe_attr| {
                        if (maybe_attr != .attribute) break;
                        try attributes.append((try self.lexer.next()).?.attribute);
                    }
                }
            }

            const closing_tag = try self.expectTag(false) orelse {
                // log.warn("missing closing tag for {s} at {d}");
                break :brk;
            };

            if (self.stack.popOrNull()) |expected| {
                if (expected != closing_tag and closing_tag != 0) {
                    log.err("Expected closing tag {s}, not {s} at {d}", .{
                        self.lexer.tokens.items[expected],
                        self.lexer.tokens.items[closing_tag],
                        self.lexer.pos,
                    });
                    return Error.InvalidClosingTag;
                }
            } else {
                log.err("Unmatched closing tag {s} at {d}", .{
                    self.lexer.tokens.items[closing_tag],
                    self.lexer.pos,
                });
                return Error.InvalidClosingTag;
            }
        } else {
            try self.maybeParseText(&text);
        }

        return Element{
            .tag = self.lexer.tokens.items[tag],
            .text = try text.toOwnedSlice(),
            .attributes = try attributes.toOwnedSlice(),
            .children = try children.toOwnedSlice(),
        };
    }
};

test "single simple tag" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele1 = (try parser.next()).?;
    defer ele1.deinit(testing.allocator);
    try testing.expectEqualStrings("id", ele1.tag);
    try testing.expectEqualStrings(usfm[4..], ele1.text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "two simple tags" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
        \\\usfm 3.0
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele1 = (try parser.next()).?;
    defer ele1.deinit(testing.allocator);
    try testing.expectEqualStrings("id", ele1.tag);
    try testing.expectEqualStrings(usfm[4..30], ele1.text);

    const ele2 = (try parser.next()).?;
    defer ele2.deinit(testing.allocator);
    try testing.expectEqualStrings("usfm", ele2.tag);
    try testing.expectEqualStrings("3.0", ele2.text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "single attribute tag" {
    const usfm =
        \\\v 1 \w hello |   x-occurences  =   "1" \w*
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("1 ", ele.text);

    const word = ele.children[0];
    try testing.expectEqualStrings("w", word.tag);
    try testing.expectEqualStrings("hello ", word.text);

    const attr = word.attributes[0];
    try testing.expectEqualStrings("x-occurences", attr.key);
    try testing.expectEqualStrings("1", attr.val);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "empty attribute tag" {
    const usfm =
        \\\v 1 \w hello |\w*
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("1 ", ele.text);

    const word = ele.children[0];
    try testing.expectEqualStrings("w", word.tag);
    try testing.expectEqualStrings("hello ", word.text);

    try testing.expectEqual(@as(usize, 0), word.attributes.len);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "milestones" {
    const usfm =
        \\\v 1 \zaln-s\*\w In\w*\zaln-e\*there
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);

    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("1 there", ele.text);

    const zalns = ele.children[0];
    try testing.expectEqualStrings("zaln-s", zalns.tag);

    const word = ele.children[1];
    try testing.expectEqualStrings("w", word.tag);
    try testing.expectEqualStrings("In", word.text);

    const zalne = ele.children[2];
    try testing.expectEqualStrings("zaln-e", zalne.tag);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "line breaks" {
    const usfm =
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
    try ele.print(std.io.getStdErr().writer());

    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("1 ", ele.text);
    try testing.expectEqual(@as(usize, 3), ele.children.len);
}
