const std = @import("std");
const simargs = @import("simargs");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;
const ast = @import("./ast.zig");

pub const std_options = .{
    .log_level = .warn,
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
            std.process.exit(2);
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
                .whitespace = .indent_tab,
            },
            outfile.writer(),
        );
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try simargs.parse(allocator, struct {
        output_dir: []const u8 = ".",
        help: bool = false,

        pub const __shorts__ = .{
            .output_dir = .o,
            .help = .h,
        };
    }, "[file]", null);
    defer opt.deinit();

    for (opt.positional_args.items) |fname| try parseFile(opt.args.output_dir, fname);
}
