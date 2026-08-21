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
              produced it. Its message is reduced to a redacted bounded summary
              and a digest; transcript tags do not establish provenance.
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
import hashlib
import json
import math
import os
import re
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
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
_SECRET_KEY = (
    r"(?:[A-Za-z0-9_.-]*?(?:token|secret|password|passwd|pwd|api[_-]?key|auth|"
    r"cookie|session|credential|private[_-]?key)[A-Za-z0-9_.-]*)"
)
_SECRET_ASSIGNMENT = re.compile(
    rf'''(?ix)(
        (?<![A-Za-z0-9_.-])["']?{_SECRET_KEY}["']?\s*[:=]\s*
    )(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;)&\]}}]+)'''
)
_SECRET_HEADER = re.compile(
    r"(?im)(\b(?:authorization|cookie|set-cookie|x-api-key)\s*:\s*)([^\r\n]*)"
)
_BEARER_OR_BASIC = re.compile(r"(?i)(\b(?:bearer|basic)\s+)([A-Za-z0-9+/=_-]+)")
_JWT = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])")
_PEM = re.compile(r"-----BEGIN [^-\r\n]{1,64}-----.*?(?:-----END [^-\r\n]{1,64}-----|\Z)", re.I | re.S)
_KNOWN_SECRET = re.compile(r"\b(?:ghp|gho|ghs|github_pat|sk|xox[baprs])[-_][A-Za-z0-9_=-]{8,}\b", re.I)
_OPAQUE = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z0-9_+/=-]{24,})(?![A-Za-z0-9_])")
_TIMESTAMP = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})$"
)
ERROR_DISPLAY_LIMIT = 130


def clean_text(text) -> str:
    if not isinstance(text, str):
        return ""
    return _WS.sub(" ", _CONTROL.sub(" ", text)).strip()


def display(text: str, limit: int | None = None) -> str:
    text = clean_text(text)
    if limit is not None and len(text) > limit:
        return text[:limit] + "..."
    return text


def redact_secrets(text: str) -> str:
    if not isinstance(text, str):
        return ""
    text = _PEM.sub("<REDACTED>", text)
    text = _SECRET_HEADER.sub(r"\1<REDACTED>", text)
    text = _SECRET_ASSIGNMENT.sub(r"\1<REDACTED>", text)
    text = _BEARER_OR_BASIC.sub(r"\1<REDACTED>", text)
    text = _JWT.sub("<REDACTED>", text)
    text = _KNOWN_SECRET.sub("<REDACTED>", text)

    def redact_opaque(match):
        value = match.group(1)
        counts = defaultdict(int)
        for char in value:
            counts[char] += 1
        entropy = -sum(
            (count / len(value)) * math.log2(count / len(value))
            for count in counts.values()
        )
        return "<REDACTED>" if entropy >= 3.5 else value

    return clean_text(_OPAQUE.sub(redact_opaque, text))


def signature(text: str) -> str:
    """Collapse one error message into a signature that groups its recurrences.

    Paths, ids and counts are what make two instances of the SAME fault look
    different, so they are replaced by placeholders before grouping. Order matters:
    UUIDs and paths must go before the generic hex/number rules, or those would eat
    them piecemeal and two instances would still fail to group.
    """
    t = _UUID.sub("<UUID>", redact_secrets(text))
    t = _WINPATH.sub("<PATH>", t)
    t = _POSIXPATH.sub("<PATH>", t)
    t = _HEX.sub("<ID>", t)
    t = _NUM.sub("<N>", t)
    return t


def tool_error_key(text: str) -> tuple[str, str]:
    normalized = signature(text)
    identity = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return identity, display(normalized, ERROR_DISPLAY_LIMIT)


def safe_label(value, limit: int = ERROR_DISPLAY_LIMIT) -> str:
    return display(redact_secrets(value), limit)


