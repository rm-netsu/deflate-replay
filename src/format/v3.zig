const std = @import("std");
const bits = @import("../bits.zig");
const matchfind = @import("../matchfind.zig");
const tables = @import("../tables.zig");
const huffman = @import("../huffman.zig");
const container = @import("../container.zig");

const params = @import("../params.zig");

const Diagnostics = @import("../diagnostics.zig").Diagnostics;

const DynHdr = @import("../records.zig").DynHdr;
const StreamFlags = @import("../records.zig").StreamFlags;
const BlockHdr = @import("../records.zig").BlockHdr;
const StoredBlock = @import("../records.zig").StoredBlock;
const Token = @import("../records.zig").Token;
const TrailingRec = @import("../records.zig").TrailingRec;

pub const magic = [4]u8{ 'D', 'R', 'P', '3' };

/// Chain-visit budget for the "candidate exists" context feature.
const exist_hops = 64;
/// Safety chain budget for the source walk.
const src_hops = matchfind.max_hops;
/// Candidate budget for the source walk.
const src_candidates = 64;

pub const Provider = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    br: bits.BitReader,
    diagnostics: *Diagnostics,
    /// raw file, when available for reconstruction
    raw: ?[]const u8,
    stream_no: usize = 0,
    kind: u8 = 0,
    // per-stream state
    self_contained: bool = false,
    rank_mode: bool = false,
    fdict: bool = false,
    raw_base: usize = 0,
    raw_len_stored: u64 = 0,
    srclen: usize = 0,
    raw_loc: []const u8 = &.{},
    matcher: matchfind.Matcher,
    ctx: WalkCtx = undefined,
    md: Models = undefined,
    // per-block token section state
    seg_count: usize = 0,
    tokens_left: usize = 0,
    dec: rc.Decoder = undefined,
    // scratch
    dyn: DynHdr = .{
        .hlit = tables.min_hlit,
        .hdist = 1,
        .hclen = 4,
    },
    cl_dec: huffman.Decode = undefined,
    stored_buf: [65535]u8 = undefined,

    pub fn init(
        gpa: std.mem.Allocator,
        params_bytes: []const u8,
        raw: ?[]const u8,
        diagnostics: *Diagnostics,
    ) !*Self {
        if (params_bytes.len < 6 or
            !std.mem.eql(u8, params_bytes[0..4], &magic) or
            params_bytes[4] != 3 or
            params_bytes[5] != 0)
        {
            diagnostics.set("not a valid DRP3 params file", .{});
            return error.BadParams;
        }
        const self = try gpa.create(Self);
        self.* = .{
            .gpa = gpa,
            .br = .{
                .data = params_bytes,
                .bitpos = 48,
            },
            .diagnostics = diagnostics,
            .raw = raw,
            .matcher = undefined,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.gpa.destroy(self);
    }

    fn bad(
        self: *Self,
        comptime fmt: []const u8,
        args: anytype,
    ) error{BadParams} {
        self.diagnostics.set("corrupt params: " ++ fmt, args);
        return error.BadParams;
    }

    pub fn done(self: *const Self) bool {
        return self.br.bitpos >= @as(u64, self.br.data.len) << 3;
    }

    pub fn nextKind(self: *Self) !u8 {
        self.br.alignToByte();
        const k = self.br.readBits(8) catch
            return self.bad("unexpected end of file", .{});
        const kb: u8 = @intCast(k);
        if (kb < 1 or kb > 4)
            return self.bad("bad record kind {d}", .{kb});
        self.kind = kb;
        self.fdict = false;
        if (kb != 4) self.stream_no += 1;
        return kb;
    }

    pub fn zlibHeader(self: *Self) ![2]u8 {
        const s = self.br.readSlice(2) catch
            return self.bad(
                "zlib header missing in stream {d}",
                .{self.stream_no},
            );
        self.fdict = s[1] & 0x20 != 0;
        return .{ s[0], s[1] };
    }

    pub fn fdictId(self: *Self) ![4]u8 {
        const d = self.br.readSlice(4) catch
            return self.bad(
                "FDICT id missing in stream {d}",
                .{self.stream_no},
            );
        return d[0..4].*;
    }

    pub fn gzipHeader(self: *Self) ![]const u8 {
        const s = self.br.readSlice(2) catch
            return self.bad(
                "gzip header missing in stream {d}",
                .{self.stream_no},
            );
        const hlen = container.le16(s);
        if (hlen < 10)
            return self.bad(
                "gzip header too short in stream {d} ({d} bytes)",
                .{ self.stream_no, hlen },
            );
        return self.br.readSlice(hlen) catch
            return self.bad(
                "gzip header truncated in stream {d}",
                .{self.stream_no},
            );
    }

    pub fn streamFlags(self: *Self) !StreamFlags {
        const sc = self.br.readBit() catch return self.bad(
            "stream flags missing",
            .{},
        );
        const rm = self.br.readBit() catch return self.bad(
            "stream flags missing",
            .{},
        );
        const raw_len = params.getUvarint(&self.br) catch
            return self.bad(
                "raw length record missing in stream {d}",
                .{self.stream_no},
            );
        self.self_contained = sc != 0;
        self.rank_mode = rm != 0;
        self.raw_len_stored = raw_len;
        if (self.rank_mode and self.self_contained)
            return self.bad(
                "rank mode with self-contained stream {d}",
                .{self.stream_no},
            );

        self.srclen = @intCast(raw_len);
        self.raw_loc = &.{};
        if (self.raw) |rw| {
            // Self-contained streams (FDICT) keep the stored length: their
            // output is not part of the raw file. Everything else is clamped
            // to what the raw file actually provides (corrupt-raw safety).
            if (!self.self_contained) {
                const avail = rw.len -| self.raw_base;
                self.srclen = @min(self.srclen, avail);
                self.raw_loc = rw[self.raw_base..][0..self.srclen];
            }
        }
        if (!self.self_contained and self.raw != null) {
            self.matcher.reset(.{ .slice = .{ .data = self.raw.?, .base = self.raw_base, .len = self.srclen } });
        }
        self.md.reset();
        self.ctx = .{
            .m = &self.matcher,
            .matcher_active = !self.self_contained and self.raw != null,
            .srclen = self.srclen,
            .rank_mode = self.rank_mode,
            .self_contained = self.self_contained,
        };
        self.tokens_left = 0;
        self.seg_count = 0;
        return .{ .self_contained = self.self_contained, .rank_mode = self.rank_mode };
    }

    pub fn blockHeader(self: *Self) !BlockHdr {
        const bfinal = self.br.readBit() catch return self.bad(
            "block header truncated",
            .{},
        );
        const btype_raw = self.br.readBits(2) catch return self.bad(
            "block header truncated",
            .{},
        );
        const btype: u2 = @intCast(btype_raw);
        if (btype == 3)
            return self.bad(
                "reserved block type 3 in stream {d}",
                .{self.stream_no},
            );
        if (btype == 1) try self.readTokenSection();
        return .{ .bfinal = bfinal != 0, .btype = btype };
    }

    fn readTokenSection(self: *Self) !void {
        self.br.alignToByte();
        const count = params.getUvarint(&self.br) catch
            return self.bad(
                "token section truncated in stream {d}",
                .{self.stream_no},
            );
        const rc_len = params.getUvarint(&self.br) catch
            return self.bad(
                "token section truncated in stream {d}",
                .{self.stream_no},
            );
        if (rc_len > self.br.data.len)
            return self.bad(
                "token section too large in stream {d}",
                .{self.stream_no},
            );
        const seg = self.br.readSlice(@intCast(rc_len)) catch
            return self.bad(
                "token section truncated in stream {d}",
                .{self.stream_no},
            );
        self.seg_count = @intCast(count);
        self.tokens_left = @intCast(count);
        self.dec = rc.Decoder.init(seg) catch
            return self.bad(
                "bad range-coded segment in stream {d}",
                .{self.stream_no},
            );
    }

    pub fn dynHeader(self: *Self) !*const DynHdr {
        const hlit5 = self.br.readBits(5) catch return self.badDyn();
        const hdist5 = self.br.readBits(5) catch return self.badDyn();
        const hclen4 = self.br.readBits(4) catch return self.badDyn();
        const hlit: usize = 257 + @as(usize, @intCast(hlit5));
        const hdist: usize = 1 + @as(usize, @intCast(hdist5));
        const hclen: usize = 4 + @as(usize, @intCast(hclen4));
        if (hlit > tables.max_hlit or hdist > tables.max_hdist)
            return self.bad(
                "too many codes in stream {d} (hlit={d}, hdist={d})",
                .{ self.stream_no, hlit, hdist },
            );

        const d = &self.dyn;
        d.hlit = @intCast(hlit);
        d.hdist = @intCast(hdist);
        d.hclen = @intCast(hclen);
        d.rle_count = 0;

        var cl_lens: [19]u8 = @splat(0);
        for (0..hclen) |i| {
            const v = self.br.readBits(3) catch return self.badDyn();
            d.cl_stream[i] = @intCast(v);
            cl_lens[tables.cl_permutation[i]] = @intCast(v);
        }
        self.cl_dec = huffman.Decode.init(&cl_lens) catch
            return self.bad(
                "over-subscribed code-length code in stream {d}",
                .{self.stream_no},
            );

        var idx: usize = 0;
        const total = hlit + hdist;
        while (idx < total) {
            const sym = self.cl_dec.decode(&self.br) catch
                return self.bad(
                    "bad code-length code in stream {d}",
                    .{self.stream_no},
                );
            switch (sym) {
                0...15 => {
                    d.lens[idx] = @intCast(sym);
                    idx += 1;
                    d.rle[d.rle_count] = .{
                        .sym = @intCast(sym),
                        .extra = 0,
                    };
                    d.rle_count += 1;
                },
                16 => {
                    const e = self.br.readBits(2) catch return self.badDyn();
                    const n = 3 + @as(usize, @intCast(e));
                    if (idx == 0 or idx + n > total)
                        return self.bad(
                            "bad code-length repeat in stream {d}",
                            .{self.stream_no},
                        );
                    @memset(d.lens[idx..][0..n], d.lens[idx - 1]);
                    idx += n;
                    d.rle[d.rle_count] = .{ .sym = 16, .extra = @intCast(e) };
                    d.rle_count += 1;
                },
                17 => {
                    const e = self.br.readBits(3) catch return self.badDyn();
                    const n = 3 + @as(usize, @intCast(e));
                    if (idx + n > total)
                        return self.bad(
                            "bad code-length run in stream {d}",
                            .{self.stream_no},
                        );
                    @memset(d.lens[idx..][0..n], 0);
                    idx += n;
                    d.rle[d.rle_count] = .{ .sym = 17, .extra = @intCast(e) };
                    d.rle_count += 1;
                },
                18 => {
                    const e = self.br.readBits(7) catch return self.badDyn();
                    const n = 11 + @as(usize, @intCast(e));
                    if (idx + n > total)
                        return self.bad("bad code-length run in stream {d}", .{self.stream_no});
                    @memset(d.lens[idx..][0..n], 0);
                    idx += n;
                    d.rle[d.rle_count] = .{ .sym = 18, .extra = @intCast(e) };
                    d.rle_count += 1;
                },
                else => return self.bad("bad code-length symbol {d} in stream {d}", .{ sym, self.stream_no }),
            }
        }

        if (d.lens[256] == 0)
            return self.bad("dynamic block has no end-of-block code in stream {d}", .{self.stream_no});
        _ = huffman.Encode.init(d.lens[0..hlit]) catch
            return self.bad("bad literal/length code set in stream {d}", .{self.stream_no});
        _ = huffman.Encode.init(d.lens[hlit..][0..hdist]) catch
            return self.bad("bad distance code set in stream {d}", .{self.stream_no});
        try self.readTokenSection();
        return d;
    }

    fn badDyn(self: *Self) error{BadParams} {
        return self.bad(
            "dynamic header truncated in stream {d}",
            .{self.stream_no},
        );
    }

    pub fn storedBlock(self: *Self, p: usize) !StoredBlock {
        const pad = self.br.readBits(7) catch
            return self.bad(
                "stored block truncated in stream {d}",
                .{self.stream_no},
            );
        const len = params.getUvarint(&self.br) catch
            return self.bad(
                "stored block truncated in stream {d}",
                .{self.stream_no},
            );
        if (len > 65535)
            return self.bad(
                "stored block LEN too large in stream {d}",
                .{self.stream_no},
            );
        if (self.self_contained) {
            for (self.stored_buf[0..@intCast(len)]) |*b| {
                b.* = @intCast(
                    self.br.readBits(8) catch
                        return self.bad(
                            "stored block truncated in stream {d}",
                            .{self.stream_no},
                        ),
                );
            }
            return .{
                .pad = @intCast(pad),
                .len = @intCast(len),
                .data = self.stored_buf[0..@intCast(len)],
            };
        }
        if (self.raw) |rw| {
            const base = self.raw_base + p;
            if (base + @as(usize, @intCast(len)) > rw.len)
                return self.bad(
                    "raw data too short for stored block in stream {d}",
                    .{self.stream_no},
                );
            return .{
                .pad = @intCast(pad),
                .len = @intCast(len),
                .data = rw[base..][0..@intCast(len)],
            };
        }
        return .{
            .pad = @intCast(pad),
            .len = @intCast(len),
            .data = null,
        };
    }

    pub fn token(self: *Self, p: usize) !Token {
        if (self.tokens_left == 0)
            return self.bad(
                "token count exceeded in stream {d}",
                .{self.stream_no},
            );
        if (!self.self_contained and self.raw == null)
            return self.bad(
                "DRP3 token decoding in stream {d} requires the raw file",
                .{self.stream_no},
            );
        const t = decodeToken(&self.dec, &self.md, &self.ctx, self.raw_loc, p) catch |err|
            return self.bad(
                "bad token stream in stream {d} ({s})",
                .{ self.stream_no, @errorName(err) },
            );
        self.tokens_left -= 1;
        if (t == .eob and self.tokens_left != 0)
            return self.bad(
                "token count mismatch in stream {d}",
                .{self.stream_no},
            );
        return t;
    }

    pub fn streamTrailingPad(self: *Self) !u8 {
        const v = self.br.readBits(7) catch
            return self.bad(
                "stream {d} pad record missing",
                .{self.stream_no},
            );
        return @intCast(v);
    }

    pub fn checksumTrailer(self: *Self) ![]const u8 {
        self.br.alignToByte();
        const n: usize = switch (self.kind) {
            1 => 4,
            2 => 8,
            else => 0,
        };
        if (n == 0) return &[_]u8{};
        return self.br.readSlice(n) catch
            self.bad(
                "checksum record missing in stream {d}",
                .{self.stream_no},
            );
    }

    pub fn rawLen(self: *Self) !u64 {
        // The raw length is stored in the stream header (predictor bounds);
        // only the raw-file cursor advances here. Saturating add: replayCore
        // bounds-checks the stream against the actual raw file, so an absurd
        // stored length must fail cleanly instead of overflowing here.
        if (!self.fdict) self.raw_base +|= @intCast(self.raw_len_stored);
        return self.raw_len_stored;
    }

    pub fn rawCrc(self: *Self) !?u32 {
        if (self.self_contained) return null;
        self.br.alignToByte();
        const s = self.br.readSlice(4) catch
            return self.bad(
                "raw CRC record missing in stream {d}",
                .{self.stream_no},
            );
        return container.le32(s);
    }

    pub fn trailingRecord(self: *Self) !TrailingRec {
        self.br.alignToByte();
        const n = params.getUvarint(&self.br) catch
            return self.bad("trailing record truncated", .{});
        const b = self.br.readSlice(@intCast(n)) catch
            return self.bad("trailing record truncated", .{});
        return .{ .count = n, .bytes = b };
    }

    // dump support (duck-typed alongside V1Provider/V2Provider)
    pub fn undecodableTokens(self: *const Self) bool {
        return !self.self_contained and self.raw == null;
    }

    pub fn segTokenCount(self: *const Self) ?usize {
        return self.seg_count;
    }
};

