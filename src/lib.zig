const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.usfm);

const TagType = u32;

const Token = union(enum) {
	const Self = @This();
	const KV = struct { key: []const u8, val: []const u8 };

	tag_open: TagType,
	text: []u8,
	attribute_start: void,
	attribute: KV,
	tag_close: TagType,

	fn print(self: Self) void {
		switch (self) {
			.text => |t| log.debug("token '{s}'", .{ t }),
			else => |t| log.debug("token {any}", .{ t }),
		}
	}
};

const Error = error {
	UnexpectedClosingTag,
};

pub fn Lexer(comptime ReaderType: type) type {
	return struct {
		const Self = @This();
		const TokenIds = std.StringHashMap(TagType);
		const State = union(enum) {
			tag: TagType,
			// inline_tag: TagType,
			attribute: void,
		};
		const Stack = std.ArrayList(State);
		const Tokens = std.ArrayList([]const u8);

		allocator: Allocator,
		reader: std.io.PeekStream(.{ .Static = 1 }, std.io.BufferedReader(4096, ReaderType)),
		stack: Stack,
		token_buf: [4096]u8,
		tokens: Tokens,
		token_ids: TokenIds,
		is_eof: bool,

		fn init(allocator: Allocator, reader: ReaderType) !Self {
			var res = Self {
				.allocator = allocator,
				.reader = std.io.peekStream(1, std.io.bufferedReader(reader)),
				.stack = try Stack.initCapacity(allocator, 64),
				.token_buf = undefined,
				.tokens = try Tokens.initCapacity(allocator, 64),
				.token_ids = TokenIds.init(allocator),
				.is_eof = false,
			};
			// Reserve 0
			try res.tokens.append("");
			try res.token_ids.put("", 0);
			return res;
		}

		fn deinit(self: *Self) void {
			self.stack.deinit();
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
			const maybe_id = try self.token_ids.fetchPut(key, val);
			if (maybe_id) |i| return i.value;

			const copy = try self.allocator.alloc(u8, key.len);
			@memcpy(copy, key);
			try self.tokens.append(copy);
			return val;
		}
		
		fn eatSpace(self: *Self) !void {
			var byte = try self.reader.reader().readByte();
			log.debug("ate '{c}'", .{ byte });
			while (byte == ' ' or byte == '\t') {
				byte = try self.reader.reader().readByte(); 
				log.debug("ate '{c}'", .{ byte });
			}
			log.debug("put back '{c}'", .{ byte });
			try self.reader.putBackByte(byte);
		}

		fn nextToken2(self: *Self) !Token {
			const reader = self.reader.reader();
			var token_buf = self.token_buf;

			token_buf[0] = reader.readByte() catch |err| blk: {
				if (err == error.EndOfStream) {
					self.is_eof = true;
					break :blk '\n';
				} else {
					return err;
				}
			};
			if (token_buf[0] == '\\') {
				const len = try self.readUntilDelimiters(&token_buf, &[_]u8{'\n', '\t', ' ', '*'});
				var tag = token_buf[0..len];
				log.debug("tag '{s}'", .{ tag });

				if (tag[tag.len - 1] != '*') {
					const id = try self.getOrPut(tag, self.token_ids.count());
					try self.stack.append(.{ .tag = id });
					return .{ .tag_open = id };
				} else { // End tag like `\w*` or '\*';
					if (self.stack.items[self.stack.items.len - 1] == .attribute) _ = self.stack.pop();

					var id: TagType = 0;
					if (tag.len > 1) {
						tag = tag[0..tag.len - 1];
						const expected_tag_id = self.stack.pop().tag;
						if (expected_tag_id != self.token_ids.get(tag)) {
							log.err("expected closing tag {s}, got {s}", .{ self.tokens.items[expected_tag_id], tag });
							return Error.UnexpectedClosingTag;
						}
						id = try self.getOrPut(tag, self.token_ids.count());
					} else {
						id = self.stack.pop().tag;
					}

					return .{ .tag_close = id };
				}
			} else if (token_buf[0] == '|') { // TODO: only allow in inline tags
				try self.stack.append(.attribute);
				try self.eatSpace();
				return .attribute_start;
			} else if (token_buf[0] == '\n') {
				if (self.stack.items.len > 0) {
					const last = self.stack.pop().tag; // TODO: disallow popping inline tags
					return .{ .tag_close = last };
				}
			} else if (self.stack.items.len > 0 and self.stack.items[self.stack.items.len - 1] == .attribute) {
				var key_len = try self.readUntilDelimiters(token_buf[1..], &[_]u8{'\n', '=', '\\', ' '});
				const key = token_buf[0..key_len + 1];
				log.debug("key '{s}'", .{ key });

				try self.eatSpace();
				const maybe_equals = try reader.readByte();
				var val: []u8 = "";
				if (maybe_equals == '=') {
					try self.eatSpace();
					const maybe_quote = try reader.readByte();
					if (maybe_quote == '"') {
						val = try reader.readUntilDelimiter(token_buf[key_len+1..], '"');
						try self.eatSpace();
						log.debug("val {s}", .{ val });
					}
				} else {
					try self.reader.putBackByte(maybe_equals);
				}
				log.debug("KV {s} {s}", .{ key, val });
				return .{ .attribute = .{ .key = key, .val = val } };
			}
			// read until '|' or '\'
			const len = try self.readUntilDelimiters(token_buf[1..], &[_]u8{'\n', '|', '\\'});
			const text = token_buf[0..len + 1];

			return .{ .text = text };
		}

		pub fn nextToken(self: *Self) !?Token {
			if (self.is_eof) {
				if (self.stack.items.len > 0) {
					log.warn("expected closing tags:", .{ });
					for (self.stack.items) |i| {
						log.warn("\t{any}", .{ i });
					}
				}
				return null;
			}
			const res = try self.nextToken2();
			res.print();
			return res;
		}
	};
}

