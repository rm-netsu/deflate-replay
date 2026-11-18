//! replay: .drp params (v1, v2 or v3) + raw data -> bit-identical compressed
//! stream. The version is detected from the file magic; all formats feed
//! the same re-encoder core.

const std = @import("std");
const bits = @import("bits.zig");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");
const container = @import("container.zig");
const params = @import("params.zig");
const records = @import("records.zig");
const compact3 = @import("compact3.zig");
const raw = @import("raw.zig");
const stats = @import("stats.zig");

pub const Options = stats.Options;
pub const Result = stats.Result;
pub const StreamStats = stats.StreamStats;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;

const format_v1 = @import("format/v1.zig");
const format_v2 = @import("format/v2.zig");
const format_v3 = @import("format/v3.zig");

const msg_badparams_magic =
    "not a valid params file (expected DRP1, DRP2 or DRP3 magic)";
const msg_badparams_drp1 =
    "not a valid DRP1 params file ({s})";

pub fn replay(
    gpa: std.mem.Allocator,
    params_bytes: []const u8,
    raw_bytes: []const u8,
    opts: Options,
    diagnostics: *Diagnostics,
    out: *std.Io.Writer,
) !Result {
    if (params_bytes.len < 6) {
        diagnostics.set(msg_badparams_magic, .{});
        return error.BadParams;
    }

    if (std.mem.eql(u8, params_bytes[0..4], &format_v1.magic)) {
        const pr = format_v1.Reader.init(
            params_bytes,
        ) catch |err| {
            diagnostics.set(msg_badparams_drp1, .{@errorName(err)});
            return error.BadParams;
        };

        var pv = format_v1.Provider.init(pr, diagnostics);
        return replayCore(
            gpa,
            format_v1.Provider,
            &pv,
            raw_bytes,
            opts,
            diagnostics,
            out,
        );
    }

    if (std.mem.eql(u8, params_bytes[0..4], &format_v2.magic)) {
        const raw_for_reconstruction: ?[]const u8 =
            if (opts.verify_raw) raw_bytes else null;

        var pv = try format_v2.Provider.init(
            gpa,
            params_bytes,
            raw_for_reconstruction,
            diagnostics,
        );
        defer pv.deinit();
        return replayCore(
            gpa,
            format_v2.Provider,
            pv,
            raw_bytes,
            opts,
            diagnostics,
            out,
        );
    }

    if (std.mem.eql(u8, params_bytes[0..4], &format_v3.magic)) {
        const raw_for_reconstruction: ?[]const u8 =
            if (opts.verify_raw) raw_bytes else null;

        var pv = try format_v3.Provider.init(
            gpa,
            params_bytes,
            raw_for_reconstruction,
            diagnostics,
        );
        defer pv.deinit();
        return replayCore(
            gpa,
            format_v3.Provider,
            pv,
            raw_bytes,
            opts,
            diagnostics,
            out,
        );
    }

    diagnostics.set(msg_badparams_magic, .{});
    return error.BadParams;
}