/// Per-stream codec state. `m` must point at the matcher; the raw view and
/// flags describe the stream being coded.
pub const WalkCtx = struct {
    m: *matchfind.Matcher,
    matcher_active: bool,
    srclen: usize,
    rank_mode: bool,
    self_contained: bool,
    prev_lit: bool = false,
};

const rc = @import("../rc.zig");

pub const Models = struct {
    const Self = @This();

    /// token type: 0=literal 1=match 2=end-of-block (2-bit tree),
    /// context = matchable(2) x prev-literal(2)
    type_tree: [4][4]u16,
    /// "is this running-maximum candidate the source?", context = first(2)
    src_flag: [2]u16,
    /// length equals the extension at the source, context = e == 258(2)
    delta0: [2]u16,
    /// length shortfall below the extension, minus one (8-bit tree)
    delta_tree: [256]u16,
    /// length 258: 0 -> code 285, 1 -> code 284 + extra 31
    len258: u16,
    /// fallback: explicit length code (5-bit tree, 0..28)
    lcode_tree: [32]u16,
    /// fallback: distance rank (full-length candidates, DRP2 semantics)
    rank0: u16,
    rank16: u16,
    rank4_tree: [16]u16,
    rank9_tree: [512]u16,
    rank_esc: u16,
    /// fallback: explicit distance code (5-bit tree, 0..29)
    dcode_tree: [32]u16,
    /// self-contained streams: literal byte values (8-bit tree)
    lit_tree: [256]u16,

    pub fn reset(self: *Self) void {
        for (&self.type_tree) |*t| @memset(t, rc.prob_init);
        @memset(&self.src_flag, rc.prob_init);
        @memset(&self.delta0, rc.prob_init);
        @memset(&self.delta_tree, rc.prob_init);
        self.len258 = rc.prob_init;
        @memset(&self.lcode_tree, rc.prob_init);
        self.rank0 = rc.prob_init;
        self.rank16 = rc.prob_init;
        @memset(&self.rank4_tree, rc.prob_init);
        @memset(&self.rank9_tree, rc.prob_init);
        self.rank_esc = rc.prob_init;
        @memset(&self.dcode_tree, rc.prob_init);
        @memset(&self.lit_tree, rc.prob_init);
    }
};

