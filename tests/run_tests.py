#!/usr/bin/env python3
"""Run the deflate-replay test suite.

  python3 tests/run_tests.py [zig] [extra inputs...]

Steps:
  1. zig build (ReleaseSafe) + zig build test (unit tests)
  2. regenerate vectors
  3. for each vector: roundtrip -> expect BIT-IDENTICAL and raw == expected
  4. negative vectors: expect a clean error (exit 1) and no crash
  5. extra inputs (e.g. real-world .idat files) as additional roundtrips
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VEC = os.path.join(HERE, "vectors")
EXP = os.path.join(HERE, "expected")
ZIG = sys.argv[1] if len(sys.argv) > 1 else "zig"
EXTRA_INPUTS = sys.argv[2:]

BIN = os.path.join(ROOT, "zig-out", "bin", "deflate-replay")

passed = failed = 0
failures = []


def check(name: str, ok: bool, detail: str = ""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS {name}" + (f"  ({detail})" if detail else ""))
    else:
        failed += 1
        failures.append(name)
        print(f"  FAIL {name}  {detail}")


def run(args, cwd=None, timeout=300):
    return subprocess.run(args, cwd=cwd, capture_output=True, timeout=timeout)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


print("== build ==")
t0 = time.time()
r = run([ZIG, "build", "-Doptimize=ReleaseSafe"], cwd=ROOT)
if r.returncode != 0:
    print(r.stdout.decode())
    print(r.stderr.decode())
    sys.exit("build failed")
check("zig build ReleaseSafe", True, f"{time.time() - t0:.1f}s")

r = run([ZIG, "build", "test"], cwd=ROOT)
if r.returncode != 0:
    print(r.stdout.decode())
    print(r.stderr.decode())
check("zig build test (unit tests)", r.returncode == 0)

print("== generate vectors ==")
r = run([sys.executable, os.path.join(HERE, "gen_vectors.py")])
if r.returncode != 0:
    print(r.stderr.decode())
    sys.exit("vector generation failed")
manifest = json.load(open(os.path.join(HERE, "manifest.json")))

print("== roundtrip vectors (DRP3 default) ==")
work = tempfile.mkdtemp(prefix="drp-tests-")
for name in sorted(manifest):
    m = manifest[name]
    if m.get("skip_roundtrip"):
        continue
    vec_path = os.path.join(VEC, name)
    r = run([BIN, "roundtrip", vec_path] + m.get("flags", []))
    out = r.stdout.decode() + r.stderr.decode()
    if m["expect_ok"]:
        ok = r.returncode == 0 and "RESULT: BIT-IDENTICAL" in out
        check(name, ok, "" if ok else out.strip().splitlines()[-1] if out.strip() else "no output")
        if ok:
            exp_raw = os.path.join(EXP, name + ".raw")
            got_raw = vec_path + ".raw"
            same = sha(exp_raw) == sha(got_raw) and os.path.getsize(exp_raw) == os.path.getsize(got_raw)
            check(name + " [raw == expected]", same)
            # dump must also succeed on the params file (without and with raw)
            rd = run([BIN, "dump", vec_path + ".drp", "--tokens", "3"])
            check(name + " [dump no raw]", rd.returncode == 0)
            if os.path.getsize(got_raw) > 0:
                rd = run([BIN, "dump", vec_path + ".drp", got_raw, "--tokens", "3"])
                check(name + " [dump with raw]", rd.returncode == 0)
    else:
        ok = r.returncode != 0 and r.returncode != 134 and "error:" in out
        check(name + " [clean error]", ok, out.strip().splitlines()[-1] if out.strip() else "no output")

print("== extra real-world inputs ==")
for path in EXTRA_INPUTS:
    if not os.path.exists(path):
        print(f"  (skip missing {path})")
        continue
    r = run([BIN, "roundtrip", path])
    out = r.stdout.decode() + r.stderr.decode()
    ok = r.returncode == 0 and "RESULT: BIT-IDENTICAL" in out
    base = os.path.basename(path)
    check(f"real: {base}", ok)
    if ok:
        import zlib as _z
        data = open(path, "rb").read()
        ref = _z.decompress(data)
        got = open(path + ".raw", "rb").read()
        check(f"real: {base} [raw == python zlib]", ref == got)

print("== replay CLI contract ==")
# regression: stream stats must not leak debug markers into CLI output
r = run([BIN, "roundtrip", os.path.join(VEC, "gzip_plain.gz")])
out = r.stdout.decode() + r.stderr.decode()
check("clean stats output (no debug markers)",
      r.returncode == 0 and "BIT-IDENTICAL" in out and "::ss" not in out)
vec = os.path.join(VEC, "concat_mixed.bin")
r = run([BIN, "analyze", vec])
check("analyze default names", r.returncode == 0
      and os.path.exists(vec + ".drp") and os.path.exists(vec + ".raw"))
r = run([BIN, "replay", vec + ".drp", vec + ".raw", "--out", os.path.join(work, "rt.bin")])
check("replay explicit --out", r.returncode == 0 and sha(os.path.join(work, "rt.bin")) == sha(vec))
# replay with deliberately wrong raw must fail with a mismatch message
wrong_raw = os.path.join(work, "wrong.raw")
open(wrong_raw, "wb").write(b"totally wrong raw data" * 100)
r = run([BIN, "replay", vec + ".drp", wrong_raw])
out = r.stdout.decode() + r.stderr.decode()
check("replay wrong raw -> mismatch error", r.returncode != 0 and "mismatch" in out)
# trailing junk roundtrips verbatim
tj = os.path.join(VEC, "trailing_junk.z")
r = run([BIN, "roundtrip", tj])
out = r.stdout.decode() + r.stderr.decode()
check("trailing junk bit-identical + warning",
      r.returncode == 0 and "RESULT: BIT-IDENTICAL" in out and "trailing" in out)
# raw deflate forced format
rd0 = os.path.join(VEC, "raw_l6.def")
r = run([BIN, "roundtrip", rd0, "--format", "deflate"])
check("forced --format deflate", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())

print("== params format matrix ==")
vec = os.path.join(VEC, "zlib_l6.z")
# legacy v1 params
r = run([BIN, "roundtrip", vec, "--v1"])
out = r.stdout.decode() + r.stderr.decode()
check("--v1 roundtrip bit-identical", r.returncode == 0 and "BIT-IDENTICAL" in out)
with open(vec + ".drp", "rb") as f:
    check("--v1 writes DRP1 magic", f.read(4) == b"DRP1")
r = run([BIN, "replay", vec + ".drp", vec + ".raw", "--out", os.path.join(work, "v1rt.bin")])
check("v1 params replay", r.returncode == 0 and sha(os.path.join(work, "v1rt.bin")) == sha(vec))
# DRP3 default + magic, DRP2 selectable
r = run([BIN, "roundtrip", vec])
check("default (v3) roundtrip bit-identical", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
with open(vec + ".drp", "rb") as f:
    check("default writes DRP3 magic", f.read(4) == b"DRP3")
r = run([BIN, "roundtrip", vec, "--v2"])
check("--v2 roundtrip bit-identical", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
with open(vec + ".drp", "rb") as f:
    check("--v2 writes DRP2 magic", f.read(4) == b"DRP2")
r = run([BIN, "replay", vec + ".drp", vec + ".raw", "--out", os.path.join(work, "v2rt.bin")])
check("v2 params replay", r.returncode == 0 and sha(os.path.join(work, "v2rt.bin")) == sha(vec))
r = run([BIN, "roundtrip", vec])  # restore the default v3 params for later checks
# --no-rank
r = run([BIN, "roundtrip", vec, "--no-rank"])
check("--no-rank roundtrip bit-identical", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
# --self-contained + replay without raw
sc = os.path.join(VEC, "zlib_strat_default.z")
r = run([BIN, "roundtrip", sc, "--self-contained"])
check("--self-contained roundtrip bit-identical",
      r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
r = run([BIN, "replay", sc + ".drp", "--no-raw", "--out", os.path.join(work, "sc.bin")])
check("self-contained replay --no-raw",
      r.returncode == 0 and sha(os.path.join(work, "sc.bin")) == sha(sc))
# derived params must refuse replay without raw
r = run([BIN, "replay", vec + ".drp", "--no-raw"])
out = r.stdout.decode() + r.stderr.decode()
check("derived params --no-raw -> error", r.returncode != 0 and "raw" in out)
# analyze idempotence: two analyze runs produce identical params bytes
r1 = run([BIN, "analyze", os.path.join(VEC, "concat_mixed.bin"),
          "--out-params", os.path.join(work, "a1.drp"), "--out-raw", os.path.join(work, "a1.raw")])
r2 = run([BIN, "analyze", os.path.join(VEC, "concat_mixed.bin"),
          "--out-params", os.path.join(work, "a2.drp"), "--out-raw", os.path.join(work, "a2.raw")])
check("analyze idempotent (DRP3 bytes stable)",
      r1.returncode == 0 and r2.returncode == 0
      and sha(os.path.join(work, "a1.drp")) == sha(os.path.join(work, "a2.drp")))
# rank-1 and escape vectors really exercise the fallback paths
for name in ("handmade_rank1.def", "handmade_escape.def"):
    p = os.path.join(VEC, name)
    r = run([BIN, "roundtrip", p])
    check(f"rank path: {name}", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
# dump of a v2 rank-mode file without raw shows rank placeholders
r = run([BIN, "roundtrip", os.path.join(VEC, "handmade_rank1.def"), "--v2"])
check("--v2 rank vector roundtrip", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
r = run([BIN, "dump", os.path.join(VEC, "handmade_rank1.def.drp"), "--tokens", "10"])
check("dump rank placeholders (v2, no raw)", r.returncode == 0 and "rank(" in r.stdout.decode())
# dump of a v3 file without raw shows the structure and token counts
r = run([BIN, "roundtrip", os.path.join(VEC, "handmade_rank1.def")])
check("--v3 rank vector roundtrip", r.returncode == 0 and "BIT-IDENTICAL" in r.stdout.decode())
r = run([BIN, "dump", os.path.join(VEC, "handmade_rank1.def.drp"), "--tokens", "10"])
out = r.stdout.decode()
check("dump v3 no raw shows counts", r.returncode == 0 and "requires the raw file" in out)
r = run([BIN, "dump", os.path.join(VEC, "handmade_rank1.def.drp"),
         os.path.join(VEC, "handmade_rank1.def.raw"), "--tokens", "10"])
check("dump v3 with raw decodes tokens",
      r.returncode == 0 and "requires the raw file" not in r.stdout.decode())

print()
print(f"TOTAL: {passed} passed, {failed} failed")
if failures:
    print("failed:", ", ".join(failures))
sys.exit(1 if failed else 0)