fn replayCore(
    gpa: std.mem.Allocator,
    comptime TProvider: type,
    provider: *TProvider,
    raw_bytes: []const u8,
    opts: Options,
    diagnostics: *Diagnostics,
    out: *std.Io.Writer,
) !Result {
    var bw = bits.BitWriter.init(out);
    var sink: raw.RawSink = undefined;

    var streams: std.ArrayList(StreamStats) = .empty;
    errdefer streams.deinit(gpa);
    var raw_pos: usize = 0;
    var trailing: u64 = 0;

    while (!provider.done()) {
        const kind = try provider.nextKind();

        if (kind == @intFromEnum(container.Kind.trailing)) {
            const tr = try provider.trailingRecord();
            try bw.writeAligned(tr.bytes);
            trailing += tr.count;
            continue;
        }

        const stream_no = provider.stream_no;
        var st = StreamStats{ .kind = @enumFromInt(kind) };
        const stream_start_bytes = bw.bytes_written;

        switch (kind) {
            @intFromEnum(container.Kind.zlib) => {
                const hdr = try provider.zlibHeader();
                try bw.writeAligned(&hdr);
                st.header_bytes = hdr;
                st.window_kb = (@as(u64, 1) << @intCast((hdr[0] >> 4) + 8)) >> 10;
                st.flevel = hdr[1] >> 6;
                if (hdr[1] & 0x20 != 0) {
                    const dict = try provider.fdictId();
                    try bw.writeAligned(&dict);
                    st.fdict = true;
                }
                st.checksum_kind = .adler;
            },
            @intFromEnum(container.Kind.gzip) => {
                const gh = try provider.gzipHeader();
                try bw.writeAligned(gh);
                st.header_bytes = .{ gh[0], gh[1] };
                st.checksum_kind = .crc;
            },
            @intFromEnum(container.Kind.deflate) => {},
            else => unreachable,
        }

        const flags = try provider.streamFlags();
        if (!flags.self_contained and !opts.verify_raw) {
            diagnostics.set("stream {d}: params store raw-derived literals; the raw file is required (re-analyze with --self-contained for standalone params)", .{stream_no});
            return error.RawRequired;
        }
        // Per-stream verification: FDICT streams have no raw data (their
        // output depends on the preset dictionary) and are reproduced from
        // the params alone; everything else is verified against the raw file.
        const can_verify = opts.verify_raw and !st.fdict;
        sink.start(null, if (can_verify) raw_bytes[raw_pos..] else null);

        blocks: while (true) {
            const bh = try provider.blockHeader();
            try bw.writeBit(@intFromBool(bh.bfinal));
            try bw.writeBits(bh.btype, 2);

            switch (bh.btype) {
                0 => {
                    const sb = try provider.storedBlock(@intCast(sink.head));
                    const data = sb.data orelse {
                        diagnostics.set("stream {d}: stored-block data requires the raw file", .{stream_no});
                        return error.RawRequired;
                    };
                    try bw.padToBoundary(sb.pad);
                    try bw.writeAlignedU16le(sb.len);
                    try bw.writeAlignedU16le(~sb.len);
                    try bw.writeAligned(data);
                    sink.putSlice(data) catch |err| {
                        rawFail(diagnostics, stream_no, &sink);
                        return err;
                    };
                    st.blocks += 1;
                    st.stored_blocks += 1;
                    if (sb.len == 0) st.stored_flush_blocks += 1;
                    if (bh.bfinal) break :blocks;
                },
                1, 2 => {
                    var lit_enc: huffman.Encode = undefined;
                    var dist_enc: huffman.Encode = undefined;
                    if (bh.btype == 2) {
                        const dh = try provider.dynHeader();
                        try records.emitDynHeader(&bw, dh, &lit_enc, &dist_enc);
                        st.dynamic_blocks += 1;
                    } else {
                        lit_enc = try huffman.Encode.init(&tables.fixed_literal_lengths);
                        dist_enc = try huffman.Encode.init(&tables.fixed_dist_lengths);
                        st.fixed_blocks += 1;
                    }
                    while (true) {
                        const t = try provider.token(@intCast(sink.head));
                        switch (t) {
                            .literal => |v_opt| {
                                const v = v_opt orelse {
                                    diagnostics.set("stream {d}: raw-derived literal requires the raw file", .{stream_no});
                                    return error.RawRequired;
                                };
                                lit_enc.write(&bw, v) catch |err| switch (err) {
                                    error.SymbolWithoutCode => {
                                        if (flags.self_contained) {
                                            diagnostics.set("corrupt params: literal {d} has no code in stream {d}", .{ v, stream_no });
                                        } else {
                                            diagnostics.set("stream {d}: raw data mismatch: literal value 0x{X:0>2} from the raw file has no code in this block (wrong raw file?)", .{ stream_no, v });
                                        }
                                        return error.RawMismatch;
                                    },
                                    else => return err,
                                };
                                sink.put(v) catch |err| {
                                    rawFail(diagnostics, stream_no, &sink);
                                    return err;
                                };
                                st.literals += 1;
                            },
                            .match => |mt| {
                                if (!mt.dist_known) {
                                    diagnostics.set("stream {d}: rank-derived distance requires the raw file", .{stream_no});
                                    return error.RawRequired;
                                }
                                if (mt.rank) |r| {
                                    if (r == 0) st.dist_rank0 += 1 else st.dist_ranked += 1;
                                }
                                if (mt.escaped) st.dist_escaped += 1;

                                lit_enc.write(&bw, @as(u16, mt.lcode) + 257) catch |err| switch (err) {
                                    error.SymbolWithoutCode => {
                                        diagnostics.set("corrupt params: length code {d} has no code in stream {d}", .{ @as(u16, mt.lcode) + 257, stream_no });
                                        return error.BadParams;
                                    },
                                    else => return err,
                                };
                                if (tables.length_extra[mt.lcode] > 0) {
                                    try bw.writeBits(mt.lextra, tables.length_extra[mt.lcode]);
                                }
                                const dc = tables.distCodeOf(mt.dist) orelse {
                                    if (mt.rank != null) {
                                        diagnostics.set("stream {d}: raw data mismatch: distance {d} derived from the raw file is invalid (wrong raw file?)", .{ stream_no, mt.dist });
                                        return error.RawMismatch;
                                    }
                                    diagnostics.set("corrupt params: bad distance {d} in stream {d}", .{ mt.dist, stream_no });
                                    return error.BadParams;
                                };
                                dist_enc.write(&bw, dc.code) catch |err| switch (err) {
                                    error.SymbolWithoutCode => {
                                        diagnostics.set("corrupt params: distance code {d} has no code in stream {d}", .{ dc.code, stream_no });
                                        return error.BadParams;
                                    },
                                    else => return err,
                                };
                                if (tables.dist_extra[dc.code] > 0) {
                                    try bw.writeBits(dc.extra, tables.dist_extra[dc.code]);
                                }
                                const len: u32 = @as(u32, tables.length_base[mt.lcode]) + mt.lextra;
                                sink.copyMatch(mt.dist, len) catch |err| {
                                    rawFail(diagnostics, stream_no, &sink);
                                    return err;
                                };
                                st.matches += 1;
                            },
                            .eob => {
                                lit_enc.write(&bw, 256) catch |err| switch (err) {
                                    error.SymbolWithoutCode => {
                                        diagnostics.set(
                                            "corrupt params: end-of-block has no code in stream {d}",
                                            .{stream_no},
                                        );
                                        return error.BadParams;
                                    },
                                    else => return err,
                                };
                                break;
                            },
                        }
                    }
                    st.blocks += 1;
                    if (bh.bfinal) break :blocks;
                },
                else => unreachable,
            }
        }

        const padval = try provider.streamTrailingPad();
        const bits_before = bw.bits_written;
        try bw.padToBoundary(padval);
        st.trailing_pad_bits = @intCast(bw.bits_written - bits_before);

        switch (kind) {
            @intFromEnum(container.Kind.zlib) => {
                const tr = try provider.checksumTrailer();
                try bw.writeAligned(tr);
                st.checksum_recorded = container.be32(tr);
                st.checksum_computed = sink.adler;
                st.checksum_verified = !st.fdict;
            },
            @intFromEnum(container.Kind.gzip) => {
                const tr = try provider.checksumTrailer();
                try bw.writeAligned(tr);
                st.checksum_recorded = container.le32(tr[0..4]);
                st.checksum_computed = sink.crcFinal();
                st.checksum_verified = true;
                st.isize_recorded = container.le32(tr[4..8]);
                st.isize_computed = @truncate(sink.head);
            },
            else => {},
        }

        const raw_len = try provider.rawLen();
        const stored_crc = try provider.rawCrc();
        st.raw_len = raw_len;
        st.compressed_len = bw.bytes_written - stream_start_bytes;
        if (can_verify) {
            // Subtraction form: raw_pos <= raw_bytes.len always holds, and
            // an addition here would overflow-panic on an absurd raw_len
            // from a corrupt params file before the comparison runs.
            if (raw_len > raw_bytes.len - raw_pos) {
                diagnostics.set(
                    "stream {d}: raw data length mismatch (params require {d} bytes, raw provides {d})",
                    .{ stream_no, raw_len, raw_bytes.len - raw_pos },
                );
                return error.RawLengthMismatch;
            }
            if (sink.head != raw_len or sink.expect_pos != raw_len) {
                diagnostics.set(
                    "stream {d}: raw data mismatch at raw offset {d} (bytes regenerated from params differ from the raw file)",
                    .{ stream_no, sink.mismatch_at orelse 0 },
                );
                return error.RawMismatch;
            }
            if (stored_crc) |want| {
                const got = std.hash.Crc32.hash(
                    raw_bytes[raw_pos..][0..@intCast(raw_len)],
                );
                if (got != want) {
                    diagnostics.set(
                        "stream {d}: raw data mismatch: CRC32 of the raw file does not match the params (wrong raw file?)",
                        .{stream_no},
                    );
                    return error.RawMismatch;
                }
            }
            raw_pos += @intCast(raw_len);
        }
        try streams.append(gpa, st);
    }

    if (opts.verify_raw and raw_pos != raw_bytes.len) {
        diagnostics.set(
            "raw file has {d} byte(s) beyond what params describe ({d} consumed)",
            .{ raw_bytes.len - raw_pos, raw_pos },
        );
        return error.RawExtraBytes;
    }

    return .{
        .streams = try streams.toOwnedSlice(gpa),
        .trailing_bytes = trailing,
    };
}

