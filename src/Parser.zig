allocator: Allocator,
lexer: Lexer,

pub fn init(allocator: Allocator, buffer: []const u8) Parser {
    return Parser{
        .allocator = allocator,
        .lexer = Lexer.init(allocator, buffer),
    };
}

fn printErr(self: *Parser, token: Token, comptime fmt: []const u8, args: anytype) void {
    var lineno: usize = 0;
    var lineno_pos: usize = 0;
    for (0..token.start) |i| {
        if (self.lexer.buffer[i] == '\n') {
            lineno += 1;
            lineno_pos = i;
        }
    }
    const charno = token.start - lineno_pos;
    const context = self.lexer.buffer[token.start..token.end];

    const args2 = args ++ .{ lineno + 1, charno, context };
    log.err(fmt ++ " at {d}:{d}\n{s}", args2);
}

fn expect(self: *Parser, tag: Token.Tag) !Token {
    if (try self.lexer.next()) |actual| {
        if (actual.tag == tag) return actual;
        self.printErr(actual, "expected {s}, got {s}", .{ @tagName(tag), @tagName(actual.tag) });
    }
    log.err("expected {s}, got EOF", .{ @tagName(tag) });
    return error.UnexpectedToken;
}

fn maybe(self: *Parser, tag: Token.Tag) !?Token {
    if (try self.lexer.peek()) |actual| {
        if (actual.tag == tag) return actual;
    }
    return null;
}

fn parseTag(self: *Parser, token: Token) !Tag {
    const tag_text = self.lexer.view(token);
    return Tag.init(tag_text) catch |e| {
        self.printErr(token, "invalid tag {s}", .{tag_text});
        return e;
    };
}

// Caller owns returned element and should call `.deinit`
pub fn next(self: *Parser) !?Element {
    const peek = try self.lexer.peek();
    if (peek == null) return null;

    return try self.parseNode() orelse try self.parseText() orelse {
        self.printErr(peek.?, "expected opening tag or text", .{});
        return error.UnexpectedToken;
    };
}

fn parseNode(self: *Parser) Error!?Element {
    return try self.parseMilestone() orelse
        try self.parseInline() orelse
        try self.parseParagraph() orelse
        try self.parseCharacter();
}

fn nodeBuilder(self: *Parser) !?NodeBuilder {
    const token = try self.lexer.peek() orelse return null;
    if (token.tag != .tag_open) return null;
    const tag = try self.parseTag(token);

    return NodeBuilder.init( self.allocator, token, tag);
}

const Error = Allocator.Error || error{
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
};

