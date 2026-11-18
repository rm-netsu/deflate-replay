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

const format_v1 = @import("format/v1.zig");
const format_v2 = @import("format/v2.zig");
const format_v3 = @import("format/v3.zig");

const print = @import("print/_.zig");

// MARK: dump

pub const DumpOptions = struct {
    /// Print at most this many tokens per block (0 = none).
    max_tokens: usize = 0,
};

const msg_invalid_params_file =
    "not a valid params file (expected DRP1, DRP2 or DRP3 magic)";

pub fn dump(
    gpa: std.mem.Allocator,
    params_bytes: []const u8,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    if (params_bytes.len < 6) {
        diagnostics.set(msg_invalid_params_file, .{});
        return error.BadParams;
    }

    if (matchMagic(params_bytes, format_v1.magic))
        return dumpV1(
            params_bytes,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );

    if (matchMagic(params_bytes, format_v2.magic))
        return dumpV2(
            gpa,
            params_bytes,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );

    if (matchMagic(params_bytes, format_v3.magic))
        return dumpV3(
            gpa,
            params_bytes,
            raw_bytes,
            opts,
            diagnostics,
            w,
        );

    diagnostics.set(msg_invalid_params_file, .{});
    return error.BadParams;
}

inline fn matchMagic(params_bytes: []const u8, magic: [4]u8) bool {
    return std.mem.eql(u8, params_bytes[0..4], &magic);
}

// MARK: dumpV1

inline fn dumpV1(
    params_bytes: []const u8,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    const Reader = format_v1.Reader;
    const Provider = format_v1.Provider;

    const reader = Reader.init(params_bytes) catch |err| {
        diagnostics.set(
            "not a valid DRP1 params file ({s})",
            .{@errorName(err)},
        );
        return error.BadParams;
    };
    var provider = Provider.init(reader, diagnostics);

    try printParamsOutline(w, params_bytes, "DRP1 (v1)");
    try dumpStreams(
        Provider,
        &provider,
        raw_bytes,
        opts,
        diagnostics,
        w,
    );
    return;
}

// MARK: dumpV2

inline fn dumpV2(
    gpa: std.mem.Allocator,
    params_bytes: []const u8,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    const Provider = format_v2.Provider;

    var provider = try Provider.init(
        gpa,
        params_bytes,
        raw_bytes,
        diagnostics,
    );
    defer provider.deinit();

    try printParamsOutline(w, params_bytes, "DRP2 (v2)");
    try dumpStreams(
        Provider,
        provider,
        raw_bytes,
        opts,
        diagnostics,
        w,
    );
    return;
}

// MARK: dumpV3

inline fn dumpV3(
    gpa: std.mem.Allocator,
    params_bytes: []const u8,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    diagnostics: *Diagnostics,
    w: *std.Io.Writer,
) !void {
    const Provider = format_v3.Provider;

    var provider = try Provider.init(
        gpa,
        params_bytes,
        raw_bytes,
        diagnostics,
    );
    defer provider.deinit();

    try printParamsOutline(w, params_bytes, "DRP3 (v3)");
    try dumpStreams(
        Provider,
        provider,
        raw_bytes,
        opts,
        diagnostics,
        w,
    );
    return;
}

// MARK: printParamsOutline

inline fn printParamsOutline(
    w: *std.Io.Writer,
    params_bytes: []const u8,
    comptime ver: []const u8,
) !void {
    try w.print(
        "params: {d} bytes, format " ++ ver ++ "\n",
        .{params_bytes.len},
    );
}

// MARK: dumpStreams

