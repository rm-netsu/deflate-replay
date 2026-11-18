//! Shared option/result types for analyze, replay and dump.

const std = @import("std");
const container = @import("container.zig");

pub const Format = enum {
    auto,
    zlib,
    gzip,
    deflate,
};

pub const ParamsVersion = enum { v1, v2, v3 };

pub const Options = struct {
    format: Format = .auto,
    /// Accept zlib FDICT streams (token extraction works; raw output is not available).
    allow_fdict: bool = false,
    /// Fail hard on unparseable tail instead of recording it verbatim.
    strict_streams: bool = false,
    /// replay(): when false, skip raw-data verification (FDICT escape hatch).
    verify_raw: bool = true,
    /// analyze(): params file format (v3 = range-coded predictions,
    /// default; v2 = bit-packed ranks; v1 = legacy verbose).
    params_version: ParamsVersion = .v3,
    /// analyze(): store literal values and stored-block bytes in the params
    /// instead of deriving them from the raw data at replay time (forced
    /// automatically for FDICT streams).
    self_contained: bool = false,
    /// analyze(): derive distances from raw-data predictions (v2 ranks,
    /// v3 source walk; non-self-contained streams only).
    use_rank: bool = true,
};

pub const ChecksumKind = enum { none, adler, crc };

pub const StreamStats = struct {
    kind: container.Kind = .deflate,
    input_offset: u64 = 0,
    compressed_len: u64 = 0,
    raw_len: u64 = 0,
    blocks: u64 = 0,
    stored_blocks: u64 = 0,
    stored_flush_blocks: u64 = 0,
    fixed_blocks: u64 = 0,
    dynamic_blocks: u64 = 0,
    literals: u64 = 0,
    matches: u64 = 0,
    /// v2 rank statistics (distances stored as the rank of the nearest
    /// candidate in the raw data).
    dist_rank0: u64 = 0,
    dist_ranked: u64 = 0,
    dist_escaped: u64 = 0,
    header_bytes: [2]u8 = .{ 0, 0 },
    fdict: bool = false,
    window_kb: u64 = 0,
    flevel: u8 = 0,
    checksum_kind: ChecksumKind = .none,
    checksum_recorded: u32 = 0,
    checksum_computed: u32 = 0,
    checksum_verified: bool = false,
    isize_recorded: u32 = 0,
    isize_computed: u32 = 0,
    trailing_pad_bits: u8 = 0,
};

pub const Result = struct {
    const Self = @This();

    streams: []StreamStats,
    trailing_bytes: u64 = 0,

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.streams);
        self.* = undefined;
    }

    pub fn totalRaw(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.streams) |s| total += s.raw_len;
        return total;
    }
};
