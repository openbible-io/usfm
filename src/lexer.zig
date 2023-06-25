const std = @import("std");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const TagType = types.TagType;
const Token = types.Token;
const log = types.log;

pub fn Lexer(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const TokenIds = std.StringHashMap(TagType);
        const Tokens = std.ArrayList([]const u8);
        const max_token_len = 4096;

        allocator: Allocator,
        reader: std.io.PeekStream(.{ .Static = 1 }, std.io.CountingReader(std.io.BufferedReader(max_token_len, ReaderType))),
        token_buf: [max_token_len]u8,
        tokens: Tokens,
        token_ids: TokenIds,
        is_eof: bool,
        in_attribute: bool,

        pub fn init(allocator: Allocator, reader: ReaderType) !Self {
            var res = Self{
                .allocator = allocator,
                .reader = std.io.peekStream(1, std.io.countingReader(std.io.bufferedReaderSize(max_token_len, reader))),
                .token_buf = undefined,
                .tokens = try Tokens.initCapacity(allocator, 64),
                .token_ids = TokenIds.init(allocator),
                .is_eof = false,
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

        fn readUntilDelimiters(self: *Self, buf: []u8, comptime delimiters: []const u8) !usize {
            var len: usize = 0;
            while (true) {
                buf[len] = self.reader.reader().readByte() catch |err| {
                    if (err == error.EndOfStream) return len;
                    return err;
                };
                inline for (delimiters) |d| {
                    if (buf[len] == d) {
                        if (d == '\n' or d == '\\' or d == '|' or d == '=') try self.reader.putBackByte(d);
                        if (d == '*') len += 1;
                        return len;
                    }
                }
                len += 1;
            }
        }

        fn getOrPut(self: *Self, key: []u8, val: TagType) !TagType {
            const maybe_id = self.token_ids.get(key);
            if (maybe_id) |id| return id;

            const copy = try self.allocator.alloc(u8, key.len);
            @memcpy(copy, key);
            try self.tokens.append(copy);
            try self.token_ids.put(copy, val);
            return val;
        }

        fn eatSpace(self: *Self) !void {
            var byte = try self.reader.reader().readByte();
            // log.debug("ate '{c}'", .{ byte });
            while (byte == ' ' or byte == '\t') {
                byte = try self.reader.reader().readByte();
                // log.debug("ate '{c}'", .{ byte });
            }
            // log.debug("put back '{c}'", .{ byte });
            try self.reader.putBackByte(byte);
        }

        pub fn next(self: *Self) !?Token {
            const reader = self.reader.reader();
            var token_buf = self.token_buf;

            token_buf[0] = reader.readByte() catch |err| {
                return if (err == error.EndOfStream) null else err;
            };
            if (token_buf[0] == '\\') {
                const len = try self.readUntilDelimiters(&token_buf, &[_]u8{ '\n', '\t', ' ', '*' });
                var tag = token_buf[0..len];
                log.debug("tag '{s}'", .{tag});

                if (tag[tag.len - 1] != '*') {
                    const id = try self.getOrPut(tag, @intCast(TagType, self.token_ids.count()));
                    return .{ .tag_open = id };
                } else { // End tag like `\w*` or '\*';
                    self.in_attribute = false;
                    var id: TagType = 0;
                    if (tag.len > 1) {
                        tag = tag[0 .. tag.len - 1];
                        id = try self.getOrPut(tag, @intCast(TagType, self.token_ids.count()));
                    }
                    return .{ .tag_close = id };
                }
            } else if (token_buf[0] == '|') {
                try self.eatSpace();
                self.in_attribute = true;
                return .attribute_start;
            } else if (self.in_attribute) {
                var key_len = try self.readUntilDelimiters(token_buf[1..], &[_]u8{ '\n', '\t', ' ', '=', '\\' });
                const key = token_buf[0 .. key_len + 1];
                log.debug("key '{s}'", .{key});

                try self.eatSpace();
                const maybe_equals = try reader.readByte();
                var val: []u8 = "";
                if (maybe_equals == '=') {
                    try self.eatSpace();
                    const maybe_quote = try reader.readByte();
                    if (maybe_quote == '"') {
                        val = try reader.readUntilDelimiter(token_buf[key_len + 1 ..], '"');
                        try self.eatSpace();
                        log.debug("val {s}", .{val});
                    }
                } else {
                    try self.reader.putBackByte(maybe_equals);
                }
                log.debug("KV {s} {s}", .{ key, val });
                return .{ .attribute = .{ .key = key, .val = val } };
            }
            const len = try self.readUntilDelimiters(token_buf[1..], &[_]u8{ '|', '\\' });
            const text = token_buf[0 .. len + 1];

            return .{ .text = text };
        }
    };
}

pub fn lexer(allocator: Allocator, reader: anytype) !Lexer(@TypeOf(reader)) {
    return Lexer(@TypeOf(reader)).init(allocator, reader);
}

test "single simple tag" {
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
    ;
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try lexer(testing.allocator, stream.reader());
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
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try lexer(testing.allocator, stream.reader());
    defer lex.deinit();

    try testing.expectEqual(Token{ .tag_open = 1 }, (try lex.next()).?);
    try testing.expectEqualStrings(usfm[4..30], (try lex.next()).?.text);
    try testing.expectEqual(Token{ .tag_open = 2 }, (try lex.next()).?);
    try testing.expectEqualStrings("3.0", (try lex.next()).?.text);
    try testing.expectEqual(@as(?Token, null), try lex.next());
}

test "single attribute tag" {
    const usfm =
        \\\w hello | x-occurences = "1"\w*
    ;
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try lexer(testing.allocator, stream.reader());
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
    var stream = std.io.fixedBufferStream(usfm);
    var reader = stream.reader();
    var lex = try lexer(testing.allocator, reader);
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
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try lexer(testing.allocator, stream.reader());
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
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try lexer(testing.allocator, stream.reader());
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

test "full file" {
    var file = try std.fs.cwd().openFile("./examples/01-GEN.usfm", .{});
    defer file.close();
    var lex = try lexer(testing.allocator, file.reader());
    defer lex.deinit();

    var tok = try lex.next();
    while (tok != null) tok = try lex.next();
}
