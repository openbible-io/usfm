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

    // Otherwise we'll need a decent bit of look-ahead to support multiline inline tags
    // \v 1 Hello
    // \f this an inline child of v1 or a sibling? idk unless i parse all this \f*
    pub fn isInline(self: Self, tag_id: TagType) bool {
        const tag = self.tagName(tag_id);
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

        // Milestones
        for ([_][]const u8{
            "qt",
            "ts",
            "z",
        }) |t| if (std.mem.startsWith(u8, tag, t)) return true;

        return false;
    }

    fn canHaveChildren(self: Self, tag_id: TagType) bool {
        const tag = self.tagName(tag_id);
        for ([_][]const u8{
            "c",
            "v",
            "f",
        }) |t| if (std.mem.eql(u8, tag, t)) return true;
        return false;
    }

    fn tagName(self: Self, tag_id: TagType) []const u8 {
        return self.lexer.tokens.items[tag_id];
    }

    fn level(self: Self, tag_id: TagType) u8 {
        const tag = self.tagName(tag_id);
        if (std.mem.eql(u8, tag, "c")) return 0;
        if (std.mem.eql(u8, tag, "p")) return 1;
        if (std.mem.eql(u8, tag, "v")) return 2;
        if (std.mem.eql(u8, tag, "f")) return 3;
        if (!self.isInline(tag_id)) return 4;
        return 5;
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
        try self.lexer.eatSpace();
        const err_pos = self.lexer.pos;
        if (try self.lexer.next()) |maybe_tag| {
            if (maybe_tag != if (comptime is_open) .tag_open else .tag_close) {
                const tag_string = try maybe_tag.toString(self.allocator);
                defer self.allocator.free(tag_string);
                self.printErr(
                    err_pos,
                    "expected {s}ing tag, got {s}",
                    .{ if (comptime is_open) "open" else "clos", tag_string },
                );
                return null;
            }
            return if (comptime is_open) maybe_tag.tag_open else maybe_tag.tag_close;
        }
        return null;
    }

    fn addMaybeChildText(self: *Self, children: *std.ArrayList(Element)) !void {
        if (try self.lexer.peek()) |maybe_token| {
            switch (maybe_token) {
                .text => |t| {
                    _ = try self.lexer.next();
                    var child_text = try self.allocator.dupe(u8, t);
                    errdefer self.allocator.free(child_text);
                    try children.append(Element{
                        .tag = "text",
                        .text = child_text,
                        .attributes = &.{},
                        .children = &.{},
                    });
                },
                else => {},
            }
        }
    }

    // Caller owns returned element and should call `.deinit`
    pub fn next(self: *Self) !?Element {
        var text = std.ArrayList(u8).init(self.allocator);
        errdefer text.deinit();
        const allocator = self.allocator;
        var attributes = std.ArrayList(Attribute).init(allocator);
        errdefer attributes.deinit();
        var children = std.ArrayList(Element).init(allocator);
        errdefer {
            for (children.items) |c| c.deinit(allocator);
            children.deinit();
        }

        const tag = try self.expectTag(true) orelse return null;
        try self.stack.append(tag);

        if (try self.lexer.peek()) |maybe_text| {
            if (maybe_text == .text) {
                try text.appendSlice(maybe_text.text);
                log.debug("text {s}", .{text.items});
                _ = try self.lexer.next();
            }
        }

        while (try self.lexer.peek()) |maybe_child| {
            switch (maybe_child) {
                .tag_open => |t| {
                    log.debug("tag {s} maybe_child {s}", .{ self.lexer.tokens.items[tag], self.lexer.tokens.items[t] });
                    if ((self.canHaveChildren(tag) or self.isInline(tag) or self.isInline(t)) // Only allow expected children
                    and self.level(tag) < self.level(t) // Prevent duplicate tags from nesting
                    ) {
                        log.debug("is child", .{});
                        try children.append((try self.next()).?);
                    } else {
                        break;
                    }
                },
                .text => try self.addMaybeChildText(&children),
                else => break,
            }
        }

        if (try self.lexer.peek()) |maybe_attributes| {
            if (maybe_attributes == .attribute_start) {
                _ = try self.lexer.next();
                while (try self.lexer.peek()) |maybe_attr| {
                    if (maybe_attr != .attribute) break;
                    try attributes.append((try self.lexer.next()).?.attribute);
                }
            }
        }

        if (try self.lexer.peek()) |maybe_close| {
            if (maybe_close == .tag_close) {
                _ = try self.expectTag(false);
                _ = self.stack.popOrNull();
            }
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
    try testing.expectEqualStrings("1 ", ele.text);

    const zalns = ele.children[0];
    try testing.expectEqualStrings("zaln-s", zalns.tag);

    const word = ele.children[1];
    try testing.expectEqualStrings("w", word.tag);
    try testing.expectEqualStrings("In", word.text);

    const zalne = ele.children[2];
    try testing.expectEqualStrings("zaln-e", zalne.tag);

    const text = ele.children[3];
    try testing.expectEqualStrings("text", text.tag);
    try testing.expectEqualStrings("there", text.text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "line breaks" {
    const usfm =
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
        \\textnode
    ;
    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);

    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("1 ", ele.text);
    try testing.expectEqualStrings("In", ele.children[0].text);
    try testing.expectEqualStrings("\n", ele.children[1].text);
    try testing.expectEqualStrings("the", ele.children[2].text);
    try testing.expectEqualStrings("\n", ele.children[3].text);
    try testing.expectEqualStrings("beginning", ele.children[4].text);
    try testing.expectEqualStrings("\ntextnode", ele.children[5].text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "footnote with inline fqa" {
    const usfm =
        \\\v 2
        \\\f + \ft footnote: \fqa some text\fqa*.\f*
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
    // try ele.print(std.io.getStdErr().writer());

    try testing.expectEqualStrings("v", ele.tag);
    try testing.expectEqualStrings("2\n", ele.text);

    const footnote = ele.children[0];
    try testing.expectEqualStrings("f", footnote.tag);
    try testing.expectEqualStrings("+ ", footnote.text);

    try testing.expectEqualStrings("ft", footnote.children[0].tag);
    try testing.expectEqualStrings("footnote: ", footnote.children[0].text);

    try testing.expectEqualStrings("fqa", footnote.children[1].tag);
    try testing.expectEqualStrings("some text", footnote.children[1].text);

    try testing.expectEqualStrings("text", footnote.children[2].tag);
    try testing.expectEqualStrings(".", footnote.children[2].text);

    try testing.expectEqual(@as(?Element, null), try parser.next());

    const footnote2 = ele.footnote().?;
    try testing.expectEqualStrings("f", footnote2.tag);
    try testing.expectEqualStrings("+ ", footnote2.text);
}

test "footnote with block fqa" {
    const usfm =
        \\\v 1 \f + \fq until they had crossed over \ft or perhaps \fqa until we had crossed over \ft (Hebrew Ketiv).\f*
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
}

test "header" {
    const usfm =
        \\\mt Genesis
        \\
        \\\ts\*
        \\\c 1
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const ele = (try parser.next()).?;
    defer ele.deinit(testing.allocator);
    try testing.expectEqualStrings("mt", ele.tag);
    try testing.expectEqualStrings("Genesis\n\n", ele.text);

    const ele1 = ele.children[0];
    defer ele1.deinit(testing.allocator);
    try testing.expectEqualStrings("ts", ele1.tag);

    const ele2 = (try parser.next()).?;
    defer ele2.deinit(testing.allocator);
    try testing.expectEqualStrings("c", ele2.tag);
    try testing.expectEqualStrings("1", ele2.text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "chapters" {
    const usfm =
        \\\c 1
        \\\v 1 verse1
        \\\v 2 verse2
        \\\c 2
        \\\v 1 asdf
        \\\v 2 hjkl
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const c1 = (try parser.next()).?;
    defer c1.deinit(testing.allocator);
    // try c1.print(std.io.getStdErr().writer());

    try testing.expectEqualStrings("c", c1.tag);
    try testing.expectEqualStrings("1\n", c1.text);
    try testing.expectEqual(@as(usize, 2), c1.children.len);

    var verse1 = c1.children[0];
    try testing.expectEqualStrings("v", verse1.tag);
    try testing.expectEqualStrings("1 verse1\n", verse1.text);

    var verse2 = c1.children[1];
    try testing.expectEqualStrings("v", verse2.tag);
    try testing.expectEqualStrings("2 verse2\n", verse2.text);

    const c2 = (try parser.next()).?;
    defer c2.deinit(testing.allocator);
    // try c2.print(std.io.getStdErr().writer());

    verse1 = c2.children[0];
    try testing.expectEqualStrings("v", verse1.tag);
    try testing.expectEqualStrings("1 asdf\n", verse1.text);

    verse2 = c2.children[1];
    try testing.expectEqualStrings("v", verse2.tag);
    try testing.expectEqualStrings("2 hjkl", verse2.text);

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "hanging text" {
    const usfm =
        \\\ip Hello
        \\\bk inline tag\bk* hanging text.
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const c1 = (try parser.next()).?;
    defer c1.deinit(testing.allocator);
    // try c1.print(std.io.getStdErr().writer());

    try testing.expectEqual(@as(?Element, null), try parser.next());
}

test "paragraphs" {
    const usfm =
        \\\p
        \\\v 1 verse1
        \\\p
        \\\v 2 verse2
    ;

    var parser = try Parser.init(testing.allocator, usfm);
    defer parser.deinit();

    const p1 = (try parser.next()).?;
    defer p1.deinit(testing.allocator);
    try p1.print(std.io.getStdErr().writer());

    const v1 = (try parser.next()).?;
    defer v1.deinit(testing.allocator);
    try v1.print(std.io.getStdErr().writer());

    const p2 = (try parser.next()).?;
    defer p2.deinit(testing.allocator);
    try p2.print(std.io.getStdErr().writer());

    const v2 = (try parser.next()).?;
    defer v2.deinit(testing.allocator);
    try v2.print(std.io.getStdErr().writer());

    try testing.expectEqual(@as(?Element, null), try parser.next());
}
