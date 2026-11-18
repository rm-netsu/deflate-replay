const std = @import("std");
const drp = @import("main.zig").drp;

pub fn getFlagValue(
    args: []const [:0]const u8,
    arg_idx: *usize,
    diagnostics: *drp.Diagnostics,
) ![]const u8 {
    if (arg_idx.* + 1 >= args.len) {
        diagnostics.set(
            "option '{s}' requires a value",
            .{args[arg_idx.*]},
        );
        return error.Usage;
    }

    arg_idx.* += 1;
    return args[arg_idx.*];
}

pub const CommonFlags = struct {
    format: drp.stats.Format = .auto,
    allow_fdict: bool = false,
    strict_streams: bool = false,
    v1: bool = false,
    v2: bool = false,
    v3: bool = false,
    self_contained: bool = false,
    no_rank: bool = false,
};

pub fn parseCommonFlag(
    flags: *CommonFlags,
    args: []const [:0]const u8,
    arg_idx: *usize,
    diagnostics: *drp.Diagnostics,
) !bool {
    const arg = args[arg_idx.*];

    if (std.mem.eql(u8, arg, "--format")) {
        const v = try getFlagValue(
            args,
            arg_idx,
            diagnostics,
        );
        flags.format = std.meta.stringToEnum(
            drp.stats.Format,
            v,
        ) orelse {
            diagnostics.set(
                "unknown --format value '{s}' (expected auto|zlib|gzip|deflate)",
                .{v},
            );
            return error.Usage;
        };
        return true;
    }

    if (std.mem.eql(u8, arg, "--allow-fdict")) {
        flags.allow_fdict = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--strict-streams")) {
        flags.strict_streams = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--v1")) {
        if (flags.v2 or flags.v3) {
            diagnostics.set(
                "conflicting params format flags: pick at most one of --v1/--v2/--v3 ('{s}' clashes with an earlier flag)",
                .{arg},
            );
            return error.Usage;
        }
        flags.v1 = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--v2")) {
        if (flags.v1 or flags.v3) {
            diagnostics.set(
                "conflicting params format flags: pick at most one of --v1/--v2/--v3 ('{s}' clashes with an earlier flag)",
                .{arg},
            );
            return error.Usage;
        }
        flags.v2 = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--v3")) {
        if (flags.v1 or flags.v2) {
            diagnostics.set(
                "conflicting params format flags: pick at most one of --v1/--v2/--v3 ('{s}' clashes with an earlier flag)",
                .{arg},
            );
            return error.Usage;
        }
        flags.v3 = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--self-contained")) {
        flags.self_contained = true;
        return true;
    }

    if (std.mem.eql(u8, arg, "--no-rank")) {
        flags.no_rank = true;
        return true;
    }

    return false;
}

pub fn flagsToAnalyzeOptions(flags: CommonFlags) drp.Options {
    return .{
        .format = flags.format,
        .allow_fdict = flags.allow_fdict,
        .strict_streams = flags.strict_streams,
        .params_version = paramsVersionFromFlag(flags),
        .self_contained = flags.self_contained,
        .use_rank = !flags.no_rank,
    };
}

inline fn paramsVersionFromFlag(flags: CommonFlags) drp.ParamsVersion {
    // Conflicting combinations are rejected in parseCommonFlag(); exactly one
    // of the three flags (or none) is set by the time this runs.
    return if (flags.v1) .v1 else if (flags.v2) .v2 else .v3;
}