def _text_of(content) -> str:
    """Flatten a tool_result's content, which is either a string or content blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content
                        if isinstance(c, dict) and isinstance(c.get("text"), str))
    return ""


def _bash_key(inp) -> tuple[str, str]:
    """Command + first subcommand, e.g. `git log`. Enough to group, not enough to run."""
    if not isinstance(inp, dict):
        return tool_error_key("")
    cmd = clean_text(inp.get("command"))
    toks = cmd.split()
    return tool_error_key(" ".join(toks[:2]))


def denial_key(kind, name, command_identity: str, command_display: str):
    kind_value = redact_secrets(clean_text(kind))
    name_value = redact_secrets(clean_text(name))
    identity = hashlib.sha256(
        (kind_value + "\0" + name_value + "\0" + command_identity).encode("utf-8")
    ).hexdigest()
    return identity, (display(kind_value, 48) or "?", safe_label(name, 64) or "?", command_display)


def hook_key(name, event, atype) -> tuple[str, tuple[str, str, str]]:
    name_identity = redact_secrets(name)
    event_identity = redact_secrets(event)
    type_identity = redact_secrets(atype)
    identity = hashlib.sha256(
        (name_identity + "\0" + event_identity + "\0" + type_identity).encode("utf-8")
    ).hexdigest()
    return identity, (safe_label(name) or "?", safe_label(event) or "?",
                      safe_label(atype) or "?")


def parse_timestamp(value) -> str | None:
    if not isinstance(value, str) or not _TIMESTAMP.fullmatch(value):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00").replace(",", "."))
    except ValueError:
        return None
    return parsed.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def timestamp_from_mtime(mtime: float) -> str:
    return datetime.fromtimestamp(mtime, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Group:
    __slots__ = ("family", "identity", "key", "hits", "sessions", "projects", "first", "last")

    def __init__(self, family, identity, key):
        self.family = family
        self.identity = identity
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
        result = {
            "family": self.family,
            "key": list(self.identity),
            "sessions": len(self.sessions),
            "projects": len(self.projects),
            "hits": self.hits,
            "first_seen": self.first,
            "last_seen": self.last,
        }
        if self.family == "tool-error":
            result["display"] = {"tool": self.key[0], "signature": self.key[1]}
        elif self.family == "denial":
            result["display"] = {"kind": self.key[0], "tool": self.key[1],
                                 "command": self.key[2]}
        elif self.family == "hook":
            result["display"] = {"hook": self.key[0], "event": self.key[1],
                                 "type": self.key[2]}
        return result


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

    def group(self, family, identity, key=None) -> Group:
        k = (family,) + identity
        g = self.groups.get(k)
        if g is None:
            g = self.groups[k] = Group(family, identity, key if key is not None else identity)
        return g

    def note_time(self, ts):
        if not ts:
            return
        self.oldest = ts if self.oldest is None else min(self.oldest, ts)
        self.newest = ts if self.newest is None else max(self.newest, ts)


def scan_file(path: Path, root: Path, scan: Scan, mtime: float) -> None:
    session = path.relative_to(root).as_posix()
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
    saw_timestamp = False
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

            if not isinstance(obj, dict):
                scan.unparseable += 1
                continue

            ts = parse_timestamp(obj.get("timestamp"))
            if ts is not None:
                saw_timestamp = True
                scan.note_time(ts)
            kind = obj.get("type")

            if kind == "assistant":
                message = obj.get("message")
                if not isinstance(message, dict) or not isinstance(message.get("content"), list):
                    scan.unparseable += 1
                    continue
                for c in message["content"]:
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        tool_id = c.get("id")
                        if not isinstance(tool_id, str):
                            scan.unparseable += 1
                            continue
                        command_identity, command_display = _bash_key(c.get("input"))
                        names[tool_id] = (safe_label(c.get("name"), 64) or "?",
                                          command_identity, command_display)
                continue

            if kind == "user":
                denial = clean_text(obj.get("toolDenialKind"))
                message = obj.get("message")
                if not isinstance(message, dict) or not isinstance(message.get("content"), list):
                    scan.unparseable += 1
                    continue
                blocks = message["content"]

                if denial and denial not in NON_DENIAL_KINDS:
                    tid = next((c.get("tool_use_id") for c in blocks
                                if isinstance(c, dict) and c.get("type") == "tool_result" and
                                isinstance(c.get("tool_use_id"), str)), None)
                    name, command_identity, command_display = names.get(tid, ("?", *_bash_key({})))
                    identity, label = denial_key(denial, name, command_identity, command_display)
                    scan.group("denial", (identity,), label).add(session, project, ts)

                for c in blocks:
                    if not isinstance(c, dict) or c.get("type") != "tool_result":
                        continue
                    if c.get("is_error") is not True:
                        continue
                    raw = _text_of(c.get("content"))
                    if not raw.strip():
                        continue
                    tool_id = c.get("tool_use_id")
                    name = names.get(tool_id, ("?", "", ""))[0] if isinstance(tool_id, str) else "?"
                    identity, summary = tool_error_key(raw)
                    scan.group("tool-error", (name, identity), (name, summary)).add(session, project, ts)
                continue

            if kind == "attachment":
                att = obj.get("attachment")
                if not isinstance(att, dict) or not isinstance(att.get("type"), str):
                    scan.unparseable += 1
                    continue
                atype = att["type"]
                if not atype.startswith("hook_"):
                    continue
                if atype == "hook_cancelled" and att.get("timedOut") is not True:
                    continue  # user pressed Esc; says nothing about hook health
                if atype == "hook_success":
                    continue
                identity, label = hook_key(att.get("hookName"), att.get("hookEvent"), atype)
                scan.group("hook", (identity,), label).add(session, project, ts)
    if not saw_timestamp:
        scan.note_time(timestamp_from_mtime(mtime))


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
    for p, mtime in sorted(files, key=lambda q: q[1], reverse=True):
        scan_file(p, root, scan, mtime)
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
                name, sig = g.key
                left, right = name, sig
            elif family == "denial":
                kind, name, bkey = g.key
                left, right = kind, (f"{name} {bkey}".strip())
            else:
                hook, event, atype = g.key
                left, right = hook, f"{event} / {atype}"
            star = "*" if len(g.projects) > 1 else " "
            left_limit = ERROR_DISPLAY_LIMIT if family == "hook" else 16
            print(f"  {len(g.sessions):>4} {len(g.projects):>4}{star}{g.hits:>5}  "
                  f"{short(g.last):<10}  {display(left, left_limit):<16} {display(right)}")
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
