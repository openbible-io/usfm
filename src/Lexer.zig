allocator: Allocator,
buffer: []const u8,
pos: usize = 0,
in_attribute: bool = false,

pub fn init(allocator: Allocator, buffer: []const u8) Lexer {
    return .{ .allocator = allocator, .buffer = buffer };
}

fn readByte(self: *Lexer) !u8 {
    if (self.pos >= self.buffer.len) return error.EndOfStream;
    defer self.pos += 1;
    return self.buffer[self.pos];
}

fn readUntilDelimiters(self: *Lexer, comptime delimiters: []const u8) !usize {
    var len: usize = 0;
    while (true) {
        const byte = self.readByte() catch |err| switch (err) {
            error.EndOfStream => return len + 1,
            else => |e| return e,
        };
        len += 1;
        inline for (delimiters) |d| {
            if (byte == d) {
                if (byte == '*') {
                    // Consume *s for ending tags
                    len += 1;
                } else {
                    self.pos -= 1;
                }
                return len;
            }
        }
    }
}

fn eatSpaceN(self: *Lexer, n: usize) !void {
    var n_eaten: usize = 0;
    while (n_eaten <= n) {
        const byte = self.readByte() catch return;
        if (std.mem.indexOfScalar(u8, whitespace, byte)) |_| {
            n_eaten += 1;
        } else {
            self.pos -= 1;
            return;
        }
    }
}

pub fn eatSpace(self: *Lexer) !void {
    try self.eatSpaceN(std.math.maxInt(usize));
}

pub fn next(self: *Lexer) !Token {
    var res = Token{
        .start = self.pos,
        .end = self.pos + 1,
        .tag = .eof,
    };

    const next_c = self.readByte() catch |err| switch (err) {
        error.EndOfStream => {
            res.end = self.pos;
            return res;
        },
        else => return err,
    };
    if (next_c == '\\') {
        self.in_attribute = false;
        _ = try self.readUntilDelimiters(whitespace ++ "*\\");
        if (self.buffer[self.pos - 1] != '*') {
            res.end = self.pos;
            res.tag = .tag_open;
            try self.eatSpaceN(1);
        } else { // End tag like `\w*` or '\*';
            res.end = self.pos;
            res.tag = .tag_close;
        }
    } else if (next_c == '|') {
        self.in_attribute = true;
        res.tag = .attribute_start;
        try self.eatSpace();
    } else if (self.in_attribute) {
        if (next_c == '=') {
            res.tag = .@"=";
            try self.eatSpace();
            return res;
        } else if (next_c == '"') {
            var last_backslash = false;
            while (true) {
                const c = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                if (c == '"' and !last_backslash) {
                    res.start += 1;
                    res.end = self.pos - 1;
                    res.tag = .id;
                    break;
                }
                last_backslash = c == '\\';
            }
            try self.eatSpace();
        } else {
            _ = try self.readUntilDelimiters(whitespace ++ "=\\");
            res.end = self.pos;
            res.tag = .id;
            try self.eatSpace();
        }
    } else {
        self.in_attribute = false;
        _ = try self.readUntilDelimiters("|\\");
        res.end = self.pos;
        res.tag = .text;
    }

    return res;
}

pub fn peek(self: *Lexer) !Token {
    const pos = self.pos;
    const res = try self.next();
    self.pos = pos;
    return res;
}

pub fn view(self: Lexer, token: Token) []const u8 {
    return self.buffer[token.start..token.end];
}

const Expected = struct {
    tag: Token.Tag,
    text: ?[]const u8 = null,
};
fn expectTokens(usfm: []const u8, expected: []const Expected) !void {
    const allocator = testing.allocator;

    var actual = std.ArrayList(Token).init(allocator);
    defer actual.deinit();

    var lex = Lexer.init(allocator, usfm);
    while (true) {
        const t = try lex.next();
        if (t.tag == .eof) break;
        try actual.append(t);
    }

    if (expected.len != actual.items.len) {
        std.debug.print("expected {d} tokens, got {d}\n", .{ expected.len, actual.items.len });
        for (actual.items, 0..) |a, i| {
            std.debug.print("{d} {} \"{s}\"\n", .{ i, a.tag, lex.view(a) });
        }
        return error.LenMismatch;
    }

    for (expected, actual.items) |e, a| {
        try std.testing.expectEqual(e.tag, a.tag);
        if (e.text) |t| try std.testing.expectEqualStrings(t, lex.view(a));
    }
}

