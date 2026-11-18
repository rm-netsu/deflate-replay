//! DRP3: the most compact params format. It keeps the DRP2 record structure
//! but replaces the token coding with an adaptive range coder whose model is
//! driven by predictions computed from the raw data itself:
//!
//!   - the token type (literal / match / end-of-block) is coded with a
//!     context of "does any 3-byte match candidate exist at this position"
//!     (deterministic nearest-first enumeration, see matchfind.zig) and
//!     "was the previous token a literal"; literal VALUES are never stored —
//!     a literal is raw[p] by construction
//!   - for a match, the source position is predicted by walking candidates
//!     nearest-first and asking (arithmetically coded, only at running
//!     maxima of the match extension) "is this candidate the source?".
//!     For greedy/lazy encoders (zlib) the emitted source is always the
//!     nearest candidate whose extension covers the emitted length, so this
//!     usually costs a fraction of a bit
//!   - once the source is confirmed, the length is coded as a delta from the
//!     extension at that candidate (usually zero) plus a one-bit choice
//!     between the two encodings of length 258 (code 285 vs 284+31)
//!   - when the source walk is exhausted without a confirmation, or for
//!     self-contained / --no-rank streams, the token falls back to explicit
//!     coding: length code tree + extra bits, then either the DRP2-style
//!     candidate rank or an explicit distance code
//!
//! Per-block token sections are independent range-coder segments preceded by
//! a uvarint token count and a uvarint segment length. Dynamic headers stay
//! bit-packed exactly as in DRP2. The stream header stores this stream's
//! raw length up front (needed for stream-local predictor bounds).

const std = @import("std");
const bits = @import("bits.zig");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");
const container = @import("container.zig");
const params = @import("params.zig");
const records = @import("records.zig");
const matchfind = @import("matchfind.zig");
const stats = @import("stats.zig");
const rc = @import("rc.zig");

const format_v1 = @import("format/v1.zig");
const format_v3 = @import("format/v3.zig");

pub const Options = stats.Options;
pub const StreamStats = stats.StreamStats;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

// ---------------------------------------------------------------------------
// v1 -> v3 converter
// ---------------------------------------------------------------------------

