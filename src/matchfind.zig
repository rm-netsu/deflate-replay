//! Deterministic nearest-first match-candidate enumeration (rank coding).
//!
//! A distance can be stored compactly as its *rank* among the candidate
//! positions instead of 15 raw bits. Both analyze (converter) and replay
//! enumerate candidates with byte-for-byte identical rules over the same raw
//! data, so the rank unambiguously reconstructs the distance:
//!
//!   - candidates for a match at stream position `p`, length `len`, are all
//!     positions j in [max(0, p-32768), p-1] with
//!     raw[j..j+len] == raw[p..p+len] (overlapping copies included);
//!   - enumeration is strictly nearest-first (descending j);
//!   - positions are indexed by a 15-bit hash of their first 3 bytes; the
//!     chains yield positions in descending order for j <= p-3, while
//!     j = p-1 and j = p-2 (whose 3-byte prefixes are incomplete at insert
//!     time on the producing side) are checked explicitly first.
//!
//! Hash collisions only add non-matching entries that fail the full-length
//! comparison; they never change the candidate sequence.

const std = @import("std");

pub const hash_bits = 15;
pub const hash_size = 1 << hash_bits;
pub const window: usize = 32768;
/// Highest rank that can be stored without an explicit escape.
pub const max_rank = 528;
/// Position-visit budget before the converter gives up and escapes.
pub const max_hops = 4096;

pub const Error = error{RankNotFound};

fn hash3(a: u8, b: u8, c: u8) usize {
    const h = (@as(u32, a) << 16) ^ (@as(u32, b) << 8) ^ @as(u32, c);
    const m = h *% 0x9E3779B1;
    return @intCast(m >> (32 - hash_bits));
}

pub const ByteSrc = union(enum) {
    /// Raw data of the whole file plus this stream's base offset and the
    /// number of valid positions in this stream's slice.
    slice: struct { data: []const u8, base: usize, len: usize },

    pub fn at(self: ByteSrc, pos: usize) u8 {
        return switch (self) {
            .slice => |s| s.data[s.base + pos],
        };
    }
};

pub const DistEncoding = union(enum) {
    rank: u16,
    escape,
};

pub const Matcher = struct {
    src: ByteSrc,
    /// head[h] = latest position with hash h, plus one (0 = empty).
    head: [hash_size]u64,
    /// prev[pos & (window-1)] = previous position with the same hash, plus one.
    prev: [window]u64,
    /// Next stream position to insert.
    inserted: usize,

    pub fn init(src: ByteSrc) Matcher {
        return .{ .src = src, .head = @splat(0), .prev = @splat(0), .inserted = 0 };
    }

    pub fn reset(self: *Matcher, src: ByteSrc) void {
        self.src = src;
        @memset(&self.head, 0);
        @memset(&self.prev, 0);
        self.inserted = 0;
    }

    fn insert(self: *Matcher, pos: usize) void {
        const h = hash3(self.src.at(pos), self.src.at(pos + 1), self.src.at(pos + 2));
        const tag = @as(u64, @intCast(pos)) + 1;
        self.prev[pos & (window - 1)] = self.head[h];
        self.head[h] = tag;
    }

    /// Inserts every position j <= p-3 into the chains. Positions p-1 and
    /// p-2 are intentionally left out (their 3-byte prefixes are not
    /// complete on the producing side at this point); the walker checks
    /// them explicitly. Both sides apply the identical rule at identical
    /// points, so the candidate sequence is reproducible.
    pub fn syncTo(self: *Matcher, p: usize) void {
        const bound = if (p >= 3) p - 2 else 0;
        while (self.inserted < bound) : (self.inserted += 1) {
            self.insert(self.inserted);
        }
    }

    fn fullMatch(self: *const Matcher, j: usize, p: usize, len: usize) bool {
        if (self.src.at(j + len - 1) != self.src.at(p + len - 1)) return false;
        var k: usize = 0;
        while (k < len) : (k += 1) {
            if (self.src.at(j + k) != self.src.at(p + k)) return false;
        }
        return true;
    }

    pub const Walker = struct {
        m: *const Matcher,
        p: usize,
        len: usize,
        lo: usize,
        next_manual: usize,
        manual_left: u8,
        cur: u64,
        hops: usize,

        pub fn init(m: *const Matcher, p: usize, len: usize) Walker {
            return .{
                .m = m,
                .p = p,
                .len = len,
                .lo = if (p > window) p - window else 0,
                .next_manual = if (p >= 1) p - 1 else 0,
                .manual_left = @intCast(@min(p, 2)),
                .cur = m.head[hash3(m.src.at(p), m.src.at(p + 1), m.src.at(p + 2))],
                .hops = 0,
            };
        }

        /// Next candidate position (nearest-first, full match) or null.
        pub fn next(self: *Walker) ?usize {
            while (true) {
                var j: usize = undefined;
                if (self.manual_left > 0) {
                    self.manual_left -= 1;
                    j = self.next_manual;
                    if (self.next_manual > 0) self.next_manual -= 1;
                } else {
                    if (self.cur == 0) return null;
                    j = @intCast(self.cur - 1);
                    if (j < self.lo) return null; // chain is descending: older entries are even lower
                    self.cur = self.m.prev[j & (window - 1)];
                }
                self.hops += 1;
                if (self.m.fullMatch(j, self.p, self.len)) return j;
            }
        }
    };

    /// Rank of the actual distance `d` for the match at `p` (0 = nearest
    /// candidate). The raw bytes at p..p+len-1 must be complete in `src`.
    /// Returns .escape when the rank exceeds max_rank/max_hops or the
    /// distance points before the start of the stream.
    pub fn rankOf(self: *Matcher, p: usize, len: usize, d: u32) DistEncoding {
        if (d < 1 or @as(usize, d) > p) return .escape;
        const actual = p - d;
        var w = Walker.init(self, p, len);
        var rank: u16 = 0;
        while (w.next()) |j| {
            if (j == actual) return .{ .rank = rank };
            if (w.hops > max_hops) return .escape;
            rank += 1;
            if (rank > max_rank) return .escape;
        }
        return .escape;
    }

    /// Distance of the candidate with the given rank (replay side).
    pub fn nth(self: *Matcher, p: usize, len: usize, rank: u16) Error!u32 {
        var w = Walker.init(self, p, len);
        var seen: u16 = 0;
        while (w.next()) |j| {
            if (seen == rank) return @intCast(p - j);
            seen += 1;
        }
        return error.RankNotFound;
    }

    /// Nearest candidate matching `len` bytes at `p`, or null when none is
    /// found within `max_hops` chain visits. Requires p + len <= src length.
    pub fn firstCandidate(self: *const Matcher, p: usize, len: usize, hop_budget: usize) ?usize {
        var w = Walker.init(self, p, len);
        while (w.next()) |j| {
            if (w.hops > hop_budget) return null;
            return j;
        }
        return null;
    }
};

