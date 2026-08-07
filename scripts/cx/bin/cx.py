#!/usr/bin/env python3
"""cx — cross-Claude session comms over kitty remote control.

Gives every Claude Code session in a kitty pane a stable, human-sized id
(slot number + name) so one Claude can be told to talk to another:

    cx ls                      # roster with live status
    cx send 3 "rebase onto main"
    cx peek 3                  # read pane 3's screen
    cx focus 3

Identity model
--------------
One Claude per kitty pane, so the kitty *window id* is the durable key. A
SessionStart hook (cx-register) drops a JSON file per pane under
$CX_STATE_DIR/panes/<kitty_window_id>.json holding the Claude session_id,
cwd and a slot number. Registration is best-effort: panes with no registry
file still show up in `cx ls`, discovered from kitty's process table, they
just lack a session_id. Nothing here depends on the hook being installed.

Status
------
Read from $CX_STATE_DIR/state/<session_id>.json, which
scripts/term/bin/kitty-agent-title writes on every agent lifecycle hook. The
hook is *told* the state (`hook_event_name`), so this is exact, and reading it
is one directory read for the whole roster.

Screen scraping ("esc to interrupt" => running, a permission prompt =>
waiting) survives as a fallback for panes with no record: sessions started
before the hooks were installed, or panes that are not agents at all. It is
strictly worse — it infers from English UI strings that change between Claude
Code versions, and costs a `kitten @ get-text` per pane.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time

STATE_DIR = os.path.expanduser(os.environ.get("CX_STATE_DIR", "~/.claude/cx"))
PANES_DIR = os.path.join(STATE_DIR, "panes")
MAIL_DIR = os.path.join(STATE_DIR, "mail")
# Queued messages for sessions that were busy when someone sent to them, one
# directory per session id. Drained by the Stop hook (`cx drain`).
INBOX_DIR = os.path.join(STATE_DIR, "inbox")
# One file per session, written by scripts/term/bin/kitty-agent-title on every
# agent lifecycle hook. Authoritative status: the hook is *told* what the session
# is doing, where screen scraping has to infer it.
STATUS_DIR = os.path.join(STATE_DIR, "state")

# A session that died between hooks (SIGKILL, closed pane, crashed host) leaves
# its last record behind claiming to be running. Records older than this are
# reported stale rather than trusted — long enough that a genuinely long tool call
# is not mislabelled, short enough that a corpse does not look busy for hours.
STALE_AFTER = 15 * 60

# Claude Code's TUI footer while a turn is in flight. Matched case-insensitively
# against the pane's visible screen.
RUNNING_MARKERS = ("esc to interrupt",)
# Permission / plan-approval prompts: the pane is blocked on a human.
WAITING_MARKERS = (
    "do you want to",
    "would you like to",
    "no, and tell claude",
    "yes, and don't ask again",
    "ready to code?",
)

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def trunc(s: str, width: int, left: bool = False) -> str:
    """Clip to width, marking the elided side with an ellipsis."""
    if len(s) <= width:
        return s
    return "…" + s[-(width - 1):] if left else s[: width - 1] + "…"


def die(msg: str, code: int = 1):
    print(f"cx: {msg}", file=sys.stderr)
    raise SystemExit(code)


# --------------------------------------------------------------------------
# kitty remote control
# --------------------------------------------------------------------------

def kitty_bin() -> str:
    for candidate in ("kitty", "kitten"):
        path = shutil.which(candidate)
        if path:
            return path
    die("kitty not found on PATH")


def kitty(*args: str, check: bool = True) -> str:
    """Run `kitty @ ...`. Returns stdout; raises SystemExit on failure."""
    cmd = [kitty_bin(), "@", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        if not check:
            return ""
        err = (proc.stderr or proc.stdout).strip()
        if "Failed to connect" in err or "no such file" in err:
            die(
                "kitty remote control unreachable. Needs `allow_remote_control yes` "
                "in kitty.conf, and this must run inside kitty (KITTY_LISTEN_ON set). "
                f"kitty said: {err}"
            )
        die(f"`kitty @ {' '.join(args)}` failed: {err}")
    return proc.stdout


def kitty_tree() -> list:
    return json.loads(kitty("ls"))


def pane_screen(win_id: int, extent: str = "screen") -> str:
    txt = kitty("get-text", "--match", f"id:{win_id}", "--extent", extent, check=False)
    return ANSI.sub("", txt)


def type_into(win_id: int, text: str) -> None:
    """Paste text into a pane and submit it, as a user pressing Enter would.

    Two things matter here, both learned the hard way:

    --stdin, not `-- text`: with `--`, kitty interprets escapes in the argument,
    so a message containing a Windows path or a literal \\n is silently mangled —
    and an interpreted newline SUBMITS, splitting one message into several
    prompts.

    --bracketed-paste auto: wraps the text in paste markers when the receiving
    program has bracketed paste on, so the TUI ingests it as one atomic paste
    instead of a stream of keystrokes it might interleave with its own redraws.
    `auto` rather than `enable` because a plain shell has paste mode off, and
    sending the markers to it would leave literal escape junk on the line.
    """
    subprocess.run(
        [kitty_bin(), "@", "send-text", "--match", f"id:{win_id}",
         "--bracketed-paste", "auto", "--stdin"],
        input=text, text=True, capture_output=True,
    )
    # Enter goes as its own write. The paste above is a single unit to the TUI,
    # so no sleep is needed between them — the guessed delay this replaces was
    # only ever compensating for keystroke-by-keystroke delivery.
    kitty("send-text", "--match", f"id:{win_id}", "--", "\\r", check=False)


# States in which the pane is NOT sitting at an empty prompt, so typing into it
# would either be swallowed mid-turn or answer a dialog that expects a keypress.
#
# Only genuinely mid-turn states belong here. `start` and `notify` must NOT:
# a session that has fired SessionStart (or an idle_prompt notification) and
# nothing since is sitting at an empty prompt, ready to be typed into. Treating
# those as busy deadlocks delivery — the message queues, and the queue only
# drains on Stop, which never fires because no turn ever begins. Verified: a
# fresh session held two messages indefinitely while showing an empty prompt.
BUSY_STATES = ("running", "waiting", "compacting")


def inbox_path(session_id: str) -> str:
    return os.path.join(INBOX_DIR, session_id)


def enqueue(session_id: str, sender: str, msg: str) -> str:
    """Append a message to a session's inbox. Returns the file written."""
    d = inbox_path(session_id)
    os.makedirs(d, exist_ok=True)
    # time_ns keeps arrival order without a counter, and pid keeps two senders in
    # the same nanosecond from colliding.
    path = os.path.join(d, f"{time.time_ns()}-{os.getpid()}.json")
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        json.dump({"from": sender, "msg": msg, "ts": time.time()}, fh)
    os.replace(tmp, path)
    return path


