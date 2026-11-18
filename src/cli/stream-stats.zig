const std = @import("std");
const drp = @import("main.zig").drp;

pub fn printStreamStats(
    out: *std.Io.Writer,
    stream_idx: usize,
    stats: drp.StreamStats,
) !void {
    switch (stats.kind) {
        .zlib => try out.print(
            "  stream {d}: zlib, header {X:0>2} {X:0>2}, window {d}K, level {s}\n",
            .{
                stream_idx,
                stats.header_bytes[0],
                stats.header_bytes[1],
                stats.window_kb,
                drp.container.flevelName(@intCast(stats.flevel)),
            },
        ),
        .gzip => try out.print(
            "  stream {d}: gzip\n",
            .{stream_idx},
        ),
        .deflate => try out.print(
            "  stream {d}: raw DEFLATE\n",
            .{stream_idx},
        ),
        .trailing => unreachable,
    }

    try out.print(
        "    blocks: {d} (dynamic {d}, fixed {d}, stored {d}",
        .{
            stats.blocks,
            stats.dynamic_blocks,
            stats.fixed_blocks,
            stats.stored_blocks,
        },
    );
    if (stats.stored_flush_blocks > 0) {
        try out.print(
            ", {d} empty flush",
            .{stats.stored_flush_blocks},
        );
    }
    try out.print(")\n", .{});

    try out.print(
        "    tokens: {d} literals, {d} matches\n",
        .{ stats.literals, stats.matches },
    );

    if (stats.dist_rank0 + stats.dist_ranked + stats.dist_escaped > 0) {
        try out.print(
            "    distances: {d} rank-0, {d} ranked, {d} escaped\n",
            .{ stats.dist_rank0, stats.dist_ranked, stats.dist_escaped },
        );
    }

    try out.print("    raw: {d} bytes\n", .{stats.raw_len});

    if (stats.fdict) {
        try out.print(
            "    FDICT stream: raw output unavailable (dictionary not present)\n",
            .{},
        );
    }

    switch (stats.checksum_kind) {
        .adler => try printChecksumLine(out, "adler32", stats),
        .crc => {
            try printChecksumLine(out, "crc32", stats);
            try out.print(
                "    isize: recorded {d}, computed {d}, {s}\n",
                .{
                    stats.isize_recorded, stats.isize_computed,
                    if (stats.isize_recorded == stats.isize_computed)
                        "::ss1a match"
                    else
                        "::ss1b MISMATCH (reproduced verbatim)",
                },
            );
        },
        .none => {},
    }
}

fn printChecksumLine(
    out: *std.Io.Writer,
    name: []const u8,
    stats: drp.StreamStats,
) !void {
    if (!stats.checksum_verified) {
        try out.print(
            "    {s}: recorded 0x{X:0>8} (not verified: FDICT)\n",
            .{ name, stats.checksum_recorded },
        );
        return;
    }

    if (stats.checksum_recorded == stats.checksum_computed) {
        try out.print(
            "    {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, match\n",
            .{ name, stats.checksum_recorded, stats.checksum_computed },
        );
        return;
    }

    try out.print(
        "    {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, MISMATCH (reproduced verbatim)\n",
        .{ name, stats.checksum_recorded, stats.checksum_computed },
    );
}
