"""Release-gate unit tests: the addon must honor CLAMD_HOST/CLAMD_PORT env
(compose/K8s deployments point clamd at a separate container), while the
default stays 127.0.0.1:3310 for the single-host appliance."""
import importlib.util
import os
import sys
import types
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _ensure_stub():
    import conftest  # noqa: F401  (installs the mitmproxy stub)

    importlib.import_module("conftest")


def _load_under(env=None):
    env = env or {}
    for k in ("CLAMD_HOST", "CLAMD_PORT"):
        os.environ.pop(k, None)
    os.environ.update(env)
    # fresh module load: python caches by name, so use a unique name per env
    spec = importlib.util.spec_from_file_location(
        f"addon_under_test_{abs(hash(tuple(sorted(env.items()))))}",
        REPO_ROOT / "nix" / "mitmproxy" / "opensase_addon.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_default_is_loopback_appliance():
    mod = _load_under({})
    assert mod.CLAMD_ADDR == ("127.0.0.1", 3310)


def test_env_override_matches_compose():
    mod = _load_under({"CLAMD_HOST": "clamav", "CLAMD_PORT": "3310"})
    assert mod.CLAMD_ADDR == ("clamav", 3310)


def test_env_override_custom_host_port():
    mod = _load_under({"CLAMD_HOST": "10.9.9.9", "CLAMD_PORT": "9999"})
    assert mod.CLAMD_ADDR == ("10.9.9.9", 9999)
