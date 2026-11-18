#!/usr/bin/env python3
"""Generate DEFLATE/zlib/gzip test vectors for deflate-replay.

Every vector comes with:
  vectors/<name>          the compressed stream (input for roundtrip)
  expected/<name>.raw     the exact expected raw (inflated) bytes
  manifest.json           metadata (description, expected exit code)

Run:  python3 tests/gen_vectors.py
"""

import gzip
import json
import os
import random
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
VEC = os.path.join(HERE, "vectors")
EXP = os.path.join(HERE, "expected")

random.seed(0x20261020)


def write_vector(name: str, compressed: bytes, raw: bytes, note: str, ok: bool = True,
                 flags: list = None):
    with open(os.path.join(VEC, name), "wb") as f:
        f.write(compressed)
    with open(os.path.join(EXP, name + ".raw"), "wb") as f:
        f.write(raw)
    manifest[name] = {
        "note": note,
        "expect_ok": ok,
        "raw_len": len(raw),
        "compressed_len": len(compressed),
        "flags": flags or [],
    }


def raw_deflate(data: bytes, level: int = 6, strategy: int = zlib.Z_DEFAULT_STRATEGY) -> bytes:
    co = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return co.compress(data) + co.flush()


manifest = {}

os.makedirs(VEC, exist_ok=True)
os.makedirs(EXP, exist_ok=True)
for f in os.listdir(VEC):
    os.remove(os.path.join(VEC, f))
for f in os.listdir(EXP):
    os.remove(os.path.join(EXP, f))

# --- corpora ---------------------------------------------------------------

rnd = bytes(random.getrandbits(8) for _ in range(65536))
text = (b"The quick brown fox jumps over the lazy dog. " * 6000
        + bytes(random.getrandbits(8) for _ in range(2000)))
zeros = b"\x00" * 1_000_000
lorem = (b"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do "
         b"eiusmod tempor incididunt ut labore et dolore magna aliqua. " * 4000)
mixed = b"".join(
    [bytes([i & 0xFF]) * (i % 97 + 1) for i in range(512)] * 4
) + rnd[:4096] + lorem[:100_000]
one_byte = b"a"
empty = b""

# --- zlib: all levels ------------------------------------------------------

for level in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9):
    data = mixed if level else mixed[:200_000]
    write_vector(f"zlib_l{level}.z", zlib.compress(data, level), data,
                 f"zlib level {level}" + (" (stored blocks)" if level == 0 else ""))

# memLevel variation (block splitting)
co = zlib.compressobj(6, zlib.DEFLATED, 15, 1)
blob = co.compress(mixed) + co.flush()
write_vector("zlib_memlevel1.z", blob, mixed, "zlib level 6 memLevel 1 (tiny blocks)")

# --- zlib: strategies ------------------------------------------------------

strategies = [
    ("default", zlib.Z_DEFAULT_STRATEGY),
    ("filtered", zlib.Z_FILTERED),
    ("huffman", zlib.Z_HUFFMAN_ONLY),
    ("rle", zlib.Z_RLE),
    ("fixed", zlib.Z_FIXED),
]
for name, strat in strategies:
    data = lorem[:400_000]
    co = zlib.compressobj(6, zlib.DEFLATED, 15, 9, strat)
    write_vector(f"zlib_strat_{name}.z", co.compress(data) + co.flush(), data,
                 f"zlib strategy {name}")

# --- flush markers ---------------------------------------------------------

co = zlib.compressobj(6)
parts = [
    co.compress(lorem[:100_000]),
    co.flush(zlib.Z_SYNC_FLUSH),
    co.compress(lorem[100_000:200_000]),
    co.flush(zlib.Z_FULL_FLUSH),
    co.compress(lorem[200_000:300_000]),
    co.flush(),
]
write_vector("zlib_flushes.z", b"".join(parts), lorem[:300_000],
             "sync + full flush markers (empty stored blocks)")

# stored blocks via level 0 with two flush points
co = zlib.compressobj(0)
parts = [co.compress(rnd[:70_000]), co.flush(zlib.Z_SYNC_FLUSH), co.compress(rnd[70_000:100_000]), co.flush()]
write_vector("zlib_l0_flush.z", b"".join(parts), rnd[:100_000],
             "level 0 stored blocks with sync flush")

