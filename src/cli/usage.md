deflate-replay 1.2.0 — universal DEFLATE/zlib/gzip stream reproducer

usage:
  deflate-replay analyze <input> [options]
      Extract the parameter set (.drp) and the raw (inflated) data.
      --out-params <file>              default: <input>.drp
      --out-raw <file>                 default: <input>.raw
      --format auto|zlib|gzip|deflate  default: auto
      --v3                             write DRP3 params (default):
                                         range-coded predictions from
                                         the raw data (most compact)
      --v2                             write DRP2 params (bit-packed ranks)
      --v1                             write legacy verbose DRP1 params
      --self-contained                 store literal values in the params
                                         (replay without raw)
      --no-rank                        store distances explicitly
                                         instead of predicting them
      --allow-fdict                    accept zlib FDICT streams
                                         (reproduced from params, no
                                         raw data exists for them)
      --strict-streams                 fail on unparseable tail instead
                                         of recording it verbatim

  deflate-replay replay <params> <raw> [options]
      Rebuild the bit-identical compressed stream from params + raw.
      Params format (DRP1/DRP2/DRP3) is auto-detected.
      --out <file>                     default: <params>.recompressed
      --no-raw                         params-only mode, skip raw
                                         verification (works for
                                         self-contained params; raw-
                                         derived params need the raw file)

  deflate-replay roundtrip <input> [options]
      analyze + replay + byte-exact comparison; writes <input>.drp,
      <input>.raw and <input>.recompressed. Same options as analyze.

  deflate-replay dump <params> [raw] [options]
      Human-readable view of a params file. The optional raw file
      resolves raw-derived literals and rank-coded distances; DRP3
      token sections require it (without it only the structure and
      per-block token counts are shown).
      --tokens <n>                     show first n tokens per block

DRP3 predicts the LZ77 tokenizer from the raw data itself (nearest
candidate enumeration + match extension lengths) and range-codes only
the deviations, so replay requires the raw file (a CRC32 of each
stream's raw slice is stored and verified). Container detection (auto):
gzip magic, then zlib header check, then raw
DEFLATE. Concatenated streams are supported; an unparseable tail is
recorded and reproduced verbatim.
