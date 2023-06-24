const std = @import("std");
const lexer = @import("./lib.zig").lexer;

pub fn main() !void {
    var file = try std.fs.cwd().openFile("../en_ult/01-GEN.usfm", .{});
    defer file.close();
    var reader = file.reader();
    var lex = try lexer(std.heap.page_allocator, reader);
    defer lex.deinit();

    while (try lex.nextToken()) |tok| {
        _ = tok;
    }
}
