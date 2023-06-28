const std = @import("std");
const clap = @import("clap");
const Parser = @import("./lib.zig").Parser;
const Element = @import("./lib.zig").Element;
const log = @import("./types.zig").log;

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

fn getNumber(text: []const u8) []const u8 {
    for (text, 0..) |c, i| {
        if (c < '0' or c > '9') return text[0..i];
    }
    return "";
}

fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

fn isVerse(c: Element) bool {
    return std.mem.eql(u8, "v", c.tag);
}

fn isChapter(c: Element) bool {
    return std.mem.eql(u8, "c", c.tag);
}

fn isBr(c: Element) bool {
    return std.mem.eql(u8, "p", c.tag);
}

const Child = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    number: ?[]const u8 = null,
    footnote: ?[]const u8 = null,
};

fn tagName(usfm_name: []const u8) []const u8 {
    if (std.mem.eql(u8, "v", usfm_name)) return "verse";
    if (std.mem.eql(u8, "p", usfm_name)) return "br";
    return usfm_name;
}

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
        var children = std.ArrayList(Child).init(allocator);
        // try ele.print(std.io.getStdErr().writer());
        // We only care about chapters
        if (!isChapter(ele)) continue;

        for (ele.children) |child| {
            // We only care about verses and breaks
            if (isVerse(child)) {
                const inner = getText(try child.innerText(allocator));
                const number = getNumber(inner);
                try children.append(Child{
                    .type = tagName(child.tag),
                    .text = getText(inner[number.len..]),
                    .number = if (std.mem.eql(u8, "v", child.tag)) number else null,
                    .footnote = if (child.footnote()) |f| getText(try f.footnoteInnerText(allocator)) else null,
                });
            } else if (isBr(child)) {
                try children.append(Child{
                    .type = tagName(child.tag),
                });
            }
        }
        const chapter_number = std.fmt.parseInt(u8, trimWhitespace(ele.text), 10) catch {
            log.err("could not parse chapter number {s}", .{trimWhitespace(ele.text)});
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
            children.items,
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