test "single simple tag" {
    try expectTokens(
        \\\id GEN EN_ULT en_English_ltr
    ,
        &[_]Expected{
            .{ .tag = .tag_open, .text = "\\id" },
            .{ .tag = .text, .text = "GEN EN_ULT en_English_ltr" },
        },
    );
}

test "two simple tags" {
    try expectTokens(
        \\\id GEN EN_ULT en_English_ltr
        \\\usfm 3.0
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "GEN EN_ULT en_English_ltr\n" },
            .{ .tag = .tag_open },
            .{ .tag = .text },
        },
    );
}

test "single attribute tag" {
    try expectTokens(
        \\\word hello |   x-occurences  =   "1"\word*
    ,
        &[_]Expected{
            .{ .tag = .tag_open, .text = "\\word" },
            .{ .tag = .text, .text = "hello " },
            .{ .tag = .attribute_start, .text = "|" },
            .{ .tag = .id, .text = "x-occurences" },
            .{ .tag = .@"=", .text = "=" },
            .{ .tag = .id, .text = "1" },
            .{ .tag = .tag_close, .text = "\\word*" },
        },
    );
}

test "empty attribute tag" {
    try expectTokens(
        \\\word hello |\word*
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .text },
            .{ .tag = .attribute_start },
            .{ .tag = .tag_close },
        },
    );
}

test "attributes with spaces" {
    try expectTokens(
        \\\zaln-s |x-lemma="a b" x-abc="123" \*\zaln-e\*
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .attribute_start },
            .{ .tag = .id, .text = "x-lemma" },
            .{ .tag = .@"=" },
            .{ .tag = .id, .text = "a b" },
            .{ .tag = .id, .text = "x-abc" },
            .{ .tag = .@"=" },
            .{ .tag = .id, .text = "123" },
            .{ .tag = .tag_close },
            .{ .tag = .tag_open },
            .{ .tag = .tag_close },
        },
    );
}

test "milestones" {
    try expectTokens(
        \\\v 1 \zaln-s\*\w In\w*\zaln-e\*there
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .text },
            .{ .tag = .tag_open },
            .{ .tag = .tag_close },
            .{ .tag = .tag_open },
            .{ .tag = .text },
            .{ .tag = .tag_close },
            .{ .tag = .tag_open },
            .{ .tag = .tag_close },
            .{ .tag = .text },
        },
    );
}

test "self closing tag" {
    try expectTokens(
        \\\zaln-s hello\*
    ,
        &[_]Expected{
            .{ .tag = .tag_open, .text = "\\zaln-s" },
            .{ .tag = .text, .text = "hello" },
            .{ .tag = .tag_close, .text = "\\*" },
        },
    );
}

test "line breaks" {
    try expectTokens(
        \\\v 1 \w In\w*
        \\\w the\w* 012
        \\\w beginning\w*.
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "1 " },
            .{
                .tag = .tag_open,
            },
            .{ .tag = .text, .text = "In" },
            .{ .tag = .tag_close },
            .{ .tag = .text, .text = "\n" },
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "the" },
            .{ .tag = .tag_close },
            .{ .tag = .text, .text = " 012\n" },
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "beginning" },
            .{ .tag = .tag_close },
            .{ .tag = .text, .text = "." },
        },
    );
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.usfm);
pub const Token = struct {
    pub const Tag = enum {
        tag_open,
        tag_close,
        text,
        attribute_start,
        id,
        @"=",
        eof,
    };
    tag: Token.Tag,
    start: usize,
    end: usize,
};
pub const whitespace = " \t\n";
const Lexer = @This();
