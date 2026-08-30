"""Snappy **raw block format**: a leading varint giving the uncompressed
length, followed by a stream of literal / copy elements. See
https://github.com/google/snappy/blob/main/format_description.txt.

Compression is a single-pass greedy LZ77 matcher: a flat hash table maps
the multiplicative hash of each 4-byte window (same constant the C++
reference uses, `0x1e35a7bd`) to the most recent position with that hash,
and any 4-byte match found there is greedily extended and emitted as a
copy. This is the reference's "fast" strategy (no lazy matching, no hash
chaining) — it trades some ratio for a simple, branch-light inner loop.
"""

comptime _HASH_MUL: UInt32 = 0x1E35A7BD


def max_compressed_length(n: Int) -> Int:
    """Upper bound on the compressed size of an `n`-byte input — matches
    the C++ reference's `MaxCompressedLength(n) = 32 + n + n/6`."""
    return 32 + n + n // 6


# ── varint ────────────────────────────────────────────────────────────────


def _write_varint(mut out: List[UInt8], value: Int):
    var v = UInt64(value)
    while v >= 0x80:
        out.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    out.append(UInt8(v))


def _read_varint(data: Span[UInt8, _], start: Int) raises -> Tuple[Int, Int]:
    """Returns (value, bytes_consumed)."""
    var result: UInt64 = 0
    var shift = 0
    var i = start
    var n = len(data)
    while True:
        if i >= n:
            raise Error("snappy: truncated varint")
        if shift >= 64:
            raise Error("snappy: varint too long")
        var b = data[i]
        i += 1
        result |= UInt64(b & 0x7F) << UInt64(shift)
        if (b & 0x80) == 0:
            break
        shift += 7
    return (Int(result), i - start)


def uncompressed_length(data: Span[UInt8, _]) raises -> Int:
    """Decode the leading varint (the decompressed size) without
    decompressing the rest of `data`."""
    var parsed = _read_varint(data, 0)
    return parsed[0]


# ── element emission (compressor side) ──────────────────────────────────


def _emit_literal(
    mut out: List[UInt8], data: Span[UInt8, _], start: Int, end: Int
):
    var length = end - start
    if length <= 0:
        return
    var n = length - 1
    if n < 60:
        out.append(UInt8(n << 2))
    elif n <= 0xFF:
        out.append(UInt8(60 << 2))
        out.append(UInt8(n & 0xFF))
    elif n <= 0xFFFF:
        out.append(UInt8(61 << 2))
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
    elif n <= 0xFFFFFF:
        out.append(UInt8(62 << 2))
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
    else:
        out.append(UInt8(63 << 2))
        out.append(UInt8(n & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 24) & 0xFF))
    for i in range(start, end):
        out.append(data[i])


def _emit_copy_chunk(mut out: List[UInt8], offset: Int, length: Int):
    """`length` must already be in [1, 64] (copy1 additionally needs
    [4, 11])."""
    if length >= 4 and length <= 11 and offset < 2048:
        var tag = (
            UInt8(1)
            | (UInt8(length - 4) << 2)
            | (UInt8((offset >> 8) & 0x7) << 5)
        )
        out.append(tag)
        out.append(UInt8(offset & 0xFF))
    elif offset < 65536:
        out.append(UInt8(2) | (UInt8(length - 1) << 2))
        out.append(UInt8(offset & 0xFF))
        out.append(UInt8((offset >> 8) & 0xFF))
    else:
        out.append(UInt8(3) | (UInt8(length - 1) << 2))
        out.append(UInt8(offset & 0xFF))
        out.append(UInt8((offset >> 8) & 0xFF))
        out.append(UInt8((offset >> 16) & 0xFF))
        out.append(UInt8((offset >> 24) & 0xFF))


def _emit_copy(mut out: List[UInt8], offset: Int, length_in: Int):
    var length = length_in
    while length >= 68:
        _emit_copy_chunk(out, offset, 64)
        length -= 64
    if length > 64:
        _emit_copy_chunk(out, offset, length - 4)
        length = 4
    _emit_copy_chunk(out, offset, length)


# ── matcher (compressor side) ────────────────────────────────────────────


def _hash4(data: Span[UInt8, _], pos: Int, table_bits: Int) -> Int:
    var word = (
        UInt32(data[pos])
        | (UInt32(data[pos + 1]) << 8)
        | (UInt32(data[pos + 2]) << 16)
        | (UInt32(data[pos + 3]) << 24)
    )
    return Int((word * _HASH_MUL) >> UInt32(32 - table_bits))


def _matches4(data: Span[UInt8, _], a: Int, b: Int) -> Bool:
    return (
        data[a] == data[b]
        and data[a + 1] == data[b + 1]
        and data[a + 2] == data[b + 2]
        and data[a + 3] == data[b + 3]
    )


def _extend_match(
    data: Span[UInt8, _], a_in: Int, b_in: Int, limit: Int
) -> Int:
    var a = a_in
    var b = b_in
    while b < limit and data[a] == data[b]:
        a += 1
        b += 1
    return b - b_in


def compress(data: Span[UInt8, _]) -> List[UInt8]:
    """Compress `data` into a Snappy raw block."""
    var out = List[UInt8]()
    var n = len(data)
    _write_varint(out, n)
    if n == 0:
        return out^

    # Hash table sized to a power of two roughly matching the input, capped
    # at 2**15 entries (matches the C++ reference's kMaxHashTableSize).
    var table_bits = 8
    while (1 << table_bits) < n and table_bits < 15:
        table_bits += 1
    var table_size = 1 << table_bits
    var table = List[Int32](length=table_size, fill=Int32(-1))

    var pos = 0
    var next_emit = 0
    var limit = n - 4

    if limit >= 0:
        while pos <= limit:
            var h = _hash4(data, pos, table_bits)
            var candidate = Int(table[h])
            table[h] = Int32(pos)
            if candidate >= 0 and _matches4(data, candidate, pos):
                _emit_literal(out, data, next_emit, pos)
                var match_extra = _extend_match(data, candidate + 4, pos + 4, n)
                var match_len = 4 + match_extra
                var offset = pos - candidate
                _emit_copy(out, offset, match_len)
                pos += match_len
                next_emit = pos
            else:
                pos += 1
    _emit_literal(out, data, next_emit, n)
    return out^


