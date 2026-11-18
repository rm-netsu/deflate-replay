const std = @import("std");
const drp = @import("main.zig").drp;

const mod_flags = @import("flags.zig");
const CommonFlags = mod_flags.CommonFlags;
const parseCommonFlag = mod_flags.parseCommonFlag;
const flagsToAnalyzeOptions = mod_flags.flagsToAnalyzeOptions;
const mod_file_io = @import("file-io.zig");
const writeWholeFile = mod_file_io.writeWholeFile;
const readFile = mod_file_io.readFile;

const mod_stream_stats = @import("stream-stats.zig");
const printStreamStats = mod_stream_stats.printStreamStats;

pub fn cmdRoundtrip(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    diagnostics: *drp.Diagnostics,
    out: *std.Io.Writer,
) !u8 {
    var input_path: ?[]const u8 = null;
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
        if (std.mem.startsWith(u8, arg, "--")) {
            diagnostics.set(
                "unknown option '{s}' for roundtrip",
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
        diagnostics.set("roundtrip: missing <input> path", .{});
        return error.Usage;
    }

    const params_path = try std.fmt.allocPrint(
        arena,
        "{s}.drp",
        .{input_path.?},
    );
    const raw_path = try std.fmt.allocPrint(
        arena,
        "{s}.raw",
        .{input_path.?},
    );
    const output_path = try std.fmt.allocPrint(
        arena,
        "{s}.recompressed",
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

    var analyze_result = try drp.analyze.analyze(
        gpa,
        input_bytes,
        flagsToAnalyzeOptions(flags),
        diagnostics,
        &params_writer.writer,
        &raw_writer.writer,
    );
    defer analyze_result.deinit(gpa);

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

    var verified_bytes: u64 = 0;
    var any_fdict = false;
    for (analyze_result.streams) |st| {
        if (st.fdict) any_fdict = true else verified_bytes += st.raw_len;
    }

    var replay_out_writer: std.Io.Writer.Allocating = .init(gpa);
    defer replay_out_writer.deinit();

    var replay_result = try drp.replay.replay(
        gpa,
        params_writer.written(),
        raw_writer.written(),
        .{ .verify_raw = true },
        diagnostics,
        &replay_out_writer.writer,
    );
    defer replay_result.deinit(gpa);

    try writeWholeFile(
        io,
        output_path,
        replay_out_writer.written(),
        diagnostics,
    );

    try out.print(
        "roundtrip: {s} ({d} bytes)\n",
        .{ input_path.?, input_bytes.len },
    );

    try out.print("streams: {d}\n", .{analyze_result.streams.len});
    for (analyze_result.streams, 1..) |st, no| {
        try printStreamStats(out, no, st);
    }

    if (analyze_result.trailing_bytes > 0) {
        std.debug.print(
            "warning: {d} trailing byte(s) reproduced verbatim (not parseable as DEFLATE)\n",
            .{analyze_result.trailing_bytes},
        );
        try out.print(
            "trailing: {d} bytes (reproduced verbatim)\n",
            .{analyze_result.trailing_bytes},
        );
    }
    if (verified_bytes > 0 and any_fdict) {
        try out.print(
            "raw verification: OK ({d} bytes match; FDICT stream(s) reproduced from params)\n",
            .{verified_bytes},
        );
    } else if (verified_bytes > 0) {
        try out.print(
            "raw verification: OK ({d} bytes match)\n",
            .{verified_bytes},
        );
    } else {
        try out.print(
            "raw verification: none (all streams use preset dictionaries)\n",
            .{},
        );
    }

    try printSha256(out, "input: ", input_bytes);
    try printSha256(
        out,
        "output:",
        replay_out_writer.written(),
    );

    const identical = std.mem.eql(
        u8,
        input_bytes,
        replay_out_writer.written(),
    );
    if (identical) {
        try out.print(
            "RESULT: BIT-IDENTICAL ({d} / {d} bytes)\n",
            .{ replay_out_writer.written().len, input_bytes.len },
        );
        return 0;
    }

    try out.print(
        "RESULT: MISMATCH ({d} of {d} bytes)\n",
        .{ replay_out_writer.written().len, input_bytes.len },
    );
    return 1;
}

fn printSha256(out: *std.Io.Writer, label: []const u8, data: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);
    try out.print("  {s} sha256: {s}\n", .{ label, &hex });
}
