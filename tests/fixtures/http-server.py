#!/usr/bin/env python3
#
# Copyright 2026 The Buildish Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Loopback-only HTTP fixture for Wrapper bootstrap tests."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

MAXIMUM_JAR_BYTES = 10 * 1024 * 1024
OVERSIZE_BYTES = MAXIMUM_JAR_BYTES + 64 * 1024


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--stall-seconds", required=True, type=float)
    arguments = parser.parse_args()
    if arguments.stall_seconds <= 0:
        parser.error("--stall-seconds must be positive")
    if not arguments.payload.is_file():
        parser.error("--payload must name a regular file")
    return arguments


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, payload: bytes, log_path: Path, stall_seconds: float) -> None:
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.payload = payload
        self.log_path = log_path
        self.stall_seconds = stall_seconds
        self.log_lock = threading.Lock()
        self.barrier_condition = threading.Condition()
        self.barrier_requests = 0

    def record(self, handler: BaseHTTPRequestHandler, route: str) -> None:
        record = {
            "method": handler.command,
            "path": handler.path,
            "route": route,
        }
        with self.log_lock:
            with self.log_path.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
                stream.write("\n")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def fixture_server(self) -> FixtureServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, _format: str, *args: object) -> None:
        del args

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        route = urlsplit(self.path).path
        self.fixture_server.record(self, route)
        if route == "/jar":
            self._send_bytes(200, self.fixture_server.payload, len(self.fixture_server.payload))
            return
        if route == "/jar/barrier":
            with self.fixture_server.barrier_condition:
                self.fixture_server.barrier_requests += 1
                if self.fixture_server.barrier_requests < 2:
                    self.fixture_server.barrier_condition.wait_for(
                        lambda: self.fixture_server.barrier_requests >= 2,
                        timeout=10,
                    )
                else:
                    self.fixture_server.barrier_condition.notify_all()
            self._send_bytes(200, self.fixture_server.payload, len(self.fixture_server.payload))
            return
        if route.startswith("/status/"):
            try:
                status = int(route.removeprefix("/status/"))
            except ValueError:
                status = 404
            if status < 400 or status > 599:
                status = 404
            self._send_bytes(status, b"", 0)
            return
        if route == "/stall":
            time.sleep(self.fixture_server.stall_seconds)
            self._send_bytes(504, b"", 0)
            return
        if route == "/oversize/accurate":
            self._send_oversize(OVERSIZE_BYTES)
            return
        if route == "/oversize/missing":
            self.send_response(200)
            self.send_header("Content-Type", "application/java-archive")
            self.send_header("Connection", "close")
            self.end_headers()
            self._write_repeated(OVERSIZE_BYTES)
            return
        if route == "/oversize/misleading":
            self.send_response(200)
            self.send_header("Content-Type", "application/java-archive")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Content-Length", "1024")
            self.send_header("Connection", "close")
            self.end_headers()
            self._write_chunked_repeated(OVERSIZE_BYTES)
            return
        self._send_bytes(404, b"", 0)

    def _send_oversize(self, size: int) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/java-archive")
        self.send_header("Content-Length", str(size))
        self.send_header("Connection", "close")
        self.end_headers()
        self._write_repeated(size)

    def _send_bytes(self, status: int, body: bytes, length: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(length))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _write_repeated(self, size: int) -> None:
        chunk = b"x" * 64 * 1024
        remaining = size
        try:
            while remaining:
                part = chunk[: min(len(chunk), remaining)]
                self.wfile.write(part)
                remaining -= len(part)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _write_chunked_repeated(self, size: int) -> None:
        chunk = b"x" * 64 * 1024
        remaining = size
        try:
            while remaining:
                part = chunk[: min(len(chunk), remaining)]
                self.wfile.write(f"{len(part):x}\r\n".encode("ascii"))
                self.wfile.write(part)
                self.wfile.write(b"\r\n")
                remaining -= len(part)
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


def main() -> int:
    arguments = parse_arguments()
    arguments.log.parent.mkdir(parents=True, exist_ok=True)
    arguments.port_file.parent.mkdir(parents=True, exist_ok=True)
    server = FixtureServer(
        arguments.payload.read_bytes(), arguments.log, arguments.stall_seconds
    )
    temporary_port = arguments.port_file.with_name(
        f".{arguments.port_file.name}.{os.getpid()}.tmp"
    )
    temporary_port.write_text(f"{server.server_port}\n", encoding="ascii", newline="\n")
    os.replace(temporary_port, arguments.port_file)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