def drain_inbox(session_id: str) -> list[dict]:
    """Read and remove every queued message for a session, oldest first."""
    d = inbox_path(session_id)
    try:
        names = sorted(fn for fn in os.listdir(d) if fn.endswith(".json"))
    except OSError:
        return []
    out = []
    for fn in names:
        p = os.path.join(d, fn)
        try:
            with open(p) as fh:
                out.append(json.load(fh))
        except (OSError, ValueError):
            pass
        try:
            os.remove(p)  # remove even on parse failure, else it blocks forever
        except OSError:
            pass
    return out


# --------------------------------------------------------------------------
# registry
# --------------------------------------------------------------------------

def registry() -> dict[int, dict]:
    out: dict[int, dict] = {}
    if not os.path.isdir(PANES_DIR):
        return out
    for fn in os.listdir(PANES_DIR):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(PANES_DIR, fn)) as fh:
                rec = json.load(fh)
            out[int(rec["kitty_window_id"])] = rec
        except (OSError, ValueError, KeyError):
            continue
    return out


_STATUS_CACHE: dict | None = None


def status_records() -> dict[str, dict]:
    """session_id -> hook-published state record. One directory read, cached."""
    global _STATUS_CACHE
    if _STATUS_CACHE is not None:
        return _STATUS_CACHE
    out: dict[str, dict] = {}
    try:
        names = os.listdir(STATUS_DIR)
    except OSError:
        _STATUS_CACHE = out
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(STATUS_DIR, fn)) as fh:
                rec = json.load(fh)
            sid = rec["session_id"]
        except (OSError, ValueError, KeyError):
            continue  # a half-written record; the next hook will replace it
        out[sid] = rec
    _STATUS_CACHE = out
    return out


def status_by_win() -> dict[int, dict]:
    """Same records keyed by kitty window id, newest wins.

    A pane that has hosted several sessions accumulates a record each; only the
    most recent one describes what is in the pane now.
    """
    out: dict[int, dict] = {}
    for rec in status_records().values():
        win = rec.get("win")
        if win is None:
            continue
        if win not in out or rec.get("ts", 0) > out[win].get("ts", 0):
            out[win] = rec
    return out