/// Decodes one token at stream position `p` (must be called in order).
/// `raw_loc` is the stream-local raw slice (len == ctx.srclen).
pub fn decodeToken(
    dec: *rc.Decoder,
    md: *Models,
    ctx: *WalkCtx,
    raw_loc: []const u8,
    p: usize,
) error{ Corrupt, BadParams }!Token {
    if (ctx.matcher_active) ctx.m.syncTo(p);
    const matchable = if (ctx.matcher_active) existsCandidate(ctx.m, p, ctx.srclen) else false;
    const tctx: usize = @as(usize, @intFromBool(matchable)) * 2 + @as(usize, @intFromBool(ctx.prev_lit));

    const t = try rc.treeDecode(dec, &md.type_tree[tctx], 2);
    switch (t) {
        0 => {
            if (p >= ctx.srclen) return error.BadParams;
            ctx.prev_lit = true;
            if (ctx.self_contained) {
                const v = try rc.treeDecode(dec, &md.lit_tree, 8);
                return .{ .literal = @intCast(v) };
            }
            return .{ .literal = raw_loc[p] };
        },
        2 => return .eob,
        1 => {
            ctx.prev_lit = false;
            var lcode: u8 = undefined;
            var lextra: u16 = 0;
            var dist: u32 = 0;
            var len: usize = 0;
            var rank: ?u16 = null;
            var escaped = false;

            if (ctx.matcher_active and ctx.rank_mode) {
                const found = try srcWalkDecode(dec, md, ctx.m, p, ctx.srclen);
                if (found == .yes) {
                    const e = found.yes.e;
                    dist = found.yes.dist;
                    const d0 = try dec.decodeBit(&md.delta0[@intFromBool(e == 258)]);
                    var l: usize = e;
                    if (d0 == 1) {
                        const v = try rc.treeDecode(dec, &md.delta_tree, 8);
                        if (e < v + 4) return error.BadParams;
                        l = e - 1 - @as(usize, @intCast(v));
                    }
                    if (l == 258) {
                        const f = try dec.decodeBit(&md.len258);
                        lcode = if (f == 0) 28 else 27;
                        lextra = if (f == 0) 0 else 31;
                    } else {
                        const lc = tables.lengthCodeOf(@intCast(l)) orelse return error.BadParams;
                        lcode = lc.lcode;
                        lextra = lc.lextra;
                    }
                    len = l;
                    // 0 marks "predicted source at the first candidate";
                    // 1 marks a later running maximum (statistics only)
                    rank = if (found.yes.first) 0 else 1;
                } else {
                    lcode = @intCast(try rc.treeDecode(dec, &md.lcode_tree, 5));
                    if (lcode > 28) return error.BadParams;
                    if (tables.length_extra[lcode] > 0) {
                        lextra = @intCast(try dec.decodeDirect(tables.length_extra[lcode]));
                    }
                    len = @as(usize, tables.length_base[lcode]) + lextra;
                    const r0 = try dec.decodeBit(&md.rank0);
                    if (r0 == 0) {
                        dist = ctx.m.nth(p, len, 0) catch return error.BadParams;
                        rank = 0;
                    } else {
                        const r16 = try dec.decodeBit(&md.rank16);
                        if (r16 == 0) {
                            const v = try rc.treeDecode(dec, &md.rank4_tree, 4);
                            const r: u16 = @intCast(1 + v);
                            dist = ctx.m.nth(p, len, r) catch return error.BadParams;
                            rank = r;
                        } else {
                            const esc = try dec.decodeBit(&md.rank_esc);
                            if (esc == 0) {
                                const v = try rc.treeDecode(dec, &md.rank9_tree, 9);
                                const r: u16 = @intCast(17 + v);
                                dist = ctx.m.nth(p, len, r) catch return error.BadParams;
                                rank = r;
                            } else {
                                dist = try decodeDistExplicit(dec, md);
                                escaped = true;
                            }
                        }
                    }
                }
            } else {
                lcode = @intCast(try rc.treeDecode(dec, &md.lcode_tree, 5));
                if (lcode > 28) return error.BadParams;
                if (tables.length_extra[lcode] > 0) {
                    lextra = @intCast(try dec.decodeDirect(tables.length_extra[lcode]));
                }
                len = @as(usize, tables.length_base[lcode]) + lextra;
                dist = try decodeDistExplicit(dec, md);
            }

            if (len < 3 or len > 258) return error.BadParams;
            if (p + len > ctx.srclen) return error.BadParams;
            return .{ .match = .{
                .lcode = lcode,
                .lextra = lextra,
                .dist = dist,
                .rank = rank,
                .escaped = escaped,
            } };
        },
        else => return error.BadParams, // 3 is unused
    }
}