test "rank of nearest and farther candidates" {
    const raw_data = "abcabcabc";
    var m = Matcher.init(.{ .slice = .{ .data = raw_data, .base = 0, .len = raw_data.len } });
    // match at p=6, len=3, raw[6..9] = "abc"
    m.syncTo(6);
    // candidates nearest-first: j=3 ("abc"), j=0 ("abc")
    try std.testing.expectEqual(@as(u16, 0), m.rankOf(6, 3, 3).rank); // d=3 -> j=3
    try std.testing.expectEqual(@as(u16, 1), m.rankOf(6, 3, 6).rank); // d=6 -> j=0
    try std.testing.expectEqual(@as(u32, 3), try m.nth(6, 3, 0));
    try std.testing.expectEqual(@as(u32, 6), try m.nth(6, 3, 1));
    try std.testing.expectError(error.RankNotFound, m.nth(6, 3, 2));
}

test "manual p-1/p-2 candidates (small distances, overlap)" {
    const raw_data = "aaaaaa";
    var m = Matcher.init(.{ .slice = .{ .data = raw_data, .base = 0, .len = raw_data.len } });
    m.syncTo(2);
    // p=2, len=4: candidates j=1 then j=0 (chains hold nothing yet)
    try std.testing.expectEqual(@as(u16, 0), m.rankOf(2, 4, 1).rank);
    try std.testing.expectEqual(@as(u16, 1), m.rankOf(2, 4, 2).rank);
    try std.testing.expectEqual(@as(u32, 1), try m.nth(2, 4, 0));
    try std.testing.expectEqual(@as(u32, 2), try m.nth(2, 4, 1));
}

test "escape on long candidate lists" {
    const raw_data = "a" ** 6000;
    var m = Matcher.init(.{ .slice = .{ .data = raw_data, .base = 0, .len = raw_data.len } });
    m.syncTo(5990);
    // every position is a candidate for a run match
    try std.testing.expectEqual(@as(u16, 0), m.rankOf(5990, 3, 1).rank);
    const r = m.rankOf(5990, 3, 301);
    try std.testing.expectEqual(@as(u16, 300), r.rank);
    try std.testing.expectEqual(@as(u32, 301), try m.nth(5990, 3, 300));
    // d=4000 -> j=1990 with 3999 nearer candidates: beyond max_rank
    try std.testing.expect(m.rankOf(5990, 3, 4000) == .escape);
}

test "escape on parity-halved candidate lists" {
    const raw_data = "ab" ** 5000; // 10000 bytes
    var m = Matcher.init(.{ .slice = .{ .data = raw_data, .base = 0, .len = raw_data.len } });
    m.syncTo(9990);
    // p=9990 "abab": candidates are the even positions; d=9000 -> j=990
    // with 4499 nearer even candidates -> escape
    try std.testing.expect(m.rankOf(9990, 4, 9000) == .escape);
    try std.testing.expectEqual(@as(u16, 0), m.rankOf(9990, 4, 2).rank);
}

test "window boundary respected" {
    var data: [70000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    // filler bytes are always < 0x80; the pattern starts with 0xFF, so it
    // cannot occur by chance
    for (&data) |*b| b.* = rnd.int(u8) & 0x7F;
    const pat = "\xFFz9!";
    const p: usize = 69900;
    @memcpy(data[p - 100 ..][0..4], pat); // nearest copy
    @memcpy(data[p - 32768 ..][0..4], pat); // copy exactly at the window edge
    @memcpy(data[p..][0..4], pat);
    var m = Matcher.init(.{ .slice = .{ .data = &data, .base = 0, .len = data.len } });
    m.syncTo(p);
    try std.testing.expectEqual(@as(u16, 0), m.rankOf(p, 4, 100).rank);
    try std.testing.expectEqual(@as(u16, 1), m.rankOf(p, 4, 32768).rank);
    try std.testing.expectEqual(@as(u32, 32768), try m.nth(p, 4, 1));
    try std.testing.expectEqual(@as(u32, 100), try m.nth(p, 4, 0));
}
