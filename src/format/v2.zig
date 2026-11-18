const std = @import("std");
const bits = @import("../bits.zig");
const matchfind = @import("../matchfind.zig");
const huffman = @import("../huffman.zig");
const tables = @import("../tables.zig");
const container = @import("../container.zig");

const Diagnostics = @import("../diagnostics.zig").Diagnostics;

const DynHdr = @import("../records.zig").DynHdr;
const StreamFlags = @import("../records.zig").StreamFlags;
const BlockHdr = @import("../records.zig").BlockHdr;
const StoredBlock = @import("../records.zig").StoredBlock;
const Token = @import("../records.zig").Token;
const TrailingRec = @import("../records.zig").TrailingRec;

const params = @import("../params.zig");

pub const magic = [4]u8{ 'D', 'R', 'P', '2' };

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
    matcher: matchfind.Matcher,
    // per-block state
    lmode: bool = false,
    lit_dec: huffman.Decode = undefined,
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
            params_bytes[4] != 2 or
            params_bytes[5] != 0)
        {
            diagnostics.set("not a valid DRP2 params file", .{});
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
        const sc = self.br.readBit() catch
            return self.bad("stream flags missing", .{});
        const rm = self.br.readBit() catch
            return self.bad("stream flags missing", .{});

        self.self_contained = sc != 0;
        self.rank_mode = rm != 0;
        if (self.rank_mode and self.self_contained)
            return self.bad(
                "rank mode with self-contained stream {d}",
                .{self.stream_no},
            );
        if (self.rank_mode) {
            if (self.raw) |rw| {
                self.matcher.reset(
                    .{ .slice = .{
                        .data = rw,
                        .base = self.raw_base,
                        .len = rw.len - self.raw_base,
                    } },
                );
            }
            // without raw data (dump) ranks are read but distances stay unknown
        }
        return .{
            .self_contained = self.self_contained,
            .rank_mode = self.rank_mode,
        };
    }

    pub fn blockHeader(self: *Self) !BlockHdr {
        const bfinal = self.br.readBit() catch
            return self.bad("block header truncated", .{});
        const btype_raw = self.br.readBits(2) catch
            return self.bad("block header truncated", .{});

        const btype: u2 = @intCast(btype_raw);
        if (btype == 3)
            return self.bad(
                "reserved block type 3 in stream {d}",
                .{self.stream_no},
            );

        self.lmode = false;
        if (btype == 1 or btype == 2) {
            const lm = self.br.readBit() catch
                return self.bad("block header truncated", .{});
            self.lmode = lm != 0;
        }
        if (btype == 1) {
            self.lit_dec = huffman.Decode.init(&tables.fixed_literal_lengths) catch
                return self.bad(
                    "fixed code set rejected in stream {d}",
                    .{self.stream_no},
                );
        }
        return .{ .bfinal = bfinal != 0, .btype = btype };
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
                        return self.bad(
                            "bad code-length run in stream {d}",
                            .{self.stream_no},
                        );

                    @memset(d.lens[idx..][0..n], 0);
                    idx += n;
                    d.rle[d.rle_count] = .{ .sym = 18, .extra = @intCast(e) };
                    d.rle_count += 1;
                },
                else => return self.bad(
                    "bad code-length symbol {d} in stream {d}",
                    .{ sym, self.stream_no },
                ),
            }
        }

        if (d.lens[256] == 0)
            return self.bad(
                "dynamic block has no end-of-block code in stream {d}",
                .{self.stream_no},
            );
        self.lit_dec = huffman.Decode.init(d.lens[0..hlit]) catch
            return self.bad(
                "over-subscribed literal/length code set in stream {d}",
                .{self.stream_no},
            );
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
        if (self.rank_mode and self.raw != null) self.matcher.syncTo(p);
        const b0 = self.br.readBit() catch
            return self.bad(
                "token stream truncated in stream {d}",
                .{self.stream_no},
            );
        if (b0 == 0) {
            if (self.self_contained) {
                const v = self.br.readBits(8) catch
                    return self.bad(
                        "token stream truncated in stream {d}",
                        .{self.stream_no},
                    );

                return .{ .literal = @intCast(v) };
            }
            if (self.raw) |rw| {
                if (self.raw_base + p >= rw.len)
                    return self.bad(
                        "raw data too short in stream {d}",
                        .{self.stream_no},
                    );

                return .{ .literal = rw[self.raw_base + p] };
            }
            return .{ .literal = null };
        }
        const b1 = self.br.readBit() catch
            return self.bad(
                "token stream truncated in stream {d}",
                .{self.stream_no},
            );
        if (b0 == 1 and b1 == 1) return .eob;
        if (b0 != 1 or b1 != 0)
            return self.bad(
                "bad token tag in stream {d}",
                .{self.stream_no},
            );

        var lcode: u8 = undefined;
        if (self.lmode) {
            const sym = self.lit_dec.decode(&self.br) catch
                return self.bad(
                    "bad length code in stream {d}",
                    .{self.stream_no},
                );
            if (sym < 257 or sym > 285)
                return self.bad(
                    "symbol {d} is not a length code in stream {d}",
                    .{ sym, self.stream_no },
                );
            lcode = @intCast(sym - 257);
        } else {
            const lc = self.br.readBits(5) catch
                return self.bad(
                    "token stream truncated in stream {d}",
                    .{self.stream_no},
                );
            if (lc > 28)
                return self.bad(
                    "bad length code {d} in stream {d}",
                    .{ lc, self.stream_no },
                );
            lcode = @intCast(lc);
        }
        var lextra: u16 = 0;
        if (tables.length_extra[lcode] > 0) {
            const lx = self.br.readBits(tables.length_extra[lcode]) catch
                return self.bad(
                    "token stream truncated in stream {d}",
                    .{self.stream_no},
                );
            lextra = @intCast(lx);
        }
        const len: u32 = @as(u32, tables.length_base[lcode]) + lextra;

        if (self.rank_mode) {
            var escaped = false;
            var rank: u16 = 0;
            var dist: u32 = 0;
            const r0 = self.br.readBit() catch
                return self.bad(
                    "token stream truncated in stream {d}",
                    .{self.stream_no},
                );
            if (r0 == 0) {
                rank = 0;
            } else {
                const r1 = self.br.readBit() catch
                    return self.bad(
                        "token stream truncated in stream {d}",
                        .{self.stream_no},
                    );
                if (r1 == 0) {
                    const v = self.br.readBits(4) catch
                        return self.bad(
                            "token stream truncated in stream {d}",
                            .{self.stream_no},
                        );
                    rank = 1 + @as(u16, @intCast(v));
                } else {
                    const r2 = self.br.readBit() catch
                        return self.bad(
                            "token stream truncated in stream {d}",
                            .{self.stream_no},
                        );
                    if (r2 == 0) {
                        const v = self.br.readBits(9) catch
                            return self.bad(
                                "token stream truncated in stream {d}",
                                .{self.stream_no},
                            );
                        rank = 17 + @as(u16, @intCast(v));
                    } else {
                        escaped = true;
                        dist = try self.readDistFields();
                    }
                }
            }
            if (escaped) {
                return .{
                    .match = .{
                        .lcode = lcode,
                        .lextra = lextra,
                        .dist = dist,
                        .escaped = true,
                    },
                };
            }
            if (self.raw) |rw| {
                if (self.raw_base + p + len > rw.len)
                    return self.bad(
                        "raw data too short in stream {d}",
                        .{self.stream_no},
                    );
                const d = self.matcher.nth(
                    p,
                    @intCast(len),
                    rank,
                ) catch
                    return self.bad(
                        "distance rank {d} has no candidate in stream {d} (params/raw mismatch)",
                        .{ rank, self.stream_no },
                    );
                return .{ .match = .{
                    .lcode = lcode,
                    .lextra = lextra,
                    .dist = d,
                    .rank = rank,
                } };
            }
            return .{ .match = .{
                .lcode = lcode,
                .lextra = lextra,
                .dist_known = false,
                .rank = rank,
            } };
        }

        const dist = try self.readDistFields();
        return .{ .match = .{
            .lcode = lcode,
            .lextra = lextra,
            .dist = dist,
        } };
    }

    fn readDistFields(self: *Self) !u32 {
        const dcode = self.br.readBits(5) catch
            return self.bad(
                "token stream truncated in stream {d}",
                .{self.stream_no},
            );
        if (dcode > 29)
            return self.bad(
                "bad distance code {d} in stream {d}",
                .{ dcode, self.stream_no },
            );
        var dextra: u32 = 0;
        if (tables.dist_extra[@intCast(dcode)] > 0) {
            dextra = self.br.readBits(tables.dist_extra[@intCast(dcode)]) catch
                return self.bad(
                    "token stream truncated in stream {d}",
                    .{self.stream_no},
                );
        }
        return @as(u32, tables.dist_base[@intCast(dcode)]) + dextra;
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
        self.br.alignToByte();
        const v = params.getUvarint(&self.br) catch
            return self.bad(
                "raw length record missing in stream {d}",
                .{self.stream_no},
            );
        // FDICT streams contribute no bytes to the raw file
        if (!self.fdict) self.raw_base += @intCast(v);
        return v;
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

    // dump support (duck-typed alongside V3Provider)
    pub fn undecodableTokens(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn segTokenCount(self: *const Self) ?usize {
        _ = self;
        return null;
    }
};

test "v2 provider rejects a too-short gzip header" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics{};
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll(&magic);
    try aw.writer.writeByte(2);
    try aw.writer.writeByte(0);
    try aw.writer.writeByte(2); // kind = gzip
    try aw.writer.writeByte(0); // header_len = 0 (invalid)
    try aw.writer.writeByte(0);
    var pv = try Provider.init(allocator, aw.written(), null, &diagnostics);
    defer pv.deinit();
    try std.testing.expectEqual(@as(u8, 2), try pv.nextKind());
    try std.testing.expectError(error.BadParams, pv.gzipHeader());
}