# --- edge inputs -----------------------------------------------------------

write_vector("zlib_empty.z", zlib.compress(empty, 6), empty, "empty payload")
write_vector("zlib_one.z", zlib.compress(one_byte, 9), one_byte, "single byte")
write_vector("zlib_zeros.z", zlib.compress(zeros, 9), zeros, "1 MiB of zeros (max-length matches)")
write_vector("zlib_big.z", zlib.compress(mixed + lorem, 6), mixed + lorem,
             "~1.6 MiB mixed payload level 6")

# --- raw DEFLATE -----------------------------------------------------------

write_vector("raw_l6.def", raw_deflate(mixed), mixed, "raw DEFLATE level 6")
write_vector("raw_l9_text.def", raw_deflate(lorem, 9), lorem, "raw DEFLATE level 9 text")
write_vector("raw_l0.def", raw_deflate(rnd[:120_000], 0), rnd[:120_000], "raw DEFLATE level 0")
write_vector("raw_fixed.def", raw_deflate(lorem[:300_000], 6, zlib.Z_FIXED), lorem[:300_000],
             "raw DEFLATE fixed-Huffman blocks")
write_vector("raw_huffonly.def", raw_deflate(lorem[:300_000], 6, zlib.Z_HUFFMAN_ONLY),
             lorem[:300_000], "raw DEFLATE huffman-only (literals only)")
write_vector("raw_empty.def", raw_deflate(empty), empty, "raw DEFLATE empty")

# hand-crafted raw stream that uses length code 284 + extra 31 == 258 bytes,
# exercising the ambiguous length-258 encoding (must round-trip via codes).
def bits_lsb(bitlist):
    bits = list(bitlist)
    while len(bits) % 8 != 0:
        bits.append(0)
    out = bytearray()
    for i in range(0, len(bits), 8):
        b = 0
        for j, bit in enumerate(bits[i:i + 8]):
            b |= bit << j
        out.append(b)
    return bytes(out)


def fixed_lit_code(sym):
    if sym <= 143:
        return (0x30 + sym, 8)
    if sym <= 255:
        return (0x190 + sym - 144, 9)
    if sym <= 279:
        return (sym - 256, 7)
    return (192 + sym - 280, 8)


def code_bits(sym):
    code, n = fixed_lit_code(sym)
    return [(code >> (n - 1 - i)) & 1 for i in range(n)]


def dist_code_bits(sym):
    # fixed distance table: 5-bit codes equal to the symbol index
    assert 0 <= sym <= 29
    return [(sym >> (4 - i)) & 1 for i in range(5)]


payload = b"abcabcabcabc"  # match will extend this by 258 bytes
stream_bits = [1] + [1, 0]  # BFINAL=1, BTYPE=01 (fixed)
for ch in b"abcabcabcabc":
    stream_bits += code_bits(ch)
stream_bits += code_bits(284)   # length code 284 ...
stream_bits += [1] * 5          # ... plus extra bits 31 -> length 227+31 = 258
stream_bits += dist_code_bits(2)  # distance code 2 -> distance 3
stream_bits += code_bits(256)     # end of block
handmade = bits_lsb(stream_bits)
handmade_raw = zlib.decompress(handmade, -15)
assert len(handmade_raw) == 12 + 258, len(handmade_raw)
write_vector("handmade_len258_284.def", handmade, handmade_raw,
             "handcrafted fixed block: length 258 via code 284+31 (ambiguous encoding)")

# handcrafted fixed block where the chosen distance is NOT the nearest
# candidate: literals "abcabc" + match len=3 dist=6 while a nearer full
# match exists at dist=3 -> v2 params store distance rank 1
stream_bits = [1] + [1, 0]
for ch in b"abcabc":
    stream_bits += code_bits(ch)
stream_bits += code_bits(257)           # length 3
stream_bits += dist_code_bits(4) + [1]  # distance code 4 + extra 1 -> dist 6
stream_bits += code_bits(256)
rank1 = bits_lsb(stream_bits)
rank1_raw = zlib.decompress(rank1, -15)
assert rank1_raw == b"abcabcabc", rank1_raw
write_vector("handmade_rank1.def", rank1, rank1_raw,
             "handcrafted fixed block: distance stored as rank 1")

