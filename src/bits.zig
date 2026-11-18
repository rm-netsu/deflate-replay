//! DEFLATE bit-level I/O: LSB-first data elements, MSB-first Huffman codes (RFC 1951 3.1.1).

const std = @import("std");

pub const BitReader = struct {
    data: []const u8,
    bitpos: u64 = 0,

    pub const Error = error{EndOfStream};

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        const byte_index = self.bitpos >> 3;
        if (byte_index >= self.data.len) return error.EndOfStream;
        const shift: u3 = @intCast(self.bitpos & 7);
        const bit: u1 = @truncate(self.data[@intCast(byte_index)] >> shift);
        self.bitpos += 1;
        return bit;
    }

    pub fn readBits(self: *BitReader, n: u4) Error!u32 {
        var value: u32 = 0;
        var i: u4 = 0;
        while (i < n) : (i += 1) {
            const b = try self.readBit();
            value |= @as(u32, b) << i;
        }
        return value;
    }

    pub const PadInfo = struct {
        count: u3,
        value: u8,
    };

    /// Reads and returns the arbitrary bits skipped up to the next byte boundary.
    pub fn readPadToBoundary(self: *BitReader) Error!PadInfo {
        var info = PadInfo{ .count = 0, .value = 0 };
        while (self.bitpos & 7 != 0) {
            const b = try self.readBit();
            info.value |= @as(u8, b) << info.count;
            info.count += 1;
        }
        return info;
    }

    /// Returns a borrowed slice; requires byte alignment.
    pub fn readSlice(self: *BitReader, n: usize) Error![]const u8 {
        std.debug.assert(self.bitpos & 7 == 0);
        const start: usize = @intCast(self.bitpos >> 3);
        const end = start + n;
        if (end > self.data.len) return error.EndOfStream;
        self.bitpos += @as(u64, n) << 3;
        return self.data[start..end];
    }

    pub fn bitsConsumed(self: *const BitReader) u64 {
        return self.bitpos;
    }

    /// Skips padding bits up to the next byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bitpos = (self.bitpos + 7) & ~@as(u64, 7);
    }

    pub fn bytesConsumed(self: *const BitReader) usize {
        std.debug.assert(self.bitpos & 7 == 0);
        return @intCast(self.bitpos >> 3);
    }
};

pub const BitWriter = struct {
    out: *std.Io.Writer,
    acc: u32 = 0,
    nbits: u4 = 0,
    bits_written: u64 = 0,
    bytes_written: u64 = 0,

    pub const Error = std.Io.Writer.Error;

    pub fn init(out: *std.Io.Writer) BitWriter {
        return .{ .out = out };
    }

    fn flushByte(self: *BitWriter) Error!void {
        std.debug.assert(self.nbits == 8);
        try self.out.writeByte(@truncate(self.acc));
        self.acc >>= 8;
        self.nbits = 0;
        self.bytes_written += 1;
    }

    pub fn writeBit(self: *BitWriter, bit: u1) Error!void {
        self.acc |= @as(u32, bit) << self.nbits;
        self.nbits += 1;
        self.bits_written += 1;
        if (self.nbits == 8) try self.flushByte();
    }

    /// LSB-first data element (block headers, extra bits).
    pub fn writeBits(self: *BitWriter, value: u32, n: u4) Error!void {
        var i: u4 = 0;
        while (i < n) : (i += 1) {
            try self.writeBit(@truncate(value >> i));
        }
    }

    /// Huffman code: bits are emitted starting from the code's most significant bit.
    pub fn writeCode(self: *BitWriter, code: u16, len: u4) Error!void {
        var i: u4 = 0;
        while (i < len) : (i += 1) {
            const shift: u4 = len - 1 - i;
            try self.writeBit(@truncate(code >> shift));
        }
    }

    /// Pads up to the next byte boundary with the low bits of `pad_value`.
    pub fn padToBoundary(self: *BitWriter, pad_value: u8) Error!void {
        var i: u3 = 0;
        while (self.nbits != 0) : (i += 1) {
            try self.writeBit(@truncate(pad_value >> i));
        }
    }

    pub fn writeAligned(self: *BitWriter, bytes: []const u8) Error!void {
        std.debug.assert(self.nbits == 0);
        try self.out.writeAll(bytes);
        self.bytes_written += bytes.len;
        self.bits_written += @as(u64, bytes.len) << 3;
    }

    pub fn writeAlignedU16le(self: *BitWriter, value: u16) Error!void {
        try self.writeAligned(&.{ @truncate(value), @truncate(value >> 8) });
    }
};

test "bit roundtrip" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0b101, 3);
    try bw.writeCode(0b1011, 4);
    try bw.writeBit(1);
    // 8 bits written: byte-aligned here
    try bw.writeBit(1);
    try bw.padToBoundary(0b1010101);
    try bw.writeAligned(&.{0xAA});

    try std.testing.expectEqualSlices(u8, &.{ 0xED, 0xAB, 0xAA }, aw.written());

    var br = BitReader.init(aw.written());
    try std.testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    var code: u16 = 0;
    var i: u4 = 0;
    while (i < 4) : (i += 1) {
        code = (code << 1) | try br.readBit();
    }
    try std.testing.expectEqual(@as(u16, 0b1011), code);
    try std.testing.expectEqual(@as(u1, 1), try br.readBit());
    try std.testing.expectEqual(@as(u1, 1), try br.readBit());
    const pad = try br.readPadToBoundary();
    try std.testing.expectEqual(@as(u3, 7), pad.count);
    try std.testing.expectEqual(@as(u8, 0b1010101), pad.value);
    try std.testing.expectEqualSlices(u8, &.{0xAA}, try br.readSlice(1));
}

test "pad to boundary zero" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0xFF, 8);
    try bw.padToBoundary(0x7F);
    try std.testing.expectEqual(@as(u4, 0), bw.nbits);
    try std.testing.expectEqualSlices(u8, &.{0xFF}, aw.written());
}
