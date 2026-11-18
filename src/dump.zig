//! dump: human-readable view of a .drp params file (v1, v2 or v3,
//! infgen-style, English). Pass the raw file to resolve raw-derived literal
//! values and rank-coded distances. DRP3 token sections need the raw file
//! (the coding model itself is raw-driven); without it the structure is
//! shown with per-block token counts only.

const std = @import("std");
const huffman = @import("huffman.zig");
const tables = @import("tables.zig");
const container = @import("container.zig");
const params = @import("params.zig");
const records = @import("records.zig");
const compact3 = @import("compact3.zig");
const raw = @import("raw.zig");
const stats = @import("stats.zig");

const StreamStats = stats.StreamStats;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const DumpOptions = struct {
    /// Print at most this many tokens per block (0 = none).
    max_tokens: usize = 0,
};

const format_v1 = @import("format/v1.zig");
const format_v2 = @import("format/v2.zig");
const format_v3 = @import("format/v3.zig");

pub fn dump(
    gpa: std.mem.Allocator,
    params_bytes: []const u8,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    if (params_bytes.len >= 6 and
        std.mem.eql(u8, params_bytes[0..4], &format_v1.magic))
    {
        const pr = format_v1.Reader.init(params_bytes) catch |err| {
            diagnostics.set(
                "not a valid DRP1 params file ({s})",
                .{@errorName(err)},
            );
            return error.BadParams;
        };
        var pv = format_v1.Provider.init(
            pr,
            diagnostics,
        );
        try w.print(
            "params: {d} bytes, format DRP1 v1\n",
            .{params_bytes.len},
        );
        try dumpCore(
            format_v1.Provider,
            &pv,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );
        return;
    }
    if (params_bytes.len >= 6 and
        std.mem.eql(u8, params_bytes[0..4], &format_v2.magic))
    {
        var pv = try format_v2.Provider.init(
            gpa,
            params_bytes,
            raw_bytes,
            diagnostics,
        );
        defer pv.deinit();
        try w.print(
            "params: {d} bytes, format DRP2 v2\n",
            .{params_bytes.len},
        );
        try dumpCore(
            format_v2.Provider,
            pv,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );
        return;
    }
    if (params_bytes.len >= 6 and
        std.mem.eql(u8, params_bytes[0..4], &format_v3.magic))
    {
        var pv = try format_v3.Provider.init(
            gpa,
            params_bytes,
            raw_bytes,
            diagnostics,
        );
        defer pv.deinit();
        try w.print(
            "params: {d} bytes, format DRP3 v3\n",
            .{params_bytes.len},
        );
        try dumpCore(
            format_v3.Provider,
            pv,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );
        return;
    }
    diagnostics.set(
        "not a valid params file (expected DRP1, DRP2 or DRP3 magic)",
        .{},
    );
    return error.BadParams;
}

