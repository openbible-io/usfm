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
    try self.errors.list.append(
        self.allocator,
        Error{ .token = token, .kind = kind }
    );
}

fn expect(self: *Parser, tag: Token.Tag, why: Error.Kind) !Token {
    const token = try self.lexer.next();
    if (token.tag == tag) return token;

    try self.appendErr(token, why);
    return error.UnexpectedToken;
}

fn expectClose(self: *Parser, open: Token) !void {
    const close = try self.lexer.next();
    if (close.tag == .tag_close) {
        const open_text = self.lexer.view(open);
        const close_text = self.lexer.view(close);
        if (std.mem.eql(u8, open_text, close_text[0..close_text.len - 1])) return;
    }
    try self.appendErr(close, Error.Kind{ .expected_close = open });
    return error.ExpectedClose;
}

fn expectSelfClose(self: *Parser, for_token: Token) !void {
    const token = try self.lexer.next();
    if (token.tag == .tag_close) {
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
        return error.UnexpectedToken;
    };
}

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

fn nodeBuilder(self: *Parser) !?NodeBuilder {
    const token = try self.lexer.peek();
    if (token.tag != .tag_open) return null;
    const tag = try self.parseTag(token);

    return NodeBuilder.init(self.allocator, token, tag);
}

fn parseMilestone(self: *Parser) !?Element {
    var builder = try self.nodeBuilder() orelse return null;
    defer builder.deinit();
    if (!builder.tag.isMilestoneStart()) return null;
    _ = try self.lexer.next();

    try self.parseAttributes(builder.tag, &builder.attributes);
    try self.expectSelfClose(builder.token);

    if (builder.tag.hasMilestoneEnd()) {
        while (try self.parseNode() orelse try self.parseText()) |c| try builder.children.append(c);

        const err = Error.Kind{ .expected_milestone_close_open = builder.token };
        const end = try self.expect(.tag_open, err);
        const end_tag = try self.parseTag(end);
        const expected = self.lexer.view(builder.token)[0..self.lexer.view(builder.token).len - 1];
        const actual = self.lexer.view(end)[0..self.lexer.view(end).len - 1];
        if (!end_tag.isMilestoneEnd() or !std.mem.eql(u8, expected, actual)) {
            try self.appendErr(end, err);
            return error.UnexpectedMilestoneClose;
        }
        try self.expectSelfClose(end);
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

    try self.expectClose(builder.token);

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

    return Element{ .text =  self.lexer.view(token) };
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
            }
        }
    }
}

fn parseTextAttributes(self: *Parser, tag: Tag, out: *std.ArrayList(Element.Node.Attribute)) !void {
    // special required attributes
    switch (tag) {
        .f, .fe, .v, .c => {
            const text = try self.expect(.text, switch (tag) {
                .f, .fe => Error.Kind.expected_caller,
                .v, .c => Error.Kind.expected_number,
                else => unreachable,
            });
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
    defer parser.deinit();
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
const Element = @import("./element.zig").Element;

const Allocator = std.mem.Allocator;
const Token = Lexer.Token;
const log = std.log.scoped(.usfm);
const testing = std.testing;
const whitespace = Lexer.whitespace;
const Parser = @This();

pub const ErrorContext = struct {
    buffer_name: []const u8,
    buffer: []const u8,
    stderr: std.fs.File,

    pub fn print(self: ErrorContext, err: Error) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);

        const line_start = lineStart(self.buffer, err.token);
        try self.printLoc(line_start, err.token);

        tty_config.setColor(w, .bold) catch {};
        tty_config.setColor(w, .red) catch {};
        try w.writeAll("error: ");
        tty_config.setColor(w, .reset) catch {};
        switch (err.kind) {
            .invalid_tag => try w.writeAll("invalid tag"),
            .invalid_root => try w.writeAll("invalid root element"),
            .invalid_attribute => |a| try w.print("invalid attribute \"{s}\"", .{ a }),
            .expected_milestone_close_open => try w.writeAll("expected milestone end tag"),
            .expected_close => try w.writeAll("expected closing tag"),
            .expected_self_close => try w.writeAll("expected self-closing tag"),
            .expected_attribute_value => try w.writeAll("expected attribute value"),
            .expected_caller => try w.writeAll("expected caller"),
            .expected_number => try w.writeAll("expected number"),
            .no_default_attribute => |t| try w.print("{s} has no default attributes", .{ @tagName(t) }),
        }
        try self.printContext(line_start, err.token);

        switch (err.kind) {
            inline .expected_milestone_close_open,
            .expected_close,
            .expected_self_close => |t| {
                try w.writeByte('\n');
                const line_start2 = lineStart(self.buffer, t);
                try self.printLoc(line_start2, t);
                tty_config.setColor(w, .blue) catch {};
                try w.writeAll("note: ");
                tty_config.setColor(w, .reset) catch {};
                try w.writeAll("opening tag here");
                try self.printContext(line_start2, t);
            },
            else => {},
        }
        tty_config.setColor(w, .reset) catch {};
    }

    fn lineStart(buffer: []const u8, token: Token) usize {
        var res = @min(token.start, buffer.len - 1);
        while (res > 0 and buffer[res] != '\n') res -= 1;

        return res + 1;
    }

    fn printLoc(self: ErrorContext, line_start: usize, token: Token) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);
        tty_config.setColor(w, .reset) catch {};
        tty_config.setColor(w, .bold) catch {};
        const column = token.start - line_start;

        var token_line: usize = 1;
        for (self.buffer[0..token.start]) |c| {
            if (c == '\n') token_line += 1;
        }
        try w.print("{s}:{d}:{d} ", .{ self.buffer_name, token_line, column });
    }

    fn printContext(self: ErrorContext, line_start: usize, token: Token) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);

        const line_end = if (std.mem.indexOfScalarPos(u8, self.buffer, token.end, '\n')) |n| n else self.buffer.len;
        try w.writeByte('\n');
        try w.print("{s}", .{ self.buffer[line_start..token.start] });
        if (token.end != token.start) {
            tty_config.setColor(w, .green) catch {};
            try w.print("{s}", .{ self.buffer[token.start..token.end] });
            tty_config.setColor(w, .reset) catch {};
            try w.print("{s}", .{ self.buffer[token.end..line_end] });
        }
        try w.writeByte('\n');
    }
};

pub const Error = struct {
    token: Token,
    kind: Kind,

    const Kind = union(enum) {
        invalid_tag,
        invalid_root,
        invalid_attribute: []const u8,
        expected_attribute_value,
        expected_milestone_close_open: Token,
        expected_close: Token,
        expected_self_close: Token,
        expected_caller,
        expected_number,
        no_default_attribute: Tag,
    };
};
pub const Errors = struct {
    list: std.ArrayListUnmanaged(Error) = .{},

    pub fn deinit(self: *Errors, allocator: Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn print(self: Errors, ctx: ErrorContext) !void {
        for (self.list.items, 0..) |err, i| {
            try ctx.print(err);
            if (i != self.list.items.len) try ctx.stderr.writer().writeByte('\n');
        }
    }
};