pub fn lexer(allocator: Allocator, reader: anytype) !Lexer(@TypeOf(reader)) {
	return Lexer(@TypeOf(reader)).init(allocator, reader);
}

test "single simple tag" {
	const usfm = "\\id GEN EN_ULT en_English_ltr";
	var stream = std.io.fixedBufferStream(usfm);
	var reader = stream.reader();
	var lex = try lexer(std.testing.allocator, reader);
	defer lex.deinit();

	try std.testing.expectEqual(Token { .tag_open = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings(usfm[4..], (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token { .tag_close = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqual(@as(?Token, null), try lex.nextToken());
}

test "two simple tags" {
	const usfm = 
		\\\id GEN EN_ULT en_English_ltr
		\\\usfm 3.0
		;

	var stream = std.io.fixedBufferStream(usfm);
	var reader = stream.reader();
	var lex = try lexer(std.testing.allocator, reader);
	defer lex.deinit();

	try std.testing.expectEqual(Token { .tag_open = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings(usfm[4..29], (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token { .tag_close = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqual(Token { .tag_open = 2 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings("3.0", (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token { .tag_close = 2 }, (try lex.nextToken()).?);
	try std.testing.expectEqual(@as(?Token, null), try lex.nextToken());
}

test "single attribute tag" {
	const usfm = \\\w hello | x-occurences = "1"\w*
		;
	var stream = std.io.fixedBufferStream(usfm);
	var reader = stream.reader();
	var lex = try lexer(std.testing.allocator, reader);
	defer lex.deinit();

	try std.testing.expectEqual(Token { .tag_open = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings("hello ", (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token.attribute_start, (try lex.nextToken()).?);
	const attribute = (try lex.nextToken()).?.attribute;
	try std.testing.expectEqualStrings("x-occurences", attribute.key);
	try std.testing.expectEqualStrings("1", attribute.val);
	try std.testing.expectEqual(Token { .tag_close = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings("\n", (try lex.nextToken()).?.text);
	try std.testing.expectEqual(@as(?Token, null), try lex.nextToken());
}

test "full line" {
 	std.testing.log_level = .debug;
	const usfm = \\\v 1 \zaln-s |x-strong="b:H7225" x-morph="He,R:Ncfsa"\*\w In\w*
		;
	var stream = std.io.fixedBufferStream(usfm);
	var reader = stream.reader();
	var lex = try lexer(std.testing.allocator, reader);
	defer lex.deinit();

	try std.testing.expectEqual(Token { .tag_open = 1 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings("1 ", (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token { .tag_open = 2 }, (try lex.nextToken()).?);
	try std.testing.expectEqual(Token.attribute_start, (try lex.nextToken()).?);
	const attribute = (try lex.nextToken()).?.attribute;
	try std.testing.expectEqualStrings("x-strong", attribute.key);
	try std.testing.expectEqualStrings("b:H7225", attribute.val);
	const attribute2 = (try lex.nextToken()).?.attribute;
	try std.testing.expectEqualStrings("x-morph", attribute2.key);
	try std.testing.expectEqualStrings("He,R:Ncfsa", attribute2.val);
	try std.testing.expectEqual(Token { .tag_close = 2 }, (try lex.nextToken()).?);

	try std.testing.expectEqual(Token { .tag_open = 3 }, (try lex.nextToken()).?);
	try std.testing.expectEqualStrings("In", (try lex.nextToken()).?.text);
	try std.testing.expectEqual(Token { .tag_close = 3 }, (try lex.nextToken()).?);
	try std.testing.expectEqual(Token { .tag_close = 1 }, (try lex.nextToken()).?);

	try std.testing.expectEqual(@as(?Token, null), try lex.nextToken());
}
