#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise the actual packaged MCP stdio server against an isolated native app.

Run against a QA bundle. Does not activate a paste queue or read the user's history.
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time
import uuid

def ipc(directory, method, arguments=None):
    data = json.dumps({"method": method, "arguments": arguments or {}}).encode()
    def read(sock, n):
        result = b""
        while len(result) < n:
            chunk = sock.recv(n - len(result))
            if not chunk:
                raise RuntimeError("Socket closed")
            result += chunk
        return result
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(8)
        sock.connect(str(directory / "runtime/core.sock"))
        sock.sendall(struct.pack(">I", len(data)) + data)
        length, = struct.unpack(">I", read(sock, 4))
        result = json.loads(read(sock, length))
        if result.get("error"):
            raise RuntimeError(result)
        return result["result"]

class MCP:
    def __init__(self, app, directory):
        env = dict(os.environ, CLIPRILL_DATA_DIR=str(directory), CLIPRILL_NO_CAPTURE="1", CLIPRILL_NO_AUTOSTART="1")
        self.process = subprocess.Popen([str(app / "Contents/MacOS/cliprill-mcp")], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.next_id = 0
        self.buffer = b""
    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n"); self.process.stdin.flush()
    def request(self, method, params=None):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    raise TimeoutError(method)
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(self.process.stderr.read().decode())
                self.buffer += chunk
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == request_id:
                    if "error" in message:
                        raise RuntimeError(message)
                    return message["result"]
        raise TimeoutError(method)
    def call(self, name, arguments, error=False):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert bool(result.get("isError")) == error, result
        return json.loads(result["content"][0]["text"])
    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate(); self.process.wait(timeout=5)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--keep-app", action="store_true")
    opts = parser.parse_args()
    app = opts.app.resolve()
    directory = (opts.data_dir or Path("/tmp") / ("cliprill-smoke-" + uuid.uuid4().hex[:10])).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    logfile = directory / "app.log"
    log = logfile.open("wb")
    process = subprocess.Popen([str(app / "Contents/MacOS/Cliprill"), "--background", "--no-capture", "--data-dir", str(directory), "-AppleLanguages", "(zh-Hans)"], stdout=log, stderr=log)
    client = None
    try:
        for _ in range(80):
            if (directory / "runtime/core.sock").exists():
                break
            if process.poll() is not None:
                raise RuntimeError(logfile.read_text())
            time.sleep(0.1)
        status = ipc(directory, "app_status")
        assert not status["panel_visible"] and not status["capture_enabled"], status
        client = MCP(app, directory)
        initialization = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Cliprill smoke test", "version": "1"}})
        assert initialization["serverInfo"]["name"] == "Cliprill"
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        tools = client.request("tools/list")["tools"]
        assert len(tools) == 11, tools
        values = ["A", "A", "B\n第二行"]
        key = uuid.uuid4().hex
        args = {"title": "首版验收 · 按顺序粘贴", "items": [{"text": v, "label": label} for v, label in zip(values, ["第一项", "重复项也保留", "多行文本保持一项"])], "idempotency_key": key}
        created = client.call("queue_create", args)
        assert created == client.call("queue_create", args)
        qid = created["queue_id"]
        conflict = client.call("queue_create", dict(args, title="changed"), error=True)
        assert conflict["code"] == "idempotency_conflict"
        metadata = client.call("queue_get", {"queue_id": qid})
        assert all("text" not in item for item in metadata["items"])
        full = client.call("queue_get", {"queue_id": qid, "include_content": True})
        assert [i["text"] for i in full["items"]] == values
        assert len(set(full["item_ids"])) == 3
        appended = client.call("queue_append", {"queue_id": qid, "items": [{"text": "https://example.com", "label": "链接"}], "idempotency_key": key + "-append"})
        order = list(reversed(appended["item_ids"]))
        invalid = client.call("queue_reorder", {"queue_id": qid, "item_ids": order, "expected_revision": 0, "idempotency_key": key + "-invalid"}, error=True)
        assert invalid["code"] == "revision_conflict"
        changed = client.call("queue_reorder", {"queue_id": qid, "item_ids": order, "expected_revision": appended["revision"], "idempotency_key": key + "-reorder"})
        assert changed["item_ids"] == order
        restored = client.call("queue_reorder", {"queue_id": qid, "item_ids": appended["item_ids"], "expected_revision": changed["revision"], "idempotency_key": key + "-restore"})
        if not status["accessibility"]:
            denied = client.call("queue_activate", {"queue_id": qid, "idempotency_key": key + "-activate"}, error=True)
            assert denied["code"] == "accessibility_required", denied
            assert client.call("queue_get", {"queue_id": qid})["state"] == "paused"
        assert client.call("history_search", {"limit": 10})["items"] == []
        assert not ipc(directory, "app_status")["panel_visible"]
        client.close(); client = None
        process.terminate(); process.wait(timeout=10)
        process = subprocess.Popen([str(app / "Contents/MacOS/Cliprill"), "--background", "--no-capture", "--data-dir", str(directory), "-AppleLanguages", "(zh-Hans)"], stdout=log, stderr=log)
        for _ in range(80):
            try:
                queues = ipc(directory, "queue_list")["queues"]
                break
            except (OSError, RuntimeError):
                time.sleep(0.1)
        else:
            raise RuntimeError("App did not restart")
        assert queues[0]["queue_id"] == qid and queues[0]["remaining"] == 4 and queues[0]["state"] == "paused"
        if opts.keep_app:
            ipc(directory, "app_show")
        print(json.dumps({"passed": True, "tools": len(tools), "queue_id": qid, "remaining": restored["remaining"], "accessibility": status["accessibility"], "app_pid": process.pid, "data_directory": str(directory)}, ensure_ascii=False))
    finally:
        if client:
            client.close()
        if not opts.keep_app and process.poll() is None:
            process.terminate(); process.wait(timeout=10)
        log.close()

if __name__ == "__main__":
    main()
