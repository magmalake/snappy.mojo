# snappy.mojo

[![mojoshelf](https://mojoshelf.org/badge/snappy-mojo.svg)](https://mojoshelf.org/tins/snappy-mojo) [![mojo nightly](https://mojoshelf.org/badge/snappy-mojo/nightly.svg)](https://mojoshelf.org/tins/snappy-mojo)

> Part of **magmalake** — data lake building blocks in Mojo.

A pure-[Mojo](https://www.modular.com/mojo) implementation of
[Snappy](https://github.com/google/snappy): the **raw block format** and
the **framing format** (`sNaPpY` stream identifier, chunked, CRC-32C
checksummed). No FFI, no C dependency — Snappy is a common codec for
Parquet and Avro, so this is small enough to implement natively.

- [format_description.txt](https://github.com/google/snappy/blob/main/format_description.txt) — raw block format
- [framing_format.txt](https://github.com/google/snappy/blob/main/framing_format.txt) — framing format

## Use

```mojo
from snappy import compress, decompress

var packed = compress(Span(data))       # List[UInt8]
var back = decompress(Span(packed))     # List[UInt8], == data

from snappy import compress_framed, decompress_framed

var stream = compress_framed(Span(data))    # sNaPpY-framed, CRC-32C per chunk
var back2 = decompress_framed(Span(stream)) # verifies every chunk's checksum
```

Consume it like the other magmalake libs — `-I ../snappy.mojo/src` (no FFI,
no link flags).

## API

| function | signature | notes |
|---|---|---|
| `compress` | `compress(data: Span[UInt8]) -> List[UInt8]` | raw block format |
| `decompress` | `decompress(data: Span[UInt8]) -> List[UInt8]` | raises on corrupt input |
| `decompress_into` | `decompress_into(data: Span[UInt8], dst: Span[UInt8]) -> Int` | writes into a caller-owned buffer, returns bytes written |
| `uncompressed_length` | `uncompressed_length(data: Span[UInt8]) -> Int` | decode the leading varint without decompressing |
| `max_compressed_length` | `max_compressed_length(n: Int) -> Int` | upper bound: `32 + n + n/6`, matches the C++ reference |
| `validate` | `validate(data: Span[UInt8]) -> Bool` | best-effort structural check |
| `compress_framed` | `compress_framed(data: Span[UInt8]) -> List[UInt8]` | framing format, chunked at 64 KiB |
| `decompress_framed` | `decompress_framed(data: Span[UInt8]) -> List[UInt8]` | verifies every chunk's masked CRC-32C, raises on mismatch |
| `FramedWriter` | `.write(Span[UInt8])`, `.finish() -> List[UInt8]` | incremental framing-format encoder |
| `FramedReader` | `.read_chunk() -> Optional[List[UInt8]]` | incremental framing-format decoder |
| `crc32c` | `crc32c(data: Span[UInt8], seed: UInt32 = 0) -> UInt32` | CRC-32C (Castagnoli); `crc32c(b"123456789") == 0xE3069283` |
| `mask_crc32c` / `unmask_crc32c` | `(UInt32) -> UInt32` | the framing format's checksum masking |

## Implementation notes

- **Raw format**: a single-pass greedy LZ77 matcher. A flat hash table maps
  the multiplicative hash of each 4-byte window (`0x1e35a7bd`, same
  constant as the C++ reference) to the most recent position with that
  hash; any match is greedily extended and emitted as a copy. This is the
  reference's "fast" strategy — no lazy matching, no hash chaining — so it
  trades some ratio for a simple, branch-light inner loop. Copy/literal
  encoding (1/2/4-byte offsets, the 60-length literal-tag threshold, the
  68-byte copy-splitting rule) mirrors the reference bit-for-bit; output
  has been cross-checked against `python-snappy` (see
  `tools/gen_python_vectors.py`).
- **CRC-32C**: table-driven (slice-by-8), independent from plain CRC-32
  (different polynomial: `0x1EDC6F41`/reflected `0x82F63B78` vs.
  `0xEDB88320`) — the framing format needs Castagnoli, not the
  gzip/zlib/PNG polynomial.
- Every multi-byte integer (varints aside) is assembled byte-by-byte
  rather than through a pointer cast, so there are no unaligned-load or
  endianness assumptions — this runs the same on macOS/arm64 and
  Linux/x86-64.
- Decompression's overlapping-copy loop (`offset < length`, e.g.
  run-length patterns) copies one byte at a time by construction, since a
  bulk copy would read output that hasn't been written yet.

## Test

```sh
pixi run test    # spec edge cases, 64 KiB block boundaries, 1 MiB round
                  # trips, corrupt-input / bad-CRC handling, a byte-exact
                  # python-snappy vector
pixi run bench    # MB/s over a 64 MiB buffer (compressible + random)
```

Tests run on both a pinned stable Mojo (`pixi run -e stable test`) and the
latest nightly (`pixi run test`, the default environment) — see CI.

## Performance

64 MiB per input, this machine (Apple Silicon M4, `pixi run bench`,
single-threaded):

| input | ratio | compress | decompress |
|---|---|---|---|
| compressible (repeating text) | ~21x | ~800 MB/s | ~3.0 GB/s |
| random (incompressible) | ~1.0x | ~210 MB/s | ~20 GB/s |

The decompressor moves literals and non-overlapping copies 16 bytes at a
time, writing past the end of the element it is copying into slack that the
next element overwrites — so an incompressible input, which is one long
literal, decodes at memory-copy speed. Only overlapping run-length copies
and the last few bytes of the output take the byte-at-a-time path.

Compression is still matcher-bound on random data (a hash-table probe at
every byte position, since nothing ever matches). The reference C++
implementation reports roughly 250–500 MB/s compress on modern x86, so the
compressor is in the right range and the headroom left there (hash-chain
lookback, lazy matching, SIMD length-matching) is what this "fast strategy"
implementation doesn't chase.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
