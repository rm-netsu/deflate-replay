//! `.drp` binary parameter file formats (version 1 and version 2).
//!
//! v1 layout (all integers little-endian):
//!   magic: "DRP1", u8 flags = 0
//!   records until EOF:
//!     u8 kind: 1=zlib, 2=gzip, 3=raw DEFLATE, 4=trailing bytes
//!     zlib:   [2]u8 header (CMF/FLG); if FDICT: [4]u8 dict id (BE)
//!     gzip:   u16 header_len, [header_len]u8 header (magic..FHCRC incl.)
//!     deflate blocks:
//!       u8 flags: bits0-1 = BTYPE (0=stored,1=fixed,2=dynamic), bit2 = BFINAL
//!       stored:   u8 pad_value, u16 len, u16 nlen, [len]u8 bytes
//!       fixed:    tokens
//!       dynamic:  u16 hlit, u16 hdist, u8 hclen,
//!                 [hclen]u8 cl lens (stream permutation order),
//!                 u16 rle_count, [rle_count](u8 sym, u8 extra),
//!                 tokens
//!       tokens: u8 tag: 1=literal [u8], 2=match [u8 lcode-257, u8 lextra,
//!               u8 dcode, u16 dextra], 3=end-of-block
//!     after BFINAL block: u8 trailing pad value
//!     zlib: [4]u8 Adler-32 (BE) | gzip: [4]u8 CRC32 (LE) + [4]u8 ISIZE (LE)
//!     u64 raw_len
//!   kind=4: u64 count, [count]u8 (unparseable tail, reproduced verbatim)
//!
//! v2 ("DRP2") is defined in records.zig: same record structure, but literal
//! values are taken from the raw data, tokens are bit-packed, and distances
//! may be stored as the rank of the nearest matching candidate (see
//! matchfind.zig), which typically shrinks the file by another 2-7x.

const std = @import("std");
const bits = @import("bits.zig");

const format_v1 = @import("format/v1.zig");

pub const tok_literal: u8 = 1;
pub const tok_match: u8 = 2;
pub const tok_eob: u8 = 3;

/// LEB128-style variable-length integer riding on the bit stream: 7 data
/// bits followed by a continuation bit, 8 bits per group. When the stream is
/// byte-aligned at the start, this is plain LEB128.
pub fn putUvarint(w: *bits.BitWriter, v: u64) std.Io.Writer.Error!void {
    var x = v;
    while (true) {
        const cont: u32 = if (x >> 7 != 0) 0x80 else 0;
        try w.writeBits(@as(u32, @intCast(x & 0x7F)) | cont, 8);
        x >>= 7;
        if (x == 0) return;
    }
}

pub const UvarintError = error{ EndOfStream, UvarintOverflow };

pub fn getUvarint(r: *bits.BitReader) UvarintError!u64 {
    var v: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        const g = try r.readBits(8);
        if (shift <= 56) {
            v |= @as(u64, g & 0x7F) << @intCast(shift);
        } else if (shift == 63) {
            // tenth group: only bit 0 fits
            v |= @as(u64, g & 1) << 63;
        } else {
            return error.UvarintOverflow;
        }
        if (g & 0x80 == 0) return v;
        shift += 7;
    }
}

pub fn putU16le(w: *std.Io.Writer, v: u16) std.Io.Writer.Error!void {
    try w.writeByte(@truncate(v));
    try w.writeByte(@truncate(v >> 8));
}

pub fn putU64le(w: *std.Io.Writer, v: u64) std.Io.Writer.Error!void {
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        try w.writeByte(@truncate(v >> @intCast(@as(u7, i) * 8)));
    }
}

test "uvarint roundtrip" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var bw = bits.BitWriter.init(&aw.writer);
    const vals = [_]u64{ 0, 1, 127, 128, 16909060, 65535, 1 << 40, std.math.maxInt(u64) };
    for (vals) |v| try putUvarint(&bw, v);
    try bw.writeBits(0b101, 3); // interleave unaligned bits
    try putUvarint(&bw, 42);
    try bw.padToBoundary(0); // flush the trailing partial byte

    var br = bits.BitReader.init(aw.written());
    for (vals) |v| try std.testing.expectEqual(v, try getUvarint(&br));
    try std.testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try std.testing.expectEqual(@as(u64, 42), try getUvarint(&br));
    try std.testing.expectError(error.EndOfStream, getUvarint(&br));
}

test "reader basics" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll(&format_v1.magic);
    try aw.writer.writeByte(1);
    try aw.writer.writeByte(format_v1.flags);
    try putU16le(&aw.writer, 0xBEEF);
    try putU64le(&aw.writer, 0x0102030405060708);
    try aw.writer.writeByte(0xAA);

    var r = try format_v1.Reader.init(aw.written());
    try std.testing.expectEqual(
        @as(u16, 0xBEEF),
        try r.u16le(),
    );
    try std.testing.expectEqual(
        @as(u64, 0x0102030405060708),
        try r.u64le(),
    );
    try std.testing.expectEqual(@as(u8, 0xAA), try r.byte());
    try std.testing.expect(r.done());
    try std.testing.expectError(
        error.BadMagic,
        format_v1.Reader.init(&format_v1.magic),
    );
}
