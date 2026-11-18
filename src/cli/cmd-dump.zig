const std = @import("std");
const drp = @import("main.zig").drp;

const mod_flags = @import("flags.zig");
const getFlagValue = mod_flags.getFlagValue;

const mod_file_io = @import("file-io.zig");
const readFile = mod_file_io.readFile;

pub fn cmdDump(
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    diagnostics: *drp.Diagnostics,
    out: *std.Io.Writer,
) !u8 {
    var params_path: ?[]const u8 = null;
    var raw_path: ?[]const u8 = null;
    var max_tokens: usize = 0;

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const a = args[arg_idx];
        if (std.mem.eql(u8, a, "--tokens")) {
            const v = try getFlagValue(
                args,
                &arg_idx,
                diagnostics,
            );
            max_tokens = std.fmt.parseInt(usize, v, 10) catch {
                diagnostics.set("bad --tokens value '{s}'", .{v});
                return error.Usage;
            };
        } else if (std.mem.startsWith(u8, a, "--")) {
            diagnostics.set("unknown option '{s}' for dump", .{a});
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
        diagnostics.set("dump: missing <params> path", .{});
        return error.Usage;
    }

    const params_bytes = try readFile(
        io,
        gpa,
        params_path.?,
        diagnostics,
    );
    defer gpa.free(params_bytes);

    var raw_owned: ?[]u8 = null;
    defer if (raw_owned) |b| gpa.free(b);
    if (raw_path) |rp| raw_owned = try readFile(
        io,
        gpa,
        rp,
        diagnostics,
    );
    const raw_bytes: ?[]const u8 = raw_owned;

    try drp.dump.dump(
        gpa,
        params_bytes,
        raw_bytes,
        .{ .max_tokens = max_tokens },
        diagnostics,
        out,
    );
    return 0;
}
