"""Compress and decompress throughput over a 64 MiB buffer, both shapes of
input, through the shared harness (magmalake/bench.mojo).

    pixi run -e bench bench
    pixi run -e bench bench -- --json
    pixi run -e bench bench -- --only bench_compress_compressible

Each body rebuilds its input, because the harness re-enters a benchmark once
per phase and only what is inside `b.iter` is timed. For the decompress
benchmarks that means compressing 64 MiB in setup every time -- wall-clock
cost, never counted.
"""

from bench import Benchmark, BenchSuite, Metric, keep

from snappy import compress, decompress

comptime SIZE = 64 * 1024 * 1024


def _repeat_bytes(pattern: StaticString, n: Int) -> List[UInt8]:
    var p = String(pattern).as_bytes()
    var plen = len(p)
    var out = List[UInt8](length=n, fill=UInt8(0))
    for i in range(n):
        out[i] = p[i % plen]
    return out^


def _compressible(n: Int) -> List[UInt8]:
    return _repeat_bytes(
        "The quick brown fox jumps over the lazy dog. ", n
    )


def _random(n: Int) -> List[UInt8]:
    """LCG rather than `std.random`, so the input is identical run to run."""
    var out = List[UInt8](length=n, fill=UInt8(0))
    var state = UInt64(0xC0FFEE)
    for i in range(n):
        state = state * 6364136223846793005 + 1442695040888963407
        out[i] = UInt8((state >> 24) & 0xFF)
    return out^


def bench_compress_compressible(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var packed = compress(Span(data))
        keep(packed)

    b.iter[call]()
    keep(data)


def bench_decompress_compressible(mut b: Benchmark) raises:
    var data = _compressible(SIZE)
    var packed = compress(Span(data))
    # Throughput is quoted against the *uncompressed* size, which is the
    # number a caller cares about: bytes of payload recovered per second.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var back = decompress(Span(packed))
        keep(back)

    b.iter[call]()
    keep(data)
    keep(packed)


def bench_compress_random(mut b: Benchmark) raises:
    var data = _random(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var packed = compress(Span(data))
        keep(packed)

    b.iter[call]()
    keep(data)


def bench_decompress_random(mut b: Benchmark) raises:
    var data = _random(SIZE)
    var packed = compress(Span(data))
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var back = decompress(Span(packed))
        keep(back)

    b.iter[call]()
    keep(data)
    keep(packed)


def _print_ratios() raises:
    """Compression ratios, printed once. They are a property of the data, not
    a timing, so they have no place in the benchmark table."""
    var c = _compressible(SIZE)
    var r = _random(SIZE)
    var cp = compress(Span(c))
    var rp = compress(Span(r))
    print(
        "input", SIZE // (1024 * 1024), "MiB |",
        "compressible ->", len(cp) // 1024, "KiB",
        "(", Float64(SIZE) / Float64(len(cp)), "x ) |",
        "random ->", len(rp) // 1024, "KiB",
        "(", Float64(SIZE) / Float64(len(rp)), "x )",
    )
    if len(decompress(Span(cp))) != SIZE or len(decompress(Span(rp))) != SIZE:
        raise Error("round trip length mismatch")


def main() raises:
    _print_ratios()
    BenchSuite.run[__functions_in_module()]()
