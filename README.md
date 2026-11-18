# deflate-replay

A universal **DEFLATE / zlib / gzip stream reproducer** written in Zig 0.16.

Given a compressed stream, `analyze` extracts a complete parameter set (`.drp`
file) describing its exact bit-level structure — container framing, block
layout, alignment padding, the Huffman table definitions *exactly as they were
encoded in the header*, and the full LZ77 tokenization. `replay` then turns
those parameters plus the decompressed data back into a **bit-identical**
copy of the original compressed stream, verifying every raw byte on the way.

```
compressed ──analyze──► params (.drp) + raw
                            │
raw ────────────────────────┤
                            ▼
              replay ──► compressed' == compressed (every bit)
```

The parameters are **compact** (format v3, the default): the LZ77 tokenizer
is *predicted* from the raw data itself and only the deviations are
range-coded, so a typical params file is well below the size of the original
compressed stream — small enough to keep alongside raw data in cold storage
and reconstruct the original byte-exact stream on demand:

| file | stream | raw | v1 | v2 | **v3** | v3 / stream | v3 / raw |
|---|---|---|---|---|---|---|---|
| `sample-a.idat` | 803,501 B | 7,485,940 B | 1,967,634 B | 270,437 B | **119,733 B** | 14.9% | 1.6% |
| `sample-b.idat` | 224,295 B | 1,763,903 B | 640,962 B | 74,068 B | **31,273 B** | 13.9% | 1.8% |

(Both files round-trip bit-identically; LZMA on top of v3 does not shrink it
further — the adaptive models already sit near the entropy of the parse.
For a cold-storage layout of `raw compressed with a stronger algorithm +
params v3`, the total for `sample-a.idat` is **91.2%** of the original zlib stream.)

**I originally wrote this utility for my own use and evaluated its effectiveness using my own data. A public test dataset is in the works.**

## Why the parameters must include the LZ77 tokenization

"Compression settings" alone (levels, tables, block types) are not enough for
bit-exact reproduction: the exact choice of literals vs. matches at each
position is a decision of the original compressor, and two valid compressors
with identical settings produce different bits. The only universal way to
guarantee bit-identity is to record the tokenization as it was encoded —
which is what infgen does textually and what this tool does in a compact
binary form. Tokens are recorded as *(symbol, extra-bits value)* pairs, so
even the ambiguous **length-258-via-code-284+extra-31** encoding round-trips
byte-for-byte.

## Building

```sh
zig build -Doptimize=ReleaseSafe     # CLI binary at zig-out/bin/deflate-replay
zig build test                       # unit tests
```

Requires Zig 0.16.x. The project is a **library module** (`deflate_replay`)
plus a thin CLI that imports it — consume it as a dependency via
`build.zig.zon` if you want the library only.

## CLI

```
deflate-replay analyze <input> [--out-params F] [--out-raw F]
                 [--format auto|zlib|gzip|deflate] [--v3] [--v2] [--v1]
                 [--self-contained] [--no-rank] [--allow-fdict]
                 [--strict-streams]
deflate-replay replay <params> <raw> [--out F] [--no-raw]
deflate-replay roundtrip <input> [analyze options]
deflate-replay dump <params> [raw] [--tokens N]
```

Typical session:

```sh
$ deflate-replay analyze sample-a.idat            # -> sample-a.idat.drp + sample-a.idat.raw
$ deflate-replay replay sample-a.idat.drp sample-a.idat.raw --out rebuilt.idat
$ cmp sample-a.idat rebuilt.idat                  # identical

# one-shot with full report and artifacts:
$ deflate-replay roundtrip sample-a.idat
roundtrip: sample-a.idat (803501 bytes)
streams: 1
  stream 1: zlib, header 78 9C, window 32K, level default
    blocks: 39 (dynamic 39, fixed 0, stored 0)
    tokens: 470002 literals, 168417 matches
    distances: 168417 rank-0, 0 ranked, 0 escaped
    raw: 7485940 bytes
    adler32: recorded 0x9AA0DD1F, computed 0x9AA0DD1F, match
raw verification: OK (7485940 bytes match)
  input:  sha256: 9e004fd9…
  output: sha256: 9e004fd9…
RESULT: BIT-IDENTICAL (803501 / 803501 bytes)

$ deflate-replay dump sample-a.idat.drp sample-a.idat.raw --tokens 4
params: 119733 bytes, format DRP3 v3
stream 1: zlib, header 78 9C, window 32K, level default
  block 1: dynamic, hlit=286 hdist=30 hclen=17
    literal 0x01
    literal 0x45 'E'
    ...
```

