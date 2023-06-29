const std = @import("std");
const clap = @import("clap");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;
const ast = @import("./ast.zig");

pub const std_options = struct {
    pub const log_level: std.log.Level = .warn;
};

fn parseFile(outdir: []const u8, fname: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("parsing {s}\n", .{fname});
    var file = try std.fs.cwd().openFile(fname, .{});
    defer file.close();

    const usfm = try file.readToEndAlloc(allocator, 4 * 1_000_000_000);
    var parser = try Parser.init(allocator, usfm);

    while (try parser.next()) |ele| {
        // try ele.print(std.io.getStdErr().writer());
        // We only care about chapters
        if (!ast.isChapter(ele)) continue;

        const paragraphs = try ast.paragraphs(allocator, ele);

        const chapter_number = std.fmt.parseInt(u8, ast.trimWhitespace(ele.text), 10) catch {
            log.err("could not parse chapter number {s}", .{ast.trimWhitespace(ele.text)});
            std.os.exit(2);
        };

        const outname = try std.fmt.allocPrint(allocator, "{1s}{0c}{2s}{0c}{3d:0>3}.json", .{
            std.fs.path.sep,
            outdir,
            std.fs.path.stem(fname),
            chapter_number,
        });
        try std.fs.cwd().makePath(std.fs.path.dirname(outname).?);
        var outfile = try std.fs.cwd().createFile(outname, .{});
        defer outfile.close();
        try std.json.stringify(
            paragraphs,
            .{
                .emit_null_optional_fields = false,
                .whitespace = .{ .indent = .tab, .separator = true },
            },
            outfile.writer(),
        );
    }
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

    if (res.args.help != 0 or res.positionals.len == 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    const outdir = res.args.@"output-dir" orelse ".";
    for (res.positionals) |fname| try parseFile(outdir, fname);
}
