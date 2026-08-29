"""Snappy **framing format**: a `sNaPpY` stream identifier chunk followed
by a sequence of length-prefixed chunks, each either compressed or
uncompressed raw-format data guarded by a masked CRC-32C. See
https://github.com/google/snappy/blob/main/framing_format.txt.

Chunk layout: 1-byte type, 3-byte little-endian data length, then the
data. Compressed/uncompressed data chunks additionally carry a 4-byte
little-endian masked CRC-32C of the *uncompressed* bytes as the first 4
bytes of their data.
"""

from .crc32c import crc32c, mask_crc32c, unmask_crc32c
from .raw import compress, decompress

comptime CHUNK_COMPRESSED: UInt8 = 0x00
comptime CHUNK_UNCOMPRESSED: UInt8 = 0x01
comptime CHUNK_PADDING: UInt8 = 0xFE
comptime CHUNK_STREAM_IDENTIFIER: UInt8 = 0xFF

# The framing spec requires compliant writers to keep each chunk's
# *uncompressed* payload at or below this size.
comptime _MAX_BLOCK: Int = 65536


def _stream_magic() -> List[UInt8]:
    var span = String("sNaPpY").as_bytes()
    var out = List[UInt8]()
    for i in range(len(span)):
        out.append(span[i])
    return out^


def _write_chunk_header(mut out: List[UInt8], typ: UInt8, length: Int):
    out.append(typ)
    out.append(UInt8(length & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8((length >> 16) & 0xFF))


def _append_u32_le(mut out: List[UInt8], value: UInt32):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))


def _append_span(mut out: List[UInt8], data: Span[UInt8, _]):
    for i in range(len(data)):
        out.append(data[i])


def _write_stream_identifier(mut out: List[UInt8]):
    var magic = _stream_magic()
    _write_chunk_header(out, CHUNK_STREAM_IDENTIFIER, len(magic))
    _append_span(out, Span(magic))


def _write_block(mut out: List[UInt8], block: Span[UInt8, _]):
    """Emit one framing-format data chunk for `block` (<= 65536 bytes),
    choosing compressed vs. uncompressed by whichever is smaller on the
    wire, exactly like the C++ reference writer."""
    var checksum = mask_crc32c(crc32c(block))
    var packed = compress(block)
    if len(packed) < len(block):
        _write_chunk_header(out, CHUNK_COMPRESSED, 4 + len(packed))
        _append_u32_le(out, checksum)
        _append_span(out, Span(packed))
    else:
        _write_chunk_header(out, CHUNK_UNCOMPRESSED, 4 + len(block))
        _append_u32_le(out, checksum)
        _append_span(out, block)


def compress_framed(data: Span[UInt8, _]) -> List[UInt8]:
    """Compress `data` into a complete Snappy framing-format stream
    (stream identifier + one or more chunks, each <= 64 KiB
    uncompressed)."""
    var out = List[UInt8]()
    _write_stream_identifier(out)
    var n = len(data)
    var pos = 0
    while pos < n:
        var block_len = _MAX_BLOCK
        if n - pos < block_len:
            block_len = n - pos
        _write_block(out, data[pos : pos + block_len])
        pos += block_len
    return out^


