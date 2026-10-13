#!/usr/bin/env python3
"""Read-only Wayland registry probe. Never binds clipboard globals or reads text."""

import argparse
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time

HEADER = struct.Struct("=II")
UINT = struct.Struct("=I")
MAX_FRAME = 65532
DATA_CONTROL = {"ext_data_control_manager_v1", "zwlr_data_control_manager_v1"}


class ProtocolError(Exception):
    pass


def request(object_id, opcode, *values):
    body = b"".join(UINT.pack(value) for value in values)
    return HEADER.pack(object_id, ((8 + len(body)) << 16) | opcode) + body


def receive_exact(connection, length, deadline):
    result = bytearray()
    while len(result) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("registry roundtrip timed out")
        connection.settimeout(remaining)
        part = connection.recv(length - len(result))
        if not part:
            raise ProtocolError("compositor closed an incomplete roundtrip")
        result.extend(part)
    return bytes(result)


def receive_event(connection, deadline):
    object_id, word = HEADER.unpack(receive_exact(connection, 8, deadline))
    size, opcode = word >> 16, word & 0xFFFF
    if size < 8 or size > MAX_FRAME or size % 4:
        raise ProtocolError("invalid Wayland frame size")
    return object_id, opcode, receive_exact(connection, size - 8, deadline)


def decode_global(body):
    if len(body) < 16:
        raise ProtocolError("short registry global")
    name, length = struct.unpack_from("=II", body)
    padded = (length + 3) & ~3
    if length < 2 or length > 256 or len(body) != 12 + padded:
        raise ProtocolError("invalid interface string size")
    encoded = body[8:8 + length]
    if encoded[-1] != 0 or b"\0" in encoded[:-1]:
        raise ProtocolError("invalid interface string")
    try:
        interface = encoded[:-1].decode("ascii")
    except UnicodeDecodeError as exc:
        raise ProtocolError("non-ASCII interface name") from exc
    version = UINT.unpack_from(body, 8 + padded)[0]
    if version == 0:
        raise ProtocolError("invalid global version")
    return name, interface, version


def collect_registry(connection, timeout=3.0):
    deadline = time.monotonic() + timeout
    connection.settimeout(timeout)
    # wl_display.get_registry(new_id=2), then wl_display.sync(new_id=3).
    connection.sendall(request(1, 1, 2) + request(1, 0, 3))
    globals_by_id = {}
    for _ in range(4096):
        object_id, opcode, body = receive_event(connection, deadline)
        if object_id == 2 and opcode == 0:
            name, interface, version = decode_global(body)
            if name in globals_by_id:
                raise ProtocolError("duplicate live global name")
            globals_by_id[name] = (interface, version)
        elif object_id == 2 and opcode == 1:
            if len(body) != 4:
                raise ProtocolError("invalid global removal")
            globals_by_id.pop(UINT.unpack(body)[0], None)
        elif object_id == 3 and opcode == 0:
            if len(body) != 4:
                raise ProtocolError("invalid sync callback")
            return summarize(globals_by_id)
        elif object_id == 1 and opcode == 0:
            # Do not print arbitrary server-provided diagnostic strings.
            raise ProtocolError("compositor reported a protocol error")
        elif object_id == 1 and opcode == 1 and len(body) == 4:
            continue  # wl_display.delete_id
        else:
            raise ProtocolError("unexpected registry-roundtrip event")
    raise ProtocolError("registry event limit exceeded")


def summarize(globals_by_id):
    protocols = sorted(
        ({"interface": interface, "version": version}
         for interface, version in globals_by_id.values() if interface in DATA_CONTROL),
        key=lambda item: (item["interface"], item["version"]),
    )
    return {
        "schemaVersion": 1,
        "probe": "wayland-registry",
        "status": "advertised" if protocols else "not-advertised",
        "dataControlProtocols": protocols,
        "seatCount": sum(interface == "wl_seat" for interface, _ in globals_by_id.values()),
        "monitoringValidated": False,
        "writingValidated": False,
        "clipboardRead": False,
    }


def socket_path():
    display = os.environ.get("WAYLAND_DISPLAY")
    if not display:
        raise ValueError("WAYLAND_DISPLAY is not set; run inside the target desktop session")
    if Path(display).is_absolute():
        return display
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime or not Path(runtime).is_absolute():
        raise ValueError("an absolute XDG_RUNTIME_DIR is required")
    if Path(display).name != display:
        raise ValueError("relative WAYLAND_DISPLAY must be a socket name")
    return str(Path(runtime) / display)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()
    if not 0 < args.timeout <= 10:
        parser.error("timeout must be greater than zero and at most 10 seconds")
    try:
        path = socket_path()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(args.timeout)
            connection.connect(path)
            result = collect_registry(connection, args.timeout)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, ProtocolError) as exc:
        print(json.dumps({"schemaVersion": 1, "status": "probe-failed",
                          "errorCategory": type(exc).__name__,
                          "monitoringValidated": False, "writingValidated": False,
                          "clipboardRead": False}, sort_keys=True))
        return 2


if __name__ == "__main__":
    sys.exit(main())