fn dumpCore(
    comptime P: type,
    pv: *P,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    _ = diagnostics;
    var sink: raw.RawSink = undefined;

    var trailing: u64 = 0;
    var total_raw: u64 = 0;
    var total_literals: u64 = 0;
    var total_matches: u64 = 0;

    while (!pv.done()) {
        const kind = try pv.nextKind();

        if (kind == @intFromEnum(container.Kind.trailing)) {
            const tr = try pv.trailingRecord();
            trailing += tr.count;
            try w.print(
                "trailing: {d} byte(s) reproduced verbatim (not a DEFLATE stream)\n",
                .{tr.count},
            );
            continue;
        }

        var st = StreamStats{ .kind = @enumFromInt(kind) };

        switch (kind) {
            @intFromEnum(container.Kind.zlib) => {
                const hdr = try pv.zlibHeader();
                st.header_bytes = hdr;
                st.window_kb = (@as(u64, 1) << @intCast((hdr[0] >> 4) + 8)) >> 10;
                st.flevel = hdr[1] >> 6;
                if (hdr[1] & 0x20 != 0) {
                    _ = try pv.fdictId();
                    st.fdict = true;
                }
                st.checksum_kind = .adler;
                try w.print(
                    "stream {d}: zlib, header {X:0>2} {X:0>2}, window {d}K, level {s}",
                    .{
                        pv.stream_no,
                        hdr[0],
                        hdr[1],
                        st.window_kb,
                        container.flevelName(@intCast(st.flevel)),
                    },
                );
                if (st.fdict)
                    try w.print(
                        ", FDICT (raw output unavailable)",
                        .{},
                    );
                try w.print("\n", .{});
            },
            @intFromEnum(container.Kind.gzip) => {
                const gh = try pv.gzipHeader();
                st.checksum_kind = .crc;
                try w.print(
                    "stream {d}: gzip, header {d} bytes ({X:0>2} {X:0>2}...)\n",
                    .{ pv.stream_no, gh.len, gh[0], gh[1] },
                );
            },
            @intFromEnum(container.Kind.deflate) => try w.print(
                "stream {d}: raw DEFLATE\n",
                .{pv.stream_no},
            ),
            else => unreachable,
        }

        const flags = try pv.streamFlags();
        const have_values = flags.self_contained or raw_bytes != null;
        if (have_values) sink.start(null, null);

        var p: usize = 0;
        var block_no: usize = 0;

        blocks: while (true) {
            const bh = try pv.blockHeader();
            block_no += 1;
            const p_before = p;

            switch (bh.btype) {
                0 => {
                    const sb = try pv.storedBlock(p);
                    p += sb.len;
                    st.stored_blocks += 1;
                    if (sb.len == 0) st.stored_flush_blocks += 1;
                    if (sb.data) |d| {
                        if (have_values) try sink.putSlice(d);
                    }
                    try w.print(
                        "  block {d}: stored, len={d}{s}{s}\n",
                        .{
                            block_no,
                            sb.len,
                            if (sb.len == 0) " (flush marker)" else "",
                            if (bh.bfinal) ", final" else "",
                        },
                    );
                },
                1, 2 => {
                    if (bh.btype == 2) {
                        const dh = try pv.dynHeader();
                        st.dynamic_blocks += 1;
                        try w.print(
                            "  block {d}: dynamic, hlit={d} hdist={d} hclen={d}{s}\n",
                            .{
                                block_no,
                                dh.hlit,
                                dh.hdist,
                                dh.hclen,
                                if (bh.bfinal) ", final" else "",
                            },
                        );
                    } else {
                        st.fixed_blocks += 1;
                        try w.print(
                            "  block {d}: fixed{s}\n",
                            .{
                                block_no,
                                if (bh.bfinal) ", final" else "",
                            },
                        );
                    }

                    var shown: usize = 0;
                    var block_lits: u64 = 0;
                    var block_matches: u64 = 0;
                    if (pv.undecodableTokens()) {
                        // DRP3 without raw: the token bits cannot be decoded,
                        // but the stored per-block count is known.
                        try w.print(
                            "    tokens: {d} (decoding requires the raw file)\n",
                            .{pv.segTokenCount() orelse 0},
                        );
                    } else {
                        while (true) {
                            const t = try pv.token(p);
                            switch (t) {
                                .literal => |v_opt| {
                                    st.literals += 1;
                                    block_lits += 1;
                                    p += 1;
                                    if (have_values) {
                                        if (v_opt) |v| try sink.put(v);
                                    }
                                    shown += 1;
                                    if (opts.max_tokens > 0 and shown <= opts.max_tokens) {
                                        if (v_opt) |v| {
                                            if (std.ascii.isPrint(v)) {
                                                try w.print("    literal 0x{X:0>2} '{c}'\n", .{ v, v });
                                            } else {
                                                try w.print("    literal 0x{X:0>2}\n", .{v});
                                            }
                                        } else {
                                            try w.print("    literal <from raw>\n", .{});
                                        }
                                    }
                                },
                                .match => |mt| {
                                    st.matches += 1;
                                    block_matches += 1;
                                    const mlen = mt.length();
                                    p += mlen;
                                    if (mt.rank) |r| {
                                        if (r == 0) st.dist_rank0 += 1 else st.dist_ranked += 1;
                                    }
                                    if (mt.escaped) st.dist_escaped += 1;
                                    if (have_values and mt.dist_known) try sink.copyMatch(mt.dist, mlen);
                                    shown += 1;
                                    if (opts.max_tokens > 0 and shown <= opts.max_tokens) {
                                        if (mt.dist_known) {
                                            try w.print("    match len={d} dist={d}\n", .{ mlen, mt.dist });
                                        } else if (mt.rank) |r| {
                                            try w.print("    match len={d} dist=rank({d})\n", .{ mlen, r });
                                        } else {
                                            try w.print("    match len={d} dist=explicit\n", .{mlen});
                                        }
                                    }
                                },
                                .eob => {
                                    if (opts.max_tokens > 0 and shown > opts.max_tokens) {
                                        try w.print(
                                            "    ... ({d} tokens total)\n",
                                            .{shown},
                                        );
                                    }
                                    break;
                                },
                            }
                        }
                        try w.print(
                            "    -> {d} literals, {d} matches, {d} bytes out\n",
                            .{ block_lits, block_matches, p - p_before },
                        );
                        total_literals += st.literals;
                        total_matches += st.matches;
                        st.literals = 0; // per-block display only
                        st.matches = 0;
                    }
                },
                else => unreachable,
            }
            if (bh.bfinal) break :blocks;
        }

        _ = try pv.streamTrailingPad();

        var st_end = StreamStats{ .kind = st.kind }; // trailer stats only
        switch (kind) {
            @intFromEnum(container.Kind.zlib) => {
                const tr = try pv.checksumTrailer();
                st_end.checksum_kind = .adler;
                st_end.checksum_recorded = container.be32(tr);
                if (have_values and !st.fdict) {
                    st_end.checksum_computed = sink.adler;
                    st_end.checksum_verified = true;
                }
            },
            @intFromEnum(container.Kind.gzip) => {
                const tr = try pv.checksumTrailer();
                st_end.checksum_kind = .crc;
                st_end.checksum_recorded = container.le32(tr[0..4]);
                st_end.isize_recorded = container.le32(tr[4..8]);
                if (have_values) {
                    st_end.checksum_computed = sink.crcFinal();
                    st_end.checksum_verified = true;
                    st_end.isize_computed = @truncate(sink.head);
                }
            },
            else => {},
        }
        const raw_len = try pv.rawLen();
        _ = try pv.rawCrc();

        st.blocks = block_no;
        st.raw_len = raw_len;
        total_raw += raw_len;

        try w.print(
            "  end: raw={d} bytes, blocks={d} ({d} dynamic, {d} fixed, {d} stored)",
            .{
                raw_len,
                st.blocks,
                st.dynamic_blocks,
                st.fixed_blocks,
                st.stored_blocks,
            },
        );
        if (st.stored_flush_blocks > 0) {
            try w.print(
                ", {d} empty flush",
                .{st.stored_flush_blocks},
            );
        }
        try w.print("\n", .{});
        switch (st_end.checksum_kind) {
            .adler => try printChecksum(
                w,
                "adler32",
                st_end,
                st.fdict,
                have_values,
            ),
            .crc => {
                try printChecksum(
                    w,
                    "crc32  ",
                    st_end,
                    st.fdict,
                    have_values,
                );

                if (have_values) {
                    try w.print(
                        "  isize: recorded {d}, computed {d}, {s}\n",
                        .{
                            st_end.isize_recorded,
                            st_end.isize_computed,
                            if (st_end.isize_recorded == st_end.isize_computed)
                                "match"
                            else
                                "MISMATCH (reproduced verbatim)",
                        },
                    );
                } else {
                    try w.print(
                        "  isize: recorded {d} (computed n/a: raw not supplied)\n",
                        .{st_end.isize_recorded},
                    );
                }
            },
            .none => {},
        }
    }

    try w.print(
        "totals: streams={d}, raw={d} bytes, literals={d}, matches={d}, trailing={d}\n",
        .{
            pv.stream_no,
            total_raw,
            total_literals,
            total_matches,
            trailing,
        },
    );
}

fn printChecksum(
    w: *std.Io.Writer,
    name: []const u8,
    st: StreamStats,
    fdict: bool,
    have_values: bool,
) !void {
    if (fdict) {
        try w.print(
            "  {s}: recorded 0x{X:0>8} (not verified: FDICT)\n",
            .{ name, st.checksum_recorded },
        );
        return;
    }

    if (!have_values) {
        try w.print(
            "  {s}: recorded 0x{X:0>8} (computed n/a: raw not supplied)\n",
            .{ name, st.checksum_recorded },
        );
        return;
    }

    if (st.checksum_recorded == st.checksum_computed) {
        try w.print(
            "  {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, match\n",
            .{ name, st.checksum_recorded, st.checksum_computed },
        );
    } else {
        try w.print(
            "  {s}: recorded 0x{X:0>8}, computed 0x{X:0>8}, MISMATCH (reproduced verbatim)\n",
            .{ name, st.checksum_recorded, st.checksum_computed },
        );
    }
}
