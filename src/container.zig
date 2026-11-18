//! Container framing: raw DEFLATE, zlib (RFC 1950), gzip (RFC 1952).

const std = @import("std");

pub const Kind = enum(u8) {
    zlib = 1,
    gzip = 2,
    deflate = 3,
    trailing = 4,
};

pub fn isZlibHeader(b0: u8, b1: u8) bool {
    const cm = b0 & 0x0f;
    const cinfo = b0 >> 4;
    const check = (@as(u16, b0) << 8) | @as(u16, b1);
    return cm == 8 and cinfo <= 7 and check % 31 == 0;
}

pub fn isGzipMagic(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b;
}

pub const GzipHeaderError = error{
    Truncated,
    BadMagic,
    BadCompressionMethod,
};

/// Returns the total gzip header length (magic through all optional fields).
pub fn gzipHeaderLength(data: []const u8) GzipHeaderError!usize {
    if (data.len < 10) return error.Truncated;

    if (data[0] != 0x1f or data[1] != 0x8b) return error.BadMagic;

    if (data[2] != 8) return error.BadCompressionMethod;

    const flg = data[3];
    var pos: usize = 10;
    if (flg & 0x04 != 0) { // FEXTRA
        if (pos + 2 > data.len) return error.Truncated;

        const xlen = @as(usize, data[pos]) |
            @as(usize, data[pos + 1]) << 8;
        pos += 2;
        if (pos + xlen > data.len) return error.Truncated;

        pos += xlen;
    }
    if (flg & 0x08 != 0) { // FNAME
        pos = (std.mem.indexOfScalarPos(
            u8,
            data,
            pos,
            0,
        ) orelse return error.Truncated) + 1;
    }
    if (flg & 0x10 != 0) { // FCOMMENT
        pos = (std.mem.indexOfScalarPos(
            u8,
            data,
            pos,
            0,
        ) orelse return error.Truncated) + 1;
    }
    if (flg & 0x02 != 0) { // FHCRC
        if (pos + 2 > data.len) return error.Truncated;
        pos += 2;
    }

    return pos;
}

pub fn le16(b: []const u8) u16 {
    return @as(u16, b[0]) |
        @as(u16, b[1]) << 8;
}

pub fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) |
        @as(u32, b[1]) << 8 |
        @as(u32, b[2]) << 16 |
        @as(u32, b[3]) << 24;
}

pub fn be32(b: []const u8) u32 {
    return @as(u32, b[0]) << 24 |
        @as(u32, b[1]) << 16 |
        @as(u32, b[2]) << 8 |
        @as(u32, b[3]);
}

pub fn flevelName(level: u2) []const u8 {
    return switch (level) {
        0 => "fastest",
        1 => "fast",
        2 => "default",
        3 => "best",
    };
}

test "zlib header checks" {
    try std.testing.expect(isZlibHeader(0x78, 0x9c));
    try std.testing.expect(isZlibHeader(0x78, 0xda));
    try std.testing.expect(isZlibHeader(0x08, 0x1d));
    try std.testing.expect(!isZlibHeader(0x78, 0x9d));
    try std.testing.expect(!isZlibHeader(0x88, 0x9c)); // CM != 8
    try std.testing.expect(!isZlibHeader(0xf8, 0x51)); // CINFO > 7
}

test "gzip header length" {
    const base = [_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 };
    try std.testing.expectEqual(@as(usize, 10), try gzipHeaderLength(&base));
    try std.testing.expectError(error.BadMagic, gzipHeaderLength(&[_]u8{ 0x2f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 }));
    try std.testing.expectError(error.BadCompressionMethod, gzipHeaderLength(&[_]u8{ 0x1f, 0x8b, 9, 0, 0, 0, 0, 0, 0, 3 }));
    try std.testing.expectError(error.Truncated, gzipHeaderLength(base[0..9]));
}
