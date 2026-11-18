//! analyze: DEFLATE/zlib/gzip input -> .drp params + raw (inflated) data.
//!
//! Parses at the bit level, recording everything needed for a bit-identical
//! re-encode: container framing, block framing, alignment padding, the exact
//! Huffman table definitions (including how the table itself was RLE-coded),
//! and the full LZ77 tokenization (as emitted codes + extra bits, so even
//! the ambiguous length-258-via-code-284 encoding round-trips exactly).

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

const StreamCtx = struct {
    input: []const u8,
    pos: usize,
    defl_bit_base: u64,
    stream_no: usize,
    opts: Options,
    diagnostics: *Diagnostics,
    pw: *std.Io.Writer,
    raw_out: *std.Io.Writer,
};
const ParsedStream = struct {
    new_pos: usize,
    stats: StreamStats,
};

pub fn analyze(
    gpa: std.mem.Allocator,
    input: []const u8,
    opts: Options,
    diagnostics: *Diagnostics,
    params_out: *std.Io.Writer,
    raw_out: ?*std.Io.Writer,
) !Result {
    // Always parse into v1 records first (battle-tested path), then either
    // emit them verbatim (--v1) or convert to the compact DRP2/DRP3 format.
    var v1aw: std.Io.Writer.Allocating = .init(gpa);
    defer v1aw.deinit();
    var rawaw: std.Io.Writer.Allocating = .init(gpa);
    defer rawaw.deinit();

    var res = try analyzeV1(
        gpa,
        input,
        opts,
        diagnostics,
        &v1aw.writer,
        &rawaw.writer,
    );
    errdefer res.deinit(gpa);

    switch (opts.params_version) {
        .v1 => try params_out.writeAll(v1aw.written()),
        .v2 => try records.convert(
            gpa,
            v1aw.written(),
            rawaw.written(),
            opts,
            diagnostics,
            &res,
            params_out,
        ),
        .v3 => try compact3.convert3(
            gpa,
            v1aw.written(),
            rawaw.written(),
            opts,
            diagnostics,
            &res,
            params_out,
        ),
    }
    if (raw_out) |ro| try ro.writeAll(rawaw.written());
    return res;
}

const format_v1 = @import("format/v1.zig");

fn analyzeV1(
    gpa: std.mem.Allocator,
    input: []const u8,
    opts: Options,
    diagnostics: *Diagnostics,
    params_out: *std.Io.Writer,
    raw_out: *std.Io.Writer,
) !Result {
    try params_out.writeAll(&format_v1.magic);
    try params_out.writeByte(1);
    try params_out.writeByte(format_v1.flags);

    var streams: std.ArrayList(StreamStats) = .empty;
    errdefer streams.deinit(gpa);

    var pos: usize = 0;
    var trailing: u64 = 0;

    while (pos < input.len) {
        var sparams: std.Io.Writer.Allocating = .init(gpa);
        defer sparams.deinit();
        var sraw: std.Io.Writer.Allocating = .init(gpa);
        defer sraw.deinit();

        if (parseOneStream(.{
            .input = input,
            .pos = pos,
            .defl_bit_base = 0,
            .stream_no = streams.items.len + 1,
            .opts = opts,
            .diagnostics = diagnostics,
            .pw = &sparams.writer,
            .raw_out = &sraw.writer,
        })) |parsed| {
            pos = parsed.new_pos;
            try params_out.writeAll(sparams.written());
            try raw_out.writeAll(sraw.written());
            try streams.append(gpa, parsed.stats);
        } else |err| {
            if (err == error.OutOfMemory or err == error.WriteFailed)
                return err;

            if (streams.items.len > 0 and !opts.strict_streams) {
                trailing = input.len - pos;
                try params_out.writeByte(
                    @intFromEnum(container.Kind.trailing),
                );
                try params.putU64le(params_out, trailing);
                try params_out.writeAll(input[pos..]);
                break;
            }
            return err;
        }
    }

    return .{
        .streams = try streams.toOwnedSlice(gpa),
        .trailing_bytes = trailing,
    };
}

fn bitAbs(ctx: *const StreamCtx, br: *const bits.BitReader) u64 {
    return ctx.defl_bit_base + br.bitsConsumed();
}