def human_age(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def record_status(rec: dict) -> tuple[str, str]:
    """(status, which hook said so and how long ago) from a state record.

    The second field is deliberately not the pane's last output line — that needs
    the transcript, not the record. "PreToolUse 4s" at least says whether the
    status is fresh or the session has been sitting on it.
    """
    state = rec.get("state") or "?"
    age = time.time() - rec.get("ts", 0)
    if state not in ("ended", "idle") and age > STALE_AFTER:
        state = "stale"
    return state, f"{rec.get('event') or '?'} {human_age(age)} ago"


# --------------------------------------------------------------------------
# transcript
# --------------------------------------------------------------------------
# The pane's screen is a rendering: wrapped to the pane's width, truncated to the
# scrollback, interleaved with TUI furniture, and gone entirely for a session
# running under tmux. The transcript JSONL is the conversation itself, so context
# is read from there and the screen is kept only as a fallback.

# Transcripts reach megabytes, and only the tail is ever wanted. Read backwards
# from the end rather than parsing the whole file.
TAIL_BYTES_LS = 64 * 1024
TAIL_BYTES_PEEK = 512 * 1024


def transcript_entries(path: str, max_bytes: int = TAIL_BYTES_PEEK) -> list[dict]:
    if not path:
        return []
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > max_bytes:
                fh.seek(size - max_bytes)
                fh.readline()  # discard the partial line the seek landed inside
            raw = fh.read()
    except OSError:
        return []
    out = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue  # a line being appended as we read; skip it
    return out


def flatten(content) -> str:
    """Best-effort single string out of a content block's payload."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                parts.append(b.get("text") or "")
            elif isinstance(b, str):
                parts.append(b)
        return " ".join(p for p in parts if p)
    return ""


# The field that actually says what a tool call is doing, per tool.
TOOL_SALIENT = ("command", "file_path", "pattern", "path", "url", "prompt", "description")


def tool_brief(inp) -> str:
    if not isinstance(inp, dict):
        return ""
    for key in TOOL_SALIENT:
        val = inp.get(key)
        if isinstance(val, str) and val.strip():
            return " ".join(val.split())
    return ""


def transcript_turns(entries: list[dict], sidechain: bool = False) -> list[tuple[str, str]]:
    """(speaker, text) in order. Tool calls collapse to one line each.

    tool_result blocks are dropped unless they errored: they are the bulk of a
    transcript by volume and almost never what you want when catching up on what
    another session is doing.

    thinking blocks are dropped because the text is not there to show — Claude
    Code persists the block with its signature and an empty `thinking` field
    (0 non-empty out of 313 blocks across four transcripts).
    """
    turns: list[tuple[str, str]] = []
    for e in entries:
        if e.get("isSidechain") and not sidechain:
            continue
        if e.get("type") not in ("user", "assistant"):
            continue
        content = (e.get("message") or {}).get("content")
        if isinstance(content, str):
            if content.strip():
                turns.append(("you", content))
            continue
        for block in content or []:
            if not isinstance(block, dict):
                continue
            bt = block.get("type")
            if bt == "text":
                if (block.get("text") or "").strip():
                    turns.append(("claude", block["text"]))
            elif bt == "tool_use":
                brief = tool_brief(block.get("input"))
                turns.append(("tool", f"{block.get('name') or '?'}({brief})" if brief
                              else f"{block.get('name') or '?'}"))
            elif bt == "tool_result" and block.get("is_error"):
                turns.append(("error", flatten(block.get("content"))))
    return turns


def transcript_last_line(path: str) -> str:
    """One line describing where the conversation currently is, for `cx ls`."""
    turns = transcript_turns(transcript_entries(path, TAIL_BYTES_LS))
    for speaker, text in reversed(turns):
        if speaker in ("claude", "you", "error"):
            first = next((ln for ln in text.splitlines() if ln.strip()), "")
            if first:
                return f"{speaker}: {' '.join(first.split())}"
        if speaker == "tool":
            return f"→ {text}"
    return ""


def write_record(rec: dict) -> None:
    os.makedirs(PANES_DIR, exist_ok=True)
    path = os.path.join(PANES_DIR, f"{rec['kitty_window_id']}.json")
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(rec, fh, indent=1)
    os.replace(tmp, path)  # atomic: concurrent sessions never see a half file


def drop_record(win_id: int) -> None:
    try:
        os.remove(os.path.join(PANES_DIR, f"{win_id}.json"))
    except OSError:
        pass


# --------------------------------------------------------------------------
# roster
# --------------------------------------------------------------------------

def process_table() -> dict[int, tuple[int, str]]:
    """pid -> (ppid, command). One ps call, cached for the process lifetime."""
    global _PS_CACHE
    if _PS_CACHE is not None:
        return _PS_CACHE
    _PS_CACHE = {}
    proc = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            _PS_CACHE[int(parts[0])] = (int(parts[1]), parts[2])
    return _PS_CACHE


_PS_CACHE: dict[int, tuple[int, str]] | None = None


def _is_claude_cmd(command: str) -> bool:
    argv0 = command.split()[0] if command.split() else ""
    return os.path.basename(argv0) == "claude"


def claude_pid_in_pane(win: dict) -> int | None:
    """The pid of the claude process driving this pane, if any.

    kitty's foreground_processes are the *leaves* of the pane's process tree —
    MCP servers (serena, codex mcp-server) and helpers (caffeinate) that claude
    itself spawned. So matching their cmdlines misses the session entirely;
    the claude process is an ancestor. Walk up from every leaf instead.
    """
    table = process_table()
    for proc in win.get("foreground_processes") or []:
        pid = proc.get("pid")
        hops = 0
        while pid in table and hops < 16:
            ppid, command = table[pid]
            if _is_claude_cmd(command):
                return pid
            pid, hops = ppid, hops + 1
    return None


def is_claude_pane(win: dict) -> bool:
    return claude_pid_in_pane(win) is not None


def roster(claude_only: bool = True) -> list[dict]:
    reg = registry()
    st_by_win = status_by_win()
    rows: list[dict] = []
    seen_sessions: set[str] = set()
    live_wins: set[int] = set()
    for os_win in kitty_tree():
        for tab in os_win["tabs"]:
            for win in tab["windows"]:
                wid = win["id"]
                rec = reg.get(wid)
                st = st_by_win.get(wid)
                pid = claude_pid_in_pane(win)
                # A state record is third proof that this pane holds an agent, and
                # the only one that works when the process tree hides it (claude
                # under a tmux server, as aoe-grid-* launches it).
                if claude_only and rec is None and pid is None and st is None:
                    continue
                session_id = (rec or {}).get("session_id") or (st or {}).get("session_id") or ""
                if session_id:
                    seen_sessions.add(session_id)
                live_wins.add(wid)
                rows.append(
                    {
                        "win": wid,
                        "pid": pid,
                        "tab": tab["id"],
                        "tab_title": tab.get("title") or "",
                        "os_win": os_win["id"],
                        "title": win.get("title") or "",
                        "cwd": (rec or {}).get("cwd") or (st or {}).get("cwd") or win.get("cwd") or "",
                        # The record's repo beats the pane title as a fallback name:
                        # kitty-agent-title stamps titles with state emoji, which
                        # read badly in a NAME column and change every few seconds.
                        "name": (rec or {}).get("name") or (st or {}).get("repo") or "",
                        "slot": (rec or {}).get("slot"),
                        "session_id": session_id,
                        "registered": rec is not None,
                        "self": bool(win.get("is_self")),
                    }
                )

    # Sessions with a live record but no pane of their own: running under tmux, or
    # on another host once records are shared. Addressable for status even though
    # `cx send` cannot type into them.
    now = time.time()
    for sid, st in status_records().items():
        if sid in seen_sessions or st.get("state") == "ended":
            continue
        if now - st.get("ts", 0) > STALE_AFTER:
            continue
        # A record naming a window that the pane loop already accounted for is a
        # previous occupant of that pane, not a session living somewhere else. Left
        # in, it would appear as its own row carrying a live window id — and
        # `cx send` to it would type into whoever holds that pane now.
        if st.get("win") in live_wins:
            continue
        rows.append(
            {
                "win": st.get("win") or 0,
                "pid": None,
                "tab": None,
                "tab_title": "",
                "os_win": None,
                "title": st.get("title") or "",
                "cwd": st.get("cwd") or "",
                "name": st.get("repo") or "",
                "slot": None,
                "session_id": sid,
                "registered": False,
                "self": False,
                "detached": True,
            }
        )
    # Stable ordering: registered slots first in slot order, then kitty order.
    rows.sort(key=lambda r: (r["slot"] is None, r["slot"] if r["slot"] is not None else r["win"]))
    # Backfill display slots for unregistered panes so every row is addressable.
    used = {r["slot"] for r in rows if r["slot"] is not None}
    nxt = 1
    for r in rows:
        if r["slot"] is None:
            while nxt in used:
                nxt += 1
            r["slot"] = nxt
            used.add(nxt)
    rows.sort(key=lambda r: r["slot"])  # re-sort: backfilled slots need placing too
    return rows


# Lines that are Claude Code's own furniture rather than content. Excluded from
# the LAST column, otherwise every pane just reports its status bar.
CHROME = (
    "bypass permissions",
    "esc to interrupt",
    "for shortcuts",
    "to cycle",
    "for agents",
    "auto-accept edits",
    "plan mode",
    "context left",
)


def last_content_line(screen: str) -> str:
    for line in reversed(screen.splitlines()):
        stripped = line.strip(" \t│╭╮╰╯─═▌▐█>❯•·")
        if len(stripped) < 3:
            continue
        low = stripped.lower()
        if any(c in low for c in CHROME):
            continue
        return stripped
    return ""


def status_of(win_id: int, session_id: str = "") -> tuple[str, str]:
    """(status, one line of context) for a pane.

    A hook-published record is preferred over screen scraping: it is exact rather
    than inferred, and it costs a dict lookup instead of a `kitten @ get-text`
    subprocess per pane. Scraping stays as the fallback for panes whose session
    predates the hooks, or which are not agent sessions at all.
    """
    rec = status_records().get(session_id) if session_id else None
    if rec is None:
        rec = status_by_win().get(win_id)
    if rec is not None:
        return record_status(rec)

    screen = pane_screen(win_id)
    if not screen:
        return "?", ""
    low = screen.lower()
    last = last_content_line(screen)
    if any(m in low for m in RUNNING_MARKERS):
        return "running", last
    if any(m in low for m in WAITING_MARKERS):
        return "waiting", last
    return "idle", last


def resolve(who: str, rows: list[dict] | None = None) -> dict:
    """Resolve a slot number, name, or kitty win id (w<N>) to one roster row."""
    rows = rows if rows is not None else roster()
    if not rows:
        die("no Claude panes found (is remote control on, and are the panes running claude?)")
    if who.startswith("w") and who[1:].isdigit():
        for r in rows:
            if r["win"] == int(who[1:]):
                return r
        die(f"no pane with kitty window id {who[1:]}")
    if who.isdigit():
        for r in rows:
            if r["slot"] == int(who):
                return r
        die(f"no pane in slot {who} (see `cx ls`)")
    hits = [r for r in rows if r["name"] == who]
    if not hits:
        hits = [r for r in rows if who.lower() in r["name"].lower()]
    if not hits:
        hits = [r for r in rows if who.lower() in r["title"].lower()]
    if not hits:
        die(f"no pane matching '{who}' (see `cx ls`)")
    if len(hits) > 1:
        names = ", ".join(f"{h['slot']}:{h['name'] or h['title']}" for h in hits)
        die(f"'{who}' is ambiguous: {names}")
    return hits[0]


def require_pane(dst: dict) -> dict:
    """Refuse the pane-bound commands on a session that has no pane of its own.

    Roster rows can come from a state record alone (claude under tmux, or another
    host), which is enough to report status but gives kitty nothing to match on.
    Failing here beats letting `kitten @ --match id:0` produce a confusing error.
    """
    if not dst.get("win"):
        die(
            f"slot {dst['slot']} ({dst.get('name') or dst.get('session_id') or '?'}) has no kitty pane "
            "of its own — it is running under tmux or on another host, so it can be "
            "listed but not typed into"
        )
    return dst


def self_row(rows: list[dict] | None = None) -> dict | None:
    """The row for the pane this command is running in, via kitty's own --self."""
    rows = rows if rows is not None else roster()
    wid = os.environ.get("KITTY_WINDOW_ID")
    if wid and wid.isdigit():
        for r in rows:
            if r["win"] == int(wid):
                return r
    try:
        tree = json.loads(kitty("ls", "--self"))
        mine = tree[0]["tabs"][0]["windows"][0]["id"]
    except (SystemExit, IndexError, KeyError, ValueError):
        return None
    for r in rows:
        if r["win"] == mine:
            return r
    return None


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_ls(argv: list[str]) -> int:
    show_all = "--all" in argv
    quiet = "-q" in argv or "--quiet" in argv
    rows = roster(claude_only=not show_all)
    if not rows:
        print("cx: no Claude panes found", file=sys.stderr)
        return 1
    me = self_row(rows)
    if quiet:
        for r in rows:
            print(f"{r['slot']}\t{r['name'] or r['title']}\t{r['win']}\t{r['cwd']}")
        return 0
    print(f"{'':2}{'SLOT':>4}  {'NAME':<22} {'WIN':>4} {'STATUS':<8} {'CWD':<24} LAST")
    for r in rows:
        st, last = status_of(r["win"], r.get("session_id", ""))
        # status_of returns "<event> <age> ago" for record-backed rows; the
        # transcript says something more useful if it is available.
        rec = status_records().get(r.get("session_id") or "")
        if rec and rec.get("transcript"):
            from_transcript = transcript_last_line(rec["transcript"])
            if from_transcript:
                last = from_transcript
        mark = "*" if me and r["win"] == me["win"] else " "
        cwd = r["cwd"].replace(os.path.expanduser("~"), "~")
        name = (r["name"] or r["title"] or "-") + ("" if r["registered"] else "~")
        if r.get("detached"):
            name += "@"
        win = str(r["win"]) if r["win"] else "-"
        print(
            f"{mark:2}{r['slot']:>4}  {trunc(name, 22):<22} {win:>4} {st:<8} "
            f"{trunc(cwd, 24, left=True):<24} {trunc(last, 44)}"
        )
    print(
        "\n  * = this pane   ~ = unregistered (run cx-install-hooks so panes self-name)"
        "   @ = no pane of its own (tmux/remote)"
    )
    return 0


def cmd_send(argv: list[str]) -> int:
    """Deliver a message to another session, typing it or queueing it.

    Typing into a session that is mid-turn is the unreliable case: the TUI may
    swallow the text, and if it is sitting on a permission dialog the keystrokes
    answer the dialog instead. So a busy target gets the message queued, and its
    Stop hook (`cx drain`) feeds it in as a real turn the moment it finishes.
    """
    force_queue = "--queue" in argv
    argv = [a for a in argv if a != "--queue"]
    if len(argv) < 2:
        die("usage: cx send <slot|name> <message...> [--queue]")
    target, msg = argv[0], " ".join(argv[1:])
    rows = roster()
    dst = resolve(target, rows)
    me = self_row(rows)
    if me and dst["win"] and dst["win"] == me["win"]:
        die("refusing to send to this same pane")
    who = (me["name"] or f"slot{me['slot']}") if me else "cx"
    # No brackets in the prefix: if the target pane happens to be a bare shell
    # rather than a Claude TUI, `[cx ...]` is a zsh glob and the line dies with
    # "bad pattern" instead of showing up.
    text = f"cx/{who}: {msg}"

    sid = dst.get("session_id") or ""
    state, _ = status_of(dst["win"], sid) if (dst["win"] or sid) else ("?", "")
    label = f"slot {dst['slot']} ({dst['name'] or dst['title'] or sid[:8] or '?'})"

    if state == "ended":
        die(f"{label} has ended — nothing there to receive the message")

    # Queue when asked, when the target is busy, or when it has no pane to type
    # into at all. All three need a session id: without one there is no inbox to
    # queue to and no Stop hook that would drain it.
    if sid and (force_queue or state in BUSY_STATES or not dst["win"]):
        enqueue(sid, who, msg)
        pending = len(os.listdir(inbox_path(sid)))
        why = "queued" if force_queue else (f"busy ({state})" if state in BUSY_STATES else "no pane")
        print(f"cx: {label} {why} — queued, delivered on its next Stop "
              f"({pending} pending)")
        return 0

    require_pane(dst)
    type_into(dst["win"], text)
    print(f"cx: typed into {label}, win {dst['win']}")
    return 0


def cmd_drain(argv: list[str]) -> int:
    """Stop-hook entry point: feed this session's queued messages back to it.

    Emitting {"decision":"block","reason":...} on Stop makes Claude Code treat the
    reason as a new turn rather than ending, which is how a queued message becomes
    a real prompt instead of keystrokes raced against a redraw.
    """
    payload = {}
    if not sys.stdin.isatty():
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            payload = {}
    sid = payload.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or ""
    if not sid:
        return 0  # not in a hook context; nothing to do and nothing to report

    # A Stop hook that blocks re-enters the model, which fires Stop again when it
    # next finishes. Draining (removing) the messages is what makes that
    # terminate rather than loop on the same text forever.
    msgs = drain_inbox(sid)
    if not msgs:
        return 0

    # Blocking on Stop means the session carries straight on working — but the
    # title hook, firing on the same Stop, has just recorded it as idle, and
    # nothing will contradict that: an injected turn raises no UserPromptSubmit,
    # and a text-only reply raises no PreToolUse either. Observed leaving a
    # session marked idle for the ~20s it spent answering. Left uncorrected, the
    # next `cx send` sees idle and types into a busy TUI, which is the exact race
    # the queue exists to avoid. drain is the one thing that knows better, so it
    # corrects the record itself.
    try:
        rec = dict(status_records().get(sid) or {})
        if rec:
            rec.update(state="running", event="cx-drain", ts=int(time.time()))
            path = os.path.join(STATUS_DIR, f"{sid}.json")
            tmp = f"{path}.tmp.{os.getpid()}"
            with open(tmp, "w") as fh:
                json.dump(rec, fh)
            os.replace(tmp, path)
    except OSError:
        pass  # a failed status update must not swallow the message

    body = "\n\n".join(f"Message from {m.get('from') or 'cx'}: {m.get('msg') or ''}"
                       for m in msgs)
    json.dump({
        "decision": "block",
        "reason": f"{body}\n\n(Delivered by cx while you were busy. "
                  f"Treat it as a user message and respond to it.)",
    }, sys.stdout)
    return 0


def cmd_bcast(argv: list[str]) -> int:
    if not argv:
        die("usage: cx bcast <message...>")
    msg = " ".join(argv)
    rows = roster()
    me = self_row(rows)
    sent = 0
    for r in rows:
        if me and r["win"] == me["win"]:
            continue
        cmd_send([str(r["slot"]), msg])
        sent += 1
    print(f"cx: broadcast to {sent} pane(s)")
    return 0


def cmd_ask(argv: list[str]) -> int:
    """Send a question and block until the other session answers.

    `cx send` is fire-and-forget; this is request/reply. The mailbox is plain
    files under $CX_STATE_DIR/mail, and the reply arrives because the message
    tells the receiving Claude to run `cx answer <id> "..."` — no daemon, no
    broker, works with any Claude session that has cx on PATH.
    """
    timeout = 300
    if "--timeout" in argv:
        i = argv.index("--timeout")
        try:
            timeout = int(argv[i + 1])
        except (IndexError, ValueError):
            die("--timeout wants seconds, e.g. --timeout 120")
        del argv[i : i + 2]
    if len(argv) < 2:
        die('usage: cx ask <slot|name> "<question>" [--timeout SECS]')

    target, question = argv[0], " ".join(argv[1:])
    rows = roster()
    dst = require_pane(resolve(target, rows))
    me = self_row(rows)
    if me and dst["win"] == me["win"]:
        die("refusing to ask this same pane")

    os.makedirs(MAIL_DIR, exist_ok=True)
    req_id = f"{int(time.time())}-{os.getpid()}"
    frm = (me["name"] or f"slot{me['slot']}") if me else "cx"
    with open(os.path.join(MAIL_DIR, f"{req_id}.json"), "w") as fh:
        json.dump(
            {"id": req_id, "from": frm, "to": dst["name"] or f"slot{dst['slot']}",
             "question": question, "created": int(time.time())},
            fh,
        )

    prompt = (
        f"cx/{frm} asks (request {req_id}): {question} "
        f"-- when you have the answer, send it back by running: "
        f'cx answer {req_id} "<your answer>"'
    )
    kitty("send-text", "--match", f"id:{dst['win']}", "--", prompt)
    time.sleep(0.2)
    kitty("send-text", "--match", f"id:{dst['win']}", "--", "\r")
    print(f"cx: asked slot {dst['slot']} ({dst['name'] or dst['title']}), "
          f"request {req_id}, waiting up to {timeout}s…", file=sys.stderr)

    reply_path = os.path.join(MAIL_DIR, f"{req_id}.reply.json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(reply_path):
            try:
                with open(reply_path) as fh:
                    reply = json.load(fh)
            except ValueError:  # still being written
                time.sleep(0.3)
                continue
            print(reply.get("text", ""))
            return 0
        time.sleep(2)
    print(
        f"cx: no answer within {timeout}s. The request is still open — "
        f"`cx peek {dst['slot']}` to see what that session is doing, or "
        f"`cx answers {req_id}` once it replies.",
        file=sys.stderr,
    )
    return 2


def cmd_answer(argv: list[str]) -> int:
    """Answer a request raised by `cx ask` (run by the receiving session)."""
    if len(argv) < 2:
        die('usage: cx answer <request-id> "<answer text>"')
    req_id, text = argv[0], " ".join(argv[1:])
    req_path = os.path.join(MAIL_DIR, f"{req_id}.json")
    if not os.path.exists(req_path):
        die(f"no open request '{req_id}' (see `cx inbox`)")
    me = self_row()
    os.makedirs(MAIL_DIR, exist_ok=True)
    path = os.path.join(MAIL_DIR, f"{req_id}.reply.json")
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(
            {"id": req_id, "text": text,
             "by": (me["name"] or f"slot{me['slot']}") if me else "?",
             "at": int(time.time())},
            fh,
        )
    os.replace(tmp, path)  # atomic: the asker polls for this file existing
    print(f"cx: answered {req_id}")
    return 0


def cmd_answers(argv: list[str]) -> int:
    """Print the reply to a request id (for checking after an ask timed out)."""
    if not argv:
        die("usage: cx answers <request-id>")
    path = os.path.join(MAIL_DIR, f"{argv[0]}.reply.json")
    if not os.path.exists(path):
        die(f"no answer yet for {argv[0]}")
    with open(path) as fh:
        reply = json.load(fh)
    print(f"[{reply.get('by', '?')}] {reply.get('text', '')}")
    return 0


def cmd_inbox(argv: list[str]) -> int:
    """List requests, newest first, with whether each has been answered."""
    if not os.path.isdir(MAIL_DIR):
        print("cx: no requests")
        return 0
    reqs = sorted(
        (f for f in os.listdir(MAIL_DIR) if f.endswith(".json") and not f.endswith(".reply.json")),
        reverse=True,
    )
    if not reqs:
        print("cx: no requests")
        return 0
    for fn in reqs:
        try:
            with open(os.path.join(MAIL_DIR, fn)) as fh:
                req = json.load(fh)
        except (OSError, ValueError):
            continue
        answered = os.path.exists(os.path.join(MAIL_DIR, f"{req['id']}.reply.json"))
        state = "answered" if answered else "OPEN"
        print(f"{req['id']:<20} {state:<9} {req['from']} -> {req['to']}: {trunc(req['question'], 60)}")
    return 0


SPEAKER_WIDTH = 7


def transcript_of(dst: dict) -> str:
    """The session's transcript path, from either registry or state record."""
    sid = dst.get("session_id") or ""
    rec = status_records().get(sid) or {}
    if rec.get("transcript"):
        return rec["transcript"]
    for pane_rec in registry().values():
        if pane_rec.get("session_id") == sid and pane_rec.get("transcript"):
            return pane_rec["transcript"]
    return ""


def cmd_peek(argv: list[str]) -> int:
    if not argv:
        die("usage: cx peek <slot|name> [turns] [--screen] [--all] [--sidechain]")
    flags = {a for a in argv if a.startswith("--")}
    argv = [a for a in argv if not a.startswith("--")]
    if not argv:
        die("usage: cx peek <slot|name> [turns] [--screen] [--all] [--sidechain]")
    n = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 12

    dst = resolve(argv[0])
    st, age = status_of(dst["win"], dst.get("session_id", ""))
    head = f"── slot {dst['slot']}  {dst['name'] or dst['title'] or '-'}  {st} ({age})"

    # --screen forces the old behaviour: kitty's rendering of the pane, wrapped
    # and scrollback-limited, TUI chrome and all. Needs a real pane.
    if "--screen" in flags:
        dst = require_pane(dst)
        txt = pane_screen(dst["win"], extent="all" if "--all" in flags else "screen")
        lines = [ln.rstrip() for ln in txt.splitlines()]
        while lines and not lines[-1]:
            lines.pop()
        print(f"{head}  [pane {dst['win']} screen] ──")
        print("\n".join(lines[-(n if n > 12 else 40):]))
        return 0

    path = transcript_of(dst)
    if not path or not os.path.exists(path):
        # No transcript means no record and no registration, so fall back rather
        # than fail — but say which source is being shown, since they differ.
        if not dst.get("win"):
            die(f"slot {dst['slot']} has neither a transcript nor a pane to read")
        print(f"{head}  [no transcript — falling back to pane {dst['win']} screen] ──")
        txt = pane_screen(dst["win"])
        print("\n".join(ln.rstrip() for ln in txt.splitlines() if ln.strip())[-4000:])
        return 0

    turns = transcript_turns(transcript_entries(path), sidechain="--sidechain" in flags)
    if not turns:
        print(f"{head}  [transcript has no conversation yet] ──")
        return 0

    print(f"{head}  [transcript, last {min(n, len(turns))} of {len(turns)} turns] ──")
    for speaker, text in turns[-n:]:
        body = text.strip()
        if speaker == "tool":
            print(f"{'→':>{SPEAKER_WIDTH}} {trunc(body, 100)}")
            continue
        lines = [ln for ln in body.splitlines()]
        print(f"{speaker + ':':>{SPEAKER_WIDTH}} {lines[0] if lines else ''}")
        for ln in lines[1:]:
            print(f"{'':>{SPEAKER_WIDTH}} {ln}")
    return 0


def cmd_focus(argv: list[str]) -> int:
    if not argv:
        die("usage: cx focus <slot|name>")
    dst = require_pane(resolve(argv[0]))
    kitty("focus-window", "--match", f"id:{dst['win']}")
    print(f"cx: focused slot {dst['slot']} (win {dst['win']})")
    return 0


def cmd_name(argv: list[str]) -> int:
    if len(argv) != 2:
        die("usage: cx name <slot|name|wID> <new-name>")
    dst = resolve(argv[0])
    new = argv[1]
    reg = registry()
    rec = reg.get(dst["win"]) or {
        "kitty_window_id": dst["win"],
        "session_id": "",
        "cwd": dst["cwd"],
        "started": int(time.time()),
    }
    taken = {r.get("name") for w, r in reg.items() if w != dst["win"]}
    if new in taken:
        die(f"name '{new}' already used by another pane")
    rec["name"] = new
    rec.setdefault("slot", dst["slot"])
    write_record(rec)
    # Deliberately not touching the kitty window title: kitty-agent-title owns
    # it (it re-renders "C <repo>/<branch> <state>" on every hook event and sets
    # it permanently), so anything cx wrote there would be overwritten within
    # seconds. The name lives in the registry and shows up in `cx ls`.
    print(f"cx: slot {rec['slot']} (win {dst['win']}) is now '{new}'")
    return 0


def cmd_me(argv: list[str]) -> int:
    rows = roster()
    me = self_row(rows)
    if not me:
        die("cannot identify this pane (KITTY_WINDOW_ID unset and `kitty @ ls --self` failed)")
    print(f"slot={me['slot']} name={me['name'] or '-'} win={me['win']} "
          f"session={me['session_id'] or '-'} cwd={me['cwd']}")
    return 0


def cmd_register(argv: list[str]) -> int:
    """SessionStart hook entry point. Reads Claude's hook JSON on stdin.

    Always exits 0: a registration failure must never block a Claude session
    from starting.
    """
    try:
        payload = json.load(sys.stdin) if not sys.stdin.isatty() else {}
    except (ValueError, OSError):
        payload = {}
    wid = os.environ.get("KITTY_WINDOW_ID")
    if not (wid and wid.isdigit()):
        return 0  # not in kitty; nothing to register against
    wid_i = int(wid)
    reg = registry()
    rec = reg.get(wid_i, {})
    cwd = payload.get("cwd") or os.getcwd()
    slot = rec.get("slot")
    if slot is None:
        used = {r.get("slot") for r in reg.values()}
        slot = next(i for i in range(1, 1000) if i not in used)
    name = rec.get("name")
    if not name:
        # A launcher that already knows what this pane is says so via CX_NAME
        # (kitty-grid passes `--env CX_NAME=<label>-<i>`). Preferred over guessing
        # from cwd, which names every pane of a grid launched in $HOME the same
        # thing and then separates them by a collision counter — so the suffix
        # ends up counting name clashes rather than panes, and never lines up with
        # the pane number the grid actually shows.
        base = os.environ.get("CX_NAME", "").strip()
        if base:
            base = re.sub(r"[^A-Za-z0-9_.-]+", "-", base)[:40]
        else:
            base = re.sub(r"[^A-Za-z0-9_.-]+", "-", os.path.basename(cwd.rstrip("/")) or "session")
        taken = {r.get("name") for w, r in reg.items() if w != wid_i}
        name, n = base, 2
        while name in taken:
            name, n = f"{base}-{n}", n + 1
    write_record(
        {
            "kitty_window_id": wid_i,
            "slot": slot,
            "name": name,
            "session_id": payload.get("session_id", ""),
            "transcript": payload.get("transcript_path", ""),
            "cwd": cwd,
            "started": rec.get("started") or int(time.time()),
        }
    )
    return 0


def cmd_unregister(argv: list[str]) -> int:
    """SessionEnd hook entry point. Drops this pane's registration, then collects.

    Collecting here is what keeps the state directory bounded without a cron job or
    a daemon: session end is the moment something definitely became collectable,
    it happens once per session rather than once per tool call, and nothing is
    waiting on the result. Never allowed to fail the hook.
    """
    wid = os.environ.get("KITTY_WINDOW_ID")
    if wid and wid.isdigit():
        drop_record(int(wid))
    try:
        _STATUS_CACHE_RESET()
        cmd_gc(["--quiet"])
    except Exception:
        pass
    return 0


def _STATUS_CACHE_RESET() -> None:
    global _STATUS_CACHE
    _STATUS_CACHE = None


# A session that fired SessionEnd is definitively gone, so its record only needs
# to outlive "what was that pane doing just now?".
KEEP_ENDED = 3600
# A record in any other state means the process died without firing SessionEnd, so
# there is no positive statement that it is gone — give it much longer before
# assuming so. Both bounds exist because every `cx ls` reads this whole directory.
KEEP_ORPHANED = 24 * 3600
# Queued messages for a session that never came back. Beyond this they will not be
# wanted even if it does.
KEEP_QUEUED = 7 * 24 * 3600


def cmd_gc(argv: list[str]) -> int:
    """Drop stale pane registrations, state records and queued messages.

    State records are written per session, not per pane, so they accumulate one
    file per session forever unless pruned — and `status_records()` reads the whole
    directory on every roster. A record is dead when its session has ended (or has
    not been heard from in a long time) AND no live pane claims it.
    """
    now = time.time()
    dry = "--dry-run" in argv or "-n" in argv

    rows = roster(claude_only=False)
    live_wins = {r["win"] for r in rows}
    live_sids = {r["session_id"] for r in rows if r.get("session_id")}

    dropped_panes = [w for w in registry() if w not in live_wins]
    if not dry:
        for w in dropped_panes:
            drop_record(w)

    dropped_state = []
    for sid, rec in status_records().items():
        if sid in live_sids:
            continue
        age = now - rec.get("ts", 0)
        limit = KEEP_ENDED if rec.get("state") == "ended" else KEEP_ORPHANED
        if age > limit:
            dropped_state.append(sid)
            if not dry:
                try:
                    os.remove(os.path.join(STATUS_DIR, f"{sid}.json"))
                except OSError:
                    pass

    dropped_inbox = []
    try:
        inbox_sids = os.listdir(INBOX_DIR)
    except OSError:
        inbox_sids = []
    for sid in inbox_sids:
        d = os.path.join(INBOX_DIR, sid)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        if not names:
            if not dry:
                try:
                    os.rmdir(d)
                except OSError:
                    pass
            continue
        for fn in names:
            p = os.path.join(d, fn)
            try:
                if now - os.path.getmtime(p) > KEEP_QUEUED:
                    dropped_inbox.append(f"{sid[:8]}/{fn}")
                    if not dry:
                        os.remove(p)
            except OSError:
                pass

    if "--quiet" not in argv:
        prefix = "would drop" if dry else "dropped"
        print(f"cx: {prefix} {len(dropped_panes)} pane registration(s), "
              f"{len(dropped_state)} state record(s), "
              f"{len(dropped_inbox)} queued message(s)")
    return 0


def cmd_help(argv: list[str]) -> int:
    print(__doc__.strip())
    print(
        "\ncommands:\n"
        "  ls [--all] [-q]           roster + live status (--all: non-Claude panes too)\n"
        "  send <who> <msg...>       type a message into that pane and submit it\n"
        "  ask <who> <q> [--timeout S]  ask and block for the answer (default 300s)\n"
        "  answer <req-id> <text>    answer a request you were asked (receiver side)\n"
        "  answers <req-id>          print an answer that arrived after a timeout\n"
        "  inbox                     list requests and whether they're answered\n"
        "  bcast <msg...>            send to every pane but this one\n"
        "  peek <who> [n] [--all]    print that pane's last n lines (--all: scrollback)\n"
        "  focus <who>               jump kitty focus there\n"
        "  name <who> <new>          (re)name a pane in the registry\n"
        "  me                        this pane's slot/name/session id\n"
        "  gc                        forget registry entries for dead panes\n"
        "\n<who> is a slot number, a name, a name substring, or w<kitty-window-id>."
    )
    return 0


COMMANDS = {
    "ls": cmd_ls, "list": cmd_ls,
    "send": cmd_send, "msg": cmd_send, "tell": cmd_send,
    "ask": cmd_ask, "answer": cmd_answer, "answers": cmd_answers, "inbox": cmd_inbox,
    "bcast": cmd_bcast, "broadcast": cmd_bcast,
    "peek": cmd_peek, "read": cmd_peek,
    "focus": cmd_focus, "go": cmd_focus,
    "name": cmd_name, "rename": cmd_name,
    "me": cmd_me, "whoami": cmd_me,
    "register": cmd_register, "unregister": cmd_unregister,
    "drain": cmd_drain,
    "gc": cmd_gc,
    "help": cmd_help, "-h": cmd_help, "--help": cmd_help,
}


def main(argv: list[str]) -> int:
    if not argv:
        return cmd_ls([])
    cmd, rest = argv[0], argv[1:]
    fn = COMMANDS.get(cmd)
    if fn is None:
        die(f"unknown command '{cmd}' (try `cx help`)")
    return fn(rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
