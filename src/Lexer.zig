allocator: Allocator,
buffer: []const u8,
pos: usize = 0,
in_attribute: bool = false,

pub fn init(allocator: Allocator, buffer: []const u8) Lexer {
    return .{ .allocator = allocator, .buffer = buffer };
}

fn readByte(self: *Lexer) !u8 {
    if (self.pos >= self.buffer.len) return error.EndOfStream;
    self.pos += 1;
    return self.buffer[self.pos - 1];
}

fn readUntilDelimiters(self: *Lexer, comptime delimiters: []const u8) !usize {
    var len: usize = 0;
    while (true) {
        const c = self.readByte() catch |err| switch (err) {
            error.EndOfStream => return len + 1,
            else => |e| return e,
        };
        len += 1;
        inline for (delimiters) |d| {
            if (c == d) {
                if (c == '*') {
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

pub fn next(self: *Lexer) !?Token {
    try self.eatSpace();
    const start = self.pos;
    const next_c = self.readByte() catch |err| {
        return if (err == error.EndOfStream) null else err;
    };
    if (next_c == '\\') {
        self.in_attribute = false;
        _ = try self.readUntilDelimiters(whitespace ++ "*\\");
        if (self.buffer[self.pos - 1] != '*') {
            const end = self.pos;
            return .{ .start = start, .end = end, .tag = .tag_open };
        } else { // End tag like `\w*` or '\*';
            return .{ .start = start, .end = self.pos, .tag = .tag_close };
        }
    } else if (next_c == '|') {
        self.in_attribute = true;
        return .{ .start = start, .end = start + 1, .tag = .attribute_start };
    } else if (self.in_attribute) {
        if (next_c == '=') {
            return .{ .start = start, .end = start + 1, .tag = .@"=" };
        } else if (next_c == '"') {
            var last_backslash = false;
            while (true) {
                const c = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                if (c == '"' and !last_backslash) {
                    const end = self.pos;
                    return .{ .start = start + 1, .end = end - 1, .tag = .id };
                }
                last_backslash = c == '\\';
            }
        }
        _ = try self.readUntilDelimiters(&[_]u8{ ' ', '=', '\\' });
        const end = self.pos;
        return .{ .start = start, .end = end, .tag = .id };
    } else {
        self.in_attribute = false;
        _ = try self.readUntilDelimiters(&[_]u8{ '|', '\\' });
        var end = self.pos - 1;
        while (std.mem.indexOfScalar(u8, whitespace, self.buffer[end])) |_| end -= 1;
        return .{ .start = start, .end = end + 1, .tag = .text };
    }
}

pub fn peek(self: *Lexer) !?Token {
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
    while (try lex.next()) |t| try actual.append(t);

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
            .{ .tag = .tag_open, .text= "\\id" },
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
            .{  .tag = .text, .text = "GEN EN_ULT en_English_ltr" },
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
            .{ .tag = .text, .text = "hello" },
            .{  .tag = .attribute_start, .text = "|" },
            .{  .tag = .id, .text = "x-occurences" },
            .{  .tag = .@"=", .text = "=" },
            .{  .tag = .id, .text = "1" },
            .{  .tag = .tag_close, .text = "\\word*" },
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
        \\\zaln-s |x-lemma="a b"\*\zaln-e\*
        ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .attribute_start },
            .{ .tag = .id, .text = "x-lemma" },
            .{ .tag = .@"=" },
            .{ .tag = .id, .text = "a b" },
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
            .{  .tag = .text, .text = "hello" },
            .{ .tag = .tag_close, .text = "\\*" },
        },
    );
}

test "line breaks" {
    try expectTokens(
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
    ,
        &[_]Expected{
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "1" },
            .{ .tag = .tag_open, },
            .{ .tag = .text, .text = "In" },
            .{ .tag = .tag_close },
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "the" },
            .{ .tag = .tag_close },
            .{ .tag = .tag_open },
            .{ .tag = .text, .text = "beginning" },
            .{ .tag = .tag_close },
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
    };
    tag: Token.Tag,
    start: usize,
    end: usize,
};
pub const whitespace = " \t\n";
const Lexer = @This();