fn parseMilestone(self: *Parser) !?Element {
    var builder = try self.nodeBuilder() orelse return null;
    defer builder.deinit();
    if (!builder.tag.isMilestoneStart()) return null;
    _ = try self.lexer.next();

    try self.parseAttributes(builder.tag, &builder.attributes);
    try self.expectSelfClose();

    if (builder.tag.hasMilestoneEnd()) {
        while (try self.parseNode() orelse try self.parseText()) |c| try builder.children.append(c);

        const end = try self.expect(.tag_open);
        const end_tag = try self.parseTag(end);
        const expected = self.lexer.view(builder.token)[0..self.lexer.view(builder.token).len - 1];
        const actual = self.lexer.view(end)[0..self.lexer.view(end).len - 1];
        if (!end_tag.isMilestoneEnd() or !std.mem.eql(u8, expected, actual)) {
            self.printErr(end, "expected milestone close {s}e", .{ expected });
            return error.UnexpectedMilestoneClose;
        }
        try self.expectSelfClose();
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseInline(self: *Parser) !?Element {
    var builder = try self.nodeBuilder() orelse return null;
    defer builder.deinit();
    if (!builder.tag.isInline()) return null;
    _ = try self.lexer.next();
    try self.parseTextAttributes(builder.tag, &builder.attributes);

    while (try self.parseNode() orelse try self.parseText()) |c| try builder.children.append(c);
    try self.parseAttributes(builder.tag, &builder.attributes);

    const close = try self.expect(.tag_close);
    const closing_tag = try self.parseTag(close);
    if (!std.meta.eql(builder.tag, closing_tag)) {
        self.printErr(
            close,
            "closing tag {s} does not match opening tag {s}",
            .{ self.lexer.view(close), self.lexer.view(builder.token) },
        );
        return error.InvalidClosingTag;
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseParagraph(self: *Parser) !?Element {
    var builder = try self.nodeBuilder() orelse return null;
    defer builder.deinit();
    if (!builder.tag.isParagraph()) return null;
    _ = try self.lexer.next();
    try self.parseTextAttributes(builder.tag, &builder.attributes);

    while (
        try self.parseMilestone() orelse
        try self.parseInline() orelse
        try self.parseCharacter() orelse
        try self.parseText()
    ) |c| try builder.children.append(c);

    return Element{ .node = try builder.toOwned() };
}

fn parseCharacter(self: *Parser) !?Element {
    var builder = try self.nodeBuilder() orelse return null;
    defer builder.deinit();
    if (!builder.tag.isCharacter()) return null;
    _ = try self.lexer.next();
    try self.parseTextAttributes(builder.tag, &builder.attributes);

    if (try self.parseText()) |c| try builder.children.append(c);
    // Undocumented: may include closing tag
    const maybe_close = try self.lexer.peek();
    if (maybe_close) |mc| {
        if (mc.tag == .tag_close) {
            const closing_tag = try self.parseTag(mc);
            if (std.meta.eql(builder.tag, closing_tag)) {
                _ = try self.lexer.next();
            }
        }
    }

    return Element{ .node = try builder.toOwned() };
}

fn parseText(self: *Parser) !?Element {
    const token = try self.lexer.peek() orelse return null;
    if (token.tag != .text) return null;
    _ = try self.lexer.next();

    return .{ .text =  self.lexer.view(token) };
}

fn parseAttributes(self: *Parser, tag: Tag, out: *std.ArrayList(Element.Node.Attribute)) !void {
    const token = try self.lexer.peek() orelse return;
    if (token.tag != .attribute_start) return;
    _ = try self.lexer.next();

    // https://ubsicap.github.io/usfm/attributes/index.html
    while (try self.lexer.peek()) |maybe_id| {
        if (maybe_id.tag != .id) return;
        const id = (try self.lexer.next()).?;

        if (try self.lexer.peek()) |n| switch (n.tag) {
            .@"=" => {
                const key = self.lexer.view(id);
                if (!std.mem.startsWith(u8, key, "x-")) brk: {
                    for (tag.validAttributes()) |k| {
                        if (std.mem.eql(u8, key, k)) break :brk;
                    }
                    self.printErr( n, "invalid attribute \"{s}\"", .{ key });
                    return error.InvalidAttribute;
                }

                _ = try self.lexer.next();
                const val = try self.expect(.id);
                try out.append(.{ .key = key, .value = trimQuote(self.lexer.view(val)) });
            },
            else => {
                if (tag.defaultAttribute()) |default_key| {
                    try out.append(.{ .key = default_key, .value = self.lexer.view(id) });
                } else {
                    self.printErr(n, "no default attribute for tag {s}", .{ @tagName(tag) });
                    return error.NoDefaultAttribute;
                }
            }
        };
    }
}

fn parseTextAttributes(self: *Parser, tag: Tag, out: *std.ArrayList(Element.Node.Attribute)) !void {
    // special required attributes
    switch (tag) {
        .f, .fe, .v, .c => {
            const text = try self.expect(.text);
            const string = self.lexer.view(text);
            const end = std.mem.indexOfAny(u8, string, whitespace) orelse string.len;
            self.lexer.pos = text.start + end;
            const key = switch (tag) {
                .f, .fe => "caller",
                .v, .c => "n",
                else => unreachable,
            };
            try out.append(.{ .key = key, .value = string[0..end] });
        },
        else => {},
    }
}

fn trimQuote(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\"");
}

fn expectSelfClose(self: *Parser) !void {
    const close = try self.expect(.tag_close);
    if (!std.mem.eql(u8, self.lexer.view(close), "\\*")) {
        self.printErr(close, "expected self-closing tag", .{});
        return error.ExpectedSelfClose;
    }
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
        return Element.Node {
            .tag = self.tag,
            .attributes = try self.attributes.toOwnedSlice(),
            .children = try self.children.toOwnedSlice(),
        };
    }
};

fn expectElements(usfm: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;

    var actual = std.ArrayList(u8).init(allocator);
    defer actual.deinit();

    var parser = Parser.init(allocator, usfm);
    while (try parser.next()) |e| {
        defer e.deinit(allocator);
        try e.html(actual.writer());
        try actual.writer().writeByte('\n');
    }

    try std.testing.expectEqualStrings(expected, actual.items);
}

test "single simple tag" {
    try expectElements(
        \\\id GEN EN_ULT en_English_ltr
        ,
        \\<id>
        \\  GEN EN_ULT en_English_ltr
        \\</id>
        \\
    );
}

test "two simple tags" {
    try expectElements(
        \\\id GEN EN_ULT en_English_ltr
        \\\usfm 3.0
        ,
        \\<id>
        \\  GEN EN_ULT en_English_ltr
        \\</id>
        \\<usfm>
        \\  3.0
        \\</usfm>
        \\
    );
}

test "single attribute tag" {
    try expectElements(
        \\\v 1 \w hello |   x-occurences  =   "1" \w*
        ,
        \\<v n="1"></v>
        \\<w x-occurences="1">
        \\  hello
        \\</w>
        \\
    );
}

test "empty attribute tag" {
    try expectElements(
        \\\v 1 \w hello |\w*
        ,
        \\<v n="1"></v>
        \\<w>
        \\  hello
        \\</w>
        \\
    );
}

test "milestones" {
    try expectElements(
        \\\v 1 \zaln-s\*\w In\w*\zaln-e\*there
        ,
        \\<v n="1"></v>
        \\<z-s>
        \\  <w>
        \\    In
        \\  </w>
        \\</z-s>
        \\there
        \\
    );
}

test "line breaks" {
    try expectElements(
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
        \\textnode
    ,
        \\<v n="1"></v>
        \\<w>
        \\  In
        \\</w>
        \\<w>
        \\  the
        \\</w>
        \\<w>
        \\  beginning
        \\</w>
        \\textnode
        \\
    );
}

test "footnote with inline fqa" {
    try expectElements(
        \\\v 2
        \\\f + \ft footnote: \fqa some text\fqa*.\f*
    ,
        \\<v n="2"></v>
        \\<f caller="+">
        \\  <ft>
        \\    footnote:
        \\  </ft>
        \\  <fqa>
        \\    some text
        \\  </fqa>
        \\  .
        \\</f>
        \\
    );
}

test "footnote with block fqa" {
    try expectElements(
        \\\v 1 \f + \fq until they had crossed over \ft or perhaps \fqa until we had crossed over \ft (Hebrew Ketiv).\f*
    ,
        \\<v n="1"></v>
        \\<f caller="+">
        \\  <fq>
        \\    until they had crossed over
        \\  </fq>
        \\  <ft>
        \\    or perhaps
        \\  </ft>
        \\  <fqa>
        \\    until we had crossed over
        \\  </fqa>
        \\  <ft>
        \\    (Hebrew Ketiv).
        \\  </ft>
        \\</f>
        \\
    );
}

test "header" {
    try expectElements(
        \\\mt Genesis
        \\
        \\\ts\*
        \\\c 1
        \\\ts\*
        \\\c 1
    ,
        \\<mt>
        \\  Genesis
        \\  <ts></ts>
        \\</mt>
        \\<c n="1">
        \\  <ts></ts>
       \\</c>
        \\<c n="1"></c>
        \\
    );
}

test "chapters" {
    try expectElements(
        \\\c 1
        \\\v 1 verse1
        \\\v 2 verse2
        \\\c 2
        \\\v 1 asdf
        \\\v 2 hjkl
        ,
        \\<c n="1">
        \\  <v n="1">
        \\    verse1
        \\  </v>
        \\  <v n="2">
        \\    verse2
        \\  </v>
        \\</c>
        \\<c n="2">
        \\  <v n="1">
        \\    asdf
        \\  </v>
        \\  <v n="2">
        \\    hjkl
        \\  </v>
        \\</c>
        \\
    );
}

test "hanging text" {
    try expectElements(
        \\\ip Hello
        \\\bk inline tag\bk* hanging text.
    ,
        \\<ip>
        \\  Hello
        \\  <bk>
       \\    inline tag
        \\  </bk>
        \\  hanging text.
        \\</ip>
        \\
    );
}

test "paragraphs" {
    try expectElements(
        \\\p
        \\\v 1 verse1
        \\\p
        \\\v 2 verse2
    ,
        \\<p>
        \\  <v n="1">
        \\    verse1
        \\  </v>
        \\</p>
        \\<p>
        \\  <v n="2">
        \\    verse2
        \\  </v>
        \\</p>
        \\
    );
}

const std = @import("std");
const Tag = @import("./tag.zig").Tag;
const Lexer = @import("./Lexer.zig");

const Allocator = std.mem.Allocator;
const Token = Lexer.Token;
const log = std.log.scoped(.usfm);
const testing = std.testing;
const whitespace = Lexer.whitespace;
const Parser = @This();

pub const Element = union(enum) {
    node: Node,
    text: []const u8,

    const tab = "  ";
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

        fn html2(self: Self, writer: anytype, depth: usize) @TypeOf(writer).Error!void {
            for (0..depth) |_| try writer.writeAll(tab);
            try writer.print("<{s}", .{@tagName(self.tag)});
            for (self.attributes) |a| try writer.print(" {s}=\"{s}\"", .{ a.key, a.value });
            try writer.writeByte('>');
            for (self.children) |c| {
                try writer.writeByte('\n');
                try c.html2(writer, depth + 1);
            }
            if (self.children.len > 0) {
                try writer.writeByte('\n');
                for (0..depth) |_| try writer.writeAll(tab);
            }
            try writer.print("</{s}>", .{@tagName(self.tag)});
        }

        pub fn html(self: Self, writer: anytype) !void {
            try self.html2(writer, 0);
        }
    };

    pub fn deinit(self: Element, allocator: std.mem.Allocator) void {
        switch (self) {
            .node => |n| n.deinit(allocator),
            .text => {},
        }
    }

    pub fn html2(self: Element, writer: anytype, depth: usize) !void {
        return switch (self) {
            .node => |n| try n.html2(writer, depth),
            .text => |t| {
                for (0..depth) |_| try writer.writeAll(tab);
                const trimmed = std.mem.trim(u8, t, whitespace);
                if (trimmed.len != t.len) {
                    try writer.print("\"{s}\"", .{ t });
                } else {
                    try writer.writeAll(t);
                }
            },
        };
    }

    pub fn html(self: Element, writer: anytype) !void {
        return self.html2(writer, 0);
    }
};
