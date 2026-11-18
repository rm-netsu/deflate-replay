const std = @import("std");

const MatchTok = @import("../records.zig").MatchTok;

const fmt_literal_char =
    "    literal 0x{X:0>2} '{c}'\n";
const fmt_literal =
    "    literal 0x{X:0>2}\n";
const fmt_literal_opaque =
    "    literal <from raw>\n";

pub inline fn literal(w: *std.Io.Writer, v_opt: ?u8) !void {
    if (v_opt) |v| {
        if (std.ascii.isPrint(v))
            return w.print(fmt_literal_char, .{ v, v });

        return w.print(fmt_literal, .{v});
    }

    try w.print(fmt_literal_opaque, .{});
}

const fmt_match_known =
    "    match len={d} dist={d}\n";
const fmt_match_rank =
    "    match len={d} dist=rank({d})\n";
const fmt_match_explicit =
    "    match len={d} dist=explicit\n";

pub inline fn match(w: *std.Io.Writer, mt: MatchTok, mlen: u32) !void {
    if (mt.dist_known)
        return w.print(fmt_match_known, .{ mlen, mt.dist });

    if (mt.rank) |r|
        return w.print(fmt_match_rank, .{ mlen, r });

    try w.print(fmt_match_explicit, .{mlen});
}

const fmt_eob =
    "    ... ({d} tokens total)\n";

pub inline fn eob(w: *std.Io.Writer, shown: usize) !void {
    try w.print(fmt_eob, .{shown});
}
