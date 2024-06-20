const std = @import("std");
const testing = std.testing;

pub const log = std.log.scoped(.usfm);
pub const Tag = union(enum) {
    // identification
    id, // file id
    usfm, // version
    ide, // encoding
    sts, // status
    rem, // remark
    h, // running header text
    toc: u8, // table of contents
    toca: u8, // alt language table of contents

    // introductions
    imt: u8, // major title
    is: u8, // section heading
    ip, // paragraph
    ipi, // intented paragraph
    im, // introduction margin paragraph
    imi, // indented margin paragraph
    ipq, // introduction quote
    imq, // margin quote
    ipr, // right-aligned
    iq: u8, // poetic
    ib, // blank line
    ili: u8, // list item
    iot, // outline title
    io: u8, // outline entry
    ior, // outline reference range
    iqt, // quoted
    iex, // explanatory
    imte: u8, // major title ending
    ie, // end

    // titles, headings, and labels
    mt: u8, // major title
    mte: u8, // major title at ending
    ms: u8, // major section heading
    mr, // major reference
    s: u8, // section heading
    sr, // section reference
    r, // parallel reference
    d, // descriptive title
    sp, // speaker id
    sd: u8, // semantic division

    // chapters and verses
    c, // chapter
    ca, // alternative chapter number
    cl, // chapter label
    cp, // chapter character
    cd, // chapter description
    v, // verse number
    va, // alternative verse number
    vp, // published verse character

    // paragraphs
    p, // paragraph
    m, // margin paragraph
    po, // opening of epistle
    pr, // right-aligned
    cls, // close of epistle
    pmo, // embedded text opening
    pm, // embedded text
    pmc, // embedded closing
    pmr, // embedded refrain
    pi: u8, // indented
    mi, // indented margin
    nb, // no break
    pc, // centered
    ph: u8, // hanging indent
    b, // blank line

    // poetry
    q: u8, // poetic
    qr, // right align
    qc, // center
    qs, // selah
    qa, // acrostic heading
    qac, // acrostic letter
    qm: u8, // embedded poetic line
    qd, // hebrew note

    // lists
    lh, // list header
    li, // list entry
    lf, // list footer
    lim: u8, // embedded list entry
    litl, // list entry total
    lik, // list entry key
    liv: u8, // list entry value

    // tables
    tr, // table row
    th: u8, // table heading
    thr: u8, // right aligned table heading
    tc: u8, // table cell
    tcr: u8, // right aligned table cell

    // footnotes
    f, // footnote
    fe, // footnote endnote
    fr, // footnote reference
    fq, // footnote quotation
    fqa, // footnote alternative translation
    fk, // footnote keyword
    fl, // footnote label
    fw, // footnote witness list
    fp, // footnote additional paragraph
    fv, // footnote verse number
    ft, // footnote text
    fdc, // footnote deuterocanonical content
    fm, // footnote reference mark

    // cross references
    x, // x-ref
    xo, // origin (chapter and verse)
    xk, // keyword
    xq, // quote
    xt, // target
    xta, // target added text
    xop, // published origin
    xot, // only display with old testament publications
    xnt, // only display with new testament publications
    xdc, // only display with deuterocanonical publications
    rq, // reference quote

    // words and characters
    add, // translator's addition
    bk, // quoted book title
    dc, // deuterocanonical additions
    k, // keyword
    lit, // liturgical note
    nd, // name of God
    ord, // ordinal number
    pn, // proper name
    png, // geographic proper name
    addpn, // overlapping \pn and \add in Chinese
    qt, // quoted text
    sig, // signature of author
    sls, // secondary language source
    tl, // transliterated
    wj, // words of Jesus

    // character styling
    em, // emphasis
    bd, // bold
    it, // italic
    bdit, // bold and italic
    no, // normal
    sc, // small cap
    sup, // superscript

    // spacing and breaks
    @"~", // non-breaking space
    @"//", // optional line break
    pb, // page break

    // special features
    fig, // figure
    ndx, // index
    rb, // ruby glossing https://www.w3.org/TR/ruby/#what
    pro, // pronuncation annotation
    w, // word
    wg, // word greek
    wh, // word hebrew
    wa, // word aramaic

    // linking
    jmp,

    // milestones
    @"qt-s": u8, // quotation
    @"ts-s", // translator
    @"z-s", // user
    @"qt-e": u8, // quotation
    @"ts-e", // translator
    @"z-e", // user

    // extended study content
    ef, // extended footnote
    ex, // extended xref
    esb, // beginning of sidebar
    esbe, // end of sidebar
    cat, // category
    periph, // peripheral content

    pub fn init(in_buffer: []const u8) !Tag {
        if (in_buffer.len == 0 or in_buffer[0] != '\\') {
            return error.MissingTagPrefix;
        }
        const buffer = in_buffer[1..];

        const digits = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' };
        const digit_n = std.mem.indexOfAny(u8, buffer, &digits) orelse buffer.len;

        if (std.mem.indexOfScalar(u8, buffer, '-')) |dash_n| {
            if (buffer[0] == 'z') {
                switch (buffer[buffer.len - 1]) {
                    's' => return .@"z-s",
                    'e' => return .@"z-e",
                    else => return error.InvalidSuffix,
                }
            }

            const tag = buffer[0..@min(dash_n, digit_n)];

            var buf: [4]u8 = undefined;
            const tag_s = std.fmt.bufPrint(&buf, "{s}-{c}", .{ tag, buffer[buffer.len - 1] }) catch {
                return error.TagTooLong;
            };
            const tag2 = std.meta.stringToEnum(std.meta.Tag(Tag), tag_s) orelse return error.InvalidTag;

            switch (tag2) {
                inline .@"qt-s", .@"qt-e" => |t| {
                    var n: u8 = 0;

                    if (digit_n != buffer.len) {
                        n = try std.fmt.parseInt(u8, buffer[digit_n..dash_n], 10);
                    }
                    return @unionInit(Tag, @tagName(t), n);
                },
                inline .@"ts-s", .@"ts-e" => |t| {
                    return @unionInit(Tag, @tagName(t), {});
                },
                else => {},
            }
        } else if (std.meta.stringToEnum(std.meta.Tag(Tag), buffer[0..digit_n])) |e| {
            switch (e) {
                inline else => |t| {
                    @setEvalBranchQuota(10000);
                    if (std.meta.FieldType(Tag, t) == u8) {
                        const n = try std.fmt.parseInt(u8, buffer[digit_n..], 10);
                        return @unionInit(Tag, @tagName(t), n);
                    } else {
                        return @unionInit(Tag, @tagName(t), {});
                    }
                },
            }
        }

        return error.InvalidTag;
    }

    pub fn isParagraph(self: Tag) bool {
        return switch (self) {
            // identification
            .id,
            .usfm,
            .ide,
            .sts,
            .rem,
            .h,
            .toc,
            .toca,
            // introductions
            .imt,
            .is,
            .ip,
            .ipi,
            .im,
            .imi,
            .ipq,
            .imq,
            .ipr,
            .iq,
            .ib,
            .ili,
            .iot,
            .io,
            .iex,
            .imte,
            .ie,
            // titles, headings, and labels
            .mt,
            .mte,
            .ms,
            .mr,
            .s,
            .sr,
            .r,
            .d,
            .sp,
            .sd,
            // chapters and verses
            .cl,
            .cp,
            .cd,
            // parapgraphs
            .p,
            .m,
            .po,
            .pr,
            .cls,
            .pmo,
            .pm,
            .pmc,
            .pmr,
            .pi,
            .mi,
            .nb,
            .pc,
            .ph,
            .b,
            // poetry
            .q,
            .qr,
            .qc,
            .qa,
            .qm,
            .qd,
            // lists
            .lh,
            .li,
            .lf,
            .lim,
            // tables
            .tr,
            // footnotes (not paragraphs in spec)
            .f,
            .fe,
            // cross references
            .x,
            // spacing and breaks
            .pb,
            // special features
            .fig,
            => true,
            else => false,
        };
    }

    pub fn isInline(self: Tag) bool {
        return switch (self) {
            // introductions
            .ior,
            .iqt,
            // chapters and verses
            .ca,
            .va,
            .vp,
            // poetry
            .qs,
            .qac,
            // lists
            .litl,
            .lik,
            .liv,
            // footnotes
            .f,
            .fe,
            .fv,
            .fdc,
            .fm,
            // cross references
            .x,
            .xop,
            .xot,
            .xnt,
            .xdc,
            .rq,
            // words and characters
            .add,
            .bk,
            .dc,
            .k,
            .nd,
            .ord,
            .pn,
            .png,
            .addpn,
            .qt,
            .sig,
            .sls,
            .tl,
            .wj,
            // character styling
            .em,
            .bd,
            .it,
            .bdit,
            .no,
            .sc,
            .sup,
            // special features
            .fig,
            .ndx,
            .rb,
            .pro,
            .w,
            .wg,
            .wh,
            .wa,
            // linking
            .jmp,
            // milestones
            .@"qt-s",
            .@"ts-s",
            // extended study content
            .ef,
            .ex,
            .cat,
            => true,
            else => false,
        };
    }
};