fn rawFail(diagnostics: *Diagnostics, stream_no: usize, sink: *const raw.RawSink) void {
    diagnostics.set(
        "stream {d}: raw data mismatch at raw offset {d} (bytes regenerated from params differ from the raw file)",
        .{ stream_no, sink.mismatch_at orelse 0 },
    );
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn handcraftedV1Params(allocator: std.mem.Allocator) !std.Io.Writer.Allocating {
    var paw: std.Io.Writer.Allocating = .init(allocator);
    const w = &paw.writer;
    try w.writeAll(&format_v1.magic);
    try w.writeByte(1);
    try w.writeByte(format_v1.flags);
    try w.writeByte(@intFromEnum(container.Kind.zlib));
    try w.writeByte(0x78);
    try w.writeByte(0x9c);
    try w.writeByte(1 | 4); // fixed block, BFINAL
    try w.writeByte(params.tok_literal);
    try w.writeByte('h');
    try w.writeByte(params.tok_literal);
    try w.writeByte('i');
    try w.writeByte(params.tok_eob);
    try w.writeByte(0); // trailing pad value
    try w.writeAll(&.{ 0x01, 0x3B, 0x00, 0xD2 }); // Adler-32("hi") big-endian
    try params.putU64le(w, 2);
    return paw;
}

test "v1 replay and analyze roundtrip on handcrafted params" {
    const allocator = std.testing.allocator;
    var paw = try handcraftedV1Params(allocator);
    defer paw.deinit();

    var diagnostics = Diagnostics{};
    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var res = try replay(
        allocator,
        paw.written(),
        "hi",
        .{},
        &diagnostics,
        &out_aw.writer,
    );
    defer res.deinit(allocator);
    try std.testing.expectEqual(
        @as(usize, 1),
        res.streams.len,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        res.streams[0].raw_len,
    );
    try std.testing.expect(
        res.streams[0].checksum_recorded == res.streams[0].checksum_computed,
    );

    var p2: std.Io.Writer.Allocating = .init(allocator);
    defer p2.deinit();
    var r2: std.Io.Writer.Allocating = .init(allocator);
    defer r2.deinit();
    var res2 = try @import("analyze.zig").analyze(
        allocator,
        out_aw.written(),
        .{ .params_version = .v1 },
        &diagnostics,
        &p2.writer,
        &r2.writer,
    );
    defer res2.deinit(allocator);
    try std.testing.expectEqualSlices(
        u8,
        paw.written(),
        p2.written(),
    );
    try std.testing.expectEqualStrings("hi", r2.written());
}

test "v1 replay detects wrong raw data" {
    const allocator = std.testing.allocator;
    var paw: std.Io.Writer.Allocating = .init(allocator);
    defer paw.deinit();
    const w = &paw.writer;
    try w.writeAll(&format_v1.magic);
    try w.writeByte(1);
    try w.writeByte(format_v1.flags);
    try w.writeByte(@intFromEnum(container.Kind.deflate));
    try w.writeByte(1 | 4);
    try w.writeByte(params.tok_literal);
    try w.writeByte('a');
    try w.writeByte(params.tok_eob);
    try w.writeByte(0);
    try params.putU64le(w, 1);

    var diagnostics = Diagnostics{};
    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    try std.testing.expectError(
        error.RawMismatch,
        replay(
            allocator,
            paw.written(),
            "b",
            .{},
            &diagnostics,
            &out_aw.writer,
        ),
    );
    try std.testing.expectEqualStrings(
        "stream 1: raw data mismatch at raw offset 0 (bytes regenerated from params differ from the raw file)",
        diagnostics.get(),
    );
}

test "default (DRP3) roundtrip: analyze -> replay -> analyze is idempotent" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    // build a small zlib stream: fixed block with a match, via v1 handcraft
    var paw: std.Io.Writer.Allocating = .init(allocator);
    defer paw.deinit();
    const w = &paw.writer;
    try w.writeAll(&format_v1.magic);
    try w.writeByte(1);
    try w.writeByte(format_v1.flags);
    try w.writeByte(@intFromEnum(container.Kind.deflate));
    try w.writeByte(1 | 4);
    try w.writeByte(params.tok_literal);
    try w.writeByte('a');
    try w.writeByte(params.tok_literal);
    try w.writeByte('b');
    try w.writeByte(params.tok_match); // len 3 (code 257), dist 2 -> "aba"
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeByte(1);
    try params.putU16le(w, 0);
    try w.writeByte(params.tok_eob);
    try w.writeByte(0);
    try params.putU64le(w, 5);

    var comp_aw: std.Io.Writer.Allocating = .init(allocator);
    defer comp_aw.deinit();
    var res0 = try replay(
        allocator,
        paw.written(),
        "ababa",
        .{},
        &diagnostics,
        &comp_aw.writer,
    );
    defer res0.deinit(allocator);

    // analyze (v3 default) -> params v3 + raw
    var p2: std.Io.Writer.Allocating = .init(allocator);
    defer p2.deinit();
    var raw_aw: std.Io.Writer.Allocating = .init(allocator);
    defer raw_aw.deinit();
    var resa = try @import("analyze.zig").analyze(
        allocator,
        comp_aw.written(),
        .{},
        &diagnostics,
        &p2.writer,
        &raw_aw.writer,
    );
    defer resa.deinit(allocator);
    try std.testing.expectEqualStrings(
        "ababa",
        raw_aw.written(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &format_v3.magic,
        p2.written()[0..4],
    );
    // the match has distance 2 -> nearest candidate -> predicted source
    try std.testing.expectEqual(
        @as(u64, 1),
        resa.streams[0].dist_rank0,
    );

    // replay v3 -> bit-identical stream
    var comp2_aw: std.Io.Writer.Allocating = .init(allocator);
    defer comp2_aw.deinit();
    var resr = try replay(
        allocator,
        p2.written(),
        raw_aw.written(),
        .{},
        &diagnostics,
        &comp2_aw.writer,
    );
    defer resr.deinit(allocator);
    try std.testing.expectEqualSlices(
        u8,
        comp_aw.written(),
        comp2_aw.written(),
    );

    // analyze again -> identical v3 params bytes
    var p3: std.Io.Writer.Allocating = .init(allocator);
    defer p3.deinit();
    var raw3_aw: std.Io.Writer.Allocating = .init(allocator);
    defer raw3_aw.deinit();
    var resb = try @import("analyze.zig").analyze(
        allocator,
        comp2_aw.written(),
        .{},
        &diagnostics,
        &p3.writer,
        &raw3_aw.writer,
    );
    defer resb.deinit(allocator);
    try std.testing.expectEqualSlices(
        u8,
        p2.written(),
        p3.written(),
    );
}

test "v2 wrong raw rejected by CRC" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    // build a real zlib stream for "hi" via the v1 handcraft
    var paw = try handcraftedV1Params(allocator);
    defer paw.deinit();
    var comp_aw: std.Io.Writer.Allocating = .init(allocator);
    defer comp_aw.deinit();
    var res0 = try replay(
        allocator,
        paw.written(),
        "hi",
        .{},
        &diagnostics,
        &comp_aw.writer,
    );
    defer res0.deinit(allocator);

    var p2: std.Io.Writer.Allocating = .init(allocator);
    defer p2.deinit();
    var raw_aw: std.Io.Writer.Allocating = .init(allocator);
    defer raw_aw.deinit();
    var resa = try @import("analyze.zig").analyze(
        allocator,
        comp_aw.written(),
        .{},
        &diagnostics,
        &p2.writer,
        &raw_aw.writer,
    );
    defer resa.deinit(allocator);
    try std.testing.expectEqualStrings("hi", raw_aw.written());

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    try std.testing.expectError(
        error.RawMismatch,
        replay(
            allocator,
            p2.written(),
            "ha",
            .{},
            &diagnostics,
            &out_aw.writer,
        ),
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            diagnostics.get(),
            "mismatch",
        ) != null,
    );
}