fn readBitsOrFail(
    ctx: *const StreamCtx,
    br: *bits.BitReader,
    n: u4,
    what: []const u8,
) !u32 {
    return br.readBits(n) catch {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: unexpected end of data in {s}",
            .{ ctx.stream_no, bitAbs(ctx, br), what },
        );
        return error.EndOfStream;
    };
}

fn parseOneStream(ctx_in: StreamCtx) !ParsedStream {
    var ctx = ctx_in;
    var st = StreamStats{ .input_offset = ctx.pos };
    var pos = ctx.pos;

    const kind: container.Kind = switch (ctx.opts.format) {
        .zlib => .zlib,
        .gzip => .gzip,
        .deflate => .deflate,
        .auto => blk: {
            if (container.isGzipMagic(ctx.input[pos..])) break :blk .gzip;
            if (ctx.input.len - pos >= 2 and
                container.isZlibHeader(
                    ctx.input[pos],
                    ctx.input[pos + 1],
                ))
            {
                break :blk .zlib;
            }
            break :blk .deflate;
        },
    };

    var fdict = false;
    st.kind = kind;
    try ctx.pw.writeByte(@intFromEnum(kind));

    switch (kind) {
        .zlib => {
            if (ctx.input.len - pos < 2) {
                ctx.diagnostics.set(
                    "stream {d}: truncated zlib header",
                    .{ctx.stream_no},
                );
                return error.EndOfStream;
            }
            const b0 = ctx.input[pos];
            const b1 = ctx.input[pos + 1];
            if (!container.isZlibHeader(b0, b1)) {
                ctx.diagnostics.set(
                    "stream {d}: invalid zlib header 0x{X:0>2} 0x{X:0>2}",
                    .{ ctx.stream_no, b0, b1 },
                );
                return error.BadZlibHeader;
            }
            try ctx.pw.writeByte(b0);
            try ctx.pw.writeByte(b1);
            st.header_bytes = .{ b0, b1 };
            st.window_kb = (@as(u64, 1) << @intCast((b0 >> 4) + 8)) >> 10;
            st.flevel = b1 >> 6;
            pos += 2;
            fdict = b1 & 0x20 != 0;
            if (fdict) {
                if (!ctx.opts.allow_fdict) {
                    ctx.diagnostics.set(
                        "stream {d}: zlib FDICT (preset dictionary) stream; pass --allow-fdict to extract its tokens",
                        .{ctx.stream_no},
                    );
                    return error.FdictUnsupported;
                }
                if (ctx.input.len - pos < 4) {
                    ctx.diagnostics.set(
                        "stream {d}: truncated FDICT dictionary id",
                        .{ctx.stream_no},
                    );
                    return error.EndOfStream;
                }
                try ctx.pw.writeAll(ctx.input[pos..][0..4]);
                st.fdict = true;
                pos += 4;
            }
            st.checksum_kind = .adler;
        },
        .gzip => {
            const hlen = container.gzipHeaderLength(
                ctx.input[pos..],
            ) catch |err| {
                ctx.diagnostics.set(
                    "stream {d}: bad gzip header ({s})",
                    .{ ctx.stream_no, @errorName(err) },
                );
                return error.BadGzipHeader;
            };
            const hdr = ctx.input[pos..][0..hlen];
            try params.putU16le(ctx.pw, @intCast(hlen));
            try ctx.pw.writeAll(hdr);
            st.header_bytes = .{ hdr[0], hdr[1] };
            pos += hlen;
            st.checksum_kind = .crc;
        },
        .deflate => {},
        .trailing => unreachable,
    }

    ctx.defl_bit_base = @as(u64, pos) << 3;
    var br = bits.BitReader.init(ctx.input[pos..]);
    var sink: raw.RawSink = undefined;
    sink.start(if (fdict) null else ctx.raw_out, null);

    blocks: while (true) {
        const bfinal = br.readBit() catch {
            ctx.diagnostics.set(
                "stream {d}, bit offset {d}: unexpected end of DEFLATE data",
                .{ ctx.stream_no, bitAbs(&ctx, &br) },
            );
            return error.EndOfStream;
        };
        const btype = try readBitsOrFail(
            &ctx,
            &br,
            2,
            "block type",
        );
        try ctx.pw.writeByte(
            @as(u8, @intFromBool(bfinal != 0)) << 2 | @as(u8, @intCast(btype)),
        );

        switch (btype) {
            0 => {
                const pad = br.readPadToBoundary() catch {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: unexpected end of DEFLATE data",
                        .{ ctx.stream_no, bitAbs(&ctx, &br) },
                    );
                    return error.EndOfStream;
                };
                try ctx.pw.writeByte(pad.value);
                const ln = br.readSlice(4) catch {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: truncated stored block header",
                        .{ ctx.stream_no, bitAbs(&ctx, &br) },
                    );
                    return error.EndOfStream;
                };
                const len = container.le16(ln[0..2]);
                const nlen = container.le16(ln[2..4]);
                if (nlen != ~len) {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: stored block NLEN 0x{X:0>4} does not complement LEN 0x{X:0>4}",
                        .{ ctx.stream_no, bitAbs(&ctx, &br), nlen, len },
                    );
                    return error.BadNlen;
                }
                try params.putU16le(ctx.pw, len);
                try params.putU16le(ctx.pw, nlen);
                const data = br.readSlice(len) catch {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: stored block body truncated (LEN={d})",
                        .{ ctx.stream_no, bitAbs(&ctx, &br), len },
                    );
                    return error.EndOfStream;
                };
                try ctx.pw.writeAll(data);
                try sink.putSlice(data);
                st.blocks += 1;
                st.stored_blocks += 1;
                if (len == 0) st.stored_flush_blocks += 1;
                if (bfinal != 0) break :blocks;
            },
            1, 2 => {
                var lit: huffman.Decode = undefined;
                var dist: huffman.Decode = undefined;
                if (btype == 1) {
                    lit = try huffman.Decode.init(&tables.fixed_literal_lengths);
                    dist = try huffman.Decode.init(&tables.fixed_dist_lengths);
                    st.fixed_blocks += 1;
                } else {
                    try parseDynamicHeader(
                        &ctx,
                        &br,
                        &lit,
                        &dist,
                    );
                    st.dynamic_blocks += 1;
                }
                try tokenLoop(
                    &ctx,
                    &br,
                    &sink,
                    &lit,
                    &dist,
                    &st,
                    fdict,
                );
                st.blocks += 1;
                if (bfinal != 0) break :blocks;
            },
            else => {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: reserved block type 3",
                    .{ ctx.stream_no, bitAbs(&ctx, &br) },
                );
                return error.InvalidBlockType;
            },
        }
    }

    const trail_pad = br.readPadToBoundary() catch {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: unexpected end of DEFLATE data",
            .{ ctx.stream_no, bitAbs(&ctx, &br) },
        );
        return error.EndOfStream;
    };
    try ctx.pw.writeByte(trail_pad.value);
    st.trailing_pad_bits = trail_pad.count;

    pos += br.bytesConsumed();

    switch (kind) {
        .zlib => {
            if (ctx.input.len - pos < 4) {
                ctx.diagnostics.set(
                    "stream {d}: truncated zlib stream (Adler-32 missing)",
                    .{ctx.stream_no},
                );
                return error.EndOfStream;
            }
            const ad = ctx.input[pos..][0..4];
            try ctx.pw.writeAll(ad);
            st.checksum_recorded = container.be32(ad);
            st.checksum_computed = sink.adler;
            st.checksum_verified = !fdict;
            pos += 4;
        },
        .gzip => {
            if (ctx.input.len - pos < 8) {
                ctx.diagnostics.set(
                    "stream {d}: truncated gzip stream (CRC32/ISIZE missing)",
                    .{ctx.stream_no},
                );
                return error.EndOfStream;
            }
            const tr = ctx.input[pos..][0..8];
            try ctx.pw.writeAll(tr);
            st.checksum_recorded = container.le32(tr[0..4]);
            st.checksum_computed = sink.crcFinal();
            st.checksum_verified = true;
            st.isize_recorded = container.le32(tr[4..8]);
            st.isize_computed = @truncate(sink.head);
            pos += 8;
        },
        .deflate => {},
        .trailing => unreachable,
    }

    st.raw_len = sink.head;
    st.compressed_len = pos - ctx.pos;
    try params.putU64le(ctx.pw, sink.head);
    return .{ .new_pos = pos, .stats = st };
}

