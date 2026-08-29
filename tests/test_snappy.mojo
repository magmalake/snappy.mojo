"""Tests for the pure-Mojo Snappy implementation: CRC-32C vectors, raw
block round trips (spec edge cases + block-boundary sizes), framing round
trips with CRC verification, and corruption handling. Run via
`pixi run test`."""

from snappy import (
    Crc32c,
    FramedReader,
    FramedWriter,
    compress,
    compress_framed,
    crc32c,
    decompress,
    decompress_framed,
    decompress_into,
    mask_crc32c,
    max_compressed_length,
    uncompressed_length,
    unmask_crc32c,
    validate,
)


def _bytes(s: String) -> List[UInt8]:
    var span = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(span)):
        out.append(span[i])
    return out^


def _check(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)
    print("  [OK]", msg)


def _lcg_bytes(n: Int, seed_in: UInt64) -> List[UInt8]:
    """Deterministic pseudo-random bytes (no external RNG dependency)."""
    var out = List[UInt8](length=n, fill=UInt8(0))
    var state = seed_in
    for i in range(n):
        state = state * 6364136223846793005 + 1442695040888963407
        out[i] = UInt8((state >> 24) & 0xFF)
    return out^


def _compressible_bytes(n: Int) -> List[UInt8]:
    """Highly redundant data: a short pattern repeated, so the matcher has
    plenty to chew on."""
    var out = List[UInt8](length=n, fill=UInt8(0))
    var pattern = _bytes("The quick brown fox jumps over the lazy dog. ")
    var plen = len(pattern)
    for i in range(n):
        out[i] = pattern[i % plen]
    return out^


def _assert_bytes_equal(a: Span[UInt8, _], b: Span[UInt8, _], msg: String) raises:
    if len(a) != len(b):
        raise Error("FAIL: " + msg + " (length mismatch)")
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error("FAIL: " + msg + " (byte mismatch at " + String(i) + ")")
    print("  [OK]", msg)


def _roundtrip_raw(data: List[UInt8], label: String) raises:
    var packed = compress(Span(data))
    _check(
        len(packed) <= max_compressed_length(len(data)),
        label + ": compressed size within max_compressed_length",
    )
    var back = decompress(Span(packed))
    _assert_bytes_equal(Span(back), Span(data), label + ": raw round trip")
    _check(uncompressed_length(Span(packed)) == len(data), label + ": uncompressed_length")
    _check(validate(Span(packed)), label + ": validate accepts good data")


def _roundtrip_framed(data: List[UInt8], label: String) raises:
    var stream = compress_framed(Span(data))
    var back = decompress_framed(Span(stream))
    _assert_bytes_equal(Span(back), Span(data), label + ": framed round trip")


# ── CRC-32C ──────────────────────────────────────────────────────────────


def test_crc32c_check_value() raises:
    var v = crc32c(Span(_bytes("123456789")))
    _check(v == 0xE3069283, "crc32c(\"123456789\") == 0xE3069283")


def test_crc32c_incremental_matches_chained_seed() raises:
    var a = _bytes("hello, ")
    var b = _bytes("world!")
    var ab = _bytes("hello, world!")
    var whole = crc32c(Span(ab))
    var chained = crc32c(Span(b), seed=crc32c(Span(a)))
    _check(whole == chained, "crc32c(b, seed=crc32c(a)) == crc32c(a+b)")


def test_crc32c_struct_matches_function() raises:
    var data = _bytes("The quick brown fox")
    var viaFn = crc32c(Span(data))
    var c = Crc32c()
    c.update(Span(data))
    _check(c.finish() == viaFn, "Crc32c struct matches free function")


def test_mask_unmask_roundtrip() raises:
    var crc = crc32c(Span(_bytes("round trip me")))
    _check(unmask_crc32c(mask_crc32c(crc)) == crc, "mask_crc32c/unmask_crc32c round trip")


# ── raw format: spec-shaped edge cases ──────────────────────────────────


def test_raw_empty() raises:
    var data = List[UInt8]()
    _roundtrip_raw(data^, "empty input")


def test_raw_one_byte() raises:
    var data = _bytes("x")
    _roundtrip_raw(data^, "1-byte input")


def test_raw_small_literal() raises:
    var data = _bytes("hello world")
    _roundtrip_raw(data^, "small literal")


def test_raw_long_literal_needs_extra_length_bytes() raises:
    # >60 bytes forces the 1-extra-length-byte literal tag path; all
    # distinct bytes so the matcher can't turn any of it into a copy.
    var data = List[UInt8](length=200, fill=UInt8(0))
    for i in range(len(data)):
        data[i] = UInt8(i)
    _roundtrip_raw(data^, "200-byte all-distinct literal")


def test_raw_run_length_overlap() raises:
    # offset=1, long run -> exercises the overlapping-copy path.
    var data = List[UInt8](length=500, fill=UInt8(65))  # 'A' * 500
    _roundtrip_raw(data^, "long single-byte run (overlapping copy)")


def test_raw_64kib_boundary() raises:
    for n in [65535, 65536, 65537]:
        _roundtrip_raw(_compressible_bytes(n), "compressible " + String(n) + "B")
        _roundtrip_raw(_lcg_bytes(n, 12345), "random " + String(n) + "B")


def test_raw_1mib_compressible() raises:
    var data = _compressible_bytes(1024 * 1024)
    _roundtrip_raw(data^, "1 MiB compressible")