/// Context feature: does a 3-byte match candidate exist at p (within the
/// chain-visit budget)? Deterministic on both sides.
fn existsCandidate(m: *matchfind.Matcher, p: usize, srclen: usize) bool {
    if (p + 3 > srclen) return false;
    return m.firstCandidate(p, 3, exist_hops) != null;
}

const SrcOutcome = union(enum) {
    /// source confirmed at a running maximum; e = capped extension there
    yes: struct { e: usize, first: bool },
    /// walk budget exhausted; the caller must use the fallback coding
    exhausted,
};

/// Encoder side of the source walk: emits "no" bits at every new running
/// maximum of the candidate extension until the actual source is reached
/// ("yes") or the budget is exhausted.
fn srcWalkEncode(
    enc: *rc.Encoder,
    md: *Models,
    m: *matchfind.Matcher,
    p: usize,
    srclen: usize,
    dist: u32,
) error{ OutOfMemory, ParamsMismatch }!SrcOutcome {
    if (p + 3 > srclen) return .exhausted;
    var w = matchfind.Matcher.Walker.init(m, p, 3);
    var max_e: usize = 0;
    var cand: usize = 0;
    var first = true;
    while (w.next()) |j| {
        if (w.hops > src_hops or cand >= src_candidates) return .exhausted;
        cand += 1;
        const e = @min(@as(usize, 258), extAt(m, p, j, srclen));
        if (e > max_e) {
            max_e = e;
            const is_src = @as(u32, @intCast(p - j)) == dist;
            try enc.encodeBit(
                &md.src_flag[@intFromBool(first)],
                @intFromBool(is_src),
            );
            if (is_src)
                return .{
                    .yes = .{
                        .e = e,
                        .first = first,
                    },
                };
        }
        first = false;
    }
    return .exhausted;
}

