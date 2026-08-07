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

Status is read off the pane's own screen, since Claude Code's TUI is the
only thing that knows whether it is thinking: "esc to interrupt" => running,
a permission prompt => waiting (the state worth surfacing when you have nine
panes and can only look at one).
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
    rows: list[dict] = []
    for os_win in kitty_tree():
        for tab in os_win["tabs"]:
            for win in tab["windows"]:
                wid = win["id"]
                rec = reg.get(wid)
                pid = claude_pid_in_pane(win)
                if claude_only and rec is None and pid is None:
                    continue
                rows.append(
                    {
                        "win": wid,
                        "pid": pid,
                        "tab": tab["id"],
                        "tab_title": tab.get("title") or "",
                        "os_win": os_win["id"],
                        "title": win.get("title") or "",
                        "cwd": rec.get("cwd") if rec else win.get("cwd") or "",
                        "name": (rec or {}).get("name") or "",
                        "slot": (rec or {}).get("slot"),
                        "session_id": (rec or {}).get("session_id") or "",
                        "registered": rec is not None,
                        "self": bool(win.get("is_self")),
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


def status_of(win_id: int) -> tuple[str, str]:
    """(status, last line of real content on the pane's screen)."""
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
        st, last = status_of(r["win"])
        mark = "*" if me and r["win"] == me["win"] else " "
        cwd = r["cwd"].replace(os.path.expanduser("~"), "~")
        name = (r["name"] or r["title"] or "-") + ("" if r["registered"] else "~")
        print(
            f"{mark:2}{r['slot']:>4}  {trunc(name, 22):<22} {r['win']:>4} {st:<8} "
            f"{trunc(cwd, 24, left=True):<24} {trunc(last, 44)}"
        )
    print("\n  * = this pane   ~ = unregistered (run cx-install-hooks so panes self-name)")
    return 0


def cmd_send(argv: list[str]) -> int:
    if len(argv) < 2:
        die("usage: cx send <slot|name> <message...>")
    target, msg = argv[0], " ".join(argv[1:])
    rows = roster()
    dst = resolve(target, rows)
    me = self_row(rows)
    if me and dst["win"] == me["win"]:
        die("refusing to send to this same pane")
    who = (me["name"] or f"slot{me['slot']}") if me else "cx"
    # No brackets in the prefix: if the target pane happens to be a bare shell
    # rather than a Claude TUI, `[cx ...]` is a zsh glob and the line dies with
    # "bad pattern" instead of showing up.
    text = f"cx/{who}: {msg}"
    # Text and Enter go as separate writes: the TUI needs a beat to ingest a
    # long line before the submit, otherwise the tail of the message lands
    # after the newline and gets sent as a second prompt.
    kitty("send-text", "--match", f"id:{dst['win']}", "--", text)
    time.sleep(0.2)
    kitty("send-text", "--match", f"id:{dst['win']}", "--", "\r")
    print(f"cx: sent to slot {dst['slot']} ({dst['name'] or dst['title']}, win {dst['win']})")
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
    dst = resolve(target, rows)
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


def cmd_peek(argv: list[str]) -> int:
    if not argv:
        die("usage: cx peek <slot|name> [lines] [--all]")
    extent = "all" if "--all" in argv else "screen"
    argv = [a for a in argv if a != "--all"]
    n = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 40
    dst = resolve(argv[0])
    txt = pane_screen(dst["win"], extent=extent)
    lines = [ln.rstrip() for ln in txt.splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    print(f"--- slot {dst['slot']} ({dst['name'] or dst['title']}) win {dst['win']} ---")
    print("\n".join(lines[-n:]))
    return 0


def cmd_focus(argv: list[str]) -> int:
    if not argv:
        die("usage: cx focus <slot|name>")
    dst = resolve(argv[0])
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
    wid = os.environ.get("KITTY_WINDOW_ID")
    if wid and wid.isdigit():
        drop_record(int(wid))
    return 0


def cmd_gc(argv: list[str]) -> int:
    """Drop registry entries whose kitty pane is gone."""
    live = {r["win"] for r in roster(claude_only=False)}
    dropped = [w for w in registry() if w not in live]
    for w in dropped:
        drop_record(w)
    print(f"cx: dropped {len(dropped)} stale entr{'y' if len(dropped) == 1 else 'ies'}")
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
