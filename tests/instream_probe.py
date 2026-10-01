#!/usr/bin/env python3
"""INSTREAM probe: send bytes to clamd, print verdicts, exit non-zero on fail.

Smoke tool backing the release gate in release-images.yml and the future
end-to-end verdict suite (#15). Uses the same wire protocol as the mitmproxy
addon (zINSTREAM, 4-byte big-endian chunk framing, zero terminator).
"""
import argparse
import socket


def clamd_scan(content: bytes, host: str, port: int) -> str:
    with socket.create_connection((host, port), timeout=30) as s:
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


EICAR = (
    "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
).encode()

BENIGN = b"OpenSASE clean probe -- no signatures in these bytes."


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3310)
    ap.add_argument("--wait", type=int, default=0,
                    help="seconds to wait for clamd to become answerable "
                         "(polls a clean probe until it returns CLEAN)")
    args = ap.parse_args()

    if args.wait:
        import time
        deadline = time.monotonic() + args.wait
        while True:
            try:
                if clamd_scan(BENIGN, args.host, args.port) == "CLEAN":
                    break
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise SystemExit(f"TIMEOUT: clamd not answerable after {args.wait}s")
            time.sleep(5)
        print(f"clamd answerable (waited for CLEAN)")

    clean = clamd_scan(BENIGN, args.host, args.port)
    infected = clamd_scan(EICAR, args.host, args.port)
    print(f"clean probe:  {clean}")
    print(f"eicar probe:  {infected}")
    ok = clean == "CLEAN" and infected == "INFECTED"
    print("SMOKE:", "PASS" if ok else "FAIL")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
