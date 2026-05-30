#!/usr/bin/env python3
"""
generate-claude-code-stats-fixtures.py

One-shot: copy your local Claude Code stats data into the test fixture,
redacting any text content. Also runs the reference SNr aggregation in
Python (the same algorithm reverse-engineered from the Claude desktop
bundle) and writes an `expected.json` snapshot — that snapshot is what
the Swift `ClaudeCodeStatsTests` asserts against, so the two
implementations cross-check each other.

Run from the repo root:

    python3 macos/scripts/generate-claude-code-stats-fixtures.py

After running, commit `macos/cctermTests/Fixtures/ClaudeCodeStats/`.
The fixture is deterministic in time (a reference "today" is captured
in meta.json) and self-contained — the test never reads `~/.claude`.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import sys
import uuid

SCRIPT = pathlib.Path(__file__).resolve()
REPO_MACOS = SCRIPT.parents[1]
FIXTURE_ROOT = REPO_MACOS / "cctermTests" / "Fixtures" / "ClaudeCodeStats"
HOME = pathlib.Path.home()
CACHE_PATH = HOME / ".claude" / "stats-cache.json"
PROJECTS_ROOT = HOME / ".claude" / "projects"

# Sample knobs — keep the fixture small enough to commit comfortably.
SAMPLE_PER_SLUG = 1
MAX_SLUGS = 3
MAX_BYTES_PER_JSONL = 200_000

SYNTHETIC = "<synthetic>"
TZ = datetime.timezone.utc  # tests pin the same TZ on the Swift side


# --------------------------------------------------------------------------
# Redaction
# --------------------------------------------------------------------------


def stable_uuid(seed: str) -> str:
    digest = hashlib.sha1(seed.encode("utf-8")).digest()
    return str(uuid.UUID(bytes=digest[:16], version=4))


def redact_text(s):
    if not isinstance(s, str):
        return s
    return f"<redacted-len{len(s)}>"


def make_id_map(slug_idx: int, jsonl_idx: int):
    prefix = f"fixture-{slug_idx}-{jsonl_idx}"
    return {
        "session": stable_uuid(prefix + ":session"),
        "uuid": lambda u: stable_uuid(prefix + ":uuid:" + str(u)),
        "tool": lambda u: stable_uuid(prefix + ":tool:" + str(u)),
    }


def redact_content_item(c, idmap):
    if not isinstance(c, dict):
        return c
    c = dict(c)
    t = c.get("type")
    if t == "text":
        c["text"] = redact_text(c.get("text", ""))
    elif t == "tool_use":
        if "id" in c:
            c["id"] = idmap["tool"](c["id"])
        if "input" in c:
            c["input"] = {"redacted": True}
    elif t == "tool_result":
        if "tool_use_id" in c:
            c["tool_use_id"] = idmap["tool"](c["tool_use_id"])
        v = c.get("content")
        if isinstance(v, str):
            c["content"] = redact_text(v)
        elif isinstance(v, list):
            c["content"] = [redact_content_item(i, idmap) for i in v]
    elif t in ("image", "document"):
        c = {"type": t, "redacted": True}
    return c


def redact_entry(e, idmap):
    e = dict(e)
    for k in ("sessionId", "session_id"):
        if k in e:
            e[k] = idmap["session"]
    if "uuid" in e:
        e["uuid"] = idmap["uuid"](e["uuid"])
    if "parentUuid" in e and e["parentUuid"]:
        e["parentUuid"] = idmap["uuid"](e["parentUuid"])
    if "cwd" in e:
        e["cwd"] = "/redacted/cwd"
    if "gitBranch" in e:
        e["gitBranch"] = "redacted-branch"
    if "userType" in e and isinstance(e["userType"], str):
        pass  # not sensitive
    msg = e.get("message")
    if isinstance(msg, dict):
        msg = dict(msg)
        content = msg.get("content")
        if isinstance(content, list):
            msg["content"] = [redact_content_item(c, idmap) for c in content]
        elif isinstance(content, str):
            msg["content"] = redact_text(content)
        e["message"] = msg
    return e


# --------------------------------------------------------------------------
# Reference SNr aggregation (kept in lock-step with the Swift impl)
# --------------------------------------------------------------------------


def parse_iso(s):
    if not isinstance(s, str):
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def day_string(dt: datetime.datetime) -> str:
    return dt.astimezone(TZ).strftime("%Y-%m-%d")


def day_plus_one(s: str) -> str:
    d = datetime.date.fromisoformat(s)
    return (d + datetime.timedelta(days=1)).isoformat()


def aggregate(fixture_root: pathlib.Path, today: datetime.date):
    cache_path = fixture_root / "stats-cache.json"
    cache = json.load(cache_path.open()) if cache_path.exists() else None

    window_days = 182
    if cache and cache.get("lastComputedDate"):
        cutoff_day = day_plus_one(cache["lastComputedDate"])
    else:
        cutoff_day = (today - datetime.timedelta(days=window_days)).isoformat()

    daily: dict[str, dict] = {}
    daily_tokens: dict[str, dict[str, int]] = {}
    model_usage: dict[str, dict] = {}
    hour_counts: dict[int, int] = {}
    total_sessions = 0
    total_messages = 0
    first_date = None
    last_date = None

    if cache:
        total_sessions = cache.get("totalSessions", 0)
        total_messages = cache.get("totalMessages", 0)
        first_date = cache.get("firstSessionDate")
        for d in cache.get("dailyActivity", []):
            if d["date"] < cutoff_day:
                daily[d["date"]] = {
                    "date": d["date"],
                    "messageCount": d.get("messageCount", 0),
                    "sessionCount": d.get("sessionCount", 0),
                    "toolCallCount": d.get("toolCallCount", 0),
                }
        for d in cache.get("dailyModelTokens", []):
            if d["date"] < cutoff_day:
                daily_tokens[d["date"]] = dict(d["tokensByModel"])
        for m, u in cache.get("modelUsage", {}).items():
            model_usage[m] = {
                "inputTokens": u.get("inputTokens", 0),
                "outputTokens": u.get("outputTokens", 0),
                "cacheReadInputTokens": u.get("cacheReadInputTokens", 0),
                "cacheCreationInputTokens": u.get("cacheCreationInputTokens", 0),
            }
        for h, n in cache.get("hourCounts", {}).items():
            hour_counts[int(h)] = n

    projects = fixture_root / "projects"
    jsonls: list[pathlib.Path] = []
    if projects.exists():
        for slug in sorted(projects.iterdir()):
            if not slug.is_dir():
                continue
            for f in sorted(slug.iterdir()):
                if f.suffix == ".jsonl" and f.is_file():
                    jsonls.append(f)
            for sub in sorted(slug.iterdir()):
                if sub.is_dir():
                    agents = sub / "subagents"
                    if agents.exists():
                        for f in sorted(agents.iterdir()):
                            if (
                                f.suffix == ".jsonl"
                                and f.is_file()
                                and f.name.startswith("agent-")
                            ):
                                jsonls.append(f)

    for f in jsonls:
        entries = []
        with f.open() as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    entries.append(json.loads(ln))
                except json.JSONDecodeError:
                    continue
        ua = [e for e in entries if e.get("type") in ("user", "assistant")]
        if not ua:
            continue
        is_sub = "/subagents/" in str(f)
        filtered = ua if is_sub else [e for e in ua if not e.get("isSidechain")]
        if not filtered:
            continue
        ts0 = filtered[0].get("timestamp") or ""
        dt0 = parse_iso(ts0)
        if not dt0:
            continue
        day = day_string(dt0)
        if day < cutoff_day:
            continue

        bucket = daily.get(day) or {
            "date": day,
            "messageCount": 0,
            "sessionCount": 0,
            "toolCallCount": 0,
        }
        if not is_sub:
            total_sessions += 1
            total_messages += len(filtered)
            bucket["sessionCount"] += 1
            bucket["messageCount"] += len(filtered)
            hr = dt0.astimezone(TZ).hour
            hour_counts[hr] = hour_counts.get(hr, 0) + 1
            if not first_date or ts0 < first_date:
                first_date = ts0
            if not last_date or ts0 > last_date:
                last_date = ts0
        if (not is_sub) or (day in daily):
            daily[day] = bucket

        for e in filtered:
            if e.get("type") != "assistant":
                continue
            msg = e.get("message") or {}
            content = msg.get("content")
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        if day in daily:
                            daily[day]["toolCallCount"] += 1
            usage = msg.get("usage")
            if not usage:
                continue
            model = msg.get("model") or "unknown"
            if model == SYNTHETIC:
                continue
            mu = model_usage.setdefault(
                model,
                {
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "cacheReadInputTokens": 0,
                    "cacheCreationInputTokens": 0,
                },
            )
            mu["inputTokens"] += usage.get("input_tokens", 0) or 0
            mu["outputTokens"] += usage.get("output_tokens", 0) or 0
            mu["cacheReadInputTokens"] += usage.get("cache_read_input_tokens", 0) or 0
            mu["cacheCreationInputTokens"] += (
                usage.get("cache_creation_input_tokens", 0) or 0
            )
            total = (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0)
            if total > 0:
                tk = daily_tokens.setdefault(day, {})
                tk[model] = tk.get(model, 0) + total

    sorted_daily = sorted(daily.values(), key=lambda x: x["date"])
    sorted_tokens = [
        {"date": d, "tokensByModel": dict(sorted(t.items()))}
        for d, t in sorted(daily_tokens.items())
    ]
    active_days = len({d["date"] for d in sorted_daily})

    peak_hour = None
    peak_n = 0
    for h, n in hour_counts.items():
        if n > peak_n:
            peak_n = n
            peak_hour = h

    streaks = compute_streaks({d["date"] for d in sorted_daily}, today)

    return {
        "totalSessions": total_sessions,
        "totalMessages": total_messages,
        "activeDays": active_days,
        "firstSessionDate": first_date,
        "lastSessionDate": last_date,
        "peakActivityHour": peak_hour,
        "streaks": streaks,
        "dailyActivity": sorted_daily,
        "dailyModelTokens": sorted_tokens,
        "modelUsage": {k: model_usage[k] for k in sorted(model_usage)},
    }


def compute_streaks(days: set[str], today: datetime.date):
    if not days:
        return {"currentStreak": 0, "longestStreak": 0}
    current = 0
    d = today
    while d.isoformat() in days:
        current += 1
        d -= datetime.timedelta(days=1)
    sorted_days = sorted(days)
    longest = 1
    run = 1
    for i in range(1, len(sorted_days)):
        a = datetime.date.fromisoformat(sorted_days[i - 1])
        b = datetime.date.fromisoformat(sorted_days[i])
        if (b - a).days == 1:
            run += 1
        else:
            longest = max(longest, run)
            run = 1
    longest = max(longest, run)
    return {"currentStreak": current, "longestStreak": longest}


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--today",
        default=None,
        help="reference 'today' (YYYY-MM-DD) for expected.json; default = today's date",
    )
    args = ap.parse_args()

    if not CACHE_PATH.exists():
        print(f"no cache at {CACHE_PATH}; run Claude Code at least once", file=sys.stderr)
        sys.exit(1)

    cache = json.load(CACHE_PATH.open())
    last_day = cache["lastComputedDate"]
    cutoff_ts = (
        datetime.datetime.fromisoformat(last_day) + datetime.timedelta(days=1)
    ).timestamp()

    by_slug: dict[str, list] = {}
    for slug in os.listdir(PROJECTS_ROOT):
        d = PROJECTS_ROOT / slug
        if not d.is_dir():
            continue
        for n in os.listdir(d):
            if not n.endswith(".jsonl"):
                continue
            p = d / n
            try:
                st = p.stat()
            except OSError:
                continue
            if st.st_mtime >= cutoff_ts:
                by_slug.setdefault(slug, []).append((st.st_mtime, st.st_size, p))

    picked: list[tuple[str, pathlib.Path]] = []
    # smallest slugs first (by total bytes) — keeps fixture compact
    for slug, files in sorted(by_slug.items(), key=lambda kv: sum(x[1] for x in kv[1]))[
        :MAX_SLUGS
    ]:
        files.sort(key=lambda x: x[1])
        for _, _, path in files[:SAMPLE_PER_SLUG]:
            picked.append((slug, path))

    if FIXTURE_ROOT.exists():
        shutil.rmtree(FIXTURE_ROOT)
    FIXTURE_ROOT.mkdir(parents=True)

    cache_red = json.loads(json.dumps(cache))
    if isinstance(cache_red.get("longestSession"), dict):
        cache_red["longestSession"]["sessionId"] = stable_uuid("fixture-longest")
    with (FIXTURE_ROOT / "stats-cache.json").open("w") as f:
        json.dump(cache_red, f, indent=2, sort_keys=True)
        f.write("\n")

    for i, (_slug, src) in enumerate(picked):
        slug_alias = f"-fixture-slug-{i}"
        sid_alias = stable_uuid(f"fixture-{i}:session")
        slug_dir = FIXTURE_ROOT / "projects" / slug_alias
        slug_dir.mkdir(parents=True, exist_ok=True)
        dst = slug_dir / f"{sid_alias}.jsonl"
        idmap = make_id_map(i, 0)
        written_bytes = 0
        with src.open() as fin, dst.open("w") as fout:
            for ln in fin:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    obj = json.loads(ln)
                except json.JSONDecodeError:
                    continue
                obj = redact_entry(obj, idmap)
                out_line = json.dumps(obj) + "\n"
                fout.write(out_line)
                written_bytes += len(out_line)
                if written_bytes >= MAX_BYTES_PER_JSONL:
                    break

    today_str = args.today or datetime.date.today().isoformat()
    today_date = datetime.date.fromisoformat(today_str)
    meta = {
        "referenceToday": today_str,
        "timezone": "UTC",
        "lastComputedDate": last_day,
        "sampleJsonl": len(picked),
        "_doc": (
            "ClaudeCodeStatsTests pins time at referenceToday under the given timezone "
            "so the aggregation is deterministic. Regenerate this fixture with "
            "macos/scripts/generate-claude-code-stats-fixtures.py."
        ),
    }
    with (FIXTURE_ROOT / "meta.json").open("w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
        f.write("\n")

    expected = aggregate(FIXTURE_ROOT, today_date)
    with (FIXTURE_ROOT / "expected.json").open("w") as f:
        json.dump(expected, f, indent=2, sort_keys=True)
        f.write("\n")

    print(
        f"wrote fixture to {FIXTURE_ROOT.relative_to(REPO_MACOS.parent)} "
        f"with {len(picked)} jsonl; expected "
        f"{expected['totalSessions']} sessions / {expected['totalMessages']} msgs"
    )


if __name__ == "__main__":
    main()