The params format is chosen by `analyze` (`--v3` default, `--v2`/`--v1` for
the older formats); `replay` and `dump` auto-detect it from the file magic.

### Containers and concatenations

`--format auto` (default) detects per stream: gzip magic, then a valid zlib
header (`CM=8`, `CINFO<=7`, checksum OK), then raw DEFLATE. **Any number of
back-to-back streams is supported** — e.g. IDAT payloads of several PNGs
concatenated, or zlib + raw + gzip mixtures. An unparseable tail after the
last valid stream is recorded as a *trailing-bytes* record and reproduced
verbatim (`--strict-streams` turns that into an error instead).

Because a raw-DEFLATE stream can coincidentally begin with bytes that pass
the zlib header check (probability ≈ 1/1000), use `--format` to pin the
container when you know it.

## The `.drp` parameter format

### v3 (default, magic `DRP3`)

Same record structure as v2 (kinds, container framing, bit-packed block
headers and dynamic tables, verbatim trailers), but the per-block token
streams are **adaptive range-coded segments** (LZMA-style binary arithmetic
coder, 11-bit probabilities, integer-only and deterministic) whose model is
driven by predictions computed from the raw data:

```
per block (btype 1/2):  byte-align, uvarint token_count,
                        uvarint segment_len, [segment_len] rc bytes
```

Token coding inside a segment (models reset per stream):

* **token type** (literal / match / end-of-block) is coded with a 2-bit tree
  in the context (a) *does any 3-byte match candidate exist at this
  position* (deterministic nearest-first chain walk, 64-hop budget) and
  (b) *was the previous token a literal*. Literal values are never stored —
  a literal is `raw[p]` by construction (self-contained mode codes the byte
  with an adaptive 8-bit tree instead).
* **match source prediction**: candidates (positions matching the 3-byte
  prefix, nearest-first) are walked while tracking the running maximum of
  the *match extension* `e = min(258, extension(j), srclen - p)`. At every
  new running maximum a single bit asks "is this candidate the source?"
  (context: first candidate vs. later). For greedy/lazy encoders (zlib) the
  emitted source is always the nearest candidate whose extension covers the
  emitted length, so on the real-world test files 86%/69% of matches are
  confirmed at the very first candidate.
* **length**: once the source is confirmed, the length is coded as a delta
  from the extension at that candidate (`len = e - delta`, almost always 0)
  plus, for length 258, a one-bit choice between code 285 and the ambiguous
  code 284 + extra 31.
* **fallback**: if the walk is exhausted (budget 64 candidates / 4096 hops)
  or the source is not a running maximum — or the stream is self-contained
  or `--no-rank` was given — the match is coded explicitly: length code
  tree + extra bits, then the DRP2-style candidate rank (of full-length
  matches) or an explicit distance code tree + extra bits. The worst case
  never exceeds the v1 cost.

The stream header additionally stores this stream's raw length up front
(the predictor needs stream-local bounds); the trailer keeps the verbatim
container checksum and, for raw-derived streams, the CRC32 of the raw slice.

Why this is safe: `analyze` verifies that the recorded tokenization
reproduces the raw data before any params are written, so raw-derived
reconstruction is exact by construction; the rank/source enumeration rules
are byte-identical on the analyze and replay sides (shared `matchfind.zig`);
and the range coder is integer-only, so `.drp` bytes are reproducible across
platforms and runs.

### v2 (magic `DRP2`)

Same record structure as v1 (kinds, per-stream container framing, blocks,
trailers), but bit-packed and deduplicated against the raw data. Bit fields
are LSB-first (as `writeBits` emits them); Huffman codes ride the same bit
stream MSB-first, exactly as in a DEFLATE block.

