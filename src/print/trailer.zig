const std = @import("std");

const StreamStats = @import("../records.zig").StreamStats;

const fmt_fdict =
    "  {s}: recorded 0x{X:0>8} (not verified: FDICT)\n";
const fmt_no_values =
    "  {s}: recorded 0x{X:0>8} (computed n/a: raw not supplied)\n";
const fmt_match =
    "  {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, match\n";
const fmt_mismatch =
    "  {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, MISMATCH (reproduced verbatim)\n";

pub inline fn checksum(
    writer: *std.Io.Writer,
    name: []const u8,
    st: *const StreamStats,
    fdict: bool,
    have_values: bool,
) !void {
    if (fdict)
        return writer.print(
            fmt_fdict,
            .{ name, st.checksum_recorded },
        );

    if (!have_values)
        return writer.print(
            fmt_no_values,
            .{ name, st.checksum_recorded },
        );

    if (st.checksum_recorded == st.checksum_computed)
        return writer.print(
            fmt_match,
            .{ name, st.checksum_recorded, st.checksum_computed },
        );

    try writer.print(
        fmt_mismatch,
        .{ name, st.checksum_recorded, st.checksum_computed },
    );
}

const fmt_isize_no_values =
    "  isize: recorded {d} (computed n/a: raw not supplied)\n";
const fmt_isize_match =
    "  isize: recorded {d}, computed {d}, match\n";
const fmt_isize_mismatch =
    "  isize: recorded {d}, computed {d}, MISMATCH (reproduced verbatim)\n";

pub inline fn input_size(
    writer: *std.Io.Writer,
    st: *const StreamStats,
    have_values: bool,
) !void {
    if (!have_values)
        return try writer.print(
            fmt_isize_no_values,
            .{st.isize_recorded},
        );

    if (st.isize_recorded == st.isize_computed)
        return writer.print(
            fmt_isize_match,
            .{ st.isize_recorded, st.isize_computed },
        );

    try writer.print(
        fmt_isize_mismatch,
        .{ st.isize_recorded, st.isize_computed },
    );
}