def decompress_framed(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompress a full Snappy framing-format stream, verifying every
    chunk's masked CRC-32C. Raises on a missing/misplaced stream
    identifier, an unsupported unskippable chunk type, or a checksum
    mismatch."""
    var out = List[UInt8]()
    var n = len(data)
    var pos = 0
    var seen_stream_id = False
    while pos < n:
        if pos + 4 > n:
            raise Error("snappy: truncated chunk header")
        var typ = data[pos]
        var length = (
            Int(data[pos + 1])
            | (Int(data[pos + 2]) << 8)
            | (Int(data[pos + 3]) << 16)
        )
        pos += 4
        if pos + length > n:
            raise Error("snappy: truncated chunk data")
        var chunk = data[pos : pos + length]

        if typ == CHUNK_STREAM_IDENTIFIER:
            var magic = _stream_magic()
            if length != len(magic):
                raise Error("snappy: bad stream identifier length")
            for i in range(length):
                if chunk[i] != magic[i]:
                    raise Error("snappy: bad stream identifier")
            seen_stream_id = True
        elif typ == CHUNK_COMPRESSED or typ == CHUNK_UNCOMPRESSED:
            if not seen_stream_id:
                raise Error("snappy: data chunk before stream identifier")
            if length < 4:
                raise Error("snappy: chunk too short for its checksum")
            var stored = (
                UInt32(chunk[0])
                | (UInt32(chunk[1]) << 8)
                | (UInt32(chunk[2]) << 16)
                | (UInt32(chunk[3]) << 24)
            )
            var payload = chunk[4:length]
            var block: List[UInt8]
            if typ == CHUNK_COMPRESSED:
                block = decompress(payload)
            else:
                block = List[UInt8]()
                _append_span(block, payload)
            var actual = crc32c(Span(block))
            if unmask_crc32c(stored) != actual:
                raise Error("snappy: crc32c mismatch")
            _append_span(out, Span(block))
        elif typ == CHUNK_PADDING:
            pass  # padding chunk: no checksum, contents ignored
        elif typ >= 0x02 and typ <= 0x7F:
            raise Error("snappy: unsupported unskippable chunk type")
        # else: 0x80-0xFD reserved *skippable* chunk — ignore its data.
        pos += length
    return out^


struct FramedWriter(Movable):
    """Incremental framing-format encoder: feed arbitrary-sized buffers to
    `write`, splitting into <=64 KiB chunks internally; `finish` returns
    the complete encoded stream."""

    var _out: List[UInt8]
    var _wrote_header: Bool

    def __init__(out self):
        self._out = List[UInt8]()
        self._wrote_header = False

    def write(mut self, data: Span[UInt8, _]):
        if not self._wrote_header:
            _write_stream_identifier(self._out)
            self._wrote_header = True
        var n = len(data)
        var pos = 0
        while pos < n:
            var block_len = _MAX_BLOCK
            if n - pos < block_len:
                block_len = n - pos
            _write_block(self._out, data[pos : pos + block_len])
            pos += block_len

    def finish(deinit self) -> List[UInt8]:
        if not self._wrote_header:
            _write_stream_identifier(self._out)
        return self._out^


struct FramedReader(Movable):
    """Incremental framing-format decoder: `read_chunk` returns each data
    chunk's decompressed bytes in order (verifying its CRC-32C), or
    `None` once the stream is exhausted. Stream-identifier, padding, and
    skippable chunks are consumed transparently."""

    var _data: List[UInt8]
    var _pos: Int
    var _seen_stream_id: Bool

    def __init__(out self, data: Span[UInt8, _]):
        self._data = List[UInt8]()
        _append_span(self._data, data)
        self._pos = 0
        self._seen_stream_id = False

    def read_chunk(mut self) raises -> Optional[List[UInt8]]:
        var n = len(self._data)
        var view = Span(self._data)
        while self._pos < n:
            if self._pos + 4 > n:
                raise Error("snappy: truncated chunk header")
            var typ = view[self._pos]
            var length = (
                Int(view[self._pos + 1])
                | (Int(view[self._pos + 2]) << 8)
                | (Int(view[self._pos + 3]) << 16)
            )
            var body_start = self._pos + 4
            if body_start + length > n:
                raise Error("snappy: truncated chunk data")
            var chunk = view[body_start : body_start + length]
            self._pos = body_start + length

            if typ == CHUNK_STREAM_IDENTIFIER:
                var magic = _stream_magic()
                if length != len(magic):
                    raise Error("snappy: bad stream identifier length")
                for i in range(length):
                    if chunk[i] != magic[i]:
                        raise Error("snappy: bad stream identifier")
                self._seen_stream_id = True
                continue
            elif typ == CHUNK_COMPRESSED or typ == CHUNK_UNCOMPRESSED:
                if not self._seen_stream_id:
                    raise Error("snappy: data chunk before stream identifier")
                if length < 4:
                    raise Error("snappy: chunk too short for its checksum")
                var stored = (
                    UInt32(chunk[0])
                    | (UInt32(chunk[1]) << 8)
                    | (UInt32(chunk[2]) << 16)
                    | (UInt32(chunk[3]) << 24)
                )
                var payload = chunk[4:length]
                var block: List[UInt8]
                if typ == CHUNK_COMPRESSED:
                    block = decompress(payload)
                else:
                    block = List[UInt8]()
                    _append_span(block, payload)
                var actual = crc32c(Span(block))
                if unmask_crc32c(stored) != actual:
                    raise Error("snappy: crc32c mismatch")
                return Optional(block^)
            elif typ == CHUNK_PADDING:
                continue
            elif typ >= 0x02 and typ <= 0x7F:
                raise Error("snappy: unsupported unskippable chunk type")
            else:
                continue  # skippable reserved chunk
        return Optional[List[UInt8]](None)
