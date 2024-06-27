allocator: Allocator,
lexer: Lexer,
errors: Errors,

pub fn init(allocator: Allocator, buffer: []const u8) Parser {
    return Parser{
        .allocator = allocator,
        .lexer = Lexer.init(allocator, buffer),
        .errors = Errors{},
    };
}

pub fn deinit(self: *Parser) void {
    self.errors.deinit(self.allocator);
}

fn appendErr(self: *Parser, token: Token, kind: Error.Kind) !void {
    try self.errors.map.put(
        self.allocator,
        Error{ .token = token, .kind = kind },
        {},
    );
}

fn expect(self: *Parser, tag: Token.Tag, why: Error.Kind) !Token {
    const token = try self.lexer.next();
    if (token.tag == tag) return token;

    try self.appendErr(token, why);
    return error.UnexpectedToken;
}

fn expectClose(self: *Parser, open: Token) !void {
    const close = try self.lexer.peek();
    if (close.tag == .tag_close) {
        _ = try self.lexer.next();
        const open_text = self.lexer.view(open);
        const close_text = self.lexer.view(close);
        if (std.mem.eql(u8, open_text, close_text[0 .. close_text.len - 1])) return;
    }
    try self.appendErr(close, Error.Kind{ .expected_close = open });
    return error.ExpectedClose;
}

fn expectSelfClose(self: *Parser, for_token: Token) !void {
    const token = try self.lexer.peek();
    if (token.tag == .tag_close) {
        _ = try self.lexer.next();
        if (std.mem.eql(u8, self.lexer.view(token), "\\*")) return;
    }
    try self.appendErr(token, Error.Kind{ .expected_self_close = for_token });
    return error.ExpectedSelfClose;
}

fn parseTag(self: *Parser, token: Token) !Tag {
    const tag_text = self.lexer.view(token);
    return Tag.init(tag_text) catch |e| {
        try self.appendErr(token, .invalid_tag);
        return e;
    };
}

// Caller owns returned element and should call `.deinit`
pub fn next(self: *Parser) !?Element {
    const peek = try self.lexer.peek();
    if (peek.tag == .eof) return null;

    return try self.parseNode() orelse try self.parseText() orelse {
        try self.appendErr(peek, .invalid_root);
        _ = try self.lexer.next();
        return error.UnexpectedToken;
    };
}

/// Caller owns returned document
pub fn document(self: *Parser) !Document {
    const allocator = self.allocator;
    var root = NodeBuilder{
        .token = undefined,
        .tag = .root,
        .allocator = allocator,
        .attributes = NodeBuilder.Attributes.init(allocator),
        .children = NodeBuilder.Children.init(allocator),
    };

    while (true) {
        const e = self.next() catch continue orelse break;
        try root.children.append(e);
    }

    return Document{
        .root = .{ .node = try root.toOwned() },
    };
}

fn anyNode(_: Tag) bool {
    return true;
}

pub const Document = struct {
    root: Element,

    pub fn deinit(self: Document, allocator: Allocator) void {
        self.root.deinit(allocator);
    }
};

fn parseNode(self: *Parser) ParseNodeError!?Element {
    return try self.parseMilestone() orelse
        try self.parseInline() orelse
        try self.parseParagraph() orelse
        try self.parseCharacter();
}

const ParseNodeError = Allocator.Error || error{
    EndOfStream,
    MissingTagPrefix,
    InvalidSuffix,
    TagTooLong,
    InvalidTag,
    Overflow,
    InvalidCharacter,
    UnexpectedToken,
    InvalidAttribute,
    NoDefaultAttribute,
    ExpectedSelfClose,
    UnexpectedMilestoneClose,
    InvalidClosingTag,
    ExpectedClose,
};

fn nodeBuilder(self: *Parser, filter: fn (t: Tag) bool) !?NodeBuilder {
    const token = try self.lexer.peek();
    if (token.tag != .tag_open) return null;
    const tag = self.parseTag(token) catch return null;

    if (!filter(tag)) return null;
    _ = try self.lexer.next();

    var res = NodeBuilder.init(self.allocator, token, tag);
    try self.parseSpecialText(&res);
    return res;
}

