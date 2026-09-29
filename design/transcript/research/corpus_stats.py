"""Corpus statistics that drive the transcript tool/XML design.

A "run" = maximal sequence of tool_use blocks on the main thread with no
visible row between them (assistant text, user prompt, command, notification).
Thinking and tool results don't break a run (they are hidden).
"""
import json, glob, os, random, re, sys, statistics
from collections import Counter, defaultdict
from datetime import datetime

root = os.path.expanduser("~/.claude/projects")
files = [f for f in glob.glob(root + "/*/*.jsonl") if "ccterm-transcript" not in f and "/private-tmp" not in f]
random.seed(7)
random.shuffle(files)
files = files[: int(sys.argv[1]) if len(sys.argv) > 1 else 1500]

tool_count = Counter()
tool_err = Counter()
runs = []  # list of lists of tool names
run_durations = []
run_calls_parallel = []  # calls per assistant message (parallel fan-out)
bash_cmd_lines, bash_cmd_chars, bash_out_lines, bash_desc = [], [], [], Counter()
bash_heads = Counter()
edit_plus, edit_minus, edit_hunks = [], [], []
write_lines, write_new = [], Counter()
read_lines, read_partial = [], Counter()
grep_files, glob_files = [], []
xml_kinds = Counter()
slash_names = Counter()
cmd_out_lines = []
tag_names = Counter()
text_len = []
mcp_servers = Counter()
same_file_edits_in_run = []
visible_rows = 0
tool_rows = 0
turn_kinds = Counter()
files_per_run = []
TAG = re.compile(r"<([a-zA-Z][\w-]*)[\s>]")

def pct(xs, ps=(50, 75, 90, 95, 99)):
    if not xs:
        return {}
    s = sorted(xs)
    return {p: s[min(len(s) - 1, int(len(s) * p / 100))] for p in ps} | {"max": s[-1], "n": len(s), "mean": round(sum(s) / len(s), 1)}

def ts(d):
    t = d.get("timestamp")
    try:
        return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

for f in files:
    uses = {}
    cur = []
    cur_t0 = cur_t1 = None
    cur_files = []
    def close():
        global cur, cur_t0, cur_t1, cur_files
        if cur:
            runs.append(cur)
            if cur_t0 and cur_t1:
                run_durations.append(cur_t1 - cur_t0)
            fc = Counter(cur_files)
            files_per_run.append(len(fc))
            if fc:
                same_file_edits_in_run.append(max(fc.values()))
        cur, cur_t0, cur_t1, cur_files = [], None, None, []
    try:
        lines = open(f, errors="ignore").readlines()
    except Exception:
        continue
    last_msg_id = None
    per_msg = Counter()
    for line in lines:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("isSidechain"):
            continue
        t = d.get("type")
        m = d.get("message") or {}
        c = m.get("content")
        if t == "assistant" and isinstance(c, list):
            mid = m.get("id")
            for b in c:
                bt = b.get("type")
                if bt == "text" and b.get("text", "").strip():
                    close(); visible_rows += 1
                    text_len.append(len(b["text"]))
                elif bt == "tool_use":
                    name = b.get("name", "?")
                    tool_count[name] += 1
                    tool_rows += 1
                    per_msg[mid] += 1
                    if name.startswith("mcp__"):
                        mcp_servers[name.split("__")[1]] += 1
                    uses[b.get("id")] = (name, b.get("input") or {})
                    cur.append(name)
                    tt = ts(d)
                    cur_t0 = cur_t0 or tt
                    cur_t1 = tt or cur_t1
                    inp = b.get("input") or {}
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    if fp and name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                        cur_files.append(fp)
                    if name == "Bash":
                        cmd = inp.get("command", "")
                        bash_cmd_lines.append(cmd.count("\n") + 1)
                        bash_cmd_chars.append(len(cmd))
                        bash_desc["with" if inp.get("description") else "without"] += 1
                        head = cmd.strip().split()[0] if cmd.strip() else ""
                        if head in ("cd",) and "&&" in cmd:
                            head = cmd.split("&&", 1)[1].strip().split()[0] if cmd.split("&&", 1)[1].strip() else head
                        bash_heads[os.path.basename(head)] += 1
        elif t == "user":
            if isinstance(c, list) and c and isinstance(c[0], dict) and c[0].get("type") == "tool_result":
                r = c[0]
                name, inp = uses.get(r.get("tool_use_id"), ("?", {}))
                tur = d.get("toolUseResult")
                tt = ts(d)
                if cur:
                    cur_t1 = tt or cur_t1
                if r.get("is_error"):
                    tool_err[name] += 1
                if isinstance(tur, dict):
                    if name == "Bash":
                        out = (tur.get("stdout") or "") + (tur.get("stderr") or "")
                        bash_out_lines.append(out.count("\n") + (1 if out else 0))
                    elif name == "Edit":
                        p = mnus = 0
                        hs = tur.get("structuredPatch") or []
                        for h in hs:
                            for l in h.get("lines", []):
                                if l.startswith("+"): p += 1
                                elif l.startswith("-"): mnus += 1
                        edit_plus.append(p); edit_minus.append(mnus); edit_hunks.append(len(hs))
                    elif name == "Write":
                        write_lines.append((tur.get("content") or "").count("\n") + 1)
                        write_new[tur.get("type")] += 1
                    elif name == "Read":
                        fl = tur.get("file") or {}
                        if tur.get("type") == "text":
                            read_lines.append(fl.get("numLines", 0))
                            read_partial["partial" if fl.get("numLines", 0) < fl.get("totalLines", 0) else "whole"] += 1
                        else:
                            read_partial[tur.get("type")] += 1
                    elif name == "Grep":
                        grep_files.append(tur.get("numFiles", 0))
                    elif name == "Glob":
                        glob_files.append(tur.get("numFiles", 0))
                continue
            text = c if isinstance(c, str) else (c[0].get("text") if isinstance(c, list) and c and isinstance(c[0], dict) else None)
            if d.get("isMeta") or d.get("isCompactSummary"):
                if text:
                    for tg in TAG.findall(text[:400]):
                        tag_names["meta:" + tg] += 1
                continue
            if not text:
                continue
            tags = TAG.findall(text.strip()[:200]) if text.strip().startswith("<") else []
            if tags:
                for tg in set(tags):
                    tag_names[tg] += 1
                k = tags[0]
                xml_kinds[k] += 1
                if k == "command-name":
                    mm = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
                    if mm:
                        slash_names[mm.group(1).strip()] += 1
                if k in ("local-command-stdout", "bash-stdout", "local-command-stderr", "bash-stderr"):
                    inner = re.sub(r"</?[\w-]+>", "", text)
                    cmd_out_lines.append(inner.strip().count("\n") + (1 if inner.strip() else 0))
                if k in ("local-command-caveat",):
                    continue
                close(); visible_rows += 1
            elif text.strip().startswith("[Request interrupted"):
                xml_kinds["interrupted"] += 1
                close(); visible_rows += 1
            else:
                xml_kinds["prompt"] += 1
                close(); visible_rows += 1
        elif t == "system" and d.get("subtype") == "compact_boundary":
            close(); visible_rows += 1
    close()
    run_calls_parallel.extend(per_msg.values())

