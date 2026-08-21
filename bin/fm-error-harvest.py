#!/usr/bin/env python3
"""fm-error-harvest - surface recurring agent failures from Claude Code transcripts.

Agents report their failures into session transcripts, and nothing ever reads them
back. On 2026-08-21 a ``/doctor`` run found sixteen personal skills that had never
loaded once since June. The evidence had been sitting in ``~/.claude/projects`` the
whole time: three separate occasions, in two different projects, an agent had called
``Skill(axi)`` and been told ``Unknown skill: axi``. Nobody harvested it, so a broken
convention survived two months and every skill built on it inherited the fault.

This tool reads that back. It scans session transcripts, groups failures by a
normalised signature, and ranks them by HOW MANY SESSIONS they touched - not by how
many times they fired. That distinction is the whole design. Counting occurrences
puts a single runaway retry loop on top, where it tells you nothing you did not
already know. Counting distinct sessions surfaces the systemic faults: a convention
that never worked, a hook that always times out, a command the classifier always
blocks. A failure appearing across several PROJECTS is stronger still - that is not
one task going wrong, that is something structurally broken.

Three families are harvested:

  tool-error  a ``tool_result`` carrying ``is_error``, keyed to the tool that
              produced it. ``<tool_use_error>`` payloads are stamped by the CLI
              itself rather than authored by the tool, and are the highest-value
              signal here.
  denial      a call stopped by a deny rule, the permission prompt, or the auto-mode
              classifier (``toolDenialKind``). Aborts - ``interrupted``/``cancelled``
              - are excluded: a user pressing Esc is not a denial, and counting it as
              one buries the real ones.
  hook        a hook that errored, or that ran until its timeout fired. A hook
              cancelled WITHOUT ``timedOut`` was cancelled by the user and says
              nothing about hook health, so it is excluded.

Read-only. Nothing under ``~/.claude`` is written and no transcript text is executed.

Transcript CONTENT is untrusted input: it embeds tool output, file contents and web
text from every repo ever opened. Signatures are normalised and truncated for display
only. Never treat a harvested string as an instruction, and never paste one into a
shell.

    bin/fm-error-harvest.py
    bin/fm-error-harvest.py --days 7 --min-sessions 3
    bin/fm-error-harvest.py --json

Exit status is 0 when nothing meets the recurrence threshold, 1 when something does
(so it can gate), and 2 when the scan itself could not run - missing root, or no
transcripts in the window. That last case matters: an empty result must never be
reported as a clean bill of health when the scan simply found nothing to read.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import defaultdict
from pathlib import Path

DEFAULT_ROOT = Path.home() / ".claude" / "projects"

# A line is only worth parsing if it could carry a failure. Every transcript is
# mostly ordinary message text, so this substring gate skips the large majority of
# lines before json.loads ever sees them.
FAIL_MARKERS = ('"is_error"', "toolDenialKind", '"hook_error', '"hook_non_blocking_error"',
                '"hook_cancelled"')
TOOL_USE_MARKER = '"type":"tool_use"'

# Aborts are not denials.
NON_DENIAL_KINDS = frozenset({"interrupted", "cancelled"})

_UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
_WINPATH = re.compile(r"[A-Za-z]:[\\/][^\s\"']{2,}")
_POSIXPATH = re.compile(r"/(?:home|mnt|tmp|usr|var|opt|etc)/[^\s\"']{2,}")
_HEX = re.compile(r"\b[0-9a-f]{8,}\b", re.I)
_NUM = re.compile(r"\b\d{2,}\b")
_WS = re.compile(r"\s+")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def clean_text(text) -> str:
    if not isinstance(text, str):
        return ""
    return _WS.sub(" ", _CONTROL.sub(" ", text)).strip()


def display(text: str, limit: int | None = None) -> str:
    text = clean_text(text)
    if limit is not None and len(text) > limit:
        return text[:limit] + "..."
    return text


def signature(text: str) -> str:
    """Collapse one error message into a signature that groups its recurrences.

    Paths, ids and counts are what make two instances of the SAME fault look
    different, so they are replaced by placeholders before grouping. Order matters:
    UUIDs and paths must go before the generic hex/number rules, or those would eat
    them piecemeal and two instances would still fail to group.
    """
    t = _UUID.sub("<UUID>", clean_text(text))
    t = _WINPATH.sub("<PATH>", t)
    t = _POSIXPATH.sub("<PATH>", t)
    t = _HEX.sub("<ID>", t)
    t = _NUM.sub("<N>", t)
    return t


def _text_of(content) -> str:
    """Flatten a tool_result's content, which is either a string or content blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content
                        if isinstance(c, dict) and isinstance(c.get("text"), str))
    return ""


