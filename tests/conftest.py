"""Test bootstrap: make the addon importable and stub mitmproxy if absent.

The addon imports `from mitmproxy import ctx, http`. In the shipped image that
comes from the nixpkgs mitmproxy package; in CI/local unit runs we provide a
faithful stub so the policy logic is testable without the full dependency.
If a real mitmproxy is installed it is used instead of the stub.
"""
import importlib.util
import sys
import types
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ADDON_PATH = REPO_ROOT / "nix" / "mitmproxy" / "opensase_addon.py"


def _install_stub():
    if importlib.util.find_spec("mitmproxy"):
        return

    mpm = types.ModuleType("mitmproxy")

    # ctx: the addon uses ctx.log.warn and ctx.options.<name>
    class _Options:
        pass

    class _Log:
        @staticmethod
        def warn(msg):
            print(f"[ctx.log.warn] {msg}")

        @staticmethod
        def info(msg):
            print(f"[ctx.log.info] {msg}")

    ctx_mod = types.ModuleType("mitmproxy.ctx")
    ctx_mod.log = _Log()
    ctx_mod.options = _Options()

    http_mod = types.ModuleType("mitmproxy.http")

    class HTTPFlow:
        pass

    class Response:
        @staticmethod
        def make(status_code, content=b"", headers=None):
            r = Response()
            r.status_code = status_code
            r.content = content
            r.headers = dict(headers or {})
            return r

    http_mod.HTTPFlow = HTTPFlow
    http_mod.Response = Response

    mpm.ctx = ctx_mod
    mpm.http = http_mod
    sys.modules["mitmproxy"] = mpm
    sys.modules["mitmproxy.ctx"] = ctx_mod
    sys.modules["mitmproxy.http"] = http_mod


_install_stub()


def load_addon_class():
    spec = importlib.util.spec_from_file_location("opensase_addon", ADDON_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.OpensaseAddon, mod
