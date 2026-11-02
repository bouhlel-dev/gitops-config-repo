#!/usr/bin/env python3
"""The four DORA keys, measured from this pipeline.

Every number is read out of the system that produced it -- GitHub for what was
released and when, the cluster for what the canary decided -- so this script is
a report, not a second pipeline that can disagree with the first.

Definitions, because DORA is only comparable once you say what you meant:

  Deployment frequency   A merged release PR in config-repo. That commit is
                         what Argo CD syncs, so one merge is one deploy. A CI
                         re-run that promoted nothing is not counted.

  Lead time for changes  Commit authored in app-repo -> that release PR merged
                         in config-repo, so it covers lint, test, build, scan,
                         publish and promotion in one number. The last hop --
                         Argo CD noticing the new commit -- is at most one
                         reconciliation interval (20s here) and is printed
                         separately rather than folded in.

  Change failure rate    AnalysisRuns that ended Failed, over all AnalysisRuns.
                         An AnalysisRun exists only when a canary actually ran,
                         so this means "releases the quality gate rejected",
                         not "CI jobs that went red".

  Time to restore        Two numbers, because the pipeline restores twice in two
                         different ways:
                           rollback  AnalysisRun start -> the abort. Automatic,
                                     and the stable pods never left service
                                     (maxUnavailable: 0), so the service was
                                     whole again the moment the gate failed.
                           fix       failure -> the next merged release. Human,
                                     and the one that actually hurts.

    source scripts/env.sh
    python scripts/dora.py
    python scripts/dora.py --days 1
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import NoReturn

RELEASE_TITLE = re.compile(r"^release: gitops-demo ([0-9a-f]{7,40})$")
FAILED_PHASES = ("Failed", "Error")


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def run(argv: list[str]) -> str:
    """One command, its stdout. gh and kubectl live in <workspace>/.tools/bin,
    which scripts/env.sh puts on PATH: if argv[0] is missing the shell was never
    sourced, and saying so beats a stack trace about FileNotFoundError."""
    if not shutil.which(argv[0]):
        die(f"{argv[0]} not on PATH. Run: source scripts/env.sh   (after scripts/install-tools.sh)")
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"{' '.join(argv)}\n{result.stderr.strip()}")
    return result.stdout


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(timezone.utc)


# ------------------------------------------------------------------- sources --

def merged_releases(app_repo: str, config_repo: str, since: datetime) -> list[dict]:
    """Release PRs merged since `since`, oldest first, joined to their commit."""
    pulls = json.loads(run([
        "gh", "pr", "list", "--repo", config_repo, "--state", "merged",
        "--limit", "200", "--json", "number,title,mergedAt",
    ]))
    releases = []
    for pull in pulls:
        match = RELEASE_TITLE.match(pull["title"])
        if not match:
            continue
        merged = parse_time(pull["mergedAt"])
        if merged < since:
            continue
        sha = match.group(1)
        authored = parse_time(run([
            "gh", "api", f"repos/{app_repo}/commits/{sha}", "--jq", ".commit.committer.date",
        ]).strip())
        releases.append({
            "number": pull["number"],
            "sha": sha,
            "authored": authored,
            "merged": merged,
            "lead": (merged - authored).total_seconds(),
        })
    releases.sort(key=lambda release: release["merged"])
    return releases


def analysis_runs() -> list[dict]:
    """Every AnalysisRun any canary produced, in any namespace."""
    document = json.loads(run(["kubectl", "get", "analysisruns", "--all-namespaces", "-o", "json"]))
    runs_out = []
    for item in document.get("items", []):
        status = item.get("status") or {}
        started = status.get("startedAt")
        finished = status.get("finishedAt")
        runs_out.append({
            "namespace": item["metadata"]["namespace"],
            "name": item["metadata"]["name"],
            "phase": status.get("phase", "Unknown"),
            "started": parse_time(started) if started else None,
            "finished": parse_time(finished) if finished else None,
        })
    return runs_out


# ------------------------------------------------------------------- printing --

def duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 90:
        return f"{seconds}s"
    minutes, rest = divmod(seconds, 60)
    if minutes < 90:
        return f"{minutes}m {rest:02d}s"
    return f"{minutes // 60}h {minutes % 60:02d}m"


def percentile(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * (len(ordered) - 1)))]


def report(app_repo: str, config_repo: str, days: float) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=days)
    releases = merged_releases(app_repo, config_repo, since)
    analyses = analysis_runs()
    failed = [run_ for run_ in analyses if run_["phase"] in FAILED_PHASES]

    print(f"DORA  {app_repo} + {config_repo}  last {days:g} day(s)")
    print(f"sample: {len(releases)} release(s), {len(analyses)} analysis run(s)\n")

    print("Deployment frequency")
    if releases:
        hours = max(1.0, (datetime.now(timezone.utc) - since).total_seconds() / 3600)
        gaps = [(later["merged"] - earlier["merged"]).total_seconds()
                for earlier, later in zip(releases, releases[1:])]
        print(f"  {len(releases)} deployment(s), {len(releases) / (hours / 24):.1f}/day")
        if gaps:
            print(f"  median gap between releases: {duration(percentile(gaps, 0.5))}")
    else:
        print("  nothing merged in the window")
    print()

    print("Lead time for changes  (commit authored -> release PR merged)")
    if releases:
        leads = [release["lead"] for release in releases]
        print(f"  median {duration(percentile(leads, 0.5))}  "
              f"p90 {duration(percentile(leads, 0.9))}  max {duration(max(leads))}")
        for release in releases:
            print(f"    PR #{release['number']:<3} {release['sha']}  "
                  f"authored {release['authored']:%H:%M:%S}  "
                  f"merged {release['merged']:%H:%M:%S}  {duration(release['lead'])}")
        print("  plus at most 20s before Argo CD reconciles the merged commit")
    else:
        print("  nothing to measure yet")
    print()

    print("Change failure rate  (canaries the quality gate rejected)")
    if analyses:
        by_phase: dict[str, int] = {}
        for analysis in analyses:
            by_phase[analysis["phase"]] = by_phase.get(analysis["phase"], 0) + 1
        print(f"  {len(failed)} of {len(analyses)}  ({len(failed) / len(analyses) * 100:.0f}%)  {by_phase}")
    else:
        print("  no AnalysisRun exists yet: a first deploy has no previous version")
        print("  to compare against, so it goes straight to 100% without analysis.")
    print()

    print("Time to restore")
    if failed:
        rollbacks = [(analysis["finished"] - analysis["started"]).total_seconds()
                     for analysis in failed if analysis["started"] and analysis["finished"]]
        if rollbacks:
            print(f"  automatic: {duration(percentile(rollbacks, 0.5))} "
                  f"(first measurement -> abort, stable pods never left service)")
        fixes = []
        for analysis in failed:
            later = [release for release in releases if release["merged"] > analysis["started"]]
            if later:
                fixes.append((later[0]["merged"] - analysis["started"]).total_seconds())
        if fixes:
            print(f"  by hand:   {duration(percentile(fixes, 0.5))} "
                  f"(failure -> the next release that replaced it)")
        else:
            print("  by hand:   no replacement release has landed since the failure")
    else:
        print("  no failed canary in the window, so nothing had to be restored")
    print()

    print("Read the bands against your own history, not as a grade: with a sample")
    print("this small the shape is the finding -- what a bad release costs in")
    print("minutes, and how fast the pipeline undoes it without being asked.")


def main() -> int:
    parser = argparse.ArgumentParser(description="DORA metrics for the GitOps demo")
    parser.add_argument("--app-repo", default="bouhlel-dev/gitops-app-repo")
    parser.add_argument("--config-repo", default="bouhlel-dev/gitops-config-repo")
    parser.add_argument("--days", type=float, default=30.0, help="look back this far")
    args = parser.parse_args()
    report(args.app_repo, args.config_repo, args.days)
    return 0


if __name__ == "__main__":
    sys.exit(main())
