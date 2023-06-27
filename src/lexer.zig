const std = @import("std");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const TagType = types.TagType;
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
    const TokenIds = std.StringHashMap(TagType);
    const Tokens = std.ArrayList([]const u8);

    allocator: Allocator,
    buffer: []const u8,
    pos: usize,
    tokens: Tokens,
    token_ids: TokenIds,
    in_attribute: bool,

    pub fn init(allocator: Allocator, buffer: []const u8) !Self {
        var res = Self{
            .allocator = allocator,
            .buffer = buffer,
            .pos = 0,
            .tokens = try Tokens.initCapacity(allocator, 64),
            .token_ids = TokenIds.init(allocator),
            .in_attribute = false,
        };
        // Reserve 0 for self-closing tags
        try res.tokens.append("");
        try res.token_ids.put("", 0);
        return res;
    }

    pub fn deinit(self: *Self) void {
        for (self.tokens.items) |t| if (t.len > 0) self.allocator.free(t);
        self.tokens.deinit();
        self.token_ids.deinit();
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

    fn getOrPut(self: *Self, key: []const u8, val: TagType) !TagType {
        const maybe_id = self.token_ids.get(key);
        if (maybe_id) |id| return id;

        const copy = try self.allocator.alloc(u8, key.len);
        @memcpy(copy, key);
        try self.tokens.append(copy);
        try self.token_ids.put(copy, val);
        return val;
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

    fn eatSpace(self: *Self) !void {
        try self.eatSpaceN(1_000_000);
    }

    pub fn next(self: *Self) !?Token {
        const token_start = self.pos;
        const next_c = self.readByte() catch |err| {
            return if (err == error.EndOfStream) null else err;
        };
        if (next_c == '\\') {
            const len = try self.readUntilDelimiters(&[_]u8{ '\n', '\t', ' ', '*', '\\' });
            var tag = self.buffer[token_start + 1 .. token_start + len];

            if (tag[tag.len - 1] != '*') {
                try self.eatSpaceN(1);
                log.debug("open tag '{s}'", .{tag});
                const id = try self.getOrPut(tag, @intCast(TagType, self.token_ids.count()));
                return .{ .tag_open = id };
            } else { // End tag like `\w*` or '\*';
                self.in_attribute = false;
                var id: TagType = 0;
                if (tag.len > 1) {
                    tag = tag[0 .. tag.len - 1];
                    id = try self.getOrPut(tag, @intCast(TagType, self.token_ids.count()));
                }
                log.debug("close tag '{s}'", .{tag});
                return .{ .tag_close = id };
            }
        } else if (next_c == '|') {
            try self.eatSpace();
            self.in_attribute = true;
            return .attribute_start;
        } else if (self.in_attribute) {
            var key_len = try self.readUntilDelimiters(&[_]u8{ '\n', '\t', ' ', '=', '\\' });
            const key = self.buffer[token_start .. token_start + key_len];
            log.debug("key '{s}'", .{key});

            try self.eatSpace();
            const maybe_equals = try self.readByte();
            var val: []const u8 = "";
            if (maybe_equals == '=') {
                try self.eatSpace();
                const maybe_quote = try self.readByte();
                if (maybe_quote == '"') {
                    const len = try self.readUntilDelimiters(&[_]u8{'"'});
                    self.pos += 1;
                    val = self.buffer[self.pos - len .. self.pos - 1];
                    try self.eatSpace();
                    log.debug("val {s}", .{val});
                }
            } else {
                self.pos -= 1;
            }
            log.debug("KV {s} {s}", .{ key, val });
            return .{ .attribute = .{ .key = key, .val = val } };
        }
        const len = try self.readUntilDelimiters(&[_]u8{ '|', '\\' });
        const text = self.buffer[token_start .. token_start + len];

        return .{ .text = text };
    }

    pub fn peek(self: *Self) !?Token {
        const pos = self.pos;
        const res = try self.next();
        self.pos = pos;
        return res;
    }
};

test "single simple tag" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings(usfm[4..], (try lex.next()).?.text);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "two simple tags" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
        \\\usfm 3.0
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings(usfm[4..30], (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqualStrings("3.0", (try lex.next()).?.text);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "single attribute tag" {
    const usfm =
        \\\word hello |   x-occurences  =   "1" \word*
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("hello ", (try lex.next()).?.text);
    try testing.expectEqual(Token.attribute_start, (try lex.next()).?);
    const attribute = (try lex.next()).?.attribute;
    try testing.expectEqualStrings("x-occurences", attribute.key);
    try testing.expectEqualStrings("1", attribute.val);
    try testing.expectEqual(Token{ .tag_close = 1 }, (try lex.next()).?);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "empty attribute tag" {
    const usfm =
        \\\w hello |\w*
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("hello ", (try lex.next()).?.text);
    try testing.expectEqual(Token.attribute_start, (try lex.next()).?);
    try testing.expectEqual(Token{ .tag_close = 1 }, (try lex.next()).?);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "self closing tag" {
    const usfm =
        \\\zaln-s hello\*
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("hello", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 0 }, (try lex.next()).?);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "full line" {
    const usfm =
        \\\v 1 \zaln-s |x-strong="b:H7225" x-morph="He,R:Ncfsa"\*\w In\w*
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("1 ", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqual(Token.attribute_start, (try lex.next()).?);
    const attribute = (try lex.next()).?.attribute;
    try testing.expectEqualStrings("x-strong", attribute.key);
    try testing.expectEqualStrings("b:H7225", attribute.val);
    const attribute2 = (try lex.next()).?.attribute;
    try testing.expectEqualStrings("x-morph", attribute2.key);
    try testing.expectEqualStrings("He,R:Ncfsa", attribute2.val);
    try testing.expectEqual(Token{ .tag_close = 0 }, (try lex.next()).?);

    try testing.expectEqual(Token{ .tag_open = 3 }, (try lex.next()).?);
    try testing.expectEqualStrings("In", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 3 }, (try lex.next()).?);

    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "milestones" {
    const usfm =
        \\\v 1 \zaln-s\*\w In\w*\zaln-e\*there
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("1 ", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqual(Token{ .tag_close = 0 }, (try lex.next()).?);
    try testing.expectEqual(Token{ .tag_open = 3 }, (try lex.next()).?);
    try testing.expectEqualStrings("In", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 3 }, (try lex.next()).?);
    try testing.expectEqual(Token{ .tag_open = 4 }, (try lex.next()).?);
    try testing.expectEqual(Token{ .tag_close = 0 }, (try lex.next()).?);
    try testing.expectEqualStrings("there", (try lex.next()).?.text);

    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "line breaks" {
    const usfm =
        \\\v 1 \w In\w*
        \\\w the\w*
        \\\w beginning\w*
    ;
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings("1 ", (try lex.next()).?.text);

    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqualStrings("In", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 2 }, (try lex.next()).?);

    try testing.expectEqualStrings("\n", (try lex.next()).?.text);

    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqualStrings("the", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 2 }, (try lex.next()).?);

    try testing.expectEqualStrings("\n", (try lex.next()).?.text);

    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqualStrings("beginning", (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_close = 2 }, (try lex.next()).?);

    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "full file" {
    var file = try std.fs.cwd().openFile("./examples/01-GEN.usfm", .{});
    defer file.close();
    const usfm = try file.readToEndAlloc(testing.allocator, 4 * 1_000_000_000);
    defer testing.allocator.free(usfm);
    var lex = try Lexer.init(testing.allocator, usfm);
    defer lex.deinit();

    while (try lex.next()) |_| {}
}
