const std = @import("std");
const simargs = @import("simargs");
const Parser = @import("./Parser.zig");
const Lexer = @import("./Lexer.zig");
const Element = Parser.Element;
const log = std.log.scoped(.usfm);

pub const std_options = .{
    .log_level = .warn,
};

fn parseFile(allocator: std.mem.Allocator, outdir: []const u8, fname: []const u8) !void {
    std.debug.print("{s}\n", .{fname});

    var file = try std.fs.cwd().openFile(fname, .{});
    defer file.close();

    const usfm = try file.readToEndAlloc(allocator, 1 << 32);

    var parser = Parser.init(allocator, usfm);
    defer parser.deinit();

    var outfile: ?std.fs.File = null;
    defer if (outfile) |o| o.close();

    const error_context = Parser.ErrorContext{
        .buffer_name = fname,
        .buffer = usfm,
        .stderr = std.io.getStdErr(),
    };

    while (true) {
        const ele = parser.next() catch {
            try parser.errors.print(error_context);
            parser.errors.list.clearRetainingCapacity();
            continue;
        } orelse break;
        // We only care about chapters
        switch (ele) {
            .node => |n| {
                if (n.tag == .c) {
                    const chapter = std.fmt.parseInt(u8, n.attributes[0].value, 10) catch {
                        log.err("could not parse chapter number {s}", .{n.attributes[0].value});
                        return error.InvalidChapterNumber;
                    };
                    const outname = try std.fmt.allocPrint(allocator, "{1s}{0c}{2s}{0c}{3d:0>3}.html", .{
                        std.fs.path.sep,
                        outdir,
                        std.fs.path.stem(fname),
                        chapter,
                    });
                    try std.fs.cwd().makePath(std.fs.path.dirname(outname).?);
                    if (outfile) |o| o.close();
                    outfile = try std.fs.cwd().createFile(outname, .{});
                }
            },
            .text => {},
        }
        if (outfile) |f| try ele.html(f.writer());
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

    for (opt.positional_args.items) |fname| try parseFile(allocator, opt.args.output_dir, fname);
}

test {
    _ = @import("./Lexer.zig");
    _ = @import("./Parser.zig");
}