/// Number of raw bytes at positions p and j that match, capped at
/// min(258, srclen - p). The caller guarantees j < p and p <= srclen.
fn extAt(m: *const matchfind.Matcher, p: usize, j: usize, srclen: usize) usize {
    const cap = @min(@as(usize, 258), srclen - p);
    var k: usize = 0;
    while (k < cap and m.src.at(j + k) == m.src.at(p + k)) : (k += 1) {}
    return k;
}

/// Decoder side of the source walk (mirrors srcWalkEncode exactly).
fn srcWalkDecode(
    dec: *rc.Decoder,
    md: *Models,
    m: *matchfind.Matcher,
    p: usize,
    srclen: usize,
) error{ Corrupt, BadParams }!SrcFound {
    if (p + 3 > srclen) return .exhausted;
    var w = matchfind.Matcher.Walker.init(m, p, 3);
    var max_e: usize = 0;
    var cand: usize = 0;
    var first = true;
    while (w.next()) |j| {
        if (w.hops > src_hops or cand >= src_candidates) return .exhausted;
        cand += 1;
        const e = @min(@as(usize, 258), extAt(m, p, j, srclen));
        if (e > max_e) {
            max_e = e;
            const bit = try dec.decodeBit(
                &md.src_flag[@intFromBool(first)],
            );
            if (bit == 1)
                return .{
                    .yes = .{
                        .e = e,
                        .dist = @intCast(p - j),
                        .first = first,
                    },
                };
        }
        first = false;
    }
    return .exhausted;
}

