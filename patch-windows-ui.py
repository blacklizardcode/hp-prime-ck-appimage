#!/usr/bin/env python3
"""Patch Wine's x86_64 windows.ui.dll so IUISettings2::get_TextScaleFactor works.

Wine (11.0 .. 11.21 at least) implements it as a stub returning E_NOTIMPL. The HP Connectivity
Kit reads this value at startup through C++/WinRT, which turns the failure into an uncaught
exception, so the CK aborts (exit code 3) before showing any window.

This rewrites the start of that stub to:  *value = 1.0; return S_OK;

The function is located without any third-party modules: find the "uisettings2_get_TextScaleFactor"
debug string, then the .pdata function whose code loads that string's address via a RIP-relative
LEA (the FIXME() call). Exits non-zero if it can't be found unambiguously.

usage: patch-windows-ui.py path/to/windows.ui.dll
"""
import struct
import sys

PATCH = bytes.fromhex(
    "48b8000000000000f03f"  # mov rax, 0x3ff0000000000000  (1.0)
    "488902"                # mov [rdx], rax
    "31c0"                  # xor eax, eax                 (S_OK)
    "c3"                    # ret
)
NAME = b"uisettings2_get_TextScaleFactor\0"
E_NOTIMPL_MOV = b"\xb8\x01\x40\x00\x80"  # mov eax, 0x80004001


def main(path):
    data = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        sys.exit("not a PE file")
    machine, nsec = struct.unpack_from("<HH", data, pe + 4)
    if machine != 0x8664:
        sys.exit("not an x86_64 DLL")
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    # PE32+: data directories start at opt+112; entry 3 = exception (.pdata)
    pdata_rva, pdata_size = struct.unpack_from("<II", data, opt + 112 + 3 * 8)
    secs = []
    for i in range(nsec):
        s = opt + opt_size + i * 40
        vsize, va, rsize, roff = struct.unpack_from("<IIII", data, s + 8)
        secs.append((va, max(vsize, rsize), roff))

    def rva2off(rva):
        for va, size, roff in secs:
            if va <= rva < va + size:
                return rva - va + roff
        raise ValueError(hex(rva))

    def off2rva(off):
        for va, size, roff in secs:
            if roff <= off < roff + size:
                return off - roff + va
        raise ValueError(hex(off))

    soff = data.find(NAME)
    if soff < 0:
        sys.exit("TextScaleFactor stub not present (already implemented in this Wine?) - nothing to do")
    srva = off2rva(soff)

    hits = []
    for i in range(pdata_size // 12):
        begin, end, _ = struct.unpack_from("<III", data, rva2off(pdata_rva) + i * 12)
        off = rva2off(begin)
        body = bytes(data[off:off + (end - begin)])
        if body.startswith(PATCH):
            print(f"{path}: already patched")
            return
        # look for  REX.W(+R) 8D /r with ModRM mod=00 rm=101  ==  lea reg, [rip+disp32]
        for j in range(len(body) - 6):
            if body[j] in (0x48, 0x4C) and body[j + 1] == 0x8D and (body[j + 2] & 0xC7) == 0x05:
                disp = struct.unpack_from("<i", body, j + 3)[0]
                if begin + j + 7 + disp == srva:
                    hits.append((begin, off, body))
                    break

    if len(hits) != 1:
        sys.exit(f"expected exactly one function referencing the stub string, found {len(hits)}")
    begin, off, body = hits[0]
    if E_NOTIMPL_MOV not in body or len(body) < len(PATCH):
        sys.exit("function does not look like the expected E_NOTIMPL stub; refusing to patch")
    data[off:off + len(PATCH)] = PATCH
    open(path, "wb").write(data)
    print(f"{path}: patched get_TextScaleFactor at rva {begin:#x}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
