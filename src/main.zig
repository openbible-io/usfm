const std = @import("std");
const clap = @import("clap");
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

fn parseFile(outdir: []const u8, fname: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file = try std.fs.cwd().openFile(fname, .{});
    defer file.close();

    try std.fs.cwd().makePath(outdir);
    const outname = try std.fmt.allocPrint(allocator, "{s}{c}{s}.json", .{
        outdir,
        std.fs.path.sep,
        std.fs.path.stem(fname),
    });
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

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit
        \\-o, --output-dir <str>  Parsed json output path
        \\<str>...                USFM files to parse
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    const outdir = res.args.@"output-dir" orelse ".";
    for (res.positionals) |fname| try parseFile(outdir, fname);
}