test "v2 self-contained replay without raw" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    var paw = try handcraftedV1Params(allocator);
    defer paw.deinit();
    var comp_aw: std.Io.Writer.Allocating = .init(allocator);
    defer comp_aw.deinit();
    var res0 = try replay(
        allocator,
        paw.written(),
        "hi",
        .{},
        &diagnostics,
        &comp_aw.writer,
    );
    defer res0.deinit(allocator);

    var p2: std.Io.Writer.Allocating = .init(allocator);
    defer p2.deinit();
    var raw_aw: std.Io.Writer.Allocating = .init(allocator);
    defer raw_aw.deinit();
    var resa = try @import("analyze.zig").analyze(
        allocator,
        comp_aw.written(),
        .{ .self_contained = true },
        &diagnostics,
        &p2.writer,
        &raw_aw.writer,
    );
    defer resa.deinit(allocator);

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    var resr = try replay(
        allocator,
        p2.written(),
        "",
        .{ .verify_raw = false },
        &diagnostics,
        &out_aw.writer,
    );
    defer resr.deinit(allocator);
    try std.testing.expectEqualSlices(
        u8,
        comp_aw.written(),
        out_aw.written(),
    );
}

test "v2 derived params require raw" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    var paw = try handcraftedV1Params(allocator);
    defer paw.deinit();
    var comp_aw: std.Io.Writer.Allocating = .init(allocator);
    defer comp_aw.deinit();
    var res0 = try replay(
        allocator,
        paw.written(),
        "hi",
        .{},
        &diagnostics,
        &comp_aw.writer,
    );
    defer res0.deinit(allocator);

    var p2: std.Io.Writer.Allocating = .init(allocator);
    defer p2.deinit();
    var raw_aw: std.Io.Writer.Allocating = .init(allocator);
    defer raw_aw.deinit();
    var resa = try @import("analyze.zig").analyze(
        allocator,
        comp_aw.written(),
        .{},
        &diagnostics,
        &p2.writer,
        &raw_aw.writer,
    );
    defer resa.deinit(allocator);

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    try std.testing.expectError(
        error.RawRequired,
        replay(
            allocator,
            p2.written(),
            "",
            .{ .verify_raw = false },
            &diagnostics,
            &out_aw.writer,
        ),
    );
}