fn parseDynamicHeader(
    ctx: *const StreamCtx,
    br: *bits.BitReader,
    lit: *huffman.Decode,
    dist: *huffman.Decode,
) !void {
    const hlit5 = try readBitsOrFail(ctx, br, 5, "HLIT");
    const hdist5 = try readBitsOrFail(ctx, br, 5, "HDIST");
    const hclen4 = try readBitsOrFail(ctx, br, 4, "HCLEN");
    const hlit: usize = 257 + @as(usize, @intCast(hlit5));
    const hdist: usize = 1 + @as(usize, @intCast(hdist5));
    const hclen: usize = 4 + @as(usize, @intCast(hclen4));
    if (hlit > tables.max_hlit or hdist > tables.max_hdist) {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: too many codes (hlit={d}, hdist={d})",
            .{ ctx.stream_no, bitAbs(ctx, br), hlit, hdist },
        );
        return error.TooManySymbols;
    }

    var cl_lens: [19]u8 = @splat(0);
    var cl_stream: [19]u8 = undefined;
    for (0..hclen) |i| {
        const v = try readBitsOrFail(
            ctx,
            br,
            3,
            "code-length code lengths",
        );
        cl_stream[i] = @intCast(v);
        cl_lens[tables.cl_permutation[i]] = @intCast(v);
    }
    const cl_dec = huffman.Decode.init(&cl_lens) catch {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: over-subscribed code-length code",
            .{ ctx.stream_no, bitAbs(ctx, br) },
        );
        return error.OverSubscribedCode;
    };

    var lens: [tables.max_code_lengths]u8 = undefined;
    var rle: [tables.max_code_lengths]tables.RleToken = undefined;
    var rle_count: usize = 0;
    var idx: usize = 0;
    const total = hlit + hdist;

    while (idx < total) {
        const sym = cl_dec.decode(br) catch |err| switch (err) {
            error.EndOfStream => {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: unexpected end of data in code lengths",
                    .{ ctx.stream_no, bitAbs(ctx, br) },
                );
                return error.EndOfStream;
            },
            error.InvalidCode => {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: invalid code-length code",
                    .{ ctx.stream_no, bitAbs(ctx, br) },
                );
                return error.InvalidCode;
            },
        };
        switch (sym) {
            0...15 => {
                lens[idx] = @intCast(sym);
                idx += 1;
                rle[rle_count] = .{ .sym = @intCast(sym), .extra = 0 };
                rle_count += 1;
            },
            16 => {
                const e = try readBitsOrFail(
                    ctx,
                    br,
                    2,
                    "repeat extra bits",
                );
                const n = 3 + @as(usize, @intCast(e));
                if (idx == 0) {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: code-length repeat with no previous length",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.BadCodeLengthRepeat;
                }
                if (idx + n > total) {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: code-length repeat overflows table",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.BadCodeLengthRepeat;
                }
                const prev = lens[idx - 1];
                @memset(lens[idx..][0..n], prev);
                idx += n;
                rle[rle_count] = .{ .sym = 16, .extra = @intCast(e) };
                rle_count += 1;
            },
            17 => {
                const e = try readBitsOrFail(
                    ctx,
                    br,
                    3,
                    "zero-run extra bits",
                );
                const n = 3 + @as(usize, @intCast(e));
                if (idx + n > total) {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: code-length run overflows table",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.BadCodeLengthRepeat;
                }
                @memset(lens[idx..][0..n], 0);
                idx += n;
                rle[rle_count] = .{ .sym = 17, .extra = @intCast(e) };
                rle_count += 1;
            },
            18 => {
                const e = try readBitsOrFail(
                    ctx,
                    br,
                    7,
                    "zero-run extra bits",
                );
                const n = 11 + @as(usize, @intCast(e));
                if (idx + n > total) {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: code-length run overflows table",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.BadCodeLengthRepeat;
                }
                @memset(lens[idx..][0..n], 0);
                idx += n;
                rle[rle_count] = .{ .sym = 18, .extra = @intCast(e) };
                rle_count += 1;
            },
            else => unreachable,
        }
    }

    if (lens[256] == 0) {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: dynamic block has no end-of-block code",
            .{ ctx.stream_no, bitAbs(ctx, br) },
        );
        return error.MissingEndOfBlockCode;
    }
    lit.* = huffman.Decode.init(lens[0..hlit]) catch {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: over-subscribed literal/length code set",
            .{ ctx.stream_no, bitAbs(ctx, br) },
        );
        return error.OverSubscribedCode;
    };
    dist.* = huffman.Decode.init(lens[hlit..][0..hdist]) catch {
        ctx.diagnostics.set(
            "stream {d}, bit offset {d}: over-subscribed distance code set",
            .{ ctx.stream_no, bitAbs(ctx, br) },
        );
        return error.OverSubscribedCode;
    };

    try params.putU16le(ctx.pw, @intCast(hlit));
    try params.putU16le(ctx.pw, @intCast(hdist));
    try ctx.pw.writeByte(@intCast(hclen));
    try ctx.pw.writeAll(cl_stream[0..hclen]);
    try params.putU16le(ctx.pw, @intCast(rle_count));
    for (rle[0..rle_count]) |t| {
        try ctx.pw.writeByte(t.sym);
        try ctx.pw.writeByte(t.extra);
    }
}

