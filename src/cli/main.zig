pub const drp = @import("deflate_replay");

const std = @import("std");
const Io = std.Io;

const usage_text = @embedFile("usage.md");

pub fn main(init: std.process.Init) !void {
    var diagnostics = drp.Diagnostics{};
    const exit_code = run(
        init,
        &diagnostics,
    ) catch |err| switch (err) {
        error.Usage => {
            if (diagnostics.get().len > 0) {
                std.debug.print("error: {s}\n", .{diagnostics.get()});
            }
            std.debug.print("{s}", .{usage_text});
            std.process.exit(2);
        },
        else => {
            if (diagnostics.get().len > 0) {
                std.debug.print("error: {s}\n", .{diagnostics.get()});
            } else {
                std.debug.print("error: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        },
    };
    std.process.exit(exit_code);
}

const mod_commands = @import("commands.zig");
const cmdAnalyze = mod_commands.cmdAnalyze;
const cmdDump = mod_commands.cmdDump;
const cmdReplay = mod_commands.cmdReplay;
const cmdRoundtrip = mod_commands.cmdRoundtrip;

fn run(init: std.process.Init, diagnostics: *drp.Diagnostics) !u8 {
    const arena: std.mem.Allocator = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(
        .stdout(),
        io,
        &stdout_buffer,
    );
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage_text);
        return 2;
    }
    const cmd: []const u8 = args[1];

    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try out.writeAll(usage_text);
        return 0;
    } else if (std.mem.eql(u8, cmd, "analyze")) {
        return cmdAnalyze(
            arena,
            gpa,
            io,
            args[2..],
            diagnostics,
            out,
        );
    } else if (std.mem.eql(u8, cmd, "replay")) {
        return cmdReplay(
            arena,
            gpa,
            io,
            args[2..],
            diagnostics,
            out,
        );
    } else if (std.mem.eql(u8, cmd, "roundtrip")) {
        return cmdRoundtrip(
            arena,
            gpa,
            io,
            args[2..],
            diagnostics,
            out,
        );
    } else if (std.mem.eql(u8, cmd, "dump")) {
        return cmdDump(
            gpa,
            io,
            args[2..],
            diagnostics,
            out,
        );
    }

    diagnostics.set("unknown command '{s}'", .{cmd});
    return error.Usage;
}
