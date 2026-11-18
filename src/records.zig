//! Record-level model shared by replay and dump, the compact DRP2 format
//! (readers for both versions) and the v1 -> v2 converter.
//!
//! DRP2 keeps the v1 record structure but stores far less:
//!   - literal values are taken from the raw data (not stored); FDICT or
//!     --self-contained streams keep them inline ("self-contained" mode)
//!   - tokens are bit-packed: literal = '0', match = '10', end-of-block =
//!     '11' (tag values as writeBits() emits them, LSB-first)
//!   - the length code is written with the block's own literal/length
//!     Huffman code, or as 5 raw bits — whichever is smaller for the block
//!     (per-block "lmode" flag)
//!   - in rank mode a distance is stored as the rank of the actual source
//!     position among all candidate positions in the raw data (nearest
//!     first, see matchfind.zig): '0' rank 0 | '10'+u4 rank 1..16 |
//!     '110'+u9 rank 17..528 | '111' escape (explicit dcode + extra bits)
//!   - dynamic headers are bit-packed (HLIT/HDIST/HCLEN + 3-bit code-length
//!     lengths + the code-length RLE re-coded with its own Huffman code);
//!     stored blocks keep only pad value + LEN (data comes from raw);
//!     NLEN is derived
//!   - the stream trailer stores the container checksum verbatim, raw_len
//!     as a uvarint and, for non-self-contained streams, a CRC32 of the
//!     stream's raw slice so replay can hard-verify the params<->raw pairing

const std = @import("std");
const bits = @import("bits.zig");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");
const container = @import("container.zig");
const params = @import("params.zig");
const matchfind = @import("matchfind.zig");
const stats = @import("stats.zig");

pub const Options = stats.Options;
pub const StreamStats = stats.StreamStats;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const MatchTok = struct {
    /// length code minus 257 (0..28)
    lcode: u8,
    lextra: u16,
    /// 1..32768 when known
    dist: u32 = 0,
    dist_known: bool = true,
    /// v2 rank diagnostics (null when not rank coded)
    rank: ?u16 = null,
    escaped: bool = false,

    pub fn length(self: MatchTok) u32 {
        return @as(u32, tables.length_base[self.lcode]) + self.lextra;
    }
};

pub const Token = union(enum) {
    /// null = raw-derived and no raw data supplied (dump without a raw file)
    literal: ?u8,
    match: MatchTok,
    eob: void,
};

pub const DynHdr = struct {
    hlit: u16,
    hdist: u16,
    hclen: u8,
    /// code-length code lengths in stream permutation order
    cl_stream: [19]u8 = @splat(0),
    rle: [tables.max_code_lengths]tables.RleToken = undefined,
    rle_count: usize = 0,
    /// expanded code lengths (hlit + hdist entries)
    lens: [tables.max_code_lengths]u8 = @splat(0),
};

pub const StreamFlags = struct { self_contained: bool, rank_mode: bool };
pub const StoredBlock = struct { pad: u8, len: u16, data: ?[]const u8 };
pub const BlockHdr = struct { bfinal: bool, btype: u2 };
pub const TrailingRec = struct { count: u64, bytes: []const u8 };

/// Emits a dynamic header to the output stream and builds the token
/// encoders from the expanded code lengths.
pub fn emitDynHeader(
    bw: *bits.BitWriter,
    dh: *const DynHdr,
    lit_enc: *huffman.Encode,
    dist_enc: *huffman.Encode,
) !void {
    try bw.writeBits(@as(u32, dh.hlit) - 257, 5);
    try bw.writeBits(@as(u32, dh.hdist) - 1, 5);
    try bw.writeBits(@as(u32, dh.hclen) - 4, 4);

    var cl_lens: [19]u8 = @splat(0);
    for (dh.cl_stream[0..dh.hclen], 0..) |v, i| {
        try bw.writeBits(v, 3);
        cl_lens[tables.cl_permutation[i]] = v;
    }
    const cl_enc = try huffman.Encode.init(&cl_lens);
    for (dh.rle[0..dh.rle_count]) |t| {
        try cl_enc.write(bw, t.sym);
        switch (t.sym) {
            16 => try bw.writeBits(t.extra, 2),
            17 => try bw.writeBits(t.extra, 3),
            18 => try bw.writeBits(t.extra, 7),
            else => {},
        }
    }
    lit_enc.* = try huffman.Encode.init(dh.lens[0..dh.hlit]);
    dist_enc.* = try huffman.Encode.init(dh.lens[dh.hlit..][0..dh.hdist]);
}

