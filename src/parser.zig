const std = @import("std");
const types = @import("./types.zig");
const Lexer = @import("./lexer.zig").Lexer;

const Allocator = std.mem.Allocator;
const TagType = types.TagType;
const Token = types.Token;
const Element = types.Element;
const InlineElement = types.InlineElement;
const Attribute = types.Attribute;
const log = types.log;
const Error = error{
    InvalidClosingTag,
};
const testing = std.testing;

pub fn Parser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const LexerType = Lexer(ReaderType);
        const Stack = std.ArrayList(TagType);

        allocator: Allocator,
        lexer: LexerType,
        stack: Stack,

        pub fn init(allocator: Allocator, reader: ReaderType) !Self {
            return Self{
                .allocator = allocator,
                .lexer = try LexerType.init(allocator, reader),
                .stack = Stack.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.lexer.deinit();
            self.stack.deinit();
        }

        pub fn next(self: *Self) !?Element {
            const allocator = self.allocator;
            var res = Element{
                .tag = "",
                .text = try allocator.alloc(u8, 0),
                .inline_elements = try allocator.alloc(InlineElement, 0),
            };
            while (true) {
                if (try self.lexer.next()) |token| {
                    switch (token) {
                        .tag_open => |t| {
                            res.tag = self.lexer.tokens.items[t];
                            try self.stack.append(t);
                        },
                        .text => |t| {
                            log.debug("t {s}", .{t});
                            allocator.free(res.text);
                            res.text = try std.mem.concat(allocator, u8, &[_][]const u8{ res.text, t });
                            log.debug("res.text {s}", .{res.text});
                        },
                        .attribute_start => {},
                        .attribute => |a| {
                            var inline_ele = res.inline_elements[res.inline_elements.len - 1];
                            inline_ele.attributes = try allocator.realloc(inline_ele.attributes, res.inline_elements.len + 1);
                            inline_ele.attributes[res.inline_elements.len - 1] = a;
                        },
                        .tag_close => |t| {
                            if (self.stack.popOrNull()) |expected| {
                                if (expected != t) {
                                    log.err("Expected closing tag {s}, not {s} at {d}", .{
                                        self.lexer.tokens.items[expected],
                                        self.lexer.tokens.items[t],
                                        self.lexer.reader.unbuffered_reader.bytes_read,
                                    });
                                    return Error.InvalidClosingTag;
                                }
                            }
                            log.err("Unmatched closing tag {s} at {d}", .{
                                self.lexer.tokens.items[t],
                                self.lexer.reader.unbuffered_reader.bytes_read,
                            });
                            return Error.InvalidClosingTag;
                        },
                    }
                } else {
                    return if (res.tag.len == 0) null else res;
                }
            }
        }
    };
}

pub fn parser(allocator: Allocator, reader: anytype) !Parser(@TypeOf(reader)) {
    return Parser(@TypeOf(reader)).init(allocator, reader);
}

test "single simple tag" {
    testing.log_level = .debug;
    const usfm =
        \\\id GEN EN_ULT en_English_ltr
    ;
    var stream = std.io.fixedBufferStream(usfm);
    var lex = try parser(testing.allocator, stream.reader());
    defer lex.deinit();

    const ele1 = (try lex.next()).?;
    defer ele1.deinit(testing.allocator);
    try testing.expectEqualStrings("id", ele1.tag);
    try testing.expectEqualStrings(usfm[4..], ele1.text);
}
