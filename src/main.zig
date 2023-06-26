const std = @import("std");
const Parser = @import("./lib.zig").Parser;

pub const std_options = struct {
    pub const log_level: std.log.Level = .warn;
};

pub fn main() !void {
    var file = try std.fs.cwd().openFile("../en_ult/01-GEN.usfm", .{});
    defer file.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const usfm = try file.readToEndAlloc(allocator, 4 * 1_000_000_000);
    defer allocator.free(usfm);

    var parser = try Parser.init(allocator, usfm);
    defer parser.deinit();

    while (try parser.next()) |ele| {
        try ele.print(std.io.getStdOut().writer());
    }
}
