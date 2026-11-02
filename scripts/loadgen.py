#!/usr/bin/env python3
"""The traffic the canary analysis is measured on.

This is not a nicety. The AnalysisTemplate asks Prometheus for
rate(http_requests_total{pod=~".*-<hash>-.*"}[1m]) and a p95 over the same
window. A canary pod that has served nothing returns an EMPTY result, an empty
result is a FAILED measurement, and the rollout aborts a release that was never
given a chance to prove itself. So: no load, no signal.

    python scripts/loadgen.py --duration 300
    python scripts/loadgen.py --target dev --rate 50
    python scripts/loadgen.py --target prod --duration 120 --quiet

Stdlib only, and it talks to the ingress through 127.0.0.1 with the virtual host
in a Host header, so nothing here needs an entry in
C:\\Windows\\System32\\drivers\\etc\\hosts.
"""

from __future__ import annotations

import argparse
import http.client
import random
import sys
import threading
import time
from collections import Counter

# The vhost in each overlay's Ingress. Keep in step with
# apps/gitops-demo/overlays/<env>/kustomization.yaml.
HOSTS = {
    "dev": "gitops-demo.local",
    "prod": "gitops-demo-prod.local",
}

# Weighted so the mix looks like a small API rather than a health-check flood.
# /metrics is deliberately absent: Prometheus scrapes it, and counting scrapes
# as user traffic would inflate the success rate the analysis depends on.
PATHS = [("/", 6), ("/api/items", 3), ("/health", 1)]


def pick_path() -> str:
    return random.choices([p for p, _ in PATHS], weights=[w for _, w in PATHS])[0]


class Target:
    def __init__(self, name: str, gateway: str, port: int) -> None:
        self.name = name
        self.host = HOSTS[name]
        self.gateway = gateway
        self.port = port
        self.lock = threading.Lock()
        self.status: Counter[str] = Counter()
        self.window: list[float] = []
        self.all: list[float] = []
        self.total = 0

    def record(self, status: int, seconds: float) -> None:
        with self.lock:
            self.total += 1
            self.status[status_class(status)] += 1
            self.window.append(seconds)
            self.all.append(seconds)

    def take_window(self) -> tuple[list[float], int]:
        with self.lock:
            samples, self.window = self.window, []
            return samples, self.total


def one_request(target: Target) -> None:
    """One GET, timed, counted. A transport error is status 0 and lands in
    the same bucket as a 5xx, because as far as the analysis is concerned a
    request that never got an answer did not succeed."""
    path = pick_path()
    started = time.perf_counter()
    status = 0
    try:
        conn = http.client.HTTPConnection(target.gateway, target.port, timeout=5)
        try:
            conn.request("GET", path, headers={"Host": target.host, "User-Agent": "loadgen"})
            response = conn.getresponse()
            response.read()  # drain, or the connection is left half-used
            status = response.status
        finally:
            conn.close()
    except OSError:
        status = 0
    target.record(status, time.perf_counter() - started)


def status_class(status: int) -> str:
    if status == 0:
        return "error"
    return f"{status // 100}xx"


def worker(target: Target, interval: float, stop: threading.Event) -> None:
    while not stop.is_set():
        one_request(target)
        stop.wait(interval)


def percentile(samples: list[float], q: float) -> float:
    if not samples:
        return float("nan")
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, int(q * (len(ordered) - 1)))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--target", choices=["dev", "prod", "all"], default="all")
    parser.add_argument("--rate", type=float, default=20.0, help="requests/second per target")
    parser.add_argument("--concurrency", type=int, default=4, help="threads per target")
    parser.add_argument("--duration", type=float, default=120.0, help="seconds; 0 runs until Ctrl-C")
    parser.add_argument("--gateway", default="127.0.0.1", help="address the ingress is published on")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between summary lines")
    parser.add_argument("--quiet", action="store_true", help="only the final summary")
    args = parser.parse_args()

    names = ["dev", "prod"] if args.target == "all" else [args.target]
    targets = [Target(name, args.gateway, args.port) for name in names]
    threads = list()
    stop = threading.Event()
    # Each thread waits long enough that concurrency threads together make the
    # requested rate, so --rate 20 --concurrency 4 is a 5 second interval.
    interval = args.concurrency / args.rate
    for target in targets:
        for _ in range(args.concurrency):
            threads.append(threading.Thread(target=worker, args=(target, interval, stop), daemon=True))

    deadline = time.monotonic() + args.duration if args.duration else None
    started = time.perf_counter()
    print(f"loadgen -> {', '.join(t.host for t in targets)} "
          f"via {args.gateway}:{args.port} at ~{args.rate * len(targets):.0f} rps total", flush=True)
    for thread in threads:
        thread.start()

    last_total = {t.name: 0 for t in targets}
    try:
        while True:
            stop.wait(args.interval)
            if stop.is_set():
                break
            for target in targets:
                samples, total = target.take_window()
                window_rps = (total - last_total[target.name]) / args.interval
                last_total[target.name] = total
                if not args.quiet:
                    print(f"  {time.perf_counter() - started:7.1f}s  {target.name:<5} "
                          f"{window_rps:5.1f} rps  p50 {percentile(samples, 0.5) * 1000:6.1f}ms  "
                          f"p95 {percentile(samples, 0.95) * 1000:6.1f}ms  "
                          f"{dict(sorted(target.status.items()))}", flush=True)
            if deadline and time.monotonic() >= deadline:
                break
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        stop.set()
        for thread in threads:
            thread.join(timeout=6)

    print()
    for target in targets:
        with target.lock:
            good = target.status.get("2xx", 0)
            print(f"  {target.name:<5} {target.total:7d} requests  "
                  f"{dict(sorted(target.status.items()))}  "
                  f"p95 {percentile(target.all, 0.95) * 1000:.1f}ms  "
                  f"success {good / target.total * 100:.2f}%"
                  if target.total else f"  {target.name:<5} 0 requests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
