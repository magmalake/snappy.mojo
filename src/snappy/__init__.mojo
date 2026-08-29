"""snappy — a pure-Mojo Snappy compressor/decompressor.

Implements both the **raw block format** (varint length + literal/copy
elements) and the **framing format** (`sNaPpY` stream identifier, chunked,
CRC-32C-checksummed) from
https://github.com/google/snappy/blob/main/format_description.txt and
https://github.com/google/snappy/blob/main/framing_format.txt. No FFI, no
C dependency.

    from snappy import compress, decompress
    var packed = compress(Span(data))
    var back = decompress(Span(packed))

    from snappy import compress_framed, decompress_framed
    var stream = compress_framed(Span(data))   # sNaPpY-framed, CRC-checked
    var back2 = decompress_framed(Span(stream))
"""

from .crc32c import Crc32c, crc32c, mask_crc32c, unmask_crc32c
from .raw import (
    compress,
    decompress,
    decompress_into,
    max_compressed_length,
    uncompressed_length,
    validate,
)
from .framing import (
    FramedReader,
    FramedWriter,
    compress_framed,
    decompress_framed,
)
