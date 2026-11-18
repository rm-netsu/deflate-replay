//! deflate_replay: universal DEFLATE/zlib/gzip reproducer.
//!
//! Given a compressed stream, `analyze` extracts a complete parameter set
//! (`.drp` file) describing its exact bit-level structure: container framing,
//! block layout, alignment padding, Huffman table definitions as encoded,
//! and the full LZ77 tokenization. `replay` then turns the parameters plus
//! the decompressed data back into a bit-identical compressed stream.
//!
//! Library layout:
//!   analyze.zig  — compressed input -> params + raw data
//!   replay.zig   — params + raw data -> bit-identical compressed output
//!   dump.zig     — human-readable view of a params file
//!   records.zig  — record model, DRP2 compact format, v1->v2 converter
//!   compact3.zig — DRP3 range-coded format, v1->v3 converter
//!   rc.zig       — adaptive binary range coder (LZMA-style)
//!   matchfind.zig — deterministic candidate enumeration for distance coding
//!   bits.zig     — DEFLATE bit reader/writer
//!   huffman.zig  — canonical Huffman decode/encode
//!   tables.zig   — RFC 1951 constant tables
//!   container.zig — zlib/gzip/raw framing
//!   params.zig   — .drp binary formats (v1), uvarint
//!   raw.zig      — inflated-data sink (ring buffer, hashes, verification)
//!   stats.zig    — shared options/results
//!   diagnostics.zig     — error diagnostics

pub const analyze = @import("analyze.zig");
pub const replay = @import("replay.zig");
pub const dump = @import("dump.zig");
pub const records = @import("records.zig");
pub const compact3 = @import("compact3.zig");
pub const rc = @import("rc.zig");
pub const matchfind = @import("matchfind.zig");
pub const bits = @import("bits.zig");
pub const huffman = @import("huffman.zig");
pub const tables = @import("tables.zig");
pub const container = @import("container.zig");
pub const params = @import("params.zig");
pub const raw = @import("raw.zig");
pub const stats = @import("stats.zig");
pub const diagnostics = @import("diagnostics.zig");

pub const Options = stats.Options;
pub const ParamsVersion = stats.ParamsVersion;
pub const Result = stats.Result;
pub const StreamStats = stats.StreamStats;
pub const Diagnostics = diagnostics.Diagnostics;

test {
    _ = analyze;
    _ = replay;
    _ = dump;
    _ = records;
    _ = compact3;
    _ = rc;
    _ = matchfind;
    _ = bits;
    _ = huffman;
    _ = tables;
    _ = container;
    _ = params;
    _ = raw;
    _ = stats;
    _ = diagnostics;
}
