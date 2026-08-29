"""One-shot helper for the python-snappy interop check (see
tools/gen_python_vectors.py): compress a few payloads with our Mojo
implementation and write both raw- and framing-format output to disk, so
an independent decoder (python-snappy) can be pointed at them.

    pixi run -e stable mojo run -I src tools/dump_vectors.mojo <out_dir>
"""

from snappy import compress, compress_framed


def _bytes(s: String) -> List[UInt8]:
    var span = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(span)):
        out.append(span[i])
    return out^


def _repeat(pattern: String, n: Int) -> List[UInt8]:
    var p = _bytes(pattern)
    var plen = len(p)
    var out = List[UInt8](length=n, fill=UInt8(0))
    for i in range(n):
        out[i] = p[i % plen]
    return out^


def _write_file(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(data))


def main() raises:
    from std.sys import argv

    var args = argv()
    var out_dir = String("/tmp")
    if len(args) > 1:
        out_dir = String(args[1])

    var hello = _bytes("hello world")
    _write_file(out_dir + "/mojo_raw_hello.bin", compress(Span(hello)))
    _write_file(out_dir + "/mojo_framed_hello.bin", compress_framed(Span(hello)))

    var rep = _repeat("The quick brown fox. ", 500000)
    _write_file(out_dir + "/mojo_raw_repeat.bin", compress(Span(rep)))
    _write_file(out_dir + "/mojo_framed_repeat.bin", compress_framed(Span(rep)))

    print("wrote vectors to", out_dir)