test "v2 replay rejects an absurd raw length cleanly" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    // minimal self-contained zlib stream whose raw_len uvarint is maxInt(u64)
    var paw: std.Io.Writer.Allocating = .init(allocator);
    defer paw.deinit();
    try paw.writer.writeAll(&format_v2.magic);
    try paw.writer.writeByte(2);
    try paw.writer.writeByte(0);
    var bw = bits.BitWriter.init(&paw.writer);
    try bw.writeAligned(&[_]u8{@intFromEnum(container.Kind.zlib)});
    try bw.writeAligned(&[_]u8{ 0x78, 0x9c });
    try bw.writeBit(1); // self-contained
    try bw.writeBit(0); // rank mode off
    try bw.writeBit(1); // BFINAL
    try bw.writeBits(0, 2); // stored block
    try bw.writeBits(0, 7); // pad value
    try params.putUvarint(&bw, 0); // LEN
    try bw.writeBits(0, 7); // trailing pad
    try bw.padToBoundary(0);
    try bw.writeAligned(&[_]u8{ 0, 0, 0, 0 }); // Adler-32, verbatim
    try params.putUvarint(&bw, std.math.maxInt(u64)); // absurd raw length

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    try std.testing.expectError(
        error.RawLengthMismatch,
        replay(allocator, paw.written(), "", .{}, &diagnostics, &out_aw.writer),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, diagnostics.get(), "length mismatch") != null,
    );
}

