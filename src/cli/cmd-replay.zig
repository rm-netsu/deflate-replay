const std = @import("std");
const drp = @import("main.zig").drp;

const mod_flags = @import("flags.zig");
const getFlagValue = mod_flags.getFlagValue;

const mod_file_io = @import("file-io.zig");
const readFile = mod_file_io.readFile;
const writeWholeFile = mod_file_io.writeWholeFile;

const mod_stream_stats = @import("stream-stats.zig");
const printStreamStats = mod_stream_stats.printStreamStats;

pub fn cmdReplay(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    diagnostics: *drp.Diagnostics,
    out: *std.Io.Writer,
) !u8 {
    var params_path: ?[]const u8 = null;
    var raw_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var no_raw = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--out")) {
            out_path = try getFlagValue(args, &i, diagnostics);
        } else if (std.mem.eql(u8, a, "--no-raw")) {
            no_raw = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            diagnostics.set("unknown option '{s}' for replay", .{a});
            return error.Usage;
        } else if (params_path == null) {
            params_path = a;
        } else if (raw_path == null) {
            raw_path = a;
        } else {
            diagnostics.set("unexpected extra argument '{s}'", .{a});
            return error.Usage;
        }
    }
    if (params_path == null) {
        diagnostics.set("replay: missing <params> path", .{});
        return error.Usage;
    }
    if (raw_path == null and !no_raw) {
        diagnostics.set("replay: missing <raw> path (or use --no-raw)", .{});
        return error.Usage;
    }

    const default_out = if (std.mem.endsWith(u8, params_path.?, ".drp"))
        try std.fmt.allocPrint(arena, "{s}.recompressed", .{params_path.?[0 .. params_path.?.len - 4]})
    else
        try std.fmt.allocPrint(arena, "{s}.recompressed", .{params_path.?});
    const output_path = out_path orelse default_out;

    const params_bytes = try readFile(io, gpa, params_path.?, diagnostics);
    defer gpa.free(params_bytes);

    var raw_owned: ?[]u8 = null;
    defer if (raw_owned) |b| gpa.free(b);
    if (!no_raw) raw_owned = try readFile(io, gpa, raw_path.?, diagnostics);
    const raw_bytes: []const u8 = raw_owned orelse "";

    var outaw: std.Io.Writer.Allocating = .init(gpa);
    defer outaw.deinit();
    var result = try drp.replay.replay(gpa, params_bytes, raw_bytes, .{
        .verify_raw = !no_raw,
    }, diagnostics, &outaw.writer);
    defer result.deinit(gpa);
    try writeWholeFile(io, output_path, outaw.written(), diagnostics);

    try out.print("replay: {s} + {s}\n", .{
        params_path.?,
        if (no_raw) "(no raw file, verification skipped)" else raw_path.?,
    });
    try out.print("streams: {d}\n", .{result.streams.len});
    for (result.streams, 1..) |st, no| {
        try printStreamStats(out, no, st);
    }
    if (no_raw) {
        try out.print("raw verification: skipped (--no-raw)\n", .{});
    } else {
        try out.print("raw verification: OK ({d} bytes match)\n", .{result.totalRaw()});
    }
    if (result.trailing_bytes > 0) {
        try out.print("trailing: {d} bytes (reproduced verbatim)\n", .{result.trailing_bytes});
    }
    try out.print("output: {s} ({d} bytes)\n", .{ output_path, outaw.written().len });
    return 0;
}
