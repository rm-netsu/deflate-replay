const std = @import("std");

const container = @import("../container.zig");

const mod_stats = @import("../stats.zig");
const StreamStats = mod_stats.StreamStats;

const fmt_zlib =
    "stream {d}: zlib, header {X:0>2} {X:0>2}, window {d}K, level {s}";
const fmt_gzip =
    "stream {d}: gzip, header {d} bytes ({X:0>2} {X:0>2}...)\n";
const fmt_raw_deflate =
    "stream {d}: raw DEFLATE\n";
const fmt_trailing =
    "trailing: {d} byte(s) reproduced verbatim (not a DEFLATE stream)\n";

pub inline fn zlib(
    stream_idx: usize,
    writer: *std.Io.Writer,
    header: [2]u8,
    stats: *const StreamStats,
) !void {
    try writer.print(
        fmt_zlib,
        .{
            stream_idx,
            header[0],
            header[1],
            stats.window_kb,
            container.flevelName(@intCast(stats.flevel)),
        },
    );
    if (stats.fdict)
        try writer.print(", FDICT (raw output unavailable)", .{});

    try writer.print("\n", .{});
}

pub inline fn gzip(
    stream_idx: usize,
    writer: *std.Io.Writer,
    header: []const u8,
) !void {
    try writer.print(
        fmt_gzip,
        .{ stream_idx, header.len, header[0], header[1] },
    );
}

pub inline fn rawDeflate(stream_idx: usize, writer: *std.Io.Writer) !void {
    try writer.print(fmt_raw_deflate, .{stream_idx});
}

pub inline fn trailing(writer: *std.Io.Writer, len: usize) !void {
    try writer.print(fmt_trailing, .{len});
}
