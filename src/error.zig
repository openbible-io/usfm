const std = @import("std");
const Token = @import("./Lexer.zig").Token;
const Tag = @import("./tag.zig").Tag;
const Allocator = std.mem.Allocator;

pub const ErrorContext = struct {
    buffer_name: []const u8,
    buffer: []const u8,
    stderr: std.fs.File,

    pub fn print(self: ErrorContext, err: Error, chapter: ?usize) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);

        const line_start = lineStart(self.buffer, err.token);
        try self.printLoc(line_start, err.token);

        tty_config.setColor(w, .bold) catch {};
        tty_config.setColor(w, .yellow) catch {};
        switch (err.kind) {
            .invalid_tag => try w.writeAll("invalid tag"),
            .invalid_root => try w.writeAll("invalid root element"),
            .invalid_attribute => |a| try w.print("invalid attribute \"{s}\"", .{a}),
            .expected_milestone_close_open => try w.writeAll("expected milestone end tag"),
            .expected_close => try w.writeAll("expected closing tag"),
            .expected_self_close => try w.writeAll("expected self-closing tag"),
            .expected_attribute_value => try w.writeAll("expected attribute value"),
            .expected_caller => try w.writeAll("expected caller"),
            .expected_number => try w.writeAll("expected number"),
            .no_default_attribute => |t| try w.print("{s} has no default attributes", .{@tagName(t)}),
        }
        tty_config.setColor(w, .reset) catch {};
        if (chapter) |c| try w.print(" in chapter {d}", .{c});
        try self.printContext(line_start, err.token);

        switch (err.kind) {
            inline .expected_milestone_close_open, .expected_close, .expected_self_close => |t| {
                const line_start2 = lineStart(self.buffer, t);
                try self.printLoc(line_start2, t);
                tty_config.setColor(w, .blue) catch {};
                try w.writeAll("opening tag here");
                try self.printContext(line_start2, t);
            },
            else => {},
        }
        tty_config.setColor(w, .reset) catch {};
    }

    fn lineStart(buffer: []const u8, token: Token) usize {
        var res = @min(token.start, buffer.len - 1);
        while (res > 0 and buffer[res] != '\n') res -= 1;

        return res + 1;
    }

    fn printLoc(self: ErrorContext, line_start: usize, token: Token) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);
        tty_config.setColor(w, .reset) catch {};
        tty_config.setColor(w, .bold) catch {};
        const column = token.start - line_start + 1;

        var token_line: usize = 1;
        for (self.buffer[0..token.start]) |c| {
            if (c == '\n') token_line += 1;
        }
        try w.print("{s}:{d}:{d} ", .{ self.buffer_name, token_line, column });
    }

    fn printContext(self: ErrorContext, line_start: usize, token: Token) !void {
        const w = self.stderr.writer();
        const tty_config = std.io.tty.detectConfig(self.stderr);
        tty_config.setColor(w, .reset) catch {};

        const line_end = if (std.mem.indexOfScalarPos(u8, self.buffer, token.end, '\n')) |n| n else self.buffer.len;
        try w.writeByte('\n');
        try w.print("{s}", .{self.buffer[line_start..token.start]});
        if (token.end != token.start) {
            tty_config.setColor(w, .green) catch {};
            try w.print("{s}", .{self.buffer[token.start..token.end]});
            tty_config.setColor(w, .reset) catch {};
            try w.print("{s}", .{self.buffer[token.end..line_end]});
        }
        try w.writeByte('\n');
    }
};

pub const Error = struct {
    token: Token,
    kind: Kind,

    pub const Kind = union(enum) {
        invalid_tag,
        invalid_root,
        invalid_attribute: []const u8,
        expected_attribute_value,
        expected_milestone_close_open: Token,
        expected_close: Token,
        expected_self_close: Token,
        expected_caller,
        expected_number,
        no_default_attribute: Tag,
    };

    const HashCtx = struct {
        pub fn hash(_: @This(), key: Error) u32 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .Shallow);
            return @truncate(hasher.final());
        }
        pub fn eql(_: @This(), key1: Error, key2: Error, _: usize) bool {
            return std.meta.eql(key1, key2);
        }
    };
};
pub const Errors = struct {
    map: std.ArrayHashMapUnmanaged(Error, void, Error.HashCtx, false) = .{},

    pub fn deinit(self: *Errors, allocator: Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn print(self: Errors, ctx: ErrorContext, chapter: ?usize) !void {
        const items = self.map.keys();
        for (items, 0..) |err, i| {
            try ctx.print(err, chapter);
            if (i != items.len) try ctx.stderr.writer().writeByte('\n');
        }
    }
};