lens = [len(r) for r in runs]
print("files", len(files), "runs", len(runs), "tool rows", tool_rows, "visible non-tool rows", visible_rows)
print("run length", pct(lens))
hist = Counter(min(l, 21) for l in lens)
print("run length hist", sorted(hist.items()))
w = Counter()
for r in runs:
    w[min(len(r), 21)] += len(r)
print("share of tool calls by run length", {k: round(v / tool_rows, 3) for k, v in sorted(w.items())})
print("distinct tools per run", pct([len(set(r)) for r in runs]))
print("parallel calls per assistant msg", pct(run_calls_parallel))
print("run duration s", pct([int(x) for x in run_durations]))
print("files edited per run", pct(files_per_run))
print("max edits same file in run", pct(same_file_edits_in_run))
print("\ntools", tool_count.most_common(40))
print("tool error rate", {k: f"{tool_err[k]}/{v}={tool_err[k]/v:.2%}" for k, v in tool_count.most_common(20)})
print("mcp servers", mcp_servers.most_common(15))
print("\nbash cmd lines", pct(bash_cmd_lines), "chars", pct(bash_cmd_chars))
print("bash out lines", pct(bash_out_lines))
print("bash description", bash_desc)
print("bash heads", bash_heads.most_common(30))
print("\nedit +", pct(edit_plus), "\nedit -", pct(edit_minus), "\nedit hunks", pct(edit_hunks))
print("write lines", pct(write_lines), write_new)
print("read lines", pct(read_lines), read_partial)
print("grep files", pct(grep_files), "glob files", pct(glob_files))
print("\nuser kinds", xml_kinds.most_common(30))
print("slash names", slash_names.most_common(40))
print("cmd out lines", pct(cmd_out_lines))
print("tag names", tag_names.most_common(40))
print("assistant text chars", pct(text_len))
# common bigrams in runs
bi = Counter()
for r in runs:
    for a, b in zip(r, r[1:]):
        bi[(a, b)] += 1
print("\ntop bigrams", bi.most_common(20))
sig = Counter()
for r in runs:
    sig[" ".join(sorted(set(r)))] += 1
print("top run tool-sets", sig.most_common(20))