pub const Token = struct {
    pub const Tag = enum {
        tag_open,
        tag_close,
        text,
        attributes,
    };
    tag: Token.Tag,
    start: usize,
    end: usize,
};

pub const Element = union(enum) {
    node: Node,
    text: []const u8,

    pub const Node = struct {
        pub const Attribute = struct {
            key: []const u8,
            val: []const u8,
        };

        tag: Tag,
        attributes: []const Attribute = &.{},
        children: []const Element = &.{},

        const Self = @This();
        const tab = "  ";

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.attributes);
            for (self.children) |c| c.deinit(allocator);
            allocator.free(self.children);
        }

        fn html2(self: Self, writer: anytype, depth: usize) !void {
            for (0..depth) |_| try writer.writeAll(tab);
            try writer.print("<{s}", .{self.tag});
            for (self.attributes) |a| try writer.print(" {s}=\"{s}\"", .{ a.key, a.val });
            try writer.writeByte('>');
            for (0..depth + 1) |_| try writer.writeAll(tab);
            try writer.print("\"{s}\"", .{self.text});
            for (self.children) |c| {
                try writer.writeByte('\n');
                try c.html2(writer, depth + 1);
            }
            try writer.print("\n</{s}>", .{self.tag});
        }

        pub fn html(self: Self, writer: anytype) !void {
            try self.html2(writer, 0);
        }
    };

    pub fn deinit(self: Element, allocator: std.mem.Allocator) void {
        switch (self) {
            .node => |n| n.deinit(allocator),
            .text => {},
        }
    }
};

test "tag init" {
    const t1 = try Tag.init("\\v");
    try testing.expectEqual(Tag.v, t1);

    const t2 = try Tag.init("\\toc3");
    try testing.expectEqual(Tag{ .toc = 3 }, t2);

    const t3 = try Tag.init("\\ts-s");
    try testing.expectEqual(Tag.@"ts-s", t3);

    const t4 = try Tag.init("\\qt-s");
    try testing.expectEqual(Tag{ .@"qt-s" = 0 }, t4);

    const t5 = try Tag.init("\\qt4-s");
    try testing.expectEqual(Tag{ .@"qt-s" = 4 }, t5);

    const t6 = try Tag.init("\\zaln-s");
    try testing.expectEqual(Tag.@"z-s", t6);
}
