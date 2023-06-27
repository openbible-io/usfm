pub const Lexer = @import("./lexer.zig").Lexer;
pub const Parser = @import("./parser.zig").Parser;
pub const Element = @import("./types.zig").Element;
pub const Token = @import("./types.zig").Token;
pub const Attribute = @import("./types.zig").Attribute;

test {
    _ = @import("./lexer.zig");
    _ = @import("./parser.zig");
}