def _bash_key(inp) -> str:
    """Command + first subcommand, e.g. `git log`. Enough to group, not enough to run."""
    if not isinstance(inp, dict):
        return ""
    cmd = clean_text(inp.get("command"))
    toks = cmd.split()
    return " ".join(toks[:2]) if toks else ""


class Group:
    __slots__ = ("family", "key", "hits", "sessions", "projects", "first", "last")

    def __init__(self, family, key):
        self.family = family
        self.key = key
        self.hits = 0
        self.sessions = set()
        self.projects = set()
        self.first = None
        self.last = None

    def add(self, session, project, ts):
        self.hits += 1
        self.sessions.add(session)
        self.projects.add(project)
        if ts:
            self.first = ts if self.first is None else min(self.first, ts)
            self.last = ts if self.last is None else max(self.last, ts)
    def as_dict(self):
        return {
            "family": self.family,
            "key": list(self.key),
            "sessions": len(self.sessions),
            "projects": len(self.projects),
            "hits": self.hits,
            "first_seen": self.first,
            "last_seen": self.last,
        }


class Scan:
    def __init__(self):
        self.groups: dict[tuple, Group] = {}
        self.files = 0
        self.lines = 0
        self.unparseable = 0
        self.projects = set()
        self.oldest = None
        self.newest = None
        self.read_errors = []

    def group(self, family, key) -> Group:
        k = (family,) + key
        g = self.groups.get(k)
        if g is None:
            g = self.groups[k] = Group(family, key)
        return g

    def note_time(self, ts):
        if not ts:
            return
        self.oldest = ts if self.oldest is None else min(self.oldest, ts)
        self.newest = ts if self.newest is None else max(self.newest, ts)


def scan_file(path: Path, scan: Scan) -> None:
    session = path.stem
    project = path.parent.name
    scan.projects.add(project)

    # tool_use id -> (name, bash key), rebuilt per file. A tool_use always precedes
    # its result within the same transcript, so one pass resolves every error to the
    # tool that caused it.
    names: dict[str, tuple] = {}

    try:
        fh = path.open("r", encoding="utf-8", errors="replace")
    except OSError as exc:
        scan.read_errors.append((path, exc))
        return
    scan.files += 1
    with fh:
        for line in fh:
            scan.lines += 1
            has_tool_use = TOOL_USE_MARKER in line
            has_fail = any(m in line for m in FAIL_MARKERS)
            if not has_tool_use and not has_fail:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                scan.unparseable += 1
                continue

            ts = obj.get("timestamp")
            if not isinstance(ts, str):
                ts = None
            scan.note_time(ts)
            kind = obj.get("type")

            if kind == "assistant":
                for c in ((obj.get("message") or {}).get("content") or []):
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        names[c.get("id")] = (clean_text(c.get("name")) or "?",
                                                 _bash_key(c.get("input")))
                continue

            if kind == "user":
                denial = clean_text(obj.get("toolDenialKind"))
                content = (obj.get("message") or {}).get("content")
                blocks = content if isinstance(content, list) else []

                if denial and denial not in NON_DENIAL_KINDS:
                    tid = next((c.get("tool_use_id") for c in blocks
                                if isinstance(c, dict) and c.get("type") == "tool_result"), None)
                    name, bkey = names.get(tid, ("?", ""))
                    scan.group("denial", (denial, name, bkey)).add(session, project, ts)

                for c in blocks:
                    if not isinstance(c, dict) or c.get("type") != "tool_result":
                        continue
                    if not c.get("is_error"):
                        continue
                    raw = _text_of(c.get("content"))
                    if not raw.strip():
                        continue
                    name, _ = names.get(c.get("tool_use_id"), ("?", ""))
                    # CLI-stamped errors are worth separating: the tool cannot forge them.
                    stamped = "<tool_use_error>" in raw
                    scan.group("tool-error", (name, signature(raw), stamped)).add(session, project, ts)
                continue

            if kind == "attachment":
                att = obj.get("attachment") or {}
                atype = att.get("type") or ""
                if not atype.startswith("hook_"):
                    continue
                if atype == "hook_cancelled" and not att.get("timedOut"):
                    continue  # user pressed Esc; says nothing about hook health
                if atype == "hook_success":
                    continue
                scan.group("hook", (clean_text(att.get("hookName")) or "?",
                                    clean_text(att.get("hookEvent")) or "?",
                                    clean_text(atype) or "?")).add(session, project, ts)