# handcrafted fixed block with 599 nearer candidates than the chosen
# source (600 a-literals, then match len=3 dist=600) -> v2 escapes to an
# explicit distance
stream_bits = [1] + [1, 0]
for _ in range(600):
    stream_bits += code_bits(ord("a"))
stream_bits += code_bits(257)                            # length 3
stream_bits += dist_code_bits(18) + [1, 1, 1, 0, 1, 0, 1]  # extra 87 -> dist 600
stream_bits += code_bits(256)
rankesc = bits_lsb(stream_bits)
rankesc_raw = zlib.decompress(rankesc, -15)
assert rankesc_raw == b"a" * 603, len(rankesc_raw)
write_vector("handmade_escape.def", rankesc, rankesc_raw,
             "handcrafted fixed block: distance rank escape (>528 candidates)")

# --- gzip ------------------------------------------------------------------

write_vector("gzip_plain.gz", gzip.compress(lorem[:500_000], 6, mtime=1234567890),
             lorem[:500_000], "gzip plain")

# gzip with FNAME (via GzipFile)
import io
buf = io.BytesIO()
with gzip.GzipFile(filename="hello world.txt", mode="wb", fileobj=buf, mtime=1700000000) as g:
    g.write(lorem[:300_000])
write_vector("gzip_fname.gz", buf.getvalue(), lorem[:300_000], "gzip with FNAME")


def hand_gzip(data, *, fname=None, fcomment=None, fextra=None, fhcrc=False,
              xfl=2, osb=3, mtime=0x11223344):
    flg = 0
    tail = b""
    if fextra is not None:
        flg |= 0x04
        tail += struct.pack("<H", len(fextra)) + fextra
    if fname is not None:
        flg |= 0x08
        tail += fname + b"\x00"
    if fcomment is not None:
        flg |= 0x10
        tail += fcomment + b"\x00"
    if fhcrc:
        flg |= 0x02
    hdr = bytes([0x1F, 0x8B, 8, flg]) + struct.pack("<I", mtime) + bytes([xfl, osb]) + tail
    if fhcrc:
        hdr += struct.pack("<H", zlib.crc32(hdr) & 0xFFFF)
    body = raw_deflate(data, 6)
    tr = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return hdr + body + tr


write_vector("gzip_allopts.gz",
             hand_gzip(lorem[:200_000], fname=b"path/to/file.bin",
                       fcomment=b"comment with \xf0\x9f\x8c\x9f",
                       fextra=b"AB\x04\x00abcd", fhcrc=True, xfl=4, osb=255),
             lorem[:200_000], "gzip FEXTRA+FNAME+FCOMMENT+FHCRC")
write_vector("gzip_fextra_only.gz", hand_gzip(rnd[:5000], fextra=b"ZZZ"), rnd[:5000],
             "gzip FEXTRA only")

# --- concatenated streams --------------------------------------------------

write_vector("concat_3zlib.z",
             zlib.compress(lorem[:100_000], 1) + zlib.compress(rnd[:50_000], 6)
             + zlib.compress(zeros[:100_000], 9),
             lorem[:100_000] + rnd[:50_000] + zeros[:100_000],
             "three concatenated zlib streams (levels 1/6/9)")

write_vector("concat_mixed.bin",
             zlib.compress(lorem[:80_000], 6) + raw_deflate(rnd[:30_000])
             + gzip.compress(lorem[80_000:120_000], 9, mtime=7),
             lorem[:80_000] + rnd[:30_000] + lorem[80_000:120_000],
             "zlib + raw DEFLATE + gzip concatenated")

write_vector("concat_with_empty.z",
             zlib.compress(lorem[:50_000], 6) + zlib.compress(empty, 6),
             lorem[:50_000], "zlib + empty zlib stream")

write_vector("concat_raw_raw.def",
             raw_deflate(lorem[:40_000]) + raw_deflate(rnd[:10_000]),
             lorem[:40_000] + rnd[:10_000], "two concatenated raw DEFLATE streams")

# trailing garbage after a valid stream (reproduced verbatim)
write_vector("trailing_junk.z",
             zlib.compress(lorem[:50_000], 6) + b"\x00\x01\x02garbage-tail",
             lorem[:50_000], "zlib stream + unparseable trailing bytes")

# --- crafted PNG with split IDAT chunks -------------------------------------

def png_chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