const SrcFound = union(enum) {
    yes: struct { e: usize, dist: u32, first: bool },
    exhausted,
};

fn encodeDistExplicit(
    enc: *rc.Encoder,
    md: *Models,
    dist: u32,
) error{OutOfMemory}!void {
    const dc = tables.distCodeOf(dist).?;
    try rc.treeEncode(enc, &md.dcode_tree, 5, dc.code);
    if (tables.dist_extra[dc.code] > 0) {
        try enc.encodeDirect(dc.extra, tables.dist_extra[dc.code]);
    }
}

fn decodeDistExplicit(
    dec: *rc.Decoder,
    md: *Models,
) error{ Corrupt, BadParams }!u32 {
    const dcode = try rc.treeDecode(
        dec,
        &md.dcode_tree,
        5,
    );
    if (dcode > 29) return error.BadParams;
    var dextra: u32 = 0;
    if (tables.dist_extra[@intCast(dcode)] > 0) {
        dextra = try dec.decodeDirect(tables.dist_extra[@intCast(dcode)]);
    }
    return @as(u32, tables.dist_base[@intCast(dcode)]) + dextra;
}

/// Which coding path a token took (analyze-side statistics).
pub const TokPath = enum {
    lit,
    eob,
    /// source walk confirmed at the first candidate
    src_first,
    /// source walk confirmed at a later running maximum
    src_later,
    /// fallback: distance stored as candidate rank 0
    fb_rank0,
    /// fallback: distance stored as candidate rank > 0
    fb_rank,
    /// fallback: distance stored explicitly (escape)
    fb_escape,
    /// no rank mode: fully explicit match coding
    explicit,
};

