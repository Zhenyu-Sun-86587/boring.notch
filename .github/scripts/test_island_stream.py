#!/usr/bin/env python3
"""Exercise the real streaming client against an ephemeral localhost server, never configured services."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert request["stream"] is True and request["model"] == "fixture"
        assert self.headers["Authorization"] == "Bearer fixture-api"
        assert self.headers["CF-Access-Client-Id"] == "fixture-client"
        assert self.headers["CF-Access-Client-Secret"] == "fixture-secret"
        assert self.headers["X-Gateway-Route"] == "fixture"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if self.path.endswith("slow"):
                for _ in range(60):
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    time.sleep(0.05)
            else:
                packet = 'data: {"choices":[{"delta":{"content":"你好🌙"}}]}\r\n\r\ndata: [DONE]\n\n'.encode()
                for byte in packet:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([
            "swift", "run", "--package-path", str(root / "Packages/IslandCore"), "IslandCoreChecks",
            "--sse", f"http://127.0.0.1:{server.server_port}/stream",
        ], check=True, timeout=90)
    finally:
        server.shutdown()
        server.server_close()
