const std = @import("std");
const types = @import("./types.zig");
const Lexer = @import("./lexer.zig").Lexer;

const Allocator = std.mem.Allocator;
const Tag = types.Tag;
const Token = types.Token;
const Element = types.Element;
const log = types.log;
pub const Error = error{
    InvalidClosingTag,
    MissingClosingTag,
};
const testing = std.testing;

pub const Parser = struct {
    const Self = @This();

    allocator: Allocator,
    lexer: Lexer,

    pub fn init(allocator: Allocator, buffer: []const u8) Self {
        return Self{
            .allocator = allocator,
            .lexer = Lexer.init(allocator, buffer),
        };
    }

    fn level(tag: Tag) u8 {
        if (std.mem.eql(u8, tag, "c")) return 0;
        if (tag.isParagraph()) return 1;
        if (std.mem.eql(u8, tag, "v")) return 2;
        if (std.mem.eql(u8, tag, "f")) return 3;
        if (!tag.isCharacter()) return 4;
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
        log.err(fmt ++ " at {d}:{d}{s}", args2);
    }

    fn expect(self: *Self, tag: Token.Tag) !?Tag {
        const token = try self.lexer.next();
        if (token) |t| {
            if (t.tag == tag) return t;
            self.printErr(t.start, "expected {}, got {}", .{ tag, token });
        }
        return null;
    }

    fn expectTag(self: *Self, token: Token) !Tag {
        const tag_text = self.lexer.view(token);
        return Tag.init(tag_text) catch |e| {
            self.printErr(token.start, "invalid tag {s}", .{ tag_text });
            return e;
        };
    }

    // Caller owns returned element and should call `.deinit`
    pub fn next(self: *Self) !?Element {
        const token: Token = try self.lexer.next() orelse return null;
        switch (token.tag) {
            .tag_open => {
                const allocator = self.allocator;
                var attributes = std.ArrayList(Element.Node.Attribute).init(allocator);
                errdefer attributes.deinit();
                var children = std.ArrayList(Element).init(allocator);
                errdefer {
                    for (children.items) |c| c.deinit(allocator);
                    children.deinit();
                }

                const tag = try self.expectTag(token);
                var closed = false;
                var seen_attributes = false;
                while (try self.lexer.peek()) |next_token| {
                    switch (next_token.tag) {
                        .text => {
                            if (seen_attributes) {
                                self.printErr(token.start, "unexpected text", .{});
                                return error.UnexpectedText;
                            }
                            const text = try self.next();
                            try children.append(text.?);
                        },
                        .tag_open => {
                            if (seen_attributes) {
                                self.printErr(token.start, "unexpected opening tag", .{});
                                return error.UnexpectedTagOpen;
                            }
                            if (tag.isParagraph() or tag.isInline()) {
                                const child = try self.next();
                                try children.append(child.?);
                            } else {
                                break;
                            }
                        },
                        .tag_close => {
                            const close = (try self.lexer.next()).?;
                            const closing_tag_text = self.lexer.view(close);
                            if (closing_tag_text.len > 0) {
                                const closing_tag = try self.expectTag(close);
                                if (std.meta.eql(tag, closing_tag)) {
                                    self.printErr(
                                        close.start,
                                        "closing tag {s} does not match opening tag {s}",
                                        .{ closing_tag_text, self.lexer.view(token) },
                                    );
                                    return error.InvalidClosingTag;
                                }
                            }
                            closed = true;
                            break;
                        },
                        .attributes => {
                            seen_attributes = true;
                            // ignore for now
                        },
                    }
                }

                if (tag.isInline() and !closed) {
                    self.printErr(
                        self.lexer.pos,
                        "missing closing tag for inline tag {s}",
                        .{self.lexer.view(token)},
                    );
                    return error.MissingClosingTag;
                }

                return Element{ .node = .{
                    .tag = tag,
                    .attributes = try attributes.toOwnedSlice(),
                    .children = try children.toOwnedSlice(),
                } };
            },
            .text => {
                return .{ .text = self.lexer.view(token) };
            },
            .tag_close, .attributes => {
                self.printErr(token.start, "unexpected tag", .{});
                return error.UnexpectedTag;
            },
        }
    }
};

