"""Unit tests for the OpenSASE mitmproxy addon.

Covers the policy engine invariants the project documents (verdict order
passlist > bumplist > default bump; suffix matching; decision-log lines) and
the clamd INSTREAM framing + reply parsing. See #15 for the end-to-end
verdict suite these unit tests back.
"""
import json
import socket
import types

import pytest

from conftest import load_addon_class

OpensaseAddon, addon_mod = load_addon_class()


# ---------------------------------------------------------------- policy ---
class TestHostMatches:
    def test_exact_match(self):
        assert OpensaseAddon.host_matches("example.com", {"example.com"})

    def test_subdomain_match(self):
        assert OpensaseAddon.host_matches("a.example.com", {"example.com"})

    def test_no_partial_match(self):
        assert not OpensaseAddon.host_matches("notexample.com", {"example.com"})

    def test_dot_prefix_entry_is_suffix_match(self):
        assert OpensaseAddon.host_matches("a.example.com", {".example.com"})

    def test_dot_prefix_requires_dot(self):
        assert not OpensaseAddon.host_matches("example.com", {".example.com"})

    def test_case_insensitive(self):
        assert OpensaseAddon.host_matches("EXAMPLE.COM", {"example.com"})

    def test_empty_host(self):
        assert not OpensaseAddon.host_matches("", {"example.com"})
        assert not OpensaseAddon.host_matches(None, {"example.com"})


class TestPolicyFiles:
    def test_read_skips_comments_and_blanks(self, tmp_path):
        f = tmp_path / "list.txt"
        f.write_text("# comment\n\nexample.com\n  nixos.org  \n")
        addon = OpensaseAddon()
        assert addon._read_domain_file(str(f)) == {"example.com", "nixos.org"}

    def test_read_missing_file_warns_and_yields_empty(self, tmp_path, capsys):
        addon = OpensaseAddon()
        assert addon._read_domain_file(str(tmp_path / "nope.txt")) == set()
        assert "policy file missing" in capsys.readouterr().out

    def test_repo_policy_lists_parse(self):
        """The shipped lists must parse under the addon's own reader."""
        from conftest import REPO_ROOT

        addon = OpensaseAddon()
        passl = addon._read_domain_file(str(REPO_ROOT / "nix/policy/pass.txt"))
        bumpl = addon._read_domain_file(str(REPO_ROOT / "nix/policy/bump.txt"))
        assert "example.com" in passl and "nixos.org" in passl
        assert "testsafebrowsing.appspot.com" in bumpl


class TestVerdictOrder:
    """passlist > bumplist > default bump, evidenced by decision-log lines."""

    def _flow(self, host):
        req = types.SimpleNamespace(
            timestamp_start=1234.5,
            pretty_host=host,
            pretty_url=f"https://{host}/x",
        )
        cc = types.SimpleNamespace(peername=["10.0.0.9"])
        return types.SimpleNamespace(request=req, client_conn=cc)

    def _addon_with_log(self, tmp_path):
        addon = OpensaseAddon()
        addon.passlist = {"example.com"}
        addon.bumplist = {"testsafebrowsing.appspot.com"}
        addon.log_path = str(tmp_path / "decisions.jsonl")
        return addon, tmp_path / "decisions.jsonl"

    def test_passlisted_host_splices(self, tmp_path):
        addon, log = self._addon_with_log(tmp_path)
        addon.request(self._flow("example.com"))
        rec = json.loads(log.read_text().splitlines()[-1])
        assert rec["verdict"] == "splice"

    def test_bumplist_host_bumps(self, tmp_path):
        addon, log = self._addon_with_log(tmp_path)
        addon.request(self._flow("testsafebrowsing.appspot.com"))
        rec = json.loads(log.read_text().splitlines()[-1])
        assert rec["verdict"] == "bump"

    def test_unlisted_host_defaults_to_bump(self, tmp_path):
        addon, log = self._addon_with_log(tmp_path)
        addon.request(self._flow("something-else.net"))
        rec = json.loads(log.read_text().splitlines()[-1])
        assert rec["verdict"] == "bump"

    def test_passlist_wins_on_both_lists(self, tmp_path):
        addon, log = self._addon_with_log(tmp_path)
        addon.passlist.add("testsafebrowsing.appspot.com")
        addon.request(self._flow("testsafebrowsing.appspot.com"))
        rec = json.loads(log.read_text().splitlines()[-1])
        assert rec["verdict"] == "splice"

    def test_log_line_shape(self, tmp_path):
        addon, log = self._addon_with_log(tmp_path)
        addon.request(self._flow("example.com"))
        rec = json.loads(log.read_text().splitlines()[-1])
        assert rec["ts"] == 1234.5
        assert rec["host"] == "example.com"
        assert rec["client"] == "10.0.0.9"
        assert rec["url"] == "https://example.com/x"

    def test_no_log_path_is_silent_noop(self, tmp_path):
        addon = OpensaseAddon()
        addon.passlist = {"example.com"}
        addon.log_path = None
        addon.request(self._flow("example.com"))  # must not raise