/// Encodes one token at stream position `p` (must be called in order).
/// The matcher is advanced here (and only here) so that encoder and
/// decoder see identical candidate chains at every position.
pub fn encodeToken(
    enc: *rc.Encoder,
    md: *Models,
    ctx: *WalkCtx,
    p: usize,
    t: EncTok,
) error{ OutOfMemory, ParamsMismatch }!TokPath {
    if (ctx.matcher_active) ctx.m.syncTo(p);
    const matchable = if (ctx.matcher_active) existsCandidate(
        ctx.m,
        p,
        ctx.srclen,
    ) else false;
    const tctx: usize = @as(usize, @intFromBool(matchable)) * 2 +
        @as(usize, @intFromBool(ctx.prev_lit));

    switch (t.kind) {
        .eob => {
            try rc.treeEncode(enc, &md.type_tree[tctx], 2, 2);
            return .eob;
        },
        .lit => {
            try rc.treeEncode(enc, &md.type_tree[tctx], 2, 0);
            if (ctx.self_contained)
                try rc.treeEncode(enc, &md.lit_tree, 8, t.lit);
            ctx.prev_lit = true;
            return .lit;
        },
        .match => {
            try rc.treeEncode(enc, &md.type_tree[tctx], 2, 1);
            ctx.prev_lit = false;
            if (ctx.matcher_active and ctx.rank_mode) {
                const out = try srcWalkEncode(
                    enc,
                    md,
                    ctx.m,
                    p,
                    ctx.srclen,
                    t.dist,
                );
                if (out == .yes) {
                    const e = out.yes.e;
                    if (@as(usize, t.len) > e) return error.ParamsMismatch;
                    const delta = e - @as(usize, t.len);
                    try enc.encodeBit(
                        &md.delta0[@intFromBool(e == 258)],
                        @intFromBool(delta != 0),
                    );
                    if (delta != 0)
                        try rc.treeEncode(
                            enc,
                            &md.delta_tree,
                            8,
                            @intCast(delta - 1),
                        );
                    if (t.len == 258) {
                        try enc.encodeBit(&md.len258, @intFromBool(t.lcode != 28));
                    }
                    return if (out.yes.first) .src_first else .src_later;
                } else {
                    return try encodeFallback(enc, md, ctx, p, t);
                }
            } else {
                return try encodeFallback(enc, md, ctx, p, t);
            }
        },
    }
}