// ---------------------------------------------------------------------------
// shared helpers for the v1 -> v2 / v1 -> v3 converters
// ---------------------------------------------------------------------------

pub fn cvFail(diagnostics: *Diagnostics, stream_no: usize) error{BadParams} {
    diagnostics.set(
        "v1 params/raw data inconsistent in stream {d}",
        .{stream_no},
    );
    return error.BadParams;
}

/// Copies the container framing of the current v1 record (the kind byte
/// itself must already be emitted) and returns whether the stream uses a
/// preset dictionary (zlib FDICT).
pub fn copyStreamHeader(pv: *format_v1.Provider, bw: *bits.BitWriter) !bool {
    var fdict = false;
    switch (pv.kind) {
        @intFromEnum(container.Kind.zlib) => {
            const hdr = try pv.zlibHeader();
            try bw.writeAligned(&hdr);
            fdict = hdr[1] & 0x20 != 0;
            if (fdict) {
                const dict = try pv.fdictId();
                try bw.writeAligned(&dict);
            }
        },
        @intFromEnum(container.Kind.gzip) => {
            const gh = try pv.gzipHeader();
            const lenb = [2]u8{ @truncate(gh.len), @truncate(gh.len >> 8) };
            try bw.writeAligned(&lenb);
            try bw.writeAligned(gh);
        },
        else => {},
    }
    return fdict;
}

/// Verifies a stored block against the raw data (skipped for self-contained
/// streams) and emits the compact stored-block fields. Returns the block
/// length so the caller can advance its raw-position cursor.
pub fn copyStoredBlock(
    pv: *format_v1.Provider,
    bw: *bits.BitWriter,
    bh: BlockHdr,
    raw_bytes: []const u8,
    raw_base: usize,
    p: usize,
    self_contained: bool,
    stream_no: usize,
    diagnostics: *Diagnostics,
) !u16 {
    const sb = try pv.storedBlock(0);
    if (!self_contained) {
        const start = raw_base + p;
        if (start + @as(usize, sb.len) > raw_bytes.len)
            return cvFail(diagnostics, stream_no);
        if (!std.mem.eql(u8, sb.data.?[0..sb.len], raw_bytes[start..][0..sb.len]))
            return cvFail(diagnostics, stream_no);
    }
    try bw.writeBit(@intFromBool(bh.bfinal));
    try bw.writeBits(0, 2);
    try bw.writeBits(sb.pad & 0x7F, 7);
    try params.putUvarint(bw, sb.len);
    if (self_contained) {
        for (sb.data.?[0..sb.len]) |b|
            try bw.writeBits(b, 8);
    }
    return sb.len;
}

/// Emits the verbatim trailing pad bits and the container checksum of the
/// current v1 record.
pub fn copyStreamTrailer(pv: *format_v1.Provider, bw: *bits.BitWriter) !void {
    const pad = try pv.streamTrailingPad();
    try bw.writeBits(pad & 0x7F, 7);
    try bw.padToBoundary(0);

    const cs = try pv.checksumTrailer();
    try bw.writeAligned(cs);
}

/// Copies the verbatim trailing-bytes record (kind 4).
pub fn copyTrailingRecord(pv: *format_v1.Provider, bw: *bits.BitWriter) !void {
    const tr = try pv.trailingRecord();
    try params.putUvarint(bw, tr.count);
    try bw.writeAligned(tr.bytes);
}

