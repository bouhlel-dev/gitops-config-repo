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
                           gate decides  AnalysisRun start -> the abort.
                                         Automatic, and the stable pods never
                                         left service (maxUnavailable: 0), so
                                         the traffic that mattered was whole
                                         again the moment the gate failed.
                           fix           abort -> the corrected release's last
                                         successful AnalysisRun, i.e. the moment
                                         the new version is at 100%. Human, and
                                         the one that actually hurts. The PR
                                         merge in the middle of it is not
                                         recovery: the cluster is still on the
                                         bad version when the git pointer moves.

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
# <rollout>-<pod-template-hash>-<step index>-<sample index>, the shape Rollouts
# gives every AnalysisRun. The hash is what identifies one release of one
# namespace, which is the unit the restore numbers need.
RUN_NAME = re.compile(r"^(?P<rollout>.+)-(?P<hash>[a-z0-9]{9,10})-(?P<step>\d+)-(?P<sample>\d+)$")


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
        # `completedAt`, not `finishedAt`: that is the key Rollouts 1.10 writes
        # when a run ends. Reading the wrong one silently drops every restore
        # number, because the list is full of runs that look still running.
        finished = status.get("completedAt") or status.get("finishedAt")
        # AnalysisRun names are <rollout>-<pod-template-hash>-<step>-<sample>,
        # so the hash groups the runs belonging to one release of one namespace.
        named = RUN_NAME.match(item["metadata"]["name"])
        runs_out.append({
            "namespace": item["metadata"]["namespace"],
            "name": item["metadata"]["name"],
            "hash": named.group("hash") if named else "",
            "phase": status.get("phase", "Unknown"),
            "message": status.get("message", ""),
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
            fastest = percentile(rollbacks, 0.5)
            # Zero is a real reading, not a missing one: this run terminated on
            # its first measurement, and Rollouts stamps startedAt and
            # completedAt at the same instant when that happens. Saying "0s"
            # alone would look like a bug in the script.
            why = ("ended on its first measurement" if fastest < 1
                   else "first measurement -> abort")
            print(f"  gate decides: {duration(fastest)} ({why}; "
                  f"stable pods never left service, maxUnavailable: 0)")
        for analysis in failed:
            print(f"    {analysis['namespace']}/{analysis['name']}: {analysis['message'] or '-'}")
        # The service is whole again when the corrected release finishes walking
        # the canary, not when its PR merges. Both are printed because they are
        # different questions: the first is what the pipeline owes you, the
        # second is what a human owed it.
        for analysis in failed:
            if not analysis["started"]:
                continue
            later = [other for other in analyses
                     if other["namespace"] == analysis["namespace"]
                     and other["hash"] and other["hash"] != analysis["hash"]
                     and other["phase"] == "Successful"
                     and other["finished"] and other["finished"] > analysis["started"]]
            if not later:
                print("  corrected release: has not finished its canary in the window")
                continue
            next_hash = min(later, key=lambda other: other["finished"])["hash"]
            corrected = [other for other in later if other["hash"] == next_hash]
            last = max(corrected, key=lambda other: other["finished"])
            print(f"  corrected release: {duration((last['finished'] - analysis['started']).total_seconds())} "
                  f"(abort -> {last['namespace']}/{last['name']} done, i.e. back at 100%)")
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