width, height = 64, 64
scanlines = b"".join(b"\x00" + bytes([(x * 4 + y) & 0xFF for x in range(width * 3)]) for y in range(height))
idat_payload = zlib.compress(scanlines, 6)
mid = len(idat_payload) // 2
png = (b"\x89PNG\r\n\x1a\n"
       + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
       + png_chunk(b"IDAT", idat_payload[:mid])
       + png_chunk(b"IDAT", idat_payload[mid:])
       + png_chunk(b"IEND", b""))
with open(os.path.join(VEC, "tiny.png"), "wb") as f:
    f.write(png)
write_vector("png_idat_concat.idat", idat_payload, scanlines,
             "IDAT payloads of a real PNG (one stream split over 2 chunks)")
manifest["tiny.png"] = {
    "note": "real PNG file (informational, not a roundtrip vector)",
    "expect_ok": False, "skip_roundtrip": True,
}

# --- intentionally broken streams -------------------------------------------

good = zlib.compress(lorem[:100_000], 6)
write_vector("bad_truncated.z", good[:-10], lorem[:100_000],
             "zlib stream cut short", ok=False)

bad_adler = bytearray(good)
bad_adler[-1] ^= 0xFF
write_vector("bad_adler.z", bytes(bad_adler), lorem[:100_000],
             "zlib stream with corrupt Adler-32 (still bit-identical)", ok=True)

# fixed block: literal 'a' then match dist=2 len=3 (dist too far back)
bits = [1] + [1, 0]  # BFINAL, BTYPE=fixed
bits += code_bits(ord('a'))
bits += code_bits(257)      # length 3
bits += [0, 0, 0, 0, 1]     # distance code 1 (dist 2) MSB-first
bits += code_bits(256)
write_vector("bad_dist_far.def", bits_lsb(bits), b"aaa",
             "distance too far back", ok=False)

# reserved block type 3
write_vector("bad_btype3.def", bits_lsb([0, 1, 1] + [0] * 13), b"",
             "reserved block type 3", ok=False)

# stored block with NLEN != ~LEN
write_vector("bad_nlen.def",
             bits_lsb([1, 0, 0]) + struct.pack("<HH", 1, 0) + b"\xAA",
             b"", "stored block NLEN mismatch", ok=False)

# dynamic block with hlit > 286 (HLIT=31 -> 288 codes)
bits = [0, 0, 0]           # BFINAL=0, BTYPE=00 stored?? no: build dynamic below
bits = [1, 0, 1]           # BFINAL=1, BTYPE=10 dynamic
bits += [1, 1, 1, 1, 1]    # HLIT = 31 -> 288 (invalid)
bits += [0, 0, 0, 0, 0]    # HDIST = 1
bits += [0, 0, 0, 0]       # HCLEN = 4
bits += [0] * 12           # 4 x 3 zero cl lengths + junk
write_vector("bad_hlit.def", bits_lsb(bits), b"", "too many literal codes", ok=False)

# --- zlib FDICT (preset dictionary) ----------------------------------------

zdict = b"the quick brown fox jumps over the lazy dog. " * 8
fd_payload = (b"the quick brown fox jumps over the lazy dog. " * 60
              + bytes(random.getrandbits(8) for _ in range(2000)))
co = zlib.compressobj(6, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, zdict=zdict)
fd = co.compress(fd_payload) + co.flush()
assert fd[1] & 0x20, "generator failed to produce an FDICT stream"
write_vector("zlib_fdict.z", fd, b"",
             "zlib FDICT (preset dictionary) stream, reproduced from params",
             ok=True, flags=["--allow-fdict"])

# FDICT stream concatenated with a normal zlib stream: replay must verify
# the normal stream against raw while reproducing the FDICT stream from params
write_vector("concat_fdict.z",
             fd + zlib.compress(lorem[:50_000], 6),
             lorem[:50_000],
             "FDICT zlib + normal zlib concatenated",
             ok=True, flags=["--allow-fdict"])

with open(os.path.join(HERE, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)

print(f"generated {len(manifest)} vectors in {VEC}")
for name in sorted(manifest):
    m = manifest[name]
    if not m.get("skip_roundtrip"):
        print(f"  {name:28s} {m['compressed_len']:>9d} B -> {m['raw_len']:>9d} B raw  [{'OK' if m['expect_ok'] else 'FAIL'}] {m['note']}")
