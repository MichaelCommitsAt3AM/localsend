import os
import socket
import struct
import threading
import unittest
from unittest.mock import patch

import probe


def global_event(name, interface, version=1):
    text = interface.encode("ascii") + b"\0"
    body = struct.pack("=II", name, len(text)) + text
    body += b"\0" * (-len(text) % 4) + struct.pack("=I", version)
    return probe.HEADER.pack(2, ((8 + len(body)) << 16)) + body


class RegistryProbeTests(unittest.TestCase):
    def run_server(self, frames, fragment=False):
        client, server = socket.socketpair()
        received = []

        def respond():
            with server:
                received.append(probe.receive_exact(server, 24, __import__("time").monotonic() + 2))
                data = b"".join(frames)
                if fragment:
                    for byte in data:
                        server.sendall(bytes([byte]))
                else:
                    server.sendall(data)

        thread = threading.Thread(target=respond)
        thread.start()
        try:
            with client:
                result = probe.collect_registry(client)
        finally:
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(received, [probe.request(1, 1, 2) + probe.request(1, 0, 3)])
        return result

    def done(self):
        return probe.HEADER.pack(3, (12 << 16)) + probe.UINT.pack(1)

    def test_fragmented_stream_and_capability_is_not_permission(self):
        result = self.run_server([global_event(1, "wl_seat"),
                                  global_event(2, "ext_data_control_manager_v1"), self.done()], True)
        self.assertEqual(result["status"], "advertised")
        self.assertEqual(result["seatCount"], 1)
        self.assertFalse(result["monitoringValidated"])
        self.assertFalse(result["writingValidated"])
        self.assertFalse(result["clipboardRead"])

    def test_no_data_control(self):
        result = self.run_server([global_event(1, "wl_data_device_manager", 3), self.done()])
        self.assertEqual(result["status"], "not-advertised")

    def test_removed_global_is_not_advertised(self):
        removed = probe.HEADER.pack(2, (12 << 16) | 1) + probe.UINT.pack(2)
        result = self.run_server([global_event(2, "zwlr_data_control_manager_v1", 2), removed, self.done()])
        self.assertEqual(result["status"], "not-advertised")

    def test_malformed_frames_fail_closed(self):
        for size in (0, 4, 9):
            with self.subTest(size=size), self.assertRaises(probe.ProtocolError):
                self.run_server([probe.HEADER.pack(2, size << 16)])

    def test_incomplete_roundtrip_fails(self):
        with self.assertRaises(probe.ProtocolError):
            self.run_server([global_event(1, "wl_seat")])

    def test_global_parser_rejects_truncation_and_bad_terminator(self):
        body = global_event(1, "wl_seat")[8:]
        with self.assertRaises(probe.ProtocolError):
            probe.decode_global(body[:-1])
        damaged = bytearray(body)
        damaged[15] = 1
        with self.assertRaises(probe.ProtocolError):
            probe.decode_global(damaged)

    def test_relative_display_cannot_escape_runtime(self):
        with patch.dict(os.environ, {"WAYLAND_DISPLAY": "../socket", "XDG_RUNTIME_DIR": "/run/user/1000"}):
            with self.assertRaises(ValueError):
                probe.socket_path()


if __name__ == "__main__":
    unittest.main()