fn expectElements(usfm: []const u8, expected: []const Element) !void {
    const allocator = testing.allocator;

    var actual = std.ArrayList(Element).init(allocator);
    defer {
        for (actual.items) |e| e.deinit(allocator);
        actual.deinit();
    }

    var parser = Parser.init(allocator, usfm);
    while (try parser.next()) |e| try actual.append(e);

    try std.testing.expectEqualDeep(expected, actual.items);
}

test "single simple tag" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
    ;
    try expectElements(
        usfm,
        &[_]Element{
            .{ .node = .{ .tag = .id, .children = &[_]Element{.{ .text = usfm[4..] }} } },
        },
    );
}

// test "two simple tags" {
//     const usfm =
//         \\\id GEN EN_ULT en_English_ltr
//         \\\usfm 3.0
//     ;
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const ele1 = (try parser.next()).?;
//     defer ele1.deinit(testing.allocator);
//     try testing.expectEqualStrings("id", ele1.tag);
//     try testing.expectEqualStrings(usfm[4..30], ele1.text);
//
//     const ele2 = (try parser.next()).?;
//     defer ele2.deinit(testing.allocator);
//     try testing.expectEqualStrings("usfm", ele2.tag);
//     try testing.expectEqualStrings("3.0", ele2.text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "single attribute tag" {
//     const usfm =
//         \\\v 1 \w hello |   x-occurences  =   "1" \w*
//     ;
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
//     try testing.expectEqualStrings("v", verse.tag);
//     try testing.expectEqualStrings("1 ", verse.text);
//
//     const word = verse.children[0];
//     try testing.expectEqualStrings("w", word.tag);
//     try testing.expectEqualStrings("hello ", word.text);
//
//     const attr = word.attributes[0];
//     try testing.expectEqualStrings("x-occurences", attr.key);
//     try testing.expectEqualStrings("1", attr.val);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "empty attribute tag" {
//     const usfm =
//         \\\v 1 \w hello |\w*
//     ;
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
//     try testing.expectEqualStrings("v", verse.tag);
//     try testing.expectEqualStrings("1 ", verse.text);
//
//     const word = verse.children[0];
//     try testing.expectEqualStrings("w", word.tag);
//     try testing.expectEqualStrings("hello ", word.text);
//
//     try testing.expectEqual(@as(usize, 0), word.attributes.len);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "milestones" {
//     const usfm =
//         \\\v 1 \zaln-s\*\w In\w*\zaln-e\*there
//     ;
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
//
//     try testing.expectEqualStrings("v", verse.tag);
//     try testing.expectEqualStrings("1 ", verse.text);
//
//     const zalns = verse.children[0];
//     try testing.expectEqualStrings("zaln-s", zalns.tag);
//
//     const word = verse.children[1];
//     try testing.expectEqualStrings("w", word.tag);
//     try testing.expectEqualStrings("In", word.text);
//
//     const zalne = verse.children[2];
//     try testing.expectEqualStrings("zaln-e", zalne.tag);
//
//     const text = verse.children[3];
//     try testing.expectEqualStrings("text", text.tag);
//     try testing.expectEqualStrings("there", text.text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "line breaks" {
//     const usfm =
//         \\\v 1 \w In\w*
//         \\\w the\w*
//         \\\w beginning\w*
//         \\textnode
//     ;
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
//
//     try testing.expectEqualStrings("v", verse.tag);
//     try testing.expectEqualStrings("1 ", verse.text);
//     try testing.expectEqualStrings("In", verse.children[0].text);
//     try testing.expectEqualStrings("\n", verse.children[1].text);
//     try testing.expectEqualStrings("the", verse.children[2].text);
//     try testing.expectEqualStrings("\n", verse.children[3].text);
//     try testing.expectEqualStrings("beginning", verse.children[4].text);
//     try testing.expectEqualStrings("\ntextnode", verse.children[5].text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "footnote with inline fqa" {
//     const usfm =
//         \\\v 2
//         \\\f + \ft footnote: \fqa some text\fqa*.\f*
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
//     // try ele.print(std.io.getStdErr().writer());
//
//     try testing.expectEqualStrings("v", verse.tag);
//     try testing.expectEqualStrings("2\n", verse.text);
//
//     const footnote = verse.children[0];
//     try testing.expectEqualStrings("f", footnote.tag);
//     try testing.expectEqualStrings("+ ", footnote.text);
//
//     try testing.expectEqualStrings("ft", footnote.children[0].tag);
//     try testing.expectEqualStrings("footnote: ", footnote.children[0].text);
//
//     try testing.expectEqualStrings("fqa", footnote.children[1].tag);
//     try testing.expectEqualStrings("some text", footnote.children[1].text);
//
//     try testing.expectEqualStrings("text", footnote.children[2].tag);
//     try testing.expectEqualStrings(".", footnote.children[2].text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
//
//     const footnote2 = verse.footnote().?;
//     try testing.expectEqualStrings("f", footnote2.tag);
//     try testing.expectEqualStrings("+ ", footnote2.text);
// }
//
// test "footnote with block fqa" {
//     const usfm =
//         \\\v 1 \f + \fq until they had crossed over \ft or perhaps \fqa until we had crossed over \ft (Hebrew Ketiv).\f*
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const verse = (try parser.next()).?;
//     defer verse.deinit(testing.allocator);
// }
//
// test "header" {
//     const usfm =
//         \\\mt Genesis
//         \\
//         \\\ts\*
//         \\\c 1
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const ele = (try parser.next()).?;
//     defer ele.deinit(testing.allocator);
//     try testing.expectEqualStrings("mt", ele.tag);
//     try testing.expectEqualStrings("Genesis\n\n", ele.text);
//
//     const ele1 = ele.children[0];
//     defer ele1.deinit(testing.allocator);
//     try testing.expectEqualStrings("ts", ele1.tag);
//
//     const ele2 = (try parser.next()).?;
//     defer ele2.deinit(testing.allocator);
//     try testing.expectEqualStrings("c", ele2.tag);
//     try testing.expectEqualStrings("1", ele2.text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "chapters" {
//     const usfm =
//         \\\c 1
//         \\\v 1 verse1
//         \\\v 2 verse2
//         \\\c 2
//         \\\v 1 asdf
//         \\\v 2 hjkl
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const c1 = (try parser.next()).?;
//     defer c1.deinit(testing.allocator);
//     // try c1.print(std.io.getStdErr().writer());
//
//     try testing.expectEqualStrings("c", c1.tag);
//     try testing.expectEqualStrings("1\n", c1.text);
//     try testing.expectEqual(@as(usize, 2), c1.children.len);
//
//     var v1 = c1.children[0];
//     try testing.expectEqualStrings("v", v1.tag);
//     try testing.expectEqualStrings("1 verse1\n", v1.text);
//
//     var v2 = c1.children[1];
//     try testing.expectEqualStrings("v", v2.tag);
//     try testing.expectEqualStrings("2 verse2\n", v2.text);
//
//     const c2 = (try parser.next()).?;
//     defer c2.deinit(testing.allocator);
//     // try c2.print(std.io.getStdErr().writer());
//
//     v1 = c2.children[0];
//     try testing.expectEqualStrings("v", v1.tag);
//     try testing.expectEqualStrings("1 asdf\n", v1.text);
//
//     v2 = c2.children[1];
//     try testing.expectEqualStrings("v", v2.tag);
//     try testing.expectEqualStrings("2 hjkl", v2.text);
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "hanging text" {
//     const usfm =
//         \\\ip Hello
//         \\\bk inline tag\bk* hanging text.
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const ip = (try parser.next()).?;
//     defer ip.deinit(testing.allocator);
//     // try ip.print(std.io.getStdErr().writer());
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
//
// test "paragraphs" {
//     const usfm =
//         \\\p
//         \\\v 1 verse1
//         \\\p
//         \\\v 2 verse2
//     ;
//
//     var parser = try Parser.init(testing.allocator, usfm);
//     defer parser.deinit();
//
//     const p1 = (try parser.next()).?;
//     defer p1.deinit(testing.allocator);
//     // try p1.print(std.io.getStdErr().writer());
//
//     const v1 = (try parser.next()).?;
//     defer v1.deinit(testing.allocator);
//     // try v1.print(std.io.getStdErr().writer());
//
//     const p2 = (try parser.next()).?;
//     defer p2.deinit(testing.allocator);
//     // try p2.print(std.io.getStdErr().writer());
//
//     const v2 = (try parser.next()).?;
//     defer v2.deinit(testing.allocator);
//     // try v2.print(std.io.getStdErr().writer());
//
//     try testing.expectEqual(@as(?Element, null), try parser.next());
// }