fn tokenLoop(
    ctx: *const StreamCtx,
    br: *bits.BitReader,
    sink: *raw.RawSink,
    lit: *const huffman.Decode,
    dist: *const huffman.Decode,
    st: *StreamStats,
    fdict: bool,
) !void {
    while (true) {
        const sym = lit.decode(br) catch |err| switch (err) {
            error.EndOfStream => {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: unexpected end of data in literal/length code",
                    .{ ctx.stream_no, bitAbs(ctx, br) },
                );
                return error.EndOfStream;
            },
            error.InvalidCode => {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: invalid literal/length code",
                    .{ ctx.stream_no, bitAbs(ctx, br) },
                );
                return error.InvalidLengthCode;
            },
        };

        if (sym < 256) {
            const b: u8 = @intCast(sym);
            try ctx.pw.writeByte(params.tok_literal);
            try ctx.pw.writeByte(b);
            try sink.put(b);
            st.literals += 1;
        } else if (sym == 256) {
            try ctx.pw.writeByte(params.tok_eob);
            return;
        } else if (sym <= 285) {
            const li: usize = sym - 257;
            var lextra: u32 = 0;
            if (tables.length_extra[li] > 0) {
                lextra = try readBitsOrFail(
                    ctx,
                    br,
                    tables.length_extra[li],
                    "length extra bits",
                );
            }
            const dsym = dist.decode(br) catch |err| switch (err) {
                error.EndOfStream => {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: unexpected end of data in distance code",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.EndOfStream;
                },
                error.InvalidCode => {
                    ctx.diagnostics.set(
                        "stream {d}, bit offset {d}: invalid distance code",
                        .{ ctx.stream_no, bitAbs(ctx, br) },
                    );
                    return error.InvalidDistanceCode;
                },
            };
            if (dsym > 29) {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: invalid distance code {d}",
                    .{ ctx.stream_no, bitAbs(ctx, br), dsym },
                );
                return error.InvalidDistanceCode;
            }
            const di: usize = dsym;
            var dextra: u32 = 0;
            if (tables.dist_extra[di] > 0) {
                dextra = try readBitsOrFail(
                    ctx,
                    br,
                    tables.dist_extra[di],
                    "distance extra bits",
                );
            }
            const length: u32 = @as(u32, tables.length_base[li]) + lextra;
            const distance: u32 = @as(u32, tables.dist_base[di]) + dextra;
            if (!fdict and distance > sink.head) {
                ctx.diagnostics.set(
                    "stream {d}, bit offset {d}: distance {d} too far back ({d} byte(s) available)",
                    .{
                        ctx.stream_no,
                        bitAbs(ctx, br),
                        distance,
                        sink.head,
                    },
                );
                return error.DistanceTooFarBack;
            }
            try ctx.pw.writeByte(params.tok_match);
            try ctx.pw.writeByte(@intCast(sym - 257));
            try ctx.pw.writeByte(@intCast(lextra));
            try ctx.pw.writeByte(@intCast(dsym));
            try params.putU16le(ctx.pw, @intCast(dextra));
            try sink.copyMatch(distance, length);
            st.matches += 1;
        } else {
            ctx.diagnostics.set(
                "stream {d}, bit offset {d}: invalid literal/length code {d}",
                .{ ctx.stream_no, bitAbs(ctx, br), sym },
            );
            return error.InvalidLengthCode;
        }
    }
}
