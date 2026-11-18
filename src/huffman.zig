//! Canonical Huffman codes (RFC 1951 3.2.2): decoding (puff-style) and encoding.

const std = @import("std");
const bits = @import("bits.zig");
const tables = @import("tables.zig");

pub const max_bits = 15;
pub const max_symbols = 288;

pub const Decode = struct {
    count: [max_bits + 1]u16,
    symbol: [max_symbols]u16,
    nsymbols: u16,

    pub const Error = error{ OverSubscribed, BadLength };

    pub fn init(lengths: []const u8) Error!Decode {
        if (lengths.len > max_symbols) return error.BadLength;
        var d: Decode = .{ .count = @splat(0), .symbol = undefined, .nsymbols = 0 };
        for (lengths) |l| {
            if (l == 0) continue;
            if (l > max_bits) return error.BadLength;
            d.count[l] += 1;
            d.nsymbols += 1;
        }
        var left: i32 = 1;
        for (1..max_bits + 1) |l| {
            left <<= 1;
            left -= @as(i32, d.count[@intCast(l)]);
            if (left < 0) return error.OverSubscribed;
        }
        var offs: [max_bits + 2]u16 = undefined;
        offs[1] = 0;
        for (1..max_bits + 1) |l| offs[l + 1] = offs[l] + d.count[l];
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            d.symbol[offs[l]] = @intCast(sym);
            offs[l] += 1;
        }
        return d;
    }

    pub const DecodeError = bits.BitReader.Error || error{InvalidCode};

    /// Bit-by-bit canonical decode; incomplete codes fail only when a gap is hit.
    pub fn decode(self: *const Decode, br: *bits.BitReader) DecodeError!u16 {
        var code: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var len: usize = 1;
        while (len <= max_bits) : (len += 1) {
            code |= try br.readBit();
            const cnt: u32 = self.count[len];
            if (code < first + cnt) {
                return self.symbol[@intCast(index + code - first)];
            }
            index += cnt;
            first = (first + cnt) << 1;
            code <<= 1;
        }
        return error.InvalidCode;
    }
};

pub const Encode = struct {
    code: [max_symbols]u16 = @splat(0),
    len: [max_symbols]u8 = @splat(0),

    pub const Error = error{ OverSubscribed, BadLength };

    pub fn init(lengths: []const u8) Error!Encode {
        if (lengths.len > max_symbols) return error.BadLength;
        var e: Encode = .{};
        var count: [max_bits + 1]u32 = @splat(0);
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            if (l > max_bits) return error.BadLength;
            e.len[sym] = l;
            count[l] += 1;
        }
        var left: i32 = 1;
        for (1..max_bits + 1) |l| {
            left <<= 1;
            left -= @as(i32, @intCast(count[@intCast(l)]));
            if (left < 0) return error.OverSubscribed;
        }
        var next: [max_bits + 1]u32 = @splat(0);
        var c: u32 = 0;
        for (1..max_bits + 1) |l| {
            c = (c + count[l - 1]) << 1;
            next[l] = c;
        }
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            e.code[sym] = @intCast(next[l]);
            next[l] += 1;
        }
        return e;
    }

    pub const WriteError = bits.BitWriter.Error || error{SymbolWithoutCode};

    pub fn write(self: *const Encode, bw: *bits.BitWriter, sym: u16) WriteError!void {
        const l = self.len[sym];
        if (l == 0) return error.SymbolWithoutCode;
        try bw.writeCode(self.code[sym], @intCast(l));
    }
};

pub const RleError = error{ BadRepeat, BadSymbol };

/// Applies the code-length RLE sequence (symbols 16/17/18) to `out`.
pub fn lengthsFromRle(tokens: []const tables.RleToken, out: []u8) RleError!void {
    var idx: usize = 0;
    for (tokens) |t| {
        switch (t.sym) {
            0...15 => {
                if (idx >= out.len) return error.BadRepeat;
                out[idx] = t.sym;
                idx += 1;
            },
            16 => {
                const n = @as(usize, 3) + t.extra;
                if (idx == 0 or idx + n > out.len) return error.BadRepeat;
                @memset(out[idx..][0..n], out[idx - 1]);
                idx += n;
            },
            17 => {
                const n = @as(usize, 3) + t.extra;
                if (idx + n > out.len) return error.BadRepeat;
                @memset(out[idx..][0..n], 0);
                idx += n;
            },
            18 => {
                const n = @as(usize, 11) + t.extra;
                if (idx + n > out.len) return error.BadRepeat;
                @memset(out[idx..][0..n], 0);
                idx += n;
            },
            else => return error.BadSymbol,
        }
    }
    if (idx != out.len) return error.BadRepeat;
}

test "fixed literal codes match RFC 1951 3.2.6" {
    const enc = try Encode.init(&tables.fixed_literal_lengths);
    try std.testing.expectEqual(@as(u4, 8), @as(u4, @intCast(enc.len[0])));
    try std.testing.expectEqual(@as(u16, 0x30), enc.code[0]);
    try std.testing.expectEqual(@as(u16, 0x30 + 143), enc.code[143]);
    try std.testing.expectEqual(@as(u16, 0x190), enc.code[144]);
    try std.testing.expectEqual(@as(u16, 0x190 + 111), enc.code[255]);
    try std.testing.expectEqual(@as(u16, 0), enc.code[256]);
    try std.testing.expectEqual(@as(u16, 23), enc.code[279]);
    try std.testing.expectEqual(@as(u16, 192), enc.code[280]);
    try std.testing.expectEqual(@as(u16, 192 + 7), enc.code[287]);

    const dec = try Decode.init(&tables.fixed_literal_lengths);
    try std.testing.expectEqual(@as(u16, 256), dec.symbol[0]);
    try std.testing.expectEqual(@as(u16, 288), dec.nsymbols);
}

test "oversubscribed detection" {
    const bad = [_]u8{ 1, 1, 1 };
    try std.testing.expectError(error.OverSubscribed, Decode.init(&bad));
    try std.testing.expectError(error.OverSubscribed, Encode.init(&bad));
}

test "single incomplete code accepted" {
    const single = [_]u8{1};
    const dec = try Decode.init(&single);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeByte(0b0000_0000);
    var br = bits.BitReader.init(aw.written());
    try std.testing.expectEqual(@as(u16, 0), try dec.decode(&br));
    var br2 = bits.BitReader.init(&.{ 0xFF, 0xFF, 0xFF });
    try std.testing.expectError(error.InvalidCode, dec.decode(&br2));
}

test "rle expansion" {
    const tokens = [_]tables.RleToken{
        .{ .sym = 8, .extra = 0 },
        .{ .sym = 16, .extra = 2 }, // repeat previous five times
        .{ .sym = 17, .extra = 7 }, // ten zeros
        .{ .sym = 18, .extra = 10 }, // 21 zeros
    };
    var out: [37]u8 = undefined;
    try lengthsFromRle(&tokens, &out);
    try std.testing.expectEqualSlices(u8, &([_]u8{8} ** 6 ++ [_]u8{0} ** 31), &out);
}
