const std = @import("std");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const Token = types.Token;
const log = types.log;

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n' => true,
        else => false,
    };
}

pub const Lexer = struct {
    const Self = @This();
    const Tokens = std.ArrayList([]const u8);

    allocator: Allocator,
    buffer: []const u8,
    pos: usize = 0,

    pub fn init(allocator: Allocator, buffer: []const u8) Lexer {
        return .{ .allocator = allocator, .buffer = buffer };
    }

    fn readByte(self: *Self) !u8 {
        if (self.pos >= self.buffer.len) return error.EndOfStream;
        self.pos += 1;
        return self.buffer[self.pos - 1];
    }

    fn readUntilDelimiters(self: *Self, comptime delimiters: []const u8) !usize {
        var len: usize = 0;
        while (true) {
            const c = self.readByte() catch |err| {
                if (err == error.EndOfStream) return len + 1;
                return err;
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

    fn eatSpaceN(self: *Self, n: usize) !void {
        var n_eaten: usize = 0;
        while (n_eaten <= n) {
            switch (self.readByte() catch return) {
                ' ', '\t', '\n' => n_eaten += 1,
                else => break,
            }
        }
        // Spit back out last byte.
        self.pos -= 1;
    }

    pub fn eatSpace(self: *Self) !void {
        try self.eatSpaceN(1_000_000);
    }

    pub fn next(self: *Self) !?Token {
        const start = self.pos;
        const next_c = self.readByte() catch |err| {
            return if (err == error.EndOfStream) null else err;
        };
        if (next_c == '\\') {
            _ = try self.readUntilDelimiters(&[_]u8{ '\n', '\t', ' ', '*', '\\' });
            if (self.buffer[self.pos - 1] != '*') {
                try self.eatSpaceN(1);
                return .{ .start = start, .end = self.pos - 1, .tag = .tag_open };
            } else { // End tag like `\w*` or '\*';
                return .{ .start = start, .end = self.pos, .tag = .tag_close };
            }
        } else if (next_c == '|') {
            try self.eatSpace();
            _ = try self.readUntilDelimiters(&[_]u8{ '*', '\\' });
            return .{ .start = start + 1, .end = self.pos, .tag = .attributes };
        }
        _ = try self.readUntilDelimiters(&[_]u8{ '|', '\\' });

        return .{ .start = start, .end = self.pos, .tag = .text };
    }

    pub fn peek(self: *Self) !?Token {
        const pos = self.pos;
        const res = try self.next();
        self.pos = pos;
        return res;
    }

    pub fn view(self: Self, token: Token) []const u8 {
        return self.buffer[token.start..token.end];
    }
};

fn expectTokens(usfm: []const u8, expected: []const Token) !void {
    const allocator = testing.allocator;

    var actual = std.ArrayList(Token).init(allocator);
    defer actual.deinit();

    var lex = Lexer.init(allocator, usfm);
    while (try lex.next()) |t| try actual.append(t);

    try std.testing.expectEqualSlices(Token, expected, actual.items);
}

test "single simple tag" {
    try expectTokens(
        "\\id GEN EN_ULT en_English_ltr",
        &[_]Token{
            .{ .start = 0, .end = 3, .tag = .tag_open },
            .{ .start = 4, .end = 29, .tag = .text },
        },
    );
}

test "two simple tags" {
    try expectTokens(
        \\\id GEN EN_ULT en_English_ltr
        \\\usfm 3.0
    ,
        &[_]Token{
            .{ .start = 0, .end = 3, .tag = .tag_open },
            .{ .start = 4, .end = 30, .tag = .text },
            .{ .start = 30, .end = 35, .tag = .tag_open },
            .{ .start = 36, .end = 39, .tag = .text },
        },
    );
}

test "single attribute tag" {
    try expectTokens(
        \\\word hello |   x-occurences  =   "1" \word*
    ,
        &[_]Token{
            .{ .start = 0, .end = 5, .tag = .tag_open },
            .{ .start = 6, .end = 12, .tag = .text },
            .{ .start = 13, .end = 38, .tag = .attributes },
            .{ .start = 38, .end = 44, .tag = .tag_close },
        },
    );
}

test "empty attribute tag" {
    try expectTokens(
        \\\word hello |\word*
    ,
        &[_]Token{
            .{ .start = 0, .end = 5, .tag = .tag_open },
            .{ .start = 6, .end = 12, .tag = .text },
            .{ .start = 13, .end = 13, .tag = .attributes },
            .{ .start = 13, .end = 19, .tag = .tag_close },
        },
    );
}

test "self closing tag" {
    try expectTokens(
        \\\zaln-s hello\*
    ,
        &[_]Token{
            .{ .start = 0, .end = 7, .tag = .tag_open },
            .{ .start = 8, .end = 13, .tag = .text },
            .{ .start = 13, .end = 15, .tag = .tag_close },
        },
    );
}

test "line breaks" {
    try expectTokens(
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
    ,
        &[_]Token{
            .{ .tag = .tag_open, .start = 0, .end = 2 },
            .{ .tag = .text, .start = 3, .end = 5 },
            .{ .tag = .tag_open, .start = 5, .end = 7 },
            .{ .tag = .text, .start = 8, .end = 10 },
            .{ .tag = .tag_close, .start = 10, .end = 13 },
            .{ .tag = .text, .start = 13, .end = 14 },
            .{ .tag = .tag_open, .start = 14, .end = 16 },
            .{ .tag = .text, .start = 17, .end = 20 },
            .{ .tag = .tag_close, .start = 20, .end = 23 },
            .{ .tag = .text, .start = 23, .end = 24 },
            .{ .tag = .tag_open, .start = 24, .end = 26 },
            .{ .tag = .text, .start = 27, .end = 36 },
            .{ .tag = .tag_close, .start = 36, .end = 39 },
        },
    );
}
