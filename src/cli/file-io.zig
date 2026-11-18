const std = @import("std");
const drp = @import("main.zig").drp;

pub fn readFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    diagnostics: *drp.Diagnostics,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .unlimited,
    ) catch |err| {
        diagnostics.set(
            "cannot read '{s}': {s}",
            .{ path, @errorName(err) },
        );
        return err;
    };
}

pub fn writeWholeFile(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    diagnostics: *drp.Diagnostics,
) !void {
    const file = std.Io.Dir.cwd().createFile(
        io,
        path,
        .{},
    ) catch |err| {
        diagnostics.set(
            "cannot create '{s}': {s}",
            .{ path, @errorName(err) },
        );
        return err;
    };
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