// ---------------------------------------------------------------------------
// v1 -> v2 converter
// ---------------------------------------------------------------------------

const TokRec = union(enum) {
    lit: u8,
    match: struct { lcode: u8, lextra: u16, dist: u32, enc: matchfind.DistEncoding },
};

fn putRankVlc(bw: *bits.BitWriter, rank: u16) !void {
    std.debug.assert(rank <= matchfind.max_rank);
    if (rank == 0) return bw.writeBit(0);
    if (rank <= 16) {
        try bw.writeBits(1, 2); // stream bits 1,0
        try bw.writeBits(@as(u32, rank) - 1, 4);
        return;
    }
    try bw.writeBits(3, 3); // stream bits 1,1,0
    try bw.writeBits(@as(u32, rank) - 17, 9);
}

fn putDistFields(bw: *bits.BitWriter, dist: u32) !void {
    const dc = tables.distCodeOf(dist).?;
    try bw.writeBits(dc.code, 5);
    if (tables.dist_extra[dc.code] > 0) {
        try bw.writeBits(dc.extra, tables.dist_extra[dc.code]);
    }
}

fn litLenFor(btype: u2, dh: ?*const DynHdr, lcode: u8) u8 {
    const sym: usize = @as(usize, lcode) + 257;
    return if (btype == 2) dh.?.lens[sym] else tables.fixed_literal_lengths[sym];
}

const format_v1 = @import("format/v1.zig");
const format_v2 = @import("format/v2.zig");

