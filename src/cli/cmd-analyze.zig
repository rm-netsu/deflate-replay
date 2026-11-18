const std = @import("std");
const drp = @import("main.zig").drp;

const mod_flags = @import("flags.zig");
const getFlagValue = mod_flags.getFlagValue;
const CommonFlags = mod_flags.CommonFlags;
const parseCommonFlag = mod_flags.parseCommonFlag;
const flagsToAnalyzeOptions = mod_flags.flagsToAnalyzeOptions;

const mod_file_io = @import("file-io.zig");
const readFile = mod_file_io.readFile;
const writeWholeFile = mod_file_io.writeWholeFile;

const mod_stream_stats = @import("stream-stats.zig");
const printStreamStats = mod_stream_stats.printStreamStats;

pub fn cmdAnalyze(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    diagnostics: *drp.Diagnostics,
    out: *std.Io.Writer,
) !u8 {
    var input_path: ?[]const u8 = null;
    var out_params: ?[]const u8 = null;
    var out_raw: ?[]const u8 = null;
    var flags = CommonFlags{};

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (try parseCommonFlag(
            &flags,
            args,
            &arg_idx,
            diagnostics,
        )) continue;

        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--out-params")) {
            out_params = try getFlagValue(
                args,
                &arg_idx,
                diagnostics,
            );
        } else if (std.mem.eql(u8, arg, "--out-raw")) {
            out_raw = try getFlagValue(
                args,
                &arg_idx,
                diagnostics,
            );
        } else if (std.mem.startsWith(u8, arg, "--")) {
            diagnostics.set(
                "unknown option '{s}' for analyze",
                .{arg},
            );
            return error.Usage;
        } else if (input_path == null) {
            input_path = arg;
        } else {
            diagnostics.set(
                "unexpected extra argument '{s}'",
                .{arg},
            );
            return error.Usage;
        }
    }

    if (input_path == null) {
        diagnostics.set("analyze: missing <input> path", .{});
        return error.Usage;
    }

    const params_path = out_params orelse try std.fmt.allocPrint(
        arena,
        "{s}.drp",
        .{input_path.?},
    );
    const raw_path = out_raw orelse try std.fmt.allocPrint(
        arena,
        "{s}.raw",
        .{input_path.?},
    );

    const input_bytes = try readFile(
        io,
        gpa,
        input_path.?,
        diagnostics,
    );
    defer gpa.free(input_bytes);

    var params_writer: std.Io.Writer.Allocating = .init(gpa);
    defer params_writer.deinit();
    var raw_writer: std.Io.Writer.Allocating = .init(gpa);
    defer raw_writer.deinit();

    var result = try drp.analyze.analyze(
        gpa,
        input_bytes,
        flagsToAnalyzeOptions(flags),
        diagnostics,
        &params_writer.writer,
        &raw_writer.writer,
    );
    defer result.deinit(gpa);

    try writeWholeFile(
        io,
        params_path,
        params_writer.written(),
        diagnostics,
    );
    try writeWholeFile(
        io,
        raw_path,
        raw_writer.written(),
        diagnostics,
    );

    try out.print(
        "analyze: {s} ({d} bytes)\n",
        .{ input_path.?, input_bytes.len },
    );

    try out.print("streams: {d}\n", .{result.streams.len});
    for (result.streams, 1..) |st, no| {
        try printStreamStats(out, no, st);
    }

    if (result.trailing_bytes > 0) {
        std.debug.print(
            "warning: {d} trailing byte(s) after the last stream were not parseable as DEFLATE; recorded and reproduced verbatim\n",
            .{result.trailing_bytes},
        );
        try out.print(
            "trailing: {d} bytes (reproduced verbatim)\n",
            .{result.trailing_bytes},
        );
    }

    try out.print(
        "params: {s} ({d} bytes)\n",
        .{ params_path, params_writer.written().len },
    );
    try out.print(
        "raw:    {s} ({d} bytes)\n",
        .{ raw_path, raw_writer.written().len },
    );
    return 0;
}