test "v3 replay rejects an absurd raw length cleanly" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};

    // same stream shape in DRP3, where raw_len rides the stream header
    var paw: std.Io.Writer.Allocating = .init(allocator);
    defer paw.deinit();
    try paw.writer.writeAll(&format_v3.magic);
    try paw.writer.writeByte(3);
    try paw.writer.writeByte(0);
    var bw = bits.BitWriter.init(&paw.writer);
    try bw.writeAligned(&[_]u8{@intFromEnum(container.Kind.zlib)});
    try bw.writeAligned(&[_]u8{ 0x78, 0x9c });
    try bw.writeBit(1); // self-contained
    try bw.writeBit(0); // rank mode off
    try params.putUvarint(&bw, std.math.maxInt(u64)); // absurd raw length
    try bw.writeBit(1); // BFINAL
    try bw.writeBits(0, 2); // stored block
    try bw.writeBits(0, 7); // pad value
    try params.putUvarint(&bw, 0); // LEN
    try bw.writeBits(0, 7); // trailing pad
    try bw.padToBoundary(0);
    try bw.writeAligned(&[_]u8{ 0, 0, 0, 0 }); // Adler-32, verbatim

    var out_aw: std.Io.Writer.Allocating = .init(allocator);
    defer out_aw.deinit();
    try std.testing.expectError(
        error.RawLengthMismatch,
        replay(allocator, paw.written(), "", .{}, &diagnostics, &out_aw.writer),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, diagnostics.get(), "length mismatch") != null,
    );
}