/// Converts v1 params (as produced by analyzeV1) plus the matching raw data
/// into a DRP2 params file. Patches rank statistics into `res`.
pub fn convert(
    gpa: std.mem.Allocator,
    v1_bytes: []const u8,
    raw_bytes: []const u8,
    opts: Options,
    diagnostics: *Diagnostics,
    res: *stats.Result,
    out: *std.Io.Writer,
) !void {
    const pr = format_v1.Reader.init(v1_bytes) catch {
        diagnostics.set("internal: invalid v1 params buffer", .{});
        return error.BadParams;
    };
    var pv = format_v1.Provider.init(pr, diagnostics);
    const matcher = try gpa.create(matchfind.Matcher);
    defer gpa.destroy(matcher);
    var toks: std.ArrayList(TokRec) = .empty;
    defer toks.deinit(gpa);

    try out.writeAll(&format_v2.magic);
    try out.writeByte(2);
    try out.writeByte(0);
    var bw = bits.BitWriter.init(out);

    var raw_base: usize = 0;

    while (!pv.done()) {
        const kind = try pv.nextKind();
        try bw.writeAligned(&[_]u8{kind});

        if (kind == @intFromEnum(container.Kind.trailing)) {
            try copyTrailingRecord(&pv, &bw);
            continue;
        }

        const st = &res.streams[pv.stream_no - 1];
        const fdict = try copyStreamHeader(&pv, &bw);

        const self_contained = opts.self_contained or fdict;
        const rank_mode = opts.use_rank and !self_contained;
        try bw.writeBit(@intFromBool(self_contained));
        try bw.writeBit(@intFromBool(rank_mode));
        if (rank_mode) {
            matcher.reset(.{ .slice = .{ .data = raw_bytes, .base = raw_base, .len = raw_bytes.len - raw_base } });
        }

        var p: usize = 0;
        blocks: while (true) {
            const bh = try pv.blockHeader();

            if (bh.btype == 0) {
                p += try copyStoredBlock(
                    &pv,
                    &bw,
                    bh,
                    raw_bytes,
                    raw_base,
                    p,
                    self_contained,
                    pv.stream_no,
                    diagnostics,
                );
                if (bh.bfinal) break :blocks;
                continue;
            }

            var dh: ?*const DynHdr = null;
            if (bh.btype == 2) dh = try pv.dynHeader();

            toks.clearRetainingCapacity();
            var table_bits: usize = 0;
            var match_count: usize = 0;
            while (true) {
                if (rank_mode) matcher.syncTo(p);
                const t = try pv.token(p);
                switch (t) {
                    .literal => |v| {
                        try toks.append(gpa, .{ .lit = v.? });
                        p += 1;
                    },
                    .match => |mt| {
                        const mlen: usize = @intCast(mt.length());
                        const enc: matchfind.DistEncoding =
                            if (rank_mode)
                                matcher.rankOf(p, mlen, mt.dist)
                            else
                                .escape;
                        if (rank_mode) switch (enc) {
                            .rank => |r| if (r == 0) {
                                st.dist_rank0 += 1;
                            } else {
                                st.dist_ranked += 1;
                            },
                            .escape => st.dist_escaped += 1,
                        };
                        table_bits += litLenFor(bh.btype, dh, mt.lcode);
                        match_count += 1;
                        try toks.append(gpa, .{ .match = .{
                            .lcode = mt.lcode,
                            .lextra = mt.lextra,
                            .dist = mt.dist,
                            .enc = enc,
                        } });
                        p += mlen;
                    },
                    .eob => break,
                }
            }
            const lmode = table_bits < match_count * 5;

            try bw.writeBit(@intFromBool(bh.bfinal));
            try bw.writeBits(bh.btype, 2);
            try bw.writeBit(@intFromBool(lmode));
            var lit_enc: huffman.Encode = undefined;
            var dist_enc: huffman.Encode = undefined;
            if (bh.btype == 2) {
                try emitDynHeader(&bw, dh.?, &lit_enc, &dist_enc);
            } else {
                lit_enc = try huffman.Encode.init(&tables.fixed_literal_lengths);
                dist_enc = try huffman.Encode.init(&tables.fixed_dist_lengths);
            }
            for (toks.items) |tr| {
                switch (tr) {
                    .lit => |v| {
                        try bw.writeBit(0);
                        if (self_contained) try bw.writeBits(v, 8);
                    },
                    .match => |m| {
                        try bw.writeBits(1, 2); // stream bits 1,0
                        if (lmode) {
                            try lit_enc.write(&bw, @as(u16, m.lcode) + 257);
                        } else {
                            try bw.writeBits(m.lcode, 5);
                        }
                        if (tables.length_extra[m.lcode] > 0) {
                            try bw.writeBits(m.lextra, tables.length_extra[m.lcode]);
                        }
                        if (rank_mode) {
                            switch (m.enc) {
                                .rank => |r| try putRankVlc(&bw, r),
                                .escape => {
                                    try bw.writeBits(7, 3); // stream bits 1,1,1
                                    try putDistFields(&bw, m.dist);
                                },
                            }
                        } else {
                            try putDistFields(&bw, m.dist);
                        }
                    },
                }
            }
            try bw.writeBits(3, 2); // end of block
            if (bh.bfinal) break :blocks;
        }

        try copyStreamTrailer(&pv, &bw);
        const raw_len = try pv.rawLen();
        try params.putUvarint(&bw, raw_len);
        if (!self_contained) {
            if (raw_base + @as(usize, @intCast(raw_len)) > raw_bytes.len)
                return cvFail(diagnostics, pv.stream_no);
            const crc = std.hash.Crc32.hash(
                raw_bytes[raw_base..][0..@intCast(raw_len)],
            );
            try bw.writeAligned(&.{
                @truncate(crc),
                @truncate(crc >> 8),
                @truncate(crc >> 16),
                @truncate(crc >> 24),
            });
        }
        // FDICT streams contribute no bytes to the raw file
        if (!fdict) raw_base += @intCast(raw_len);
    }
}

test "v2 provider rejects bad magic" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    try std.testing.expectError(
        error.BadParams,
        format_v2.Provider.init(
            allocator,
            "DRP1\x01\x00",
            null,
            &diagnostics,
        ),
    );
    try std.testing.expectError(
        error.BadParams,
        format_v2.Provider.init(
            allocator,
            "DRP2\x03\x00",
            null,
            &diagnostics,
        ),
    );
}