```
file header    magic "DRP2", u8 version=2, u8 flags=0
records        until EOF (byte-aligned boundaries between records):
  u8 kind      1=zlib  2=gzip  3=raw DEFLATE  4=trailing bytes
  zlib         [2] CMF/FLG; if FDICT: [4] dictionary id (BE)
  gzip         u16 header_len, [header_len] header bytes
  stream bits  u1 self_contained, u1 rank_mode
  blocks       each:
    u1 bfinal, u2 btype
    btype 1/2: u1 lmode (length codes via the block's own lit/len table)
    btype 0:   u7 pad_value, uvarint LEN (NLEN derived; data from raw,
               or inline in self-contained mode)
    btype 2:   u5 hlit-257, u5 hdist-1, u4 hclen-4,
               [hclen] u3 code-length lengths (permutation order),
               code-length RLE until hlit+hdist lengths are filled
               (symbols coded with the code-length Huffman code,
               extras 2/3/7 bits)
    tokens     u1 0           literal (value = raw[p]; +u8 in
                                self-contained mode)
               2-bit 01       match: length code (lmode: lit/len-table
                                Huffman code, else u5), lextra bits,
                                distance:
                  rank mode:  u1 0              rank 0 (nearest)
                              2-bit 01 + u4      rank 1..16
                              3-bit 011 + u9     rank 17..528
                              3-bit 111 + u5 dcode + dextra  (escape)
                  else:       u5 dcode + dextra
               2-bit 11       end-of-block
  after BFINAL u7 trailing pad value, then pad the bit stream to a byte
  trailer      zlib [4] Adler-32 (BE) | gzip [8] CRC32+ISIZE (LE),
               uvarint raw_len, and unless self-contained [4] CRC32 of
               the stream's raw slice (LE), hard-verified on replay
  kind=4       uvarint count, [count] verbatim bytes
```

What makes it compact:

* **Literals are not stored.** The token sequence tells replay which raw
  positions are literals, and the values are read from the raw file. A
  literal costs a single bit.
* **Distances are stored as ranks.** For a match at raw position `p` with
  length `len`, the candidates are all positions `j` in the 32 KiB window
  with `raw[j..j+len] == raw[p..p+len]`, enumerated nearest-first. The rank
  of the actually-used source position unambiguously determines the distance,
  and both `analyze` and `replay` enumerate candidates with identical rules
  (a 15-bit hash of the first 3 bytes chains positions in descending order;
  the two positions nearest to `p` are checked explicitly). Real encoders
  pick the nearest candidate almost always: on both real-world test files
  **100% of the 268,216 matches are rank 0** (1 bit). Ranks beyond 528, or
  matches whose source lies before the stream start (FDICT), escape to an
  explicit dcode+dextra — the worst case never exceeds the v1 cost.
* **Length codes use the stream's own Huffman tables.** Each block already
  carries its literal/length table; coding the length symbols with it costs
  near their entropy. A per-block flag picks this or fixed 5-bit codes,
  whichever is smaller for that block.
* Stored blocks keep only the pad value and LEN; the bytes come from raw.
  NLEN is derived. Dynamic headers are re-coded bit-tightly (3-bit
  code-length lengths, RLE without a count).
* FDICT streams (and `--self-contained`) fall back to storing literal
  values and stored-block bytes inline, so they replay **without** the raw
  file (`replay params.drp --no-raw`).

Integrity: replay verifies every regenerated byte against the raw file
(matches and stored blocks), checks stream lengths, and — for raw-derived
streams — compares a stored CRC32 of each stream's raw slice, so a params
file paired with the wrong raw file is rejected with a clear error.

### v1 (legacy, magic `DRP1`)

All integers little-endian; kept readable and writable (`--v1`) for
debugging and compatibility.

```
file header   magic "DRP1", u8 version=1, u8 flags=0
records       until EOF:
  u8 kind     1=zlib  2=gzip  3=raw DEFLATE  4=trailing bytes
  zlib        [2] CMF/FLG; if FDICT: [4] dictionary id (BE)
  gzip        u16 header_len, [header_len] header bytes (incl. optional fields)
  blocks      each:
    u8 flags  bits0-1 BTYPE (0 stored, 1 fixed, 2 dynamic), bit2 BFINAL
    stored    u8 pad_value, u16 len, u16 nlen, [len] bytes
    dynamic   u16 hlit, u16 hdist, u8 hclen,
              [hclen] code-length lengths (header permutation order),
              u16 rle_count, [rle_count](u8 sym, u8 extra),
              token stream
    tokens    u8 tag: 1=literal [u8 byte]
                      2=match [u8 lcode-257, u8 lextra, u8 dcode, u16 dextra]
                      3=end-of-block
  after BFINAL block:  u8 trailing pad value
  zlib trailer [4] Adler-32 (BE) | gzip trailer [8] CRC32 (LE) + ISIZE (LE)
  u64 raw_len
  kind=4       u64 count, [count] verbatim bytes
```