fn dumpStreams(
    comptime TProvider: type,
    pv: *TProvider,
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

    while (!pv.done())
        try dumpStream(
            TProvider,
            pv,
            raw_bytes,
            opts,
            w,
            &trailing,
            &total_raw,
            &total_literals,
            &total_matches,
            &sink,
        );

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

// MARK: dumpStream

inline fn dumpStream(
    comptime TProvider: type,
    pv: *TProvider,
    raw_bytes: ?[]const u8,
    opts: DumpOptions,
    w: *std.Io.Writer,
    trailing: *u64,
    total_raw: *u64,
    total_literals: *u64,
    total_matches: *u64,
    sink: *raw.RawSink,
) !void {
    const kind = try pv.nextKind();

    if (kind == @intFromEnum(container.Kind.trailing)) {
        const tr = try pv.trailingRecord();
        trailing.* += tr.count;
        try print.stream_header.trailing(w, tr.count);
        return;
    }

    var st = StreamStats{ .kind = @enumFromInt(kind) };

    switch (kind) {
        @intFromEnum(container.Kind.zlib) => {
            const hdr = try pv.zlibHeader();
            st.header_bytes = hdr;
            st.window_kb = windowKbFromZlibHeader(hdr);
            st.flevel = flevelFromZlibHeader(hdr);
            if (hdr[1] & 0x20 != 0) {
                _ = try pv.fdictId();
                st.fdict = true;
            }

            st.checksum_kind = .adler;
            try print.stream_header.zlib(
                pv.stream_no,
                w,
                hdr,
                &st,
            );
        },
        @intFromEnum(container.Kind.gzip) => {
            st.checksum_kind = .crc;
            try print.stream_header.gzip(
                pv.stream_no,
                w,
                try pv.gzipHeader(),
            );
        },
        @intFromEnum(container.Kind.deflate) => {
            try print.stream_header.rawDeflate(
                pv.stream_no,
                w,
            );
        },
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

        try dumpBlock(
            TProvider,
            pv,
            w,
            &st,
            total_literals,
            total_matches,
            &bh,
            block_no,
            &p,
            p_before,
            have_values,
            sink,
            &opts,
        );
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
    total_raw.* += raw_len;

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
        .adler => try print.trailer.checksum(
            w,
            "adler32",
            &st_end,
            st.fdict,
            have_values,
        ),
        .crc => {
            try print.trailer.checksum(
                w,
                "crc32  ",
                &st_end,
                st.fdict,
                have_values,
            );

            try print.trailer.input_size(
                w,
                &st,
                have_values,
            );
        },
        .none => {},
    }
}

inline fn windowKbFromZlibHeader(hdr: [2]u8) u64 {
    return (@as(u64, 1) << @intCast((hdr[0] >> 4) + 8)) >> 10;
}
inline fn flevelFromZlibHeader(hdr: [2]u8) u8 {
    return hdr[1] >> 6;
}

// MARK: dumpBlock

inline fn dumpBlock(
    comptime TProvider: type,
    pv: *TProvider,
    w: *std.Io.Writer,
    st: *StreamStats,
    total_literals: *u64,
    total_matches: *u64,
    bh: *const records.BlockHdr,
    block_no: usize,
    p: *usize,
    p_before: usize,
    have_values: bool,
    sink: *raw.RawSink,
    opts: *const DumpOptions,
) !void {
    switch (bh.btype) {
        0 => {
            const sb = try pv.storedBlock(p.*);
            p.* += sb.len;
            st.stored_blocks += 1;
            if (sb.len == 0) st.stored_flush_blocks += 1;
            if (sb.data) |d| {
                if (have_values) try sink.putSlice(d);
            }
            try print.block.stored(
                block_no,
                w,
                bh.bfinal,
                &sb,
            );
        },
        1, 2 => {
            if (bh.btype == 2) {
                const dh = try pv.dynHeader();
                st.dynamic_blocks += 1;
                try print.block.dynamic(
                    block_no,
                    w,
                    bh.bfinal,
                    dh,
                );
            } else {
                st.fixed_blocks += 1;
                try print.block.fixed(
                    block_no,
                    w,
                    bh.bfinal,
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
                return;
            }

            while (true) {
                if (!try dumpToken(
                    TProvider,
                    pv,
                    w,
                    st,
                    &block_lits,
                    &block_matches,
                    p,
                    have_values,
                    sink,
                    &shown,
                    opts,
                )) break;
            }
            try w.print(
                "    -> {d} literals, {d} matches, {d} bytes out\n",
                .{ block_lits, block_matches, p.* - p_before },
            );
            total_literals.* += st.literals;
            total_matches.* += st.matches;
            st.literals = 0; // per-block display only
            st.matches = 0;
        },
        else => unreachable,
    }
}

// MARK: dumpToken

inline fn dumpToken(
    comptime TProvider: type,
    pv: *TProvider,
    w: *std.Io.Writer,
    st: *StreamStats,
    block_lits: *u64,
    block_matches: *u64,
    p: *usize,
    have_values: bool,
    sink: *raw.RawSink,
    shown: *usize,
    opts: *const DumpOptions,
) !bool {
    const t = try pv.token(p.*);
    switch (t) {
        .literal => |v_opt| {
            st.literals += 1;
            block_lits.* += 1;
            p.* += 1;
            if (have_values) {
                if (v_opt) |v| try sink.put(v);
            }

            shown.* += 1;
            if (opts.max_tokens > 0 and shown.* <= opts.max_tokens)
                try print.token.literal(w, v_opt);
        },
        .match => |mt| {
            st.matches += 1;
            block_matches.* += 1;
            const mlen = mt.length();
            p.* += mlen;
            if (mt.rank) |r| {
                if (r == 0) st.dist_rank0 += 1 else st.dist_ranked += 1;
            }
            if (mt.escaped) st.dist_escaped += 1;
            if (have_values and mt.dist_known)
                try sink.copyMatch(mt.dist, mlen);

            shown.* += 1;
            if (opts.max_tokens > 0 and shown.* <= opts.max_tokens)
                try print.token.match(w, mt, mlen);
        },
        .eob => {
            if (opts.max_tokens > 0 and shown.* > opts.max_tokens)
                try print.token.eob(w, shown.*);

            return false;
        },
    }

    return true;
}
