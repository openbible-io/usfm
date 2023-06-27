const std = @import("std");
const Parser = @import("./lib.zig").Parser;

pub const std_options = struct {
    pub const log_level: std.log.Level = .warn;
};

const whitespace = &[_]u8{ ' ', '\t', '\n' };

fn getText(text: []const u8) []const u8 {
    var res = @constCast(std.mem.trim(u8, text, whitespace));
    for (res) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    return res;
}

fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <FILE>...\n", .{args[0]});
        std.os.exit(1);
    }

    for (0..args.len - 1) |i| {
        const fname = args[i + 1];
        var file = try std.fs.cwd().openFile(fname, .{});
        defer file.close();

        const outname = try std.fmt.allocPrint(allocator, "{s}.json", .{std.fs.path.stem(fname)});
        defer allocator.free(outname);

        std.debug.print("{s} -> {s}\n", .{ fname, outname });

        var outfile = try std.fs.cwd().createFile(outname, .{});
        defer outfile.close();

        const usfm = try file.readToEndAlloc(allocator, 4 * 1_000_000_000);
        defer allocator.free(usfm);

        var parser = try Parser.init(allocator, usfm);
        defer parser.deinit();

        var first_verse_written = false;
        var writer = outfile.writer();
        try writer.writeAll("[\n");
        while (try parser.next()) |ele| {
            defer ele.deinit(allocator);

            // try ele.print(std.io.getStdErr().writer());
            if (std.mem.eql(u8, ele.tag, "v")) {
                first_verse_written = true;

                const inner_text = try ele.innerText(allocator);
                defer allocator.free(inner_text);

                const footnote_text = if (ele.footnote()) |f| try f.footnoteInnerText(allocator) else try allocator.alloc(u8, 0);
                defer allocator.free(footnote_text);

                try std.json.stringify(.{
                    .type = "verse",
                    .number = trimWhitespace(ele.text),
                    .text = getText(inner_text[ele.text.len..]),
                    .footnote = if (footnote_text.len == 0) null else trimWhitespace(footnote_text),
                }, .{ .emit_null_optional_fields = false }, writer);
                try writer.writeAll(",\n");
            } else if (std.mem.eql(u8, ele.tag, "p") and first_verse_written) {
                try std.json.stringify(.{ .type = "br" }, .{}, writer);
                try writer.writeAll(",\n");
            }
        }
        try outfile.seekBy(-2);
        try writer.writeAll("\n]");
    }
}