fn parseMilestone(self: *Parser) !?Element {
    var builder = try self.nodeBuilder(Tag.isMilestoneStart) orelse return null;
    defer builder.deinit();

    try self.parseAttributes(builder.tag, &builder.attributes);
    try self.expectSelfClose(builder.token);

    if (builder.tag.hasMilestoneEnd()) {
        while (try self.parseNode() orelse try self.parseText()) |c| try builder.children.append(c);

        const err = Error.Kind{ .expected_milestone_close_open = builder.token };
        const end = try self.expect(.tag_open, err);
        const end_tag = try self.parseTag(end);
        const expected = self.lexer.view(builder.token)[0 .. self.lexer.view(builder.token).len - 1];
        const actual = self.lexer.view(end)[0 .. self.lexer.view(end).len - 1];
        if (!end_tag.isMilestoneEnd() or !std.mem.eql(u8, expected, actual)) {
            try self.appendErr(end, err);
            return error.UnexpectedMilestoneClose;
        }
        try self.expectSelfClose(end);
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseInline(self: *Parser) !?Element {
    var builder = try self.nodeBuilder(Tag.isInline) orelse return null;
    defer builder.deinit();

    while (try self.parseNode() orelse try self.parseText()) |c| try builder.children.append(c);
    try self.parseAttributes(builder.tag, &builder.attributes);

    self.expectClose(builder.token) catch {};

    return Element{ .node = try builder.toOwned() };
}

fn parseParagraph(self: *Parser) !?Element {
    var builder = try self.nodeBuilder(Tag.isParagraph) orelse return null;
    defer builder.deinit();

    if (builder.tag != .c) { // chapters are just markers
        while (try self.parseMilestone() orelse
            try self.parseInline() orelse
            try self.parseCharacter() orelse
            try self.parseText()) |c| try builder.children.append(c);
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseCharacter(self: *Parser) !?Element {
    var builder = try self.nodeBuilder(Tag.isCharacter) orelse return null;
    defer builder.deinit();

    if (builder.tag != .v) { // verses are just markers
        if (try self.parseText()) |c| try builder.children.append(c);
    }
    // Undocumented but reasonable
    const maybe_close = try self.lexer.peek();
    if (maybe_close.tag == .tag_close) {
        const closing_tag = try self.parseTag(maybe_close);
        if (std.meta.eql(builder.tag, closing_tag)) {
            _ = try self.lexer.next();
        }
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseText(self: *Parser) !?Element {
    const token = try self.lexer.peek();
    if (token.tag != .text) return null;
    _ = try self.lexer.next();

    return Element{ .text = self.lexer.view(token) };
}

fn parseAttributes(self: *Parser, tag: Tag, out: *std.ArrayList(Element.Node.Attribute)) !void {
    const token = try self.lexer.peek();
    if (token.tag != .attribute_start) return;
    _ = try self.lexer.next();

    // https://ubsicap.github.io/usfm/attributes/index.html
    while (true) {
        const id = try self.lexer.peek();
        if (id.tag != .id) break;
        _ = try self.lexer.next();

        const n = try self.lexer.peek();
        switch (n.tag) {
            .@"=" => {
                const key = self.lexer.view(id);
                if (!std.mem.startsWith(u8, key, "x-")) brk: {
                    for (tag.validAttributes()) |k| {
                        if (std.mem.eql(u8, key, k)) break :brk;
                    }
                    try self.appendErr(n, Error.Kind{ .invalid_attribute = key });
                    return error.InvalidAttribute;
                }
                _ = try self.lexer.next();

                const val = try self.expect(.id, Error.Kind.expected_attribute_value);
                try out.append(.{ .key = key, .value = trimQuote(self.lexer.view(val)) });
            },
            else => {
                if (tag.defaultAttribute()) |default_key| {
                    try out.append(.{ .key = default_key, .value = self.lexer.view(id) });
                } else {
                    try self.appendErr(n, Error.Kind{ .no_default_attribute = tag });
                    return error.NoDefaultAttribute;
                }
            },
        }
    }
}

fn parseSpecialText(self: *Parser, builder: *NodeBuilder) !void {
    // special required attributes
    const token = try self.lexer.peek();
    switch (builder.tag) {
        .f, .fe => {
            const caller = self.firstWord(token);
            if (caller.len > 0) {
                try builder.children.append(.{ .text = caller });
            } else {
                try self.appendErr(token, .expected_caller);
            }
        },
        .v, .c => {
            const number = self.firstWord(token);
            if (number.len > 0) {
                try builder.children.append(.{ .text = number });
            } else {
                try self.appendErr(token, .expected_number);
            }
        },
        else => {},
    }
}

fn firstWord(self: *Parser, maybe_text: Token) []const u8 {
    if (maybe_text.tag == .text) {
        const string = self.lexer.view(maybe_text);
        const end = std.mem.indexOfAny(u8, string, whitespace ++ "\\") orelse string.len;
        self.lexer.pos += end;
        try self.lexer.eatSpace();
        return string[0..end];
    }
    return "";
}

fn trimQuote(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\"");
}

const NodeBuilder = struct {
    token: Token,
    tag: Tag,
    allocator: Allocator,
    attributes: Attributes,
    children: Children,

    const Attributes = std.ArrayList(Element.Node.Attribute);
    const Children = std.ArrayList(Element);

    pub fn init(allocator: Allocator, token: Token, tag: Tag) NodeBuilder {
        return NodeBuilder{
            .token = token,
            .tag = tag,
            .allocator = allocator,
            .attributes = Attributes.init(allocator),
            .children = Children.init(allocator),
        };
    }

    pub fn deinit(self: *NodeBuilder) void {
        self.attributes.deinit();
        for (self.children.items) |c| c.deinit(self.allocator);
        self.children.deinit();
    }

    pub fn toOwned(self: *NodeBuilder) !Element.Node {
        return Element.Node{
            .tag = self.tag,
            .attributes = try self.attributes.toOwnedSlice(),
            .children = try self.children.toOwnedSlice(),
        };
    }
};

fn expectElements(usfm: []const u8, comptime expected: []const u8) !void {
    const allocator = testing.allocator;

    var actual = std.ArrayList(u8).init(allocator);
    defer actual.deinit();

    var parser = Parser.init(allocator, usfm);
    defer parser.deinit();

    const doc = try parser.document();
    defer doc.deinit(allocator);

    try doc.root.html(actual.writer());

    try std.testing.expectEqualStrings(expected, actual.items);
}

test "whitespace norm 1" {
    try expectElements(
        \\\p
    ++ whitespace ++ whitespace ++
        \\asdf
    ,
        \\<p> asdf</p>
        \\
    );
}

test "single attribute tag" {
    try expectElements(
        \\\v 1\qs hello |   x-occurences  =   "1" \qs*
    ,
        \\<sup>1</sup><span class="qs">hello </span>
    );
}

test "empty attribute tag" {
    try expectElements(
        \\\v 1\w hello|\w*
    ,
        \\<sup>1</sup>hello
    );
}

test "milestones" {
    try expectElements(
        \\\zaln-s\*\w In \w*side\zaln-e\* there
    ,
        \\In side there
    );
}

test "footnote with inline fqa" {
    try expectElements(
        \\Hello\f +\ft footnote:   \fqa some text\fqa*.\f*
    ,
        \\Hello
    );
}

test "footnote with block fqa" {
    try expectElements(
        \\\f +\fq a\ft b\fqa c\ft d\f*
    , "");
}

test "paragraphs" {
    try expectElements(
        \\\c 1
        \\\p
        \\\v 1 verse1
        \\\p
        \\\v 2 verse2
    ,
        \\<p><sup>1</sup>verse1 </p>
        \\<p><sup>2</sup>verse2</p>
        \\
    );
}

const std = @import("std");
const Tag = @import("./tag.zig").Tag;
const Lexer = @import("./Lexer.zig");
const Element = @import("./element.zig").Element;
const err_mod = @import("./error.zig");

const Allocator = std.mem.Allocator;
const Token = Lexer.Token;
const log = std.log.scoped(.usfm);
const testing = std.testing;
const whitespace = Lexer.whitespace;
const Error = err_mod.Error;
const Errors = err_mod.Errors;
const Parser = @This();