def test_raw_1mib_random() raises:
    var data = _lcg_bytes(1024 * 1024, 999)
    var packed = compress(Span(data))
    _check(
        len(packed) <= max_compressed_length(len(data)),
        "1 MiB random: within max_compressed_length",
    )
    var back = decompress(Span(packed))
    _assert_bytes_equal(Span(back), Span(data), "1 MiB random round trip")


def test_raw_decompress_into_rejects_small_buffer() raises:
    var data = _bytes("some data that needs a real buffer")
    var packed = compress(Span(data))
    var tiny = List[UInt8](length=1, fill=UInt8(0))
    var threw = False
    try:
        _ = decompress_into(Span(packed), Span(tiny))
    except:
        threw = True
    _check(threw, "decompress_into raises on undersized destination")


# ── corruption handling ─────────────────────────────────────────────────


def test_corrupt_raw_bad_copy_offset() raises:
    # A copy tag (type 0b01) with offset 0 is never valid.
    var bad = List[UInt8]()
    bad.append(UInt8(1))  # varint: uncompressed length = 1
    bad.append(UInt8(0b00000001))  # copy1 tag, length field = 0 -> len 4
    bad.append(UInt8(0))  # offset low byte = 0 -> offset 0
    var threw = False
    try:
        _ = decompress(Span(bad))
    except:
        threw = True
    _check(threw, "corrupt copy (offset 0) raises")
    _check(not validate(Span(bad)), "validate rejects corrupt copy")


def test_corrupt_raw_truncated() raises:
    var data = _bytes("this will get truncated after compression")
    var packed = compress(Span(data))
    var truncated = Span(packed)[0 : len(packed) - 2]
    var threw = False
    try:
        _ = decompress(truncated)
    except:
        threw = True
    _check(threw, "truncated compressed data raises")


def test_framed_bad_crc_raises() raises:
    var data = _bytes("integrity matters")
    var stream = compress_framed(Span(data))
    # Flip a bit inside the first data chunk's checksum bytes (right after
    # the 4-byte stream-id chunk header + 6-byte "sNaPpY" body = offset
    # 10, then +4 chunk header -> checksum starts at 14).
    stream[14] = stream[14] ^ UInt8(0xFF)
    var threw = False
    try:
        _ = decompress_framed(Span(stream))
    except:
        threw = True
    _check(threw, "flipped CRC-32C in a frame raises")


def test_framed_bad_magic_raises() raises:
    var data = _bytes("hi")
    var stream = compress_framed(Span(data))
    stream[4] = UInt8(0x00)  # corrupt first byte of "sNaPpY"
    var threw = False
    try:
        _ = decompress_framed(Span(stream))
    except:
        threw = True
    _check(threw, "corrupt stream identifier raises")


# ── framing format ───────────────────────────────────────────────────────


def test_framed_roundtrip_small() raises:
    _roundtrip_framed(_bytes("hello, framed world"), "small framed")


def test_framed_roundtrip_multi_chunk() raises:
    # > 64 KiB forces multiple chunks.
    _roundtrip_framed(_compressible_bytes(200000), "multi-chunk compressible")
    _roundtrip_framed(_lcg_bytes(200000, 42), "multi-chunk random")


def test_framed_roundtrip_empty() raises:
    _roundtrip_framed(List[UInt8](), "empty framed")


def test_framed_writer_reader() raises:
    var a = _bytes("first chunk of data, ")
    var b = _bytes("second chunk of data.")
    var w = FramedWriter()
    w.write(Span(a))
    w.write(Span(b))
    var stream = w^.finish()

    var r = FramedReader(Span(stream))
    var got = List[UInt8]()
    while True:
        var chunk = r.read_chunk()
        if not chunk:
            break
        var c = chunk.value().copy()
        for i in range(len(c)):
            got.append(c[i])

    var expected = List[UInt8]()
    for i in range(len(a)):
        expected.append(a[i])
    for i in range(len(b)):
        expected.append(b[i])
    _assert_bytes_equal(Span(got), Span(expected), "FramedWriter/FramedReader round trip")


# ── known bytes produced by Python python-snappy ────────────────────────
# Generated once via tools/gen_python_vectors.py (pip install python-snappy
# in a throwaway venv) and pasted in as constants so tests have no runtime
# dependency on Python/pip. See that script for exact provenance.


def test_decompress_python_snappy_raw() raises:
    # snappy.compress(b"hello world") via python-snappy
    var expected = _bytes("hello world")
    var py_compressed = List[UInt8]()
    for b in [
        0x0B, 0x28, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72,
        0x6C, 0x64,
    ]:
        py_compressed.append(UInt8(b))
    var back = decompress(Span(py_compressed))
    _assert_bytes_equal(Span(back), Span(expected), "decompress python-snappy raw bytes")


def main() raises:
    test_crc32c_check_value()
    test_crc32c_incremental_matches_chained_seed()
    test_crc32c_struct_matches_function()
    test_mask_unmask_roundtrip()

    test_raw_empty()
    test_raw_one_byte()
    test_raw_small_literal()
    test_raw_long_literal_needs_extra_length_bytes()
    test_raw_run_length_overlap()
    test_raw_64kib_boundary()
    test_raw_1mib_compressible()
    test_raw_1mib_random()
    test_raw_decompress_into_rejects_small_buffer()

    test_corrupt_raw_bad_copy_offset()
    test_corrupt_raw_truncated()
    test_framed_bad_crc_raises()
    test_framed_bad_magic_raises()

    test_framed_roundtrip_small()
    test_framed_roundtrip_multi_chunk()
    test_framed_roundtrip_empty()
    test_framed_writer_reader()

    test_decompress_python_snappy_raw()

    print("PASS — all snappy.mojo tests")
