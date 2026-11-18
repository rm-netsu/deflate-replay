//! Adaptive binary range coder (LZMA-style) used by the DRP3 params format.
//!
//! Integer-only and therefore deterministic across platforms: an 11-bit
//! probability per bit model, adaptation shift 5, and a 24-bit normalization
//! threshold. `Encoder` output is exactly `5 + normalizations` bytes; the
//! decoder consumes exactly those bytes (5 at init, then one per
//! normalization), so no length suffix is needed inside a segment.

const std = @import("std");

pub const prob_bits = 11;
pub const prob_init: u16 = 1 << (prob_bits - 1); // 1024
pub const prob_max: u16 = 1 << prob_bits; // 2048
const top: u32 = 1 << 24;

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    low: u64 = 0,
    range: u32 = 0xFFFF_FFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.gpa);
    }

    fn shiftLow(self: *Encoder) error{OutOfMemory}!void {
        if (self.low < 0xFF00_0000 or self.low > 0xFFFF_FFFF) {
            var temp = self.cache;
            while (true) {
                const carry: u8 = @truncate(self.low >> 32);
                try self.out.append(self.gpa, temp +% carry);
                temp = 0xFF;
                self.cache_size -= 1;
                if (self.cache_size == 0) break;
            }
            self.cache = @truncate(self.low >> 24);
        }
        self.cache_size += 1;
        self.low = (self.low << 8) & 0xFFFF_FFFF;
    }

    /// Encodes one bit with an adaptive probability (`prob` = P(bit == 0)).
    pub fn encodeBit(self: *Encoder, prob: *u16, bit: u32) error{OutOfMemory}!void {
        const bound = (self.range >> prob_bits) * @as(u32, prob.*);
        if (bit == 0) {
            self.range = bound;
            prob.* +%= (prob_max - prob.*) >> 5;
        } else {
            self.low += bound;
            self.range -= bound;
            prob.* -%= prob.* >> 5;
        }
        while (self.range < top) : ({
            self.range <<= 8;
            try self.shiftLow();
        }) {}
    }

    /// Encodes `n` raw bits of `value` (MSB first) with fixed 50/50 odds.
    pub fn encodeDirect(self: *Encoder, value: u32, n: u5) error{OutOfMemory}!void {
        var i: u5 = n;
        while (i > 0) {
            i -= 1;
            const bound = self.range >> 1;
            const bit = (value >> i) & 1;
            if (bit == 0) {
                self.range = bound;
            } else {
                self.low += bound;
                self.range -= bound;
            }
            while (self.range < top) : ({
                self.range <<= 8;
                try self.shiftLow();
            }) {}
        }
    }

    /// Emits the coder tail; the segment is complete afterwards.
    pub fn flush(self: *Encoder) error{OutOfMemory}!void {
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.shiftLow();
    }
};

pub const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    range: u32 = 0xFFFF_FFFF,
    code: u32 = 0,

    pub const Error = error{Corrupt};

    pub fn init(data: []const u8) Error!Decoder {
        if (data.len < 5) return error.Corrupt;
        var self = Decoder{ .data = data };
        // The encoder's first byte is always the initial zero cache; skip it
        // and load the next four.
        var i: usize = 1;
        while (i < 5) : (i += 1) self.code = (self.code << 8) | data[i];
        self.pos = 5;
        return self;
    }

    fn readByte(self: *Decoder) Error!u8 {
        if (self.pos >= self.data.len) return error.Corrupt;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn decodeBit(self: *Decoder, prob: *u16) Error!u1 {
        const bound = (self.range >> prob_bits) * @as(u32, prob.*);
        var bit: u1 = undefined;
        if (self.code < bound) {
            self.range = bound;
            prob.* +%= (prob_max - prob.*) >> 5;
            bit = 0;
        } else {
            self.code -= bound;
            self.range -= bound;
            prob.* -%= prob.* >> 5;
            bit = 1;
        }
        while (self.range < top) : ({
            self.range <<= 8;
            self.code = (self.code << 8) | try self.readByte();
        }) {}
        return bit;
    }

    /// Decodes `n` raw bits (MSB first) with fixed 50/50 odds.
    pub fn decodeDirect(self: *Decoder, n: u5) Error!u32 {
        var value: u32 = 0;
        var i: u5 = n;
        while (i > 0) {
            i -= 1;
            const bound = self.range >> 1;
            var bit: u1 = undefined;
            if (self.code < bound) {
                self.range = bound;
                bit = 0;
            } else {
                self.code -= bound;
                self.range -= bound;
                bit = 1;
            }
            value = (value << 1) | bit;
            while (self.range < top) : ({
                self.range <<= 8;
                self.code = (self.code << 8) | try self.readByte();
            }) {}
        }
        return value;
    }
};