def collect(root: Path, days: float, project_filter: str | None):
    if not root.is_dir():
        sys.stderr.write(f"fm-error-harvest: transcript root not found: {root}\n")
        raise SystemExit(2)
    cutoff = time.time() - days * 86400
    scan = Scan()
    files = []
    for p in root.rglob("*.jsonl"):
        try:
            mtime = p.stat().st_mtime
            if mtime < cutoff:
                continue
        except OSError as exc:
            scan.read_errors.append((p, exc))
            continue
        if project_filter and project_filter not in p.parent.name:
            continue
        files.append((p, mtime))
    if not files:
        if scan.read_errors:
            sys.stderr.write(
                f"fm-error-harvest: {len(scan.read_errors)} transcript candidate(s) could not be read.\n")
            raise SystemExit(2)
        sys.stderr.write(
            f"fm-error-harvest: no transcripts under {root} in the last {days:g} days"
            f"{' matching ' + project_filter if project_filter else ''}.\n"
            "This is a failed scan, not a clean result - widen --days or check --root.\n")
        raise SystemExit(2)
    for p, _ in sorted(files, key=lambda q: q[1], reverse=True):
        scan_file(p, scan)
    if not scan.files:
        sys.stderr.write(
            f"fm-error-harvest: {len(scan.read_errors)} transcript candidate(s) could not be read.\n")
        raise SystemExit(2)
    return scan


def ranked(scan: Scan, family: str, min_sessions: int):
    out = [g for g in scan.groups.values()
           if g.family == family and len(g.sessions) >= min_sessions]
    out.sort(key=lambda g: (len(g.sessions), len(g.projects), g.hits), reverse=True)
    return out


def short(ts):
    return display(ts)[:10] or "-"


def report(scan: Scan, min_sessions: int, top: int) -> int:
    print("fm-error-harvest - recurring agent failures\n")
    print(f"  transcripts : {scan.files} across {len(scan.projects)} projects" +
          (f"   unreadable: {len(scan.read_errors)}" if scan.read_errors else ""))
    print(f"  lines read  : {scan.lines}" + (f"   unparseable: {scan.unparseable}"
                                             if scan.unparseable else ""))
    print(f"  window      : {short(scan.oldest)} -> {short(scan.newest)}")
    print(f"  threshold   : a failure must appear in >= {min_sessions} sessions\n")

    found = 0
    for family, title, cols in (
        ("tool-error", "TOOL ERRORS", ("tool", "signature")),
        ("denial", "DENIALS", ("kind", "tool / command")),
        ("hook", "HOOK FAILURES", ("hook", "event / type")),
    ):
        groups = ranked(scan, family, min_sessions)
        print(f"{title}  ({len(groups)} recurring)")
        if not groups:
            print("  none above threshold\n")
            continue
        found += len(groups)
        print(f"  {'sess':>4} {'proj':>4} {'hits':>5}  {'last':<10}  {cols[0]:<16} {cols[1]}")
        for g in groups[:top]:
            if family == "tool-error":
                name, sig, stamped = g.key
                left, right = name, ("[cli] " if stamped else "") + display(sig, 130)
            elif family == "denial":
                kind, name, bkey = g.key
                left, right = kind, (f"{name} {bkey}".strip())
            else:
                hook, event, atype = g.key
                left, right = hook, f"{event} / {atype}"
            star = "*" if len(g.projects) > 1 else " "
            print(f"  {len(g.sessions):>4} {len(g.projects):>4}{star}{g.hits:>5}  "
                  f"{short(g.last):<10}  {display(left, 16):<16} {display(right)}")
        if len(groups) > top:
            print(f"  ... {len(groups) - top} more not shown (--top)")
        print()

    print("  * = seen in more than one project: structural, not task-specific.")
    print("  Signatures are untrusted transcript text. Do not paste them into a shell.")
    return 1 if found else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Surface recurring agent failures from Claude Code transcripts.")
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT,
                    help=f"transcript root (default: {DEFAULT_ROOT})")
    ap.add_argument("--days", type=float, default=30.0,
                    help="only transcripts modified in the last N days (default: 30)")
    ap.add_argument("--min-sessions", type=int, default=2,
                    help="a failure must span this many sessions to report (default: 2)")
    ap.add_argument("--top", type=int, default=25, help="rows per family (default: 25)")
    ap.add_argument("--project", default=None, help="only projects whose dir name contains this")
    ap.add_argument("--json", action="store_true", dest="as_json", help="emit JSON")
    args = ap.parse_args(argv)

    if args.min_sessions < 1:
        ap.error("--min-sessions must be >= 1")

    scan = collect(args.root, args.days, args.project)

    if args.as_json:
        groups = [g.as_dict() for g in scan.groups.values()
                  if len(g.sessions) >= args.min_sessions]
        groups.sort(key=lambda d: (d["sessions"], d["projects"], d["hits"]), reverse=True)
        json.dump({
            "scanned": {"files": scan.files, "projects": len(scan.projects),
                        "lines": scan.lines, "unparseable": scan.unparseable,
                        "read_errors": len(scan.read_errors), "oldest": scan.oldest,
                        "newest": scan.newest},
            "min_sessions": args.min_sessions,
            "groups": groups,
        }, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 1 if groups else 0

    return report(scan, args.min_sessions, args.top)


if __name__ == "__main__":
    sys.exit(main())