pub const TokKind = enum { lit, match, eob };

pub const EncTok = struct {
    kind: TokKind,
    lit: u8 = 0,
    lcode: u8 = 0, // symbol minus 257
    lextra: u16 = 0,
    dist: u32 = 0,
    len: u32 = 0,
};

/// Explicit fallback coding: length code + extra, then rank or distance.
fn encodeFallback(
    enc: *rc.Encoder,
    md: *Models,
    ctx: *WalkCtx,
    p: usize,
    t: EncTok,
) error{ OutOfMemory, ParamsMismatch }!TokPath {
    try rc.treeEncode(enc, &md.lcode_tree, 5, t.lcode);
    if (tables.length_extra[t.lcode] > 0) {
        try enc.encodeDirect(t.lextra, tables.length_extra[t.lcode]);
    }
    if (!(ctx.matcher_active and ctx.rank_mode)) {
        try encodeDistExplicit(enc, md, t.dist);
        return .explicit;
    }
    const len: usize = @as(usize, tables.length_base[t.lcode]) + t.lextra;
    switch (ctx.m.rankOf(p, len, t.dist)) {
        .rank => |r| {
            try enc.encodeBit(&md.rank0, @intFromBool(r != 0));
            if (r != 0) {
                try enc.encodeBit(&md.rank16, @intFromBool(r > 16));
                if (r <= 16) {
                    try rc.treeEncode(enc, &md.rank4_tree, 4, r - 1);
                } else {
                    try enc.encodeBit(&md.rank_esc, 0);
                    try rc.treeEncode(enc, &md.rank9_tree, 9, r - 17);
                }
            }
            return if (r == 0) .fb_rank0 else .fb_rank;
        },
        .escape => {
            try enc.encodeBit(&md.rank0, 1);
            try enc.encodeBit(&md.rank16, 1);
            try enc.encodeBit(&md.rank_esc, 1);
            try encodeDistExplicit(enc, md, t.dist);
            return .fb_escape;
        },
    }
}

test "v3 provider rejects a too-short gzip header" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll(&magic);
    try aw.writer.writeByte(3);
    try aw.writer.writeByte(0);
    try aw.writer.writeByte(2); // kind = gzip
    try aw.writer.writeByte(0); // header_len = 0 (invalid)
    try aw.writer.writeByte(0);
    var pv = try Provider.init(allocator, aw.written(), null, &diagnostics);
    defer pv.deinit();
    try std.testing.expectEqual(@as(u8, 2), try pv.nextKind());
    try std.testing.expectError(error.BadParams, pv.gzipHeader());
}