/// Converts v1 params (as produced by analyzeV1) plus the matching raw data
/// into a DRP3 params file. Patches rank statistics into `res`.
pub fn convert3(
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
    var toks: std.ArrayList(format_v3.EncTok) = .empty;
    defer toks.deinit(gpa);

    try out.writeAll(&format_v3.magic);
    try out.writeByte(3);
    try out.writeByte(0);
    var bw = bits.BitWriter.init(out);

    var raw_base: usize = 0;

    while (!pv.done()) {
        const kind = try pv.nextKind();
        try bw.writeAligned(&[_]u8{kind});

        if (kind == @intFromEnum(container.Kind.trailing)) {
            try records.copyTrailingRecord(&pv, &bw);
            continue;
        }

        const st = &res.streams[pv.stream_no - 1];
        const fdict = try records.copyStreamHeader(&pv, &bw);

        const self_contained = opts.self_contained or fdict;
        const rank_mode = opts.use_rank and !self_contained;
        try bw.writeBit(@intFromBool(self_contained));
        try bw.writeBit(@intFromBool(rank_mode));

        const st_raw_len: usize = @intCast(st.raw_len);
        if (!fdict and raw_base + st_raw_len > raw_bytes.len)
            return records.cvFail(diagnostics, pv.stream_no);
        try params.putUvarint(&bw, st.raw_len);

        matcher.* = matchfind.Matcher.init(.{ .slice = .{
            .data = raw_bytes,
            .base = raw_base,
            .len = st_raw_len,
        } });
        var md: format_v3.Models = undefined;
        md.reset();
        var ctx: format_v3.WalkCtx = .{
            .m = matcher,
            .matcher_active = !self_contained,
            .srclen = st_raw_len,
            .rank_mode = rank_mode,
            .self_contained = self_contained,
        };

        var p: usize = 0;
        blocks: while (true) {
            const bh = try pv.blockHeader();

            if (bh.btype == 0) {
                p += try records.copyStoredBlock(
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

            var dh: ?*const records.DynHdr = null;
            if (bh.btype == 2) dh = try pv.dynHeader();

            const block_start_p = p;
            toks.clearRetainingCapacity();
            while (true) {
                const t = try pv.token(p);
                switch (t) {
                    .literal => |v| {
                        try toks.append(gpa, .{ .kind = .lit, .lit = v.? });
                        p += 1;
                    },
                    .match => |mt| {
                        const mlen: usize = @intCast(mt.length());
                        try toks.append(gpa, .{ .kind = .match, .lcode = mt.lcode, .lextra = mt.lextra, .dist = mt.dist, .len = @intCast(mlen) });
                        p += mlen;
                    },
                    .eob => break,
                }
            }

            try bw.writeBit(@intFromBool(bh.bfinal));
            try bw.writeBits(bh.btype, 2);
            var lit_enc: huffman.Encode = undefined;
            var dist_enc: huffman.Encode = undefined;
            if (bh.btype == 2) {
                try records.emitDynHeader(&bw, dh.?, &lit_enc, &dist_enc);
            }

            try bw.padToBoundary(0);
            try params.putUvarint(&bw, toks.items.len + 1);

            var enc = rc.Encoder.init(gpa);
            defer enc.deinit();
            var pq = block_start_p;
            for (toks.items) |tk| {
                const path = try format_v3.encodeToken(&enc, &md, &ctx, pq, tk);
                if (rank_mode) switch (path) {
                    .src_first, .fb_rank0 => st.dist_rank0 += 1,
                    .src_later, .fb_rank => st.dist_ranked += 1,
                    .fb_escape => st.dist_escaped += 1,
                    else => {},
                };
                pq += switch (tk.kind) {
                    .lit => 1,
                    .match => @intCast(tk.len),
                    .eob => 0,
                };
            }
            _ = try format_v3.encodeToken(
                &enc,
                &md,
                &ctx,
                pq,
                .{ .kind = .eob },
            );
            try enc.flush();

            try params.putUvarint(&bw, enc.out.items.len);
            try bw.writeAligned(enc.out.items);

            if (bh.bfinal) break :blocks;
        }

        try records.copyStreamTrailer(&pv, &bw);
        const v1_raw_len = try pv.rawLen();
        if (v1_raw_len != st.raw_len) return records.cvFail(diagnostics, pv.stream_no);
        if (!self_contained) {
            const crc = std.hash.Crc32.hash(raw_bytes[raw_base..][0..st_raw_len]);
            try bw.writeAligned(&.{
                @truncate(crc),
                @truncate(crc >> 8),
                @truncate(crc >> 16),
                @truncate(crc >> 24),
            });
        }
        // FDICT streams contribute no bytes to the raw file
        if (!fdict) raw_base += st_raw_len;
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "v3 provider rejects bad magic" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};
    try std.testing.expectError(
        error.BadParams,
        format_v3.Provider.init(allocator, "DRP2\x02\x00", null, &diagnostics),
    );
    try std.testing.expectError(
        error.BadParams,
        format_v3.Provider.init(allocator, "DRP3\x04\x00", null, &diagnostics),
    );
}

test "token codec roundtrip: derived literals, src walk, fallbacks" {
    const allocator = std.testing.allocator;
    //      0         1         2         3
    //      0123456789012345678901234567890 1
    const raw_data = "abcdabcd" ++ "efx" ++ "xxxxxx" ++ "abcdefg" ++ "abcdabc";
    var matcher = matchfind.Matcher.init(.{ .slice = .{
        .data = raw_data,
        .base = 0,
        .len = raw_data.len,
    } });

    var md: format_v3.Models = undefined;
    md.reset();
    var ctx: format_v3.WalkCtx = .{
        .m = &matcher,
        .matcher_active = true,
        .srclen = raw_data.len,
        .rank_mode = true,
        .self_contained = false,
    };

    // token plan (positions advance accordingly); every match is valid
    // against this raw data:
    //  p=0..3   literals a b c d
    //  p=4      match len=4 dist=4   (nearest "abcd" candidate j=0)
    //  p=8..10  literals e f x
    //  p=11     match len=6 dist=1   (x-run, manual candidate j=10)
    //  p=17     match len=6 dist=13  ("abcdef" at j=4)
    //  p=23     literal g
    //  p=24     match len=4 dist=20  ("abcd" at j=4)
    //  p=28     match len=3 dist=28  ("abc" at j=0, second-best candidate:
    //                                 the walk confirms j=24 first with the
    //                                 same extension 3, so j=0 is never a
    //                                 running maximum -> fallback rank path)
    const lc3 = tables.lengthCodeOf(3).?;
    const lc4 = tables.lengthCodeOf(4).?;
    const lc6 = tables.lengthCodeOf(6).?;
    const toks = [_]format_v3.EncTok{
        .{ .kind = .lit, .lit = 'a' },
        .{ .kind = .lit, .lit = 'b' },
        .{ .kind = .lit, .lit = 'c' },
        .{ .kind = .lit, .lit = 'd' },
        .{ .kind = .match, .lcode = lc4.lcode, .lextra = lc4.lextra, .dist = 4, .len = 4 },
        .{ .kind = .lit, .lit = 'e' },
        .{ .kind = .lit, .lit = 'f' },
        .{ .kind = .lit, .lit = 'x' },
        .{ .kind = .match, .lcode = lc6.lcode, .lextra = lc6.lextra, .dist = 1, .len = 6 },
        .{ .kind = .match, .lcode = lc6.lcode, .lextra = lc6.lextra, .dist = 13, .len = 6 },
        .{ .kind = .lit, .lit = 'g' },
        .{ .kind = .match, .lcode = lc4.lcode, .lextra = lc4.lextra, .dist = 20, .len = 4 },
        .{ .kind = .match, .lcode = lc3.lcode, .lextra = lc3.lextra, .dist = 28, .len = 3 },
        .{ .kind = .eob },
    };

    var enc = rc.Encoder.init(allocator);
    defer enc.deinit();
    var p: usize = 0;
    for (toks) |t| {
        _ = try format_v3.encodeToken(&enc, &md, &ctx, p, t);
        p += switch (t.kind) {
            .lit => 1,
            .match => @intCast(t.len),
            .eob => 0,
        };
    }
    try enc.flush();
    try std.testing.expect(enc.out.items.len > 0);

    // fresh decode-side state
    var matcher2 = matchfind.Matcher.init(.{ .slice = .{
        .data = raw_data,
        .base = 0,
        .len = raw_data.len,
    } });
    var md2: format_v3.Models = undefined;
    md2.reset();
    var ctx2: format_v3.WalkCtx = .{
        .m = &matcher2,
        .matcher_active = true,
        .srclen = raw_data.len,
        .rank_mode = true,
        .self_contained = false,
    };
    var dec = try rc.Decoder.init(enc.out.items);
    var p2: usize = 0;
    for (toks) |t| {
        const got = try format_v3.decodeToken(&dec, &md2, &ctx2, raw_data, p2);
        switch (t.kind) {
            .lit => {
                try std.testing.expect(got == .literal);
                try std.testing.expectEqual(t.lit, got.literal.?);
                p2 += 1;
            },
            .match => {
                try std.testing.expect(got == .match);
                try std.testing.expectEqual(t.lcode, got.match.lcode);
                try std.testing.expectEqual(t.lextra, got.match.lextra);
                try std.testing.expectEqual(t.dist, got.match.dist);
                p2 += t.len;
            },
            .eob => try std.testing.expect(got == .eob),
        }
    }
    try std.testing.expectEqual(raw_data.len, p2);
}

test "token codec roundtrip: length 258 via code 284 + extra 31" {
    const allocator = std.testing.allocator;
    // 300 bytes with a long run so a 258-match with dist=1 exists
    const raw_data = "ab" ++ "z" ** 298;
    var matcher = matchfind.Matcher.init(.{ .slice = .{
        .data = raw_data,
        .base = 0,
        .len = raw_data.len,
    } });
    var md: format_v3.Models = undefined;
    md.reset();
    var ctx: format_v3.WalkCtx = .{ .m = &matcher, .matcher_active = true, .srclen = raw_data.len, .rank_mode = true, .self_contained = false };
    // match at p=2, len=258, dist=1, deliberately encoded with code 284+31
    const t: format_v3.EncTok = .{ .kind = .match, .lcode = 27, .lextra = 31, .dist = 1, .len = 258 };

    var enc = rc.Encoder.init(allocator);
    defer enc.deinit();
    _ = try format_v3.encodeToken(&enc, &md, &ctx, 2, t);
    try enc.flush();

    var matcher2 = matchfind.Matcher.init(.{ .slice = .{ .data = raw_data, .base = 0, .len = raw_data.len } });
    var md2: format_v3.Models = undefined;
    md2.reset();
    var ctx2: format_v3.WalkCtx = .{ .m = &matcher2, .matcher_active = true, .srclen = raw_data.len, .rank_mode = true, .self_contained = false };
    var dec = try rc.Decoder.init(enc.out.items);
    const got = try format_v3.decodeToken(&dec, &md2, &ctx2, raw_data, 2);
    try std.testing.expect(got == .match);
    try std.testing.expectEqual(@as(u8, 27), got.match.lcode);
    try std.testing.expectEqual(@as(u16, 31), got.match.lextra);
    try std.testing.expectEqual(@as(u32, 1), got.match.dist);
}

test "token codec roundtrip: self-contained explicit coding" {
    const allocator = std.testing.allocator;
    // no raw data at all: matcher inactive, everything explicit
    var matcher = matchfind.Matcher.init(.{ .slice = .{ .data = "", .base = 0, .len = 0 } });
    var md: format_v3.Models = undefined;
    md.reset();
    var ctx: format_v3.WalkCtx = .{ .m = &matcher, .matcher_active = false, .srclen = 6, .rank_mode = false, .self_contained = true };

    const lc3 = tables.lengthCodeOf(3).?;
    const toks = [_]format_v3.EncTok{
        .{ .kind = .lit, .lit = 'h' },
        .{ .kind = .lit, .lit = 'e' },
        .{ .kind = .lit, .lit = 'y' },
        .{ .kind = .match, .lcode = lc3.lcode, .lextra = lc3.lextra, .dist = 3, .len = 3 },
        .{ .kind = .eob },
    };

    var enc = rc.Encoder.init(allocator);
    defer enc.deinit();
    var p: usize = 0;
    for (toks) |t| {
        _ = try format_v3.encodeToken(&enc, &md, &ctx, p, t);
        p += switch (t.kind) {
            .lit => 1,
            .match => @intCast(t.len),
            .eob => 0,
        };
    }
    try enc.flush();

    var md2: format_v3.Models = undefined;
    md2.reset();
    var ctx2: format_v3.WalkCtx = .{ .m = &matcher, .matcher_active = false, .srclen = 6, .rank_mode = false, .self_contained = true };
    var dec = try rc.Decoder.init(enc.out.items);
    var p2: usize = 0;
    for (toks) |t| {
        const got = try format_v3.decodeToken(&dec, &md2, &ctx2, "", p2);
        switch (t.kind) {
            .lit => {
                try std.testing.expectEqual(t.lit, got.literal.?);
                p2 += 1;
            },
            .match => {
                try std.testing.expectEqual(t.dist, got.match.dist);
                try std.testing.expectEqual(t.lcode, got.match.lcode);
                p2 += t.len;
            },
            .eob => try std.testing.expect(got == .eob),
        }
    }
}