/// Encodes `sym` (num_bits wide) with an adaptive binary tree.
/// `probs` must have 1 << num_bits slots (index 0 unused).
pub fn treeEncode(
    enc: *Encoder,
    probs: []u16,
    num_bits: u5,
    sym: u32,
) error{OutOfMemory}!void {
    std.debug.assert(sym < (@as(u32, 1) << num_bits));
    var m: usize = 1;
    var i: u5 = num_bits;
    while (i > 0) {
        i -= 1;
        const bit = (sym >> i) & 1;
        try enc.encodeBit(&probs[m], bit);
        m = (m << 1) | @as(usize, @intCast(bit));
    }
}

/// Decodes a num_bits-wide symbol with an adaptive binary tree.
pub fn treeDecode(dec: *Decoder, probs: []u16, num_bits: u5) Decoder.Error!u32 {
    var m: usize = 1;
    var i: u5 = 0;
    while (i < num_bits) : (i += 1) {
        const bit = try dec.decodeBit(&probs[m]);
        m = (m << 1) | @as(usize, bit);
    }
    return @intCast(m - (@as(usize, 1) << num_bits));
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "range coder bit roundtrip" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    var probs: [8]u16 = undefined;
    for (&probs) |*p| p.* = prob_init;

    var bits: [4096]u1 = undefined;
    for (&bits) |*b| {
        // biased stream so probabilities actually adapt
        b.* = @intFromBool(rnd.int(u8) < 60);
    }

    var enc = Encoder.init(allocator);
    defer enc.deinit();
    for (bits, 0..) |b, i| {
        try enc.encodeBit(&probs[i & 7], b);
    }
    try enc.flush();

    for (&probs) |*p| p.* = prob_init; // decoder-side fresh models
    var dec = try Decoder.init(enc.out.items);
    for (bits, 0..) |b, i| {
        try std.testing.expectEqual(b, try dec.decodeBit(&probs[i & 7]));
    }
}

test "range coder tree and direct roundtrip" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();

    var t8: [256]u16 = undefined;
    var t3: [8]u16 = undefined;
    var flag: u16 = prob_init;
    for (&t8) |*p| p.* = prob_init;
    for (&t3) |*p| p.* = prob_init;

    var syms8: [512]u8 = undefined;
    for (&syms8) |*s| s.* = rnd.int(u8);
    var syms3: [512]u3 = undefined;
    for (&syms3) |*s| s.* = rnd.int(u3);
    var direct: [64]u11 = undefined;
    for (&direct) |*d| d.* = rnd.int(u11);

    var enc = Encoder.init(allocator);
    defer enc.deinit();
    for (syms8, 0..) |s, i| {
        try treeEncode(&enc, &t8, 8, s);
        try enc.encodeBit(&flag, syms3[i] & 1);
        try treeEncode(&enc, &t3, 3, syms3[i]);
        try enc.encodeDirect(direct[i % direct.len], 11);
    }
    try enc.flush();

    for (&t8) |*p| p.* = prob_init;
    for (&t3) |*p| p.* = prob_init;
    flag = prob_init;
    var dec = try Decoder.init(enc.out.items);
    for (syms8, 0..) |s, i| {
        try std.testing.expectEqual(@as(u32, s), try treeDecode(&dec, &t8, 8));
        try std.testing.expectEqual(syms3[i] & 1, try dec.decodeBit(&flag));
        try std.testing.expectEqual(@as(u32, syms3[i]), try treeDecode(&dec, &t3, 3));
        try std.testing.expectEqual(@as(u32, direct[i % direct.len]), try dec.decodeDirect(11));
    }
}

test "decoder rejects short segments" {
    try std.testing.expectError(error.Corrupt, Decoder.init(""));
    try std.testing.expectError(error.Corrupt, Decoder.init("1234"));
}