Faithfulness notes (apply to both versions):

* matches are stored as *codes + extra-bit values*, not decoded lengths, so
  alternative encodings of the same (length, distance) survive;
* alignment padding around stored blocks and after the final block is
  recorded bit-exactly (the bit count is recomputed from position);
* the dynamic-block header is stored exactly as encoded (HLIT/HDIST/HCLEN
  as written, including non-minimal HCLEN, plus the RLE sequence as read);
* container checksums (Adler-32, CRC32, ISIZE) are recorded verbatim and
  cross-checked against the raw data; a mismatch is reported as a warning
  but still reproduced, keeping the output bit-identical even for corrupt
  input.

## Library use

```zig
const drp = @import("deflate_replay");

var diagnostics = drp.Diagnostics{};
var params: std.Io.Writer.Allocating = .init(gpa);
var raw: std.Io.Writer.Allocating = .init(gpa);
var result = try drp.analyze.analyze(gpa, compressed, .{}, &diagnostics,
    &params.writer, &raw.writer);
defer result.deinit(gpa);

var rebuilt: std.Io.Writer.Allocating = .init(gpa);
var result2 = try drp.replay.replay(gpa, params.written(), raw.written(),
    .{}, &diagnostics, &rebuilt.writer);
defer result2.deinit(gpa);
// rebuilt.written() == compressed, guaranteed
```

## Guarantees, edge cases, limitations

* **Bit-identity** — `replay(analyze(x).params, raw)` reproduces `x` exactly,
  including every block header field, Huffman table definition, alignment
  bit, stored-block byte, flush marker, container header/trailer and
  trailing bytes.
* **zlib-compatible validation** — HLIT>286, HDIST>30, NLEN mismatch,
  over-subscribed Huffman codes, invalid codes 286/287 and distance codes
  30/31, "distance too far back", missing end-of-block code, and RLE runs
  crossing the 316-entry limit are all rejected with a diagnostic message
  carrying the stream number and bit offset — the same inputs zlib rejects.
* Incomplete (but not over-subscribed) Huffman tables are accepted where
  zlib does, and rejected only if an actual code falls into a gap.
* **FDICT** (zlib preset dictionary): token extraction works with
  `--allow-fdict`; such streams are stored self-contained (literal values
  inline, explicit distances) and replay without the raw file. In mixed
  files the non-FDICT streams are still verified against raw.
* gzip FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT are all handled; the header bytes
  are reproduced verbatim. Reserved gzip flag bits are ignored (permissive).
* Memory profile: `analyze` holds the input plus per-stream params/raw
  buffers; `replay` holds the params file, a 512 KiB rank-matcher and
  streams the raw data through a 64 KiB ring while comparing. A `roundtrip`
  run additionally keeps the rebuilt output in memory (~ input size).
* The bit-at-a-time canonical Huffman decoder is deliberately simple; a
  full roundtrip (analyze + replay) runs at roughly 10–15 MB/s of raw data
  in ReleaseSafe (a 7.5 MB-raw PNG IDAT stream takes ~0.7 s with DRP3,
  ~0.5 s with DRP2).

## Testing

```sh
zig build test                                   # 33 unit tests
python3 tests/gen_vectors.py                     # 45+ vectors
python3 tests/run_tests.py [path-to-zig] EXTRA_FILES...
```

The integration matrix (209 checks) covers: zlib levels 0–9 and memLevel 1;
strategies default/filtered/huffman-only/RLE/fixed; sync/full flush markers;
empty and single-byte payloads; 1 MiB of zeros (max-length matches); raw
DEFLATE; hand-crafted length-258-via-284+31, distance-rank-1 and
rank-escape streams; gzip with every header option; mixed container
concatenations; an FDICT stream alone and concatenated with a normal one;
trailing garbage; a real PNG with split IDAT chunks; and negative vectors
(truncation, corrupt Adler-32, distance-too-far, BTYPE=3, NLEN mismatch,
HLIT overflow). The params-format matrix additionally checks v1/v2
compatibility, `--no-rank`, `--self-contained` with `replay --no-raw`,
wrong-raw rejection, dump with and without raw for all three formats, and
analyze idempotence. Both attached real-world
files (`sample-a.idat`, `sample-b.idat`) round-trip bit-identically with raw
output byte-equal to Python's `zlib.decompress`.
