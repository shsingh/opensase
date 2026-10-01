"""
OpenSASE mitm proxy addon -- decrypt/re-encrypt driven by URL category,
with ClamAV (clamd INSTREAM) content scanning and JSONL decision logging.

Registered options (set via `--set opensase_X=...` in the systemd unit):
  opensase_passlist  path of domains to splice (no decrypt)
  opensase_bumplist  path of domains to always decrypt
  opensase_log       JSONL decision log path

Verdict order: passlist > bumplist > default (bump).
Scannable response bodies are streamed to clamd; INFECTED responses are
replaced with a 403.
"""
import ipaddress  # noqa: F401  (kept for future client-geo policy)
import json
import os
import socket
from pathlib import Path

from mitmproxy import ctx, http

SCAN_TYPES = {
    "application/x-dosexec",
    "application/octet-stream",
    "application/x-executable",
    "application/zip",
    "application/pdf",
    "application/x-msdownload",
}

# clamd endpoint: env overrides for container deployments where clamd is a
# separate container (compose/k8s); defaults match the single-host appliance.
CLAMD_ADDR = (
    os.environ.get("CLAMD_HOST", "127.0.0.1"),
    int(os.environ.get("CLAMD_PORT", "3310")),
)


class OpensaseAddon:
    def __init__(self):
        self.passlist: set[str] = set()
        self.bumplist: set[str] = set()
        self.log_path: str | None = None

    # ---- option registration -------------------------------------------
    def load(self, loader):
        loader.add_option(
            name="opensase_passlist", typespec=str, default="",
            help="Path to splice (no-bump) domain list",
        )
        loader.add_option(
            name="opensase_bumplist", typespec=str, default="",
            help="Path to always-bump domain list",
        )
        loader.add_option(
            name="opensase_log", typespec=str, default="",
            help="JSONL decision log path",
        )

    # ---- config reloads -------------------------------------------------
    @staticmethod
    def _read_domain_file(path: str) -> set[str]:
        p = Path(path)
        if not p.exists():
            ctx.log.warn(f"opensase: policy file missing: {path}")
            return set()
        return {
            ln.strip().lower()
            for ln in p.read_text().splitlines()
            if ln.strip() and not ln.startswith("#")
        }

    def configure(self, updated):
        if "opensase_passlist" in updated:
            self.passlist = self._read_domain_file(ctx.options.opensase_passlist)
        if "opensase_bumplist" in updated:
            self.bumplist = self._read_domain_file(ctx.options.opensase_bumplist)
        if "opensase_log" in updated:
            self.log_path = ctx.options.opensase_log or None

    # ---- policy matching -------------------------------------------------
    @staticmethod
    def host_matches(host: str, entries: set[str]) -> bool:
        h = (host or "").lower()
        for e in entries:
            if e.startswith("."):
                if h.endswith(e):
                    return True
            elif h == e or h.endswith("." + e):
                return True
        return False

    def log_decision(self, rec: dict) -> None:
        if not self.log_path:
            return
        try:
            p = Path(self.log_path)
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open("a") as fh:
                fh.write(json.dumps(rec) + "\n")
        except OSError as e:
            ctx.log.warn(f"opensase: cannot write decision log: {e}")

    # ---- flow hooks -------------------------------------------------------
    def request(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host
        entry = {
            "ts": flow.request.timestamp_start,
            "host": host,
            "url": flow.request.pretty_url,
            "client": flow.client_conn.peername[0] if flow.client_conn.peername else None,
        }
        if self.host_matches(host, self.passlist):
            entry["verdict"] = "splice"
            self.log_decision(entry)
        else:
            # Not on the passlist -> TLS gets bumped (default verdict).
            entry["verdict"] = "bump"
            self.log_decision(entry)

    def response(self, flow: http.HTTPFlow):
        ctype = (flow.response.headers.get("content-type") or "").split(";")[0]
        if ctype not in SCAN_TYPES:
            return
        verdict = self.clamd_scan(flow.response.raw_content or b"")
        self.log_decision({
            "ts": flow.response.timestamp_end,
            "host": flow.request.pretty_host,
            "url": flow.request.pretty_url,
            "content_type": ctype,
            "bytes": len(flow.response.raw_content or b""),
            "verdict": verdict,
        })
        if verdict == "INFECTED":
            flow.response = http.Response.make(
                403,
                b"OpenSASE: blocked by ClamAV verdict\n",
                {"content-type": "text/plain"},
            )
        elif not verdict.startswith("CLEAN"):
            # Scanner unavailable or erroring: fail closed — never forward a
            # payload whose verdict is unknown (scanner-down = policy bypass).
            flow.response = http.Response.make(
                503,
                b"OpenSASE: scanner unavailable - payload not forwarded\n",
                {"content-type": "text/plain", "retry-after": "30"},
            )

    # ---- clamd INSTREAM -----------------------------------------------------
    @staticmethod
    def clamd_scan(content: bytes) -> str:
        try:
            with socket.create_connection(CLAMD_ADDR, timeout=10) as s:
                s.sendall(b"zINSTREAM\0")
                view = memoryview(content)
                while view:
                    chunk, view = view[:8190], view[8190:]
                    s.sendall(len(chunk).to_bytes(4, "big") + chunk)
                s.sendall((0).to_bytes(4, "big"))
                reply = s.recv(4096).decode(errors="replace").strip("\x00")
            if not reply:
                return "NOREPLY"
            token = reply.split(" ", 1)[-1]
            if token == "OK":
                return "CLEAN"
            return "INFECTED" if "FOUND" in token else "ERROR: " + token
        except OSError as e:
            return f"ERROR: {e}"


addons = [OpensaseAddon()]
