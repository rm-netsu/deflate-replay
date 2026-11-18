//! RFC 1951 constant tables and small domain types.

pub const RleToken = struct {
    sym: u8,
    extra: u8,
};

pub const cl_permutation = [19]u8{
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

pub const length_base = [29]u16{
    3,  4,  5,  6,   7,   8,   9,   10,  11,  13,
    15, 17, 19, 23,  27,  31,  35,  43,  51,  59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
};

pub const length_extra = [29]u4{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
    2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0,
};

pub const dist_base = [30]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

pub const dist_extra = [30]u4{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
    4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

pub const min_hlit = 257;
pub const max_hlit = 286;
pub const max_hdist = 30;
pub const max_code_lengths = max_hlit + max_hdist; // 316

/// Unique distance code + extra-bits value for a distance (RFC 1951 3.2.5).
pub const DistCode = struct { code: u5, extra: u16 };

pub fn distCodeOf(d: u32) ?DistCode {
    if (d < 1 or d > 32768) return null;
    var dc: u5 = 29;
    while (dc > 0 and dist_base[dc] > d) : (dc -= 1) {}
    return .{ .code = dc, .extra = @intCast(d - dist_base[dc]) };
}

/// Unique length code (minus 257) + extra-bits value for a length. Length
/// 258 maps to code 285; the equivalent 284+31 encoding is a DRP3 flag.
pub const LenCode = struct { lcode: u8, lextra: u16 };

pub fn lengthCodeOf(len: u32) ?LenCode {
    if (len < 3 or len > 258) return null;
    var i: usize = 28;
    while (i > 0 and @as(u32, length_base[i]) > len) : (i -= 1) {}
    return .{
        .lcode = @intCast(i),
        .lextra = @intCast(len - length_base[i]),
    };
}

pub const fixed_literal_lengths: [288]u8 = blk: {
    var lengths: [288]u8 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    break :blk lengths;
};

pub const fixed_dist_lengths: [32]u8 = @splat(5);
