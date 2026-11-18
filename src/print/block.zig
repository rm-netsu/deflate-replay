const std = @import("std");

const StoredBlock = @import("../records.zig").StoredBlock;
const DynHdr = @import("../records.zig").DynHdr;

const fmt_stored =
    "  block {d}: stored, len={d}{s}{s}\n";
const fmt_fixed =
    "  block {d}: fixed{s}\n";
const fmt_dynamic =
    "  block {d}: dynamic, hlit={d} hdist={d} hclen={d}{s}\n";

pub inline fn stored(
    block_idx: usize,
    writer: *std.Io.Writer,
    is_final: bool,
    sb: *const StoredBlock,
) !void {
    try writer.print(
        fmt_stored,
        .{
            block_idx,
            sb.len,
            if (sb.len == 0) " (flush marker)" else "",
            if (is_final) ", final" else "",
        },
    );
}

pub inline fn fixed(
    block_idx: usize,
    writer: *std.Io.Writer,
    is_final: bool,
) !void {
    try writer.print(
        fmt_fixed,
        .{ block_idx, if (is_final) ", final" else "" },
    );
}

pub inline fn dynamic(
    block_idx: usize,
    writer: *std.Io.Writer,
    is_final: bool,
    dh: *const DynHdr,
) !void {
    try writer.print(
        fmt_dynamic,
        .{
            block_idx,
            dh.hlit,
            dh.hdist,
            dh.hclen,
            if (is_final) ", final" else "",
        },
    );
}
