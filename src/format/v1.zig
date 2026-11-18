const std = @import("std");

pub const magic = [4]u8{ 'D', 'R', 'P', '1' };
pub const flags: u8 = 0;

pub const Reader = struct {
    buf: []const u8,
    pos: usize,

    pub const Error = error{ Truncated, BadMagic, BadFlags };

    pub fn init(buf: []const u8) Error!Reader {
        if (buf.len < 6) return error.BadMagic;
        if (!std.mem.eql(u8, buf[0..4], &magic)) return error.BadMagic;
        if (buf[4] != 1) return error.BadMagic; // version baked into magic
        if (buf[5] != flags) return error.BadFlags;
        return .{ .buf = buf, .pos = 6 };
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn u16le(self: *Reader) Error!u16 {
        const s = try self.slice(2);
        return @as(u16, s[0]) | @as(u16, s[1]) << 8;
    }

    pub fn u64le(self: *Reader) Error!u64 {
        const s = try self.slice(8);
        var v: u64 = 0;
        for (s, 0..) |b, i| v |= @as(u64, b) << @intCast(i * 8);
        return v;
    }

    pub fn slice(self: *Reader, n: usize) Error![]const u8 {
        const end = self.pos + n;
        if (end > self.buf.len) return error.Truncated;
        const s = self.buf[self.pos..end];
        self.pos = end;
        return s;
    }

    pub fn done(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }
};

const mod_diagnostics = @import("../diagnostics.zig");
const Diagnostics = mod_diagnostics.Diagnostics;

const tables = @import("../tables.zig");
const huffman = @import("../huffman.zig");
const params = @import("../params.zig");

const DynHdr = @import("../records.zig").DynHdr;
const StreamFlags = @import("../records.zig").StreamFlags;
const BlockHdr = @import("../records.zig").BlockHdr;
const StoredBlock = @import("../records.zig").StoredBlock;
const Token = @import("../records.zig").Token;
const TrailingRec = @import("../records.zig").TrailingRec;

pub const Provider = struct {
    const Self = @This();

    pr: Reader,
    diagnostics: *Diagnostics,
    stream_no: usize = 0,
    kind: u8 = 0,
    dyn: DynHdr = .{
        .hlit = tables.min_hlit,
        .hdist = 1,
        .hclen = 4,
    },

    pub fn init(pr: Reader, diagnostics: *Diagnostics) Self {
        return .{ .pr = pr, .diagnostics = diagnostics };
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
        return self.pr.done();
    }

    pub fn nextKind(self: *Self) !u8 {
        const k = self.pr.byte() catch
            return self.bad("unexpected end of file", .{});

        if (k < 1 or k > 4)
            return self.bad("bad record kind {d}", .{k});

        self.kind = k;
        if (k != 4) self.stream_no += 1;
        return k;
    }

    pub fn zlibHeader(self: *Self) ![2]u8 {
        const hdr = self.pr.slice(2) catch
            return self.bad(
                "zlib header missing in stream {d}",
                .{self.stream_no},
            );

        return .{ hdr[0], hdr[1] };
    }

    pub fn fdictId(self: *Self) ![4]u8 {
        const d = self.pr.slice(4) catch
            return self.bad(
                "FDICT id missing in stream {d}",
                .{self.stream_no},
            );

        return d[0..4].*;
    }

    pub fn gzipHeader(self: *Self) ![]const u8 {
        const hlen = self.pr.u16le() catch
            return self.bad(
                "gzip header missing in stream {d}",
                .{self.stream_no},
            );

        if (hlen < 10)
            return self.bad(
                "gzip header too short in stream {d} ({d} bytes)",
                .{ self.stream_no, hlen },
            );

        return self.pr.slice(hlen) catch
            return self.bad(
                "gzip header truncated in stream {d}",
                .{self.stream_no},
            );
    }

    /// Interface stub
    pub fn streamFlags(self: *Self) !StreamFlags {
        _ = self;
        return .{ .self_contained = true, .rank_mode = false };
    }

    pub fn blockHeader(self: *Self) !BlockHdr {
        const f = self.pr.byte() catch
            return self.bad(
                "block record truncated in stream {d}",
                .{self.stream_no},
            );

        const btype: u2 = @intCast(f & 3);
        if (btype == 3)
            return self.bad(
                "reserved block type 3 in stream {d}",
                .{self.stream_no},
            );

        return .{ .bfinal = f & 4 != 0, .btype = btype };
    }

    pub fn dynHeader(self: *Self) !*const DynHdr {
        const hlit = self.pr.u16le() catch return self.badDyn();
        const hdist = self.pr.u16le() catch return self.badDyn();
        const hclen = self.pr.byte() catch return self.badDyn();

        if (hlit < tables.min_hlit or
            hlit > tables.max_hlit or
            hdist < 1 or
            hdist > tables.max_hdist or
            hclen < 4 or
            hclen > 19)
        {
            return self.bad(
                "bad dynamic header sizes in stream {d} (hlit={d}, hdist={d}, hclen={d})",
                .{ self.stream_no, hlit, hdist, hclen },
            );
        }

        const cl = self.pr.slice(hclen) catch return self.badDyn();
        const rle_count = self.pr.u16le() catch return self.badDyn();
        if (rle_count > tables.max_code_lengths) return self.badDyn();

        const rle_bytes = self.pr.slice(@as(usize, rle_count) * 2) catch
            return self.badDyn();

        const d = &self.dyn;
        d.hlit = hlit;
        d.hdist = hdist;
        d.hclen = hclen;
        @memcpy(d.cl_stream[0..hclen], cl);
        d.rle_count = rle_count;
        for (0..rle_count) |i| {
            d.rle[i] = .{
                .sym = rle_bytes[i * 2],
                .extra = rle_bytes[i * 2 + 1],
            };
        }

        huffman.lengthsFromRle(
            d.rle[0..rle_count],
            d.lens[0 .. @as(usize, hlit) + hdist],
        ) catch
            return self.bad(
                "bad code-length RLE in stream {d}",
                .{self.stream_no},
            );

        _ = huffman.Encode.init(d.lens[0..hlit]) catch
            return self.bad(
                "bad literal/length code set in stream {d}",
                .{self.stream_no},
            );
        _ = huffman.Encode.init(d.lens[hlit..][0..hdist]) catch
            return self.bad(
                "bad distance code set in stream {d}",
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
        _ = p;

        const pad = self.pr.byte() catch
            return self.bad(
                "stored block truncated in stream {d}",
                .{self.stream_no},
            );
        const len = self.pr.u16le() catch
            return self.bad(
                "stored block truncated in stream {d}",
                .{self.stream_no},
            );
        const nlen = self.pr.u16le() catch
            return self.bad(
                "stored block truncated in stream {d}",
                .{self.stream_no},
            );
        if (nlen != ~len)
            return self.bad(
                "stored block NLEN does not complement LEN in stream {d}",
                .{self.stream_no},
            );

        const data = self.pr.slice(len) catch
            return self.bad(
                "stored block body truncated in stream {d}",
                .{self.stream_no},
            );

        return .{ .pad = pad, .len = len, .data = data };
    }

    pub fn token(self: *Self, p: usize) !Token {
        _ = p;

        const stream_no = self.stream_no;
        const tag = self.pr.byte() catch
            return self.bad(
                "token stream truncated in stream {d}",
                .{stream_no},
            );

        switch (tag) {
            params.tok_literal => {
                const b = self.pr.byte() catch
                    return self.bad(
                        "token stream truncated in stream {d}",
                        .{stream_no},
                    );
                return .{ .literal = b };
            },
            params.tok_match => {
                const lcode = self.pr.byte() catch return self.badToken();
                const lextra = self.pr.byte() catch return self.badToken();
                const dcode = self.pr.byte() catch return self.badToken();
                const dextra = self.pr.u16le() catch return self.badToken();
                if (lcode > 28 or
                    dcode > 29 or
                    lextra >= (@as(u16, 1) << tables.length_extra[lcode]) or
                    dextra >= (@as(u32, 1) << tables.dist_extra[dcode]))
                {
                    return self.bad(
                        "bad match codes in stream {d} (lcode={d}, lextra={d}, dcode={d}, dextra={d})",
                        .{ stream_no, lcode, lextra, dcode, dextra },
                    );
                }

                return .{ .match = .{
                    .lcode = lcode,
                    .lextra = lextra,
                    .dist = @as(u32, tables.dist_base[dcode]) + dextra,
                } };
            },
            params.tok_eob => return .eob,
            else => return self.bad(
                "bad token tag {d} in stream {d}",
                .{ tag, stream_no },
            ),
        }
    }

    fn badToken(self: *Self) error{BadParams} {
        return self.bad(
            "token stream truncated in stream {d}",
            .{self.stream_no},
        );
    }

    pub fn streamTrailingPad(self: *Self) !u8 {
        return self.pr.byte() catch
            self.bad(
                "stream {d} pad record missing",
                .{self.stream_no},
            );
    }

    pub fn checksumTrailer(self: *Self) ![]const u8 {
        const n: usize = switch (self.kind) {
            1 => 4,
            2 => 8,
            else => 0,
        };
        if (n == 0) return &[_]u8{};

        return self.pr.slice(n) catch
            self.bad(
                "checksum record missing in stream {d}",
                .{self.stream_no},
            );
    }

    pub fn rawLen(self: *Self) !u64 {
        return self.pr.u64le() catch
            self.bad(
                "raw length record missing in stream {d}",
                .{self.stream_no},
            );
    }

    /// Interface stub
    pub fn rawCrc(self: *Self) !?u32 {
        _ = self;
        return null;
    }

    pub fn trailingRecord(self: *Self) !TrailingRec {
        const n = self.pr.u64le() catch
            return self.bad("trailing record truncated", .{});
        const b = self.pr.slice(@intCast(n)) catch
            return self.bad("trailing record truncated", .{});

        return .{ .count = n, .bytes = b };
    }

    /// Interface stub
    pub fn undecodableTokens(self: *const Self) bool {
        _ = self;
        return false;
    }

    /// Interface stub
    pub fn segTokenCount(self: *const Self) ?usize {
        _ = self;
        return null;
    }
};

test "v1 provider rejects a too-short gzip header" {
    var diagnostics = mod_diagnostics.Diagnostics{};
    // kind = 2 (gzip), header_len = 0 (a real gzip header is >= 10 bytes)
    const bytes = "DRP1\x01\x00\x02\x00\x00";
    const pr = try Reader.init(bytes);
    var pv = Provider.init(pr, &diagnostics);
    try std.testing.expectEqual(@as(u8, 2), try pv.nextKind());
    try std.testing.expectError(error.BadParams, pv.gzipHeader());
}
