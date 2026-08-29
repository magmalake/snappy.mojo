#!/usr/bin/env python3
"""One-shot interop check against python-snappy (cramjam-backed).

Not part of `pixi run test` (no Python dependency at test time) — run once
by hand to (a) print the exact bytes `snappy.compress`/`StreamCompressor`
produce, to hand-copy into tests/test_snappy.mojo as constants, and (b)
cross-check that our Mojo output round-trips through python-snappy.

    uv venv /tmp/pysnappy-venv && source /tmp/pysnappy-venv/bin/activate
    uv pip install python-snappy
    python3 tools/gen_python_vectors.py [path/to/mojo/output.bin ...]

With no arguments it only prints the reference vectors. Pass file paths
(raw-format or framing-format Snappy files our Mojo binary produced) and
it will additionally try to decompress each with python-snappy, to prove
our encoder's output is spec-compliant to an independent implementation.
"""

import sys

import snappy


def hexbytes(b: bytes) -> str:
    return ", ".join(f"0x{x:02X}" for x in b)


def main() -> int:
    print("=== raw format ===")
    for sample in [b"", b"hello world", b"a" * 200, b"abcabcabcabcabcabc"]:
        packed = snappy.compress(sample)
        print(f"snappy.compress({sample!r}) =")
        print("  ", hexbytes(packed))
        back = snappy.decompress(packed)
        assert back == sample, "python-snappy failed to round-trip its own output"

    print()
    print("=== framing format (StreamCompressor) ===")
    for sample in [b"hello, framed world", b"xyz" * 100000]:
        sc = snappy.StreamCompressor()
        framed = sc.add_chunk(sample) + sc.flush()
        print(f"StreamCompressor({sample[:30]!r}...) length={len(framed)}")
        print("  head:", hexbytes(framed[:20]))
        sd = snappy.StreamDecompressor()
        back = sd.decompress(framed) + sd.flush()
        assert back == sample, "python-snappy failed to round-trip its own frame"

    print()
    print("=== crc32c check value (via python's own table, not python-snappy) ===")
    # python-snappy doesn't expose crc32c directly (it's internal to the
    # C/cramjam extension); cross-checked separately in Mojo tests against
    # the well-known ISO 3309 / Castagnoli check value instead.

    ok = True
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            data = f.read()
        print(f"\n=== checking Mojo output file: {path} ({len(data)} bytes) ===")
        try:
            if data[:6] == b"\xff\x06\x00sNaP"[:0] or False:
                pass
        except Exception:
            pass
        # Try framing format first (starts with an 0xff stream-id chunk),
        # else fall back to raw format.
        try:
            if len(data) >= 4 and data[0] == 0xFF:
                sd = snappy.StreamDecompressor()
                out = sd.decompress(data) + sd.flush()
                print(f"  decoded as FRAMED: {len(out)} bytes OK")
            else:
                out = snappy.decompress(data)
                print(f"  decoded as RAW: {len(out)} bytes OK")
        except Exception as e:
            print(f"  FAILED to decode with python-snappy: {e}")
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
