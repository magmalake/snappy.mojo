"""Throughput bench: compress + decompress a 64 MiB buffer (compressible
and random) and report MB/s. Run via `pixi run bench`."""

from std.time import perf_counter_ns

from snappy import compress, decompress, max_compressed_length


def _repeat_bytes(pattern: String, n: Int) -> List[UInt8]:
    var span = pattern.as_bytes()
    var p = List[UInt8]()
    for i in range(len(span)):
        p.append(span[i])
    var plen = len(p)
    var out = List[UInt8](length=n, fill=UInt8(0))
    for i in range(n):
        out[i] = p[i % plen]
    return out^


def _lcg_bytes(n: Int, seed_in: UInt64) -> List[UInt8]:
    var out = List[UInt8](length=n, fill=UInt8(0))
    var state = seed_in
    for i in range(n):
        state = state * 6364136223846793005 + 1442695040888963407
        out[i] = UInt8((state >> 24) & 0xFF)
    return out^


def _mb_per_s(bytes_count: Int, ns: Int) -> Float64:
    if ns <= 0:
        return 0.0
    var seconds = Float64(ns) / 1_000_000_000.0
    var megabytes = Float64(bytes_count) / (1024.0 * 1024.0)
    return megabytes / seconds


def _bench_one(label: String, data: List[UInt8]) raises:
    var n = len(data)

    var t0 = perf_counter_ns()
    var packed = compress(Span(data))
    var t1 = perf_counter_ns()
    var compress_mbs = _mb_per_s(n, Int(t1 - t0))

    var ratio = Float64(n) / Float64(len(packed))

    var t2 = perf_counter_ns()
    var back = decompress(Span(packed))
    var t3 = perf_counter_ns()
    var decompress_mbs = _mb_per_s(n, Int(t3 - t2))

    if len(back) != n:
        raise Error("bench: round trip length mismatch for " + label)

    print(
        label,
        ": in=", n // (1024 * 1024), "MiB",
        " packed=", len(packed) // 1024, "KiB",
        " ratio=", ratio,
        " compress=", compress_mbs, "MB/s",
        " decompress=", decompress_mbs, "MB/s",
    )


def main() raises:
    comptime SIZE = 64 * 1024 * 1024
    print("snappy.mojo bench —", SIZE // (1024 * 1024), "MiB per input")
    _bench_one("compressible", _repeat_bytes("The quick brown fox jumps over the lazy dog. ", SIZE))
    _bench_one("random      ", _lcg_bytes(SIZE, 0xC0FFEE))