# ── decompressor ─────────────────────────────────────────────────────────


def decompress_into[
    origin: Origin[mut=True], //
](data: Span[UInt8, _], dst: Span[UInt8, origin]) raises -> Int:
    """Decompress the raw Snappy block `data` into `dst`, which must be at
    least `uncompressed_length(data)` bytes. Returns the number of bytes
    written. Raises on any structural corruption.

    Literals and non-overlapping copies move 16 bytes at a time. Both are
    allowed to write past the end of the element they are copying, because
    the write always lands inside the part of `dst` the block has already
    been checked to fit in; the bytes written past the element are
    overwritten by whatever comes next. Only the last few bytes of the output,
    where that slack runs out, take the byte-at-a-time path.
    """
    var parsed = _read_varint(data, 0)
    var want = parsed[0]
    var ipos = parsed[1]
    if want > len(dst):
        raise Error("snappy: destination buffer too small")

    var n = len(data)
    var opos = 0
    var src = data.unsafe_ptr()
    var out = dst.unsafe_ptr()
    while ipos < n:
        var tag = src.unsafe_load(ipos)
        var typ = Int(tag & 0x3)
        if typ == 0:
            var top = Int(tag >> 2)
            var lit_len: Int
            if top < 60:
                lit_len = top + 1
                ipos += 1
            else:
                var extra = top - 59  # 1..4 extra length bytes
                if ipos + 1 + extra > n:
                    raise Error("snappy: truncated literal length")
                var val: UInt64 = 0
                for k in range(extra):
                    val |= UInt64(src.unsafe_load(ipos + 1 + k)) << UInt64(
                        8 * k
                    )
                lit_len = Int(val) + 1
                ipos += 1 + extra
            if lit_len < 0 or ipos + lit_len > n or opos + lit_len > want:
                raise Error("snappy: corrupt literal")
            if lit_len <= 16 and ipos + 16 <= n and opos + 16 <= want:
                out.unsafe_store[width=16](
                    opos, src.unsafe_load[width=16](ipos)
                )
            else:
                var k = 0
                while k + 16 <= lit_len:
                    out.unsafe_store[width=16](
                        opos + k, src.unsafe_load[width=16](ipos + k)
                    )
                    k += 16
                while k < lit_len:
                    out.unsafe_store(opos + k, src.unsafe_load(ipos + k))
                    k += 1
            ipos += lit_len
            opos += lit_len
        else:
            var length: Int
            var offset: Int
            if typ == 1:
                if ipos + 1 >= n:
                    raise Error("snappy: truncated copy (1-byte offset)")
                length = Int((tag >> 2) & 0x7) + 4
                offset = (Int(tag >> 5) << 8) | Int(src.unsafe_load(ipos + 1))
                ipos += 2
            elif typ == 2:
                if ipos + 2 >= n:
                    raise Error("snappy: truncated copy (2-byte offset)")
                length = Int(tag >> 2) + 1
                offset = Int(src.unsafe_load(ipos + 1)) | (
                    Int(src.unsafe_load(ipos + 2)) << 8
                )
                ipos += 3
            else:
                if ipos + 4 >= n:
                    raise Error("snappy: truncated copy (4-byte offset)")
                length = Int(tag >> 2) + 1
                offset = (
                    Int(src.unsafe_load(ipos + 1))
                    | (Int(src.unsafe_load(ipos + 2)) << 8)
                    | (Int(src.unsafe_load(ipos + 3)) << 16)
                    | (Int(src.unsafe_load(ipos + 4)) << 24)
                )
                ipos += 5
            if offset <= 0 or offset > opos:
                raise Error("snappy: invalid copy offset")
            if opos + length > want:
                raise Error("snappy: corrupt copy length")
            var at = opos - offset
            if offset >= 16 and length <= 16 and opos + 16 <= want:
                # The whole copy in one 16-byte move: the source is at least
                # 16 bytes behind, so it is entirely written already.
                out.unsafe_store[width=16](opos, out.unsafe_load[width=16](at))
            elif offset >= length:
                var k = 0
                while k + 16 <= length:
                    out.unsafe_store[width=16](
                        opos + k, out.unsafe_load[width=16](at + k)
                    )
                    k += 16
                while k < length:
                    out.unsafe_store(opos + k, out.unsafe_load(at + k))
                    k += 1
            else:
                # An overlapping run-length pattern: each byte has to be read
                # only after it has been written.
                for k in range(length):
                    out.unsafe_store(opos + k, out.unsafe_load(at + k))
            opos += length

    if opos != want:
        raise Error("snappy: truncated block")
    return opos


def decompress(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompress a Snappy raw block into a freshly allocated `List[UInt8]`."""
    var want = uncompressed_length(data)
    var out = List[UInt8](length=want, fill=UInt8(0))
    var written = decompress_into(data, Span(out))
    if written != want:
        raise Error("snappy: length mismatch")
    return out^


def validate(data: Span[UInt8, _]) -> Bool:
    """Best-effort check: does `data` parse as a well-formed raw Snappy
    block?"""
    try:
        _ = decompress(data)
        return True
    except:
        return False
