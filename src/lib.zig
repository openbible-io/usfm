pub const Lexer = @import("./lexer.zig").Lexer;
pub const Parser = @import("./parser.zig").Parser;

test {
    _ = @import("./lexer.zig");
    _ = @import("./parser.zig");
}