# ----------------------------------------------------------------- clamd ---
class FakeSocket:
    """Records INSTREAM bytes, replies with a scripted clamd response."""

    def __init__(self, reply, chunk_size=4096):
        self.received = b""
        self.reply = reply
        self.chunk_size = chunk_size

    def sendall(self, data):
        self.received += data

    def recv(self, _n):
        return self.reply.encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class TestClamdScan:
    def test_instream_framing(self, monkeypatch):
        fake = FakeSocket("stream: OK\x00")
        monkeypatch.setattr(socket, "create_connection", lambda *a, **k: fake)
        verdict = OpensaseAddon.clamd_scan(b"X" * 20000)  # forces multi-chunk
        assert verdict == "CLEAN"
        # greeting, then 4-byte-length-prefixed 8190-byte chunks, then zero-terminator
        assert fake.received.startswith(b"zINSTREAM\0")
        rest = fake.received[len(b"zINSTREAM\0"):]
        sizes = []
        while rest:
            n = int.from_bytes(rest[:4], "big")
            sizes.append(n)
            rest = rest[4 + n:]
        assert sizes[-1] == 0                       # clamd terminator
        assert sizes[:-1] == [8190, 8190, 20000 % 8190]

    @pytest.mark.parametrize("reply,expected", [
        ("stream: OK\x00", "CLEAN"),
        ("stream: Eicar-Test-Signature FOUND\x00", "INFECTED"),
        ("\x00", "NOREPLY"),
        ("stream: size limit exceeded. ERROR\x00", "ERROR: size limit exceeded. ERROR"),
    ])
    def test_reply_parsing(self, monkeypatch, reply, expected):
        fake = FakeSocket(reply)
        monkeypatch.setattr(socket, "create_connection", lambda *a, **k: fake)
        assert OpensaseAddon.clamd_scan(b"data") == expected

    def test_connection_error_reports_error(self, monkeypatch):
        def boom(*a, **k):
            raise OSError("connection refused")
        monkeypatch.setattr(socket, "create_connection", boom)
        v = OpensaseAddon.clamd_scan(b"data")
        assert v.startswith("ERROR:")
        assert "connection refused" in v


# -------------------------------------------------------------- response ---
class TestResponseHook:
    def _flow(self, ctype, content=b"MZbinary"):
        req = types.SimpleNamespace(
            pretty_host="testsafebrowsing.appspot.com",
            pretty_url="https://testsafebrowsing.appspot.com/payload",
        )
        resp = types.SimpleNamespace(
            timestamp_end=99.0,
            headers={"content-type": ctype},
            raw_content=content,
        )
        return types.SimpleNamespace(request=req, response=resp)

    def test_scannable_type_gets_verdict_line(self, tmp_path, monkeypatch):
        addon = OpensaseAddon()
        addon.log_path = str(tmp_path / "d.jsonl")
        monkeypatch.setattr(addon_mod.OpensaseAddon, "clamd_scan",
                            staticmethod(lambda content: "CLEAN"))
        addon.response(self._flow("application/pdf"))
        rec = json.loads((tmp_path / "d.jsonl").read_text().splitlines()[-1])
        assert rec["verdict"] == "CLEAN" and rec["content_type"] == "application/pdf"

    def test_unscannable_type_skipped(self, tmp_path, monkeypatch):
        addon = OpensaseAddon()
        addon.log_path = str(tmp_path / "d.jsonl")
        scanned = []
        monkeypatch.setattr(addon_mod.OpensaseAddon, "clamd_scan",
                            staticmethod(lambda c: scanned.append(c) or "CLEAN"))
        addon.response(self._flow("text/html", b"<h1>hi</h1>"))
        assert scanned == []
        assert not (tmp_path / "d.jsonl").exists()

    def test_infected_replaced_with_403(self, tmp_path, monkeypatch):
        addon = OpensaseAddon()
        addon.log_path = str(tmp_path / "d.jsonl")
        monkeypatch.setattr(addon_mod.OpensaseAddon, "clamd_scan",
                            staticmethod(lambda c: "INFECTED"))
        flow = self._flow("application/zip", b"PK\x03\x04")
        addon.response(flow)
        assert flow.response.status_code == 403
        assert b"blocked by ClamAV" in flow.response.content
        rec = json.loads((tmp_path / "d.jsonl").read_text().splitlines()[-1])
        assert rec["verdict"] == "INFECTED"

    def test_empty_content_type_skipped(self, tmp_path):
        addon = OpensaseAddon()
        addon.log_path = str(tmp_path / "d.jsonl")
        flow = self._flow("")
        flow.response.headers = {}
        addon.response(flow)
        assert not (tmp_path / "d.jsonl").exists()


# ------------------------------------------------- scanner-failure mode ---
class TestScannerFailClosed:
    """Scanner unavailable/broken must not silently forward the payload
    (fail closed per README posture; the fail-open regression is #15's
    first enforced invariant)."""

    def _flow(self, ctype="application/pdf", content=b"PAYLOAD"):
        req = types.SimpleNamespace(
            pretty_host="testsafebrowsing.appspot.com",
            pretty_url="https://testsafebrowsing.appspot.com/payload",
        )
        resp = types.SimpleNamespace(
            timestamp_end=1.0,
            headers={"content-type": ctype},
            raw_content=content,
        )
        return types.SimpleNamespace(request=req, response=resp)

    @pytest.mark.parametrize("verdict", ["NOREPLY", "ERROR: timed out"])
    def test_scan_failure_replaces_with_503(self, tmp_path, monkeypatch, verdict):
        addon = OpensaseAddon()
        addon.log_path = str(tmp_path / "d.jsonl")
        monkeypatch.setattr(addon_mod.OpensaseAddon, "clamd_scan",
                            staticmethod(lambda c: verdict))
        flow = self._flow()
        addon.response(flow)
        assert flow.response.status_code == 503, "unscannable payload must be blocked, not forwarded"
        rec = json.loads((tmp_path / "d.jsonl").read_text().splitlines()[-1])
        assert rec["verdict"] == verdict
