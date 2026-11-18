//! Error diagnostics: library calls fill this in before returning an error.

const std = @import("std");

pub const Diagnostics = struct {
    const Self = @This();

    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(
            &self.buf,
            fmt,
            args,
        ) catch blk: {
            self.buf[self.buf.len - 1] = 0;
            break :blk self.buf[0 .. self.buf.len - 1];
        };
        self.len = s.len;
    }

    pub fn get(self: *const Self) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *Self) void {
        self.len = 0;
    }
};
