"""Verify Shizuku's reflective entry point in the actual packaged APK, including R8 builds."""

import struct
import sys
import zipfile

HELPER = "Lorg/localsend/localsend_app/clipboard/ClipboardUserService;"


def verify_dex(data):
    def u32(offset):
        return struct.unpack_from("<I", data, offset)[0]

    def uleb(offset):
        value = 0
        for shift in range(0, 35, 7):
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
        raise ValueError("Invalid DEX integer")

    def string(index):
        offset = u32(u32(60) + index * 4)
        _, offset = uleb(offset)
        return data[offset:data.index(b"\0", offset)].decode("utf-8")

    def type_name(index):
        return string(u32(u32(68) + index * 4))

    if not data.startswith(b"dex\n"):
        raise ValueError("Unsupported DEX format")
    for index in range(u32(96)):
        offset = u32(100) + index * 32
        if type_name(u32(offset)) != HELPER:
            continue
        if u32(offset + 4) & 0x400:
            raise ValueError("Shizuku helper is abstract")
        offset = u32(offset + 24)
        counts = []
        for _ in range(4):
            count, offset = uleb(offset)
            counts.append(count)
        for _ in range(counts[0] + counts[1]):
            _, offset = uleb(offset)
            _, offset = uleb(offset)
        method_index = 0
        for _ in range(counts[2]):
            delta, offset = uleb(offset)
            flags, offset = uleb(offset)
            code, offset = uleb(offset)
            method_index += delta
            method = u32(92) + method_index * 8
            if string(u32(method + 4)) != "<init>":
                continue
            proto = u32(76) + struct.unpack_from("<H", data, method + 2)[0] * 12
            parameters = u32(proto + 8)
            if (parameters == 0 or u32(parameters) == 0) and flags & 1 and code != 0:
                return True
        raise ValueError("Shizuku helper has no public no-argument constructor")
    return False


def verify_apk(path):
    with zipfile.ZipFile(path) as apk:
        dex_files = [name for name in apk.namelist() if name.startswith("classes") and name.endswith(".dex")]
        if not any(verify_dex(apk.read(name)) for name in dex_files):
            raise ValueError("Shizuku helper class was removed or renamed")
    print("Shizuku helper's public constructor is present in the APK")


if __name__ == "__main__":
    verify_apk(sys.argv[1])
