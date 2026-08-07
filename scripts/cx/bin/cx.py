#!/usr/bin/env python3
"""cx — cross-Claude session comms over kitty remote control.

Gives every Claude Code session in a kitty pane an addressable name, so one
Claude can be told to talk to another — or to a whole grid at once:

    cx ls                          # roster with live status
    cx ls 'build.*'                # just that grid
    cx send build.3 "rebase onto main"
    cx send 'build.*' "pull main"   # every pane in the grid
    cx peek build.3                 # read its conversation
    cx focus build.3

Identity model
--------------
Panes are named as NATS subjects, coarse to fine:

    <host>.<label>.<index>      mpcqpq6qlm.build.3
    <label>.<index>             build.3     (same pane, from its own host)

`*` matches one token and `>` matches the rest, exactly as in NATS, so
`build.*` is one grid, `*.1` is the first pane of every grid, and `>` is
everything. NATS ordering rather than DNS's because these strings become real
NATS subjects when delivery goes cross-machine, and reversing them then would
mean two orderings for one identity.

One Claude per kitty pane, so the kitty *window id* is the durable key. A
SessionStart hook (cx-register) drops a JSON file per pane under
$CX_STATE_DIR/panes/<kitty_window_id>.json holding the subject, the Claude
session_id, cwd and a slot number. The slot is only a short integer to type;
it is unique per machine and so cannot line up with a per-grid index.
Registration is best-effort: panes with no registry file still show up in
`cx ls`, discovered from kitty's process table, they just lack a session_id.
Nothing here depends on the hook being installed.

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


# --------------------------------------------------------------------------
# subjects
# --------------------------------------------------------------------------
# Panes are named as NATS subjects: <host>.<label>.<index>, coarse to fine.
#
#   mpcqpq6qlm.fin.2      a pane, fully qualified
#   fin.2                 the same pane, written from its own host
#
# Coarse-to-fine (NATS) rather than fine-to-coarse (DNS) because these strings
# become real NATS subjects when delivery goes cross-machine — cx.<host>.<label>.
# <index>.inbox — and reversing them at that point would mean two orderings for
# one identity.
#
# Depth is always three tokens, including for a lone pane that is not part of a
# grid, so `*` means the same thing at every position and `fin.*` cannot
# accidentally match a differently-shaped name.

def host_token() -> str:
    h = os.environ.get("CX_HOST") or ""
    if not h:
        try:
            h = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
        except OSError:
            h = ""
    return token(h or "unknown")


def token(s: str) -> str:
    """Sanitise one subject token. Dots separate tokens, so they cannot occur."""
    return re.sub(r"[^a-z0-9_-]+", "-", (s or "").strip().lower()).strip("-") or "x"


def subject_of(label: str, index: int, host: str = "") -> str:
    return f"{host or host_token()}.{token(label)}.{index}"


def short_subject(subject: str) -> str:
    """Drop the host token when it is this machine's, for display and typing."""
    parts = subject.split(".", 1)
    if len(parts) == 2 and parts[0] == host_token():
        return parts[1]
    return subject


def subject_re(pattern: str) -> re.Pattern:
    """Compile a NATS-style subject pattern.

    `*` matches exactly one token, `>` matches one or more trailing tokens — the
    same meanings NATS gives them, so a pattern that works here works there.
    """
    out = []
    parts = pattern.split(".")
    for i, p in enumerate(parts):
        if p == ">":
            if i != len(parts) - 1:
                die("'>' may only appear as the last token of a subject pattern")
            out.append(r".+")
            break
        out.append(r"[^.]+" if p == "*" else re.escape(p))
    return re.compile(r"^" + r"\.".join(out) + r"$")


def subject_matches(pattern: str, subject: str) -> bool:
    """Match a pattern against a subject, with or without its host token.

    Both forms are tried so `fin.*` works from the pane's own host without having
    to spell the hostname, while `mpcqpq6qlm.fin.*` still addresses it explicitly.
    """
    rx = subject_re(pattern)
    return bool(rx.match(subject) or rx.match(short_subject(subject)))


def is_pattern(s: str) -> bool:
    return "*" in s or ">" in s


# --------------------------------------------------------------------------
# hierarchy
# --------------------------------------------------------------------------
# The subject tree is also the authority tree: a subject's parent is its prefix,
# so `proj` is above `proj.api`, which is above `proj.api.3`.
#
# Which directions are permitted is policy, set by CX_POLICY (or ~/.claude/cx/policy):
#
#   down-siblings  (default) down to any descendant, sideways to a same-parent
#                  sibling. Never up, never to a cousin. Parent->child->parent
#                  cannot cycle; siblings still can, which is why the rate cap stays.
#   down-replies   down to any descendant, and up ONLY as a reply to a request that
#                  session actually received. Cycles need a pending request, and a
#                  request is consumed when answered.
#   down           strictly down. Provably acyclic; `cx ask` cannot return an answer.
#   open           no restriction (how cx behaved before this existed).
#
# The host token is a location, not a level, so it is stripped before comparing;
# two subjects on different hosts are only related if their paths are.

POLICIES = ("down-siblings", "down-replies", "down", "open")

# Sibling chat is the one direction `down-siblings` leaves open, and two siblings
# replying to each other is a cycle. The rate cap bounds that at 20 exchanges per
# five minutes, which is a lot of unattended tokens.
#
# So an immediate reciprocation is refused as well: if A messaged B recently, B may
# not message A back within this window unless A has an unanswered request open to
# B (i.e. A asked for a reply). Tight ping-pong becomes
# impossible while request/reply and ordinary one-way traffic still work.
RECIPROCAL_WINDOW = 90
SENT_DIR = os.path.join(STATE_DIR, "sent")

# The reciprocation check above only sees a two-node loop. A ring of three walks
# straight through it: g.1 -> g.2 -> g.3 -> g.1 repeats forever, every hop legal,
# because no pair ever sends straight back. Measured: nine consecutive hops allowed.
#
# So the causal PATH is carried instead. Delivering a message records, against the
# receiving session, the chain of subjects that led to it. When that session sends,
# it inherits the chain: a target already in the chain closes a cycle of any length
# and is refused, and a chain longer than MAX_CHAIN is refused whatever its shape.
#
# This needs no cooperation from the model — cx writes the chain at delivery time,
# so it cannot be dropped by a session that never mentions it. The chain expires
# with CAUSE_TTL so an unrelated later conversation starts clean.
MAX_CHAIN = 6
CAUSE_TTL = 600
CAUSE_DIR = os.path.join(STATE_DIR, "cause")


def write_cause(session_id: str, chain: list[str]) -> None:
    """Record the chain of subjects that caused session_id's next turn."""
    if not session_id:
        return
    try:
        os.makedirs(CAUSE_DIR, exist_ok=True)
        safe = re.sub(r"[^A-Za-z0-9-]+", "-", session_id)[:80]
        tmp = os.path.join(CAUSE_DIR, f".{safe}.{os.getpid()}")
        with open(tmp, "w") as fh:
            json.dump({"chain": chain[-MAX_CHAIN:], "ts": time.time()}, fh)
        os.replace(tmp, os.path.join(CAUSE_DIR, safe))
    except OSError:
        pass


def read_cause(session_id: str) -> list[str]:
    """The chain that led to this session's current activity, if still fresh."""
    if not session_id:
        return []
    safe = re.sub(r"[^A-Za-z0-9-]+", "-", session_id)[:80]
    try:
        with open(os.path.join(CAUSE_DIR, safe)) as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return []
    if time.time() - rec.get("ts", 0) > CAUSE_TTL:
        return []
    return [c for c in rec.get("chain", []) if isinstance(c, str)]


def chain_id(row: dict) -> str:
    """How a pane is identified inside a causal chain.

    Its subject when it has one, otherwise its session id. The fallback matters:
    the hierarchy deliberately exempts subject-less panes so an agent can reach the
    operator, and without an identity here two such panes could ping-pong with no
    check at all — verified before this existed.
    """
    subj = short_subject(row.get("subject") or "")
    if subj:
        return subj
    sid = row.get("session_id") or ""
    return f"sid:{sid[:8]}" if sid else ""


def chain_check(chain: list[str], target: str) -> tuple[bool, str]:
    """(allowed, reason) for extending a causal chain to `target`."""
    if not target:
        return True, ""
    short = short_subject(target)
    # `chain` ends with this session, so the pane that messaged it is chain[-2].
    #
    # Replying to whoever just messaged you is a conversation, not a ring, and
    # blocking it broke the commonest flow there is: sending an agent a question and
    # getting an answer. Two-node back-and-forth is governed by the reciprocation
    # window and the rate cap instead; this check exists for the rings those cannot
    # see, so it ignores the immediate sender and looks only further back.
    if len(chain) >= 2 and short == short_subject(chain[-2]):
        return True, "reply to the immediate sender"
    if short in [short_subject(c) for c in chain[:-2]]:
        return False, (
            f"'{short}' is already in this message chain "
            f"({' -> '.join(short_subject(c) for c in chain)} -> {short}) — that closes a "
            f"loop, so it is refused whatever the ring size"
        )
    if len(chain) >= MAX_CHAIN:
        return False, (
            f"this message is {len(chain)} hops deep "
            f"({' -> '.join(short_subject(c) for c in chain[:3])}...) — refusing to extend "
            f"a chain past {MAX_CHAIN}"
        )
    return True, ""


def record_send(sender: str, target: str) -> None:
    """Note that sender messaged target, for the reciprocation check."""
    if not (sender and target):
        return
    try:
        os.makedirs(SENT_DIR, exist_ok=True)
        key = f"{token(short_subject(sender))}__{token(short_subject(target))}"
        with open(os.path.join(SENT_DIR, key), "w") as fh:
            fh.write(f"{time.time():.3f}\n")
    except OSError:
        pass


def sent_recently(sender: str, target: str) -> float:
    """Seconds since sender last messaged target, or -1 if never/too old."""
    if not (sender and target):
        return -1
    key = f"{token(short_subject(sender))}__{token(short_subject(target))}"
    try:
        with open(os.path.join(SENT_DIR, key)) as fh:
            age = time.time() - float(fh.read().strip())
    except (OSError, ValueError):
        return -1
    return age if age < RECIPROCAL_WINDOW else -1


def policy() -> str:
    """Active hierarchy policy: CX_POLICY, else a policy file, else the default."""
    p = (os.environ.get("CX_POLICY") or "").strip().lower()
    if not p:
        try:
            with open(os.path.join(STATE_DIR, "policy")) as fh:
                p = fh.read().strip().lower()
        except OSError:
            p = ""
    if p and p not in POLICIES:
        die(f"unknown CX_POLICY '{p}' (choose one of: {', '.join(POLICIES)})")
    return p or "down-siblings"


def subject_path(subject: str) -> list[str]:
    """The hierarchy part of a subject: its tokens with the host removed."""
    parts = subject.split(".")
    if parts and parts[0] == host_token():
        parts = parts[1:]
    return [p for p in parts if p]


def hierarchy_check(sender: str, target: str, replying: bool = False) -> tuple[bool, str]:
    """(allowed, reason) under the active policy.

    A missing sender subject is treated as the root. An unregistered pane — an
    operator's own shell, or a session that started before the hooks — has no
    subject and therefore no place in the tree; refusing it would lock the human
    driving things out of their own grid.
    """
    pol = policy()
    if pol == "open":
        return True, "no restriction"
    # A pane with no subject is outside the tree, not above or below it: an
    # operator's own shell, or a session predating the hooks. Both directions are
    # permitted, deliberately — an agent has to be able to report to the human, and
    # the human has to be able to drive their own grid. This is the one hole in the
    # policy, so it is stated rather than left to be discovered: registering that
    # pane (giving it a subject) brings it under the rules.
    if not sender:
        return True, "sender is outside the subject tree (treated as operator)"
    if not target:
        return True, "target is outside the subject tree (treated as operator)"
    s, t = subject_path(sender), subject_path(target)
    if not s or not t:
        return True, ""
    if s == t:
        return False, "that is this same session"

    if t[: len(s)] == s:
        return True, "descendant"
    if pol == "down-siblings" and len(s) == len(t) and s[:-1] == t[:-1]:
        # Refuse to complete a tight loop: the target messaged us moments ago and
        # did not ask a question, so sending back would start a ping-pong that only
        # the rate cap would stop.
        age = sent_recently(target, sender)
        if age >= 0 and not replying:
            return False, (
                f"'{'.'.join(t)}' messaged this session {int(age)}s ago and has no open "
                f"request — refusing to send straight back, which is how two siblings "
                f"start a loop. Wait {int(RECIPROCAL_WINDOW - age)}s, use `cx ask` if you "
                f"need an answer"
            )
        return True, "sibling"
    if pol == "down-replies" and replying and s[: len(t)] == t:
        return True, "reply to an open request"

    if s[: len(t)] == t:
        return False, (f"'{'.'.join(t)}' is above '{'.'.join(s)}' — policy '{pol}' does "
                       f"not allow messaging a parent"
                       + (" except as a reply to an open request"
                          if pol == "down-replies" else ""))
    if len(s) == len(t) and s[:-1] == t[:-1]:
        return False, (f"'{'.'.join(t)}' is a sibling of '{'.'.join(s)}' — policy "
                       f"'{pol}' allows only downward messages")
    return False, (f"'{'.'.join(t)}' is neither below '{'.'.join(s)}' nor a permitted "
                   f"peer under policy '{pol}'")


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


def window_exists(win_id: int) -> bool:
    return bool(kitty("ls", "--match", f"id:{win_id}", check=False).strip())


def _paste_and_submit(win_id: int, text: str) -> None:
    """The two raw writes. Callers must already hold the pane's send lock."""
    subprocess.run(
        [kitty_bin(), "@", "send-text", "--match", f"id:{win_id}",
         "--bracketed-paste", "auto", "--stdin"],
        input=text, text=True, capture_output=True,
    )
    # Enter goes as its own write. The paste above is a single unit to the TUI, so
    # no sleep is needed between them — the guessed delay this replaces was only
    # ever compensating for keystroke-by-keystroke delivery.
    kitty("send-text", "--match", f"id:{win_id}", "--", "\\r", check=False)


def input_line_text(win_id: int) -> str:
    """Whatever is currently typed on the pane's live prompt line."""
    for line in reversed(pane_screen(win_id).splitlines()):
        s = line.strip()
        if s.startswith("❯"):
            return s.lstrip("❯").strip()
    return ""


def input_line_holds(win_id: int, needle: str) -> bool:
    """Is `needle` sitting on the pane's LIVE prompt line, i.e. pasted but not sent?

    Claude Code's prompt renders as "❯ <text>", and a prompt that was submitted
    stays on screen looking exactly the same. Only the bottom-most one is the live
    input line, so only that one may be tested: scanning every "❯" line finds the
    echo of a message that DID submit and reports it as stranded, which delivered it
    twice — once typed, once from the queue.
    """
    for line in reversed(pane_screen(win_id).splitlines()):
        s = line.strip()
        if s.startswith("❯"):
            return needle in s
    return False


def deliver(dst: dict, text: str, msg: str, sid: str, who: str) -> str:
    """Deliver one message to one pane. Returns "typed" or "queued".

    Whether a pane is ready cannot be checked BEFORE writing. The state record only
    updates when the target's own hook fires, so senders milliseconds apart all read
    the stale "idle" and all type: measured with four concurrent sends, one became a
    turn immediately and three sat as unsubmitted text on the prompt line. Locking
    alone does not help, because the lag outlives the lock.

    Those three were NOT lost — Claude Code buffers input typed mid-turn and submits
    it once the turn ends, and every one of 21 test messages did eventually reach its
    target. What is wrong is that arrival becomes unbounded and unordered, and a
    message can sit visible-but-unsent for as long as the turn runs. Queueing makes
    delivery a contract (a Stop hook returning it as a turn) instead of text left on
    a prompt line hoping to be submitted.

    So the POST-condition is checked instead, which needs no guess about timing: if
    the text is still on the prompt line afterwards, the Enter did not take. That
    text is then cleared (ctrl-U) and the message is queued for the Stop hook, which
    is a real channel into the session rather than keystrokes aimed at a TUI.
    """
    if not dst["win"]:
        enqueue(sid, who, msg)
        return "queued"

    # A short, distinctive slice of the message — enough to recognise on the prompt
    # line, short enough to survive the pane being narrow enough to wrap.
    needle = " ".join(msg.split())[:24]

    with file_lock(f"send-{dst['win']}", timeout=5.0):
        # Pasting appends to whatever is already on the prompt line. A pane holding
        # a half-typed line turned "cx/a: hello" into "leecx/a: hello" — the message
        # corrupted and the draft submitted with it. Clearing first would destroy
        # someone's half-written prompt instead, so a busy input line means queue.
        pending_text = input_line_text(dst["win"])
        if pending_text and sid:
            enqueue(sid, who, msg)
            return "queued"
        _paste_and_submit(dst["win"], text)
        stranded = needle and input_line_holds(dst["win"], needle)
        if stranded:
            # ctrl-U clears the line, so the failed attempt is not left for the user
            # to submit later out of context, or prepended to whatever they type.
            kitty("send-text", "--match", f"id:{dst['win']}", "--", "\\x15", check=False)

    if not window_exists(dst["win"]):
        if sid:
            enqueue(sid, who, msg)
            return "queued"
        die(f"win {dst['win']} disappeared while sending — message lost")
    if stranded:
        if not sid:
            die(f"win {dst['win']} did not accept the message (it is mid-turn) and has "
                f"no session id to queue against")
        enqueue(sid, who, msg)
        return "queued"
    return "typed"


def type_into(win_id: int, text: str) -> bool:
    """Paste text into a pane and submit it, as a user pressing Enter would.

    Returns whether the pane was still there afterwards. kitty documents that
    send-text "always succeeds, even if no text was sent to any window", so its
    exit status proves nothing — a pane closing between resolving the roster and
    writing to it would otherwise be reported as a successful send.

    Two details of the write itself, both learned the hard way:

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
    # Locked per target pane, because the paste and the Enter are two separate
    # writes and the pair is not atomic. Two senders hitting one pane at the same
    # moment interleave between them, so both pastes land on one input line and
    # submit as a single turn — observed as
    #   "cx/a: MSG-ALPHA...cx/a: MSG-BRAVO..."
    # which loses a message. Bracketed paste makes each paste atomic; only a lock
    # makes the paste-then-submit sequence atomic.
    with file_lock(f"send-{win_id}", timeout=5.0):
        _paste_and_submit(win_id, text)
    # Checking the pane still exists is the strongest cheap confirmation available.
    # Reading the screen back would be stronger but is unreliable: by the time it
    # could be read the TUI has usually submitted and cleared the input line.
    return window_exists(win_id)


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


class file_lock:
    """A cross-process lock, used for the two things here that are not atomic.

    O_EXCL creation is the lock: atomic on every filesystem that matters here,
    needs no library, and leaves a file whose mtime says when it was taken so a
    crashed holder cannot wedge things forever.

    Both callers must degrade rather than fail — registration must never block a
    session from starting, and a send must never be dropped just because a lock was
    contended — so timing out proceeds unlocked instead of raising.
    """

    def __init__(self, name: str = "register", timeout: float = 2.0):
        self.path = os.path.join(STATE_DIR, f"{name}.lock")
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        deadline = time.time() + self.timeout
        while True:
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > 10:
                        os.unlink(self.path)  # stale: holder died mid-registration
                        continue
                except OSError:
                    pass
                if time.time() > deadline:
                    # Registration must never block a session from starting, so give
                    # up and proceed unlocked rather than fail the hook.
                    return self
                time.sleep(0.02)

    def __exit__(self, *exc):
        if self.fd is not None:
            os.close(self.fd)
            try:
                os.unlink(self.path)
            except OSError:
                pass
        return False


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
                        "subject": (rec or {}).get("subject") or (st or {}).get("subject") or "",
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
                "subject": st.get("subject") or "",
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


def self_label(rows: list[dict] | None = None) -> str:
    """How this pane names itself when sending. Its subject if it has one."""
    me = self_row(rows)
    if not me:
        return "cx"
    return short_subject(me.get("subject") or "") or me["name"] or f"slot{me['slot']}"


def resolve_all(who: str, rows: list[dict] | None = None) -> list[dict]:
    """Every roster row addressed by `who`, which may be a subject pattern.

    Patterns (`fin.*`, `>`) are what makes a group addressable without a separate
    broadcast command; everything else resolves to at most one row, as before.
    """
    rows = rows if rows is not None else roster()
    if not rows:
        die("no Claude panes found (is remote control on, and are the panes running claude?)")
    if is_pattern(who):
        hits = [r for r in rows if r.get("subject") and subject_matches(who, r["subject"])]
        if not hits:
            die(f"no pane matching subject pattern '{who}' (see `cx ls`)")
        return hits
    return [resolve(who, rows)]


def resolve(who: str, rows: list[dict] | None = None) -> dict:
    """Resolve a slot number, subject, name, or kitty win id (w<N>) to one row."""
    rows = rows if rows is not None else roster()
    if not rows:
        die("no Claude panes found (is remote control on, and are the panes running claude?)")
    if is_pattern(who):
        hits = resolve_all(who, rows)
        if len(hits) > 1:
            names = ", ".join(short_subject(h.get("subject") or "") or h["name"] for h in hits)
            die(f"'{who}' matches {len(hits)} panes ({names}) — "
                f"that is allowed for send, not for this command")
        return hits[0]
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
    # Exact subject, in either the full or host-less form, before any fuzzy match:
    # a subject is a precise address and must never be treated as a substring.
    for r in rows:
        subj = r.get("subject") or ""
        if subj and who in (subj, short_subject(subj)):
            return r
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
    pattern = next((a for a in argv if not a.startswith("-")), "")
    rows = roster(claude_only=not show_all)
    if pattern:
        # Accept a subject pattern so a grid can be listed on its own: `cx ls 'fin.*'`.
        rows = [r for r in rows
                if r.get("subject") and subject_matches(pattern, r["subject"])]
        if not rows:
            print(f"cx: no pane matching '{pattern}'", file=sys.stderr)
            return 1
    if not rows:
        print("cx: no Claude panes found", file=sys.stderr)
        return 1
    me = self_row(rows)
    if quiet:
        for r in rows:
            subj = short_subject(r.get("subject") or "") or r["name"] or r["title"]
            print(f"{r['slot']}\t{subj}\t{r['win']}\t{r['cwd']}")
        return 0
    print(f"{'':2}{'SLOT':>4}  {'SUBJECT':<22} {'WIN':>4} {'STATUS':<8} {'CWD':<24} LAST")
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
        # Show the subject, host token dropped when local; fall back to the old
        # name or the pane title for anything not registered under one.
        subj = short_subject(r.get("subject") or "")
        name = (subj or r["name"] or r["title"] or "-") + ("" if r["registered"] else "~")
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


def deliver_to(dst: dict, msg: str, who: str, force_queue: bool = False,
               label: str = "") -> int:
    """Put one message in front of one pane, and say how it got there.

    Shared by the single-target and pattern paths so that neither can drift from
    the other — `cx ask` having kept its own copy of delivery is exactly how it
    ended up exempt from every guard.

    Assumes the caller has already run guard_send for this target.
    """
    sid = dst.get("session_id") or ""
    label = label or f"slot {dst['slot']} ({dst['name'] or dst['title'] or '?'})"
    text = f"cx/{who}: {msg}"

    # An explicit --queue, or no pane to type into, is decided here. Everything else
    # goes through deliver(), which re-checks busy-ness INSIDE the pane's send lock —
    # the check cannot be made out here, because concurrent senders would all read
    # "idle" before any of them writes.
    if sid and (force_queue or not dst["win"]):
        enqueue(sid, who, msg)
        pending = len(os.listdir(inbox_path(sid)))
        why = "queued" if force_queue else "no pane"
        print(f"cx: {label} {why} — queued, delivered on its next Stop "
              f"({pending} pending)")
        return 0

    require_pane(dst)
    if deliver(dst, text, msg, sid, who) == "queued":
        pending = len(os.listdir(inbox_path(sid))) if sid else 0
        print(f"cx: {label} was busy — queued, delivered on its next Stop "
              f"({pending} pending)")
    else:
        print(f"cx: typed into {label}, win {dst['win']}")
    return 0


def guard_send(rows: list[dict], dst: dict, label: str) -> None:
    """Every check that must pass before one session may message another.

    Factored out because `cx ask` had its own delivery path and so was subject to
    none of them: under policy 'down' a sibling `cx send` was refused while the same
    pair's `cx ask` returned 0, which made the policy and the loop guards optional
    for anyone who reached for ask. Any future path that delivers to a pane belongs
    here too.

    There is deliberately no per-call override. A flag any sender can append makes
    every check advisory — an agent that hits a refusal simply retries with it, which
    is exactly the runaway this exists to stop. Widening what is permitted is
    `cx policy`: explicit, global, and visible in `cx policy` output afterwards.

    Dies on refusal; returns None when the send may proceed.
    """
    me_row = self_row(rows) or {}
    me_subj = me_row.get("subject") or ""
    dst_subj = dst.get("subject") or ""

    ok, why = hierarchy_check(
        me_subj, dst_subj, replying=has_open_request(dst_subj, me_subj)
    )
    if not ok:
        die(f"refusing to send to {label}: {why}. "
            f"Widen this with `cx policy <name>` if it is deliberate.")

    me_id, dst_id = chain_id(me_row), chain_id(dst)
    chain = read_cause(me_row.get("session_id") or "") + ([me_id] if me_id else [])
    ok, why = chain_check(chain, dst_id)
    if not ok:
        die(f"refusing to send to {label}: {why}.")

    who = self_label(rows)
    ok, n = rate_check(who)
    if not ok:
        die(f"{who} has sent {n} messages in the last {SEND_WINDOW // 60} minutes — "
            f"refusing, in case two sessions are replying to each other in a loop. "
            f"Wait for the window to pass.")

    record_send(me_subj, dst_subj)
    write_cause(dst.get("session_id") or "", chain)


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

    # A subject pattern addresses a group, so one send fans out over the matches.
    # This is what `bcast` was for, except addressable: `fin.*` is one grid, `>` is
    # everything, and the sender is always excluded so a fan-out cannot feed itself.
    if is_pattern(target):
        me_row = self_row(rows)
        hits = [r for r in resolve_all(target, rows)
                if not (me_row and r["win"] and r["win"] == me_row["win"])]
        if not hits:
            die(f"'{target}' matched only this pane — nothing to send to")
        # A pattern is a broad address, so targets the policy forbids are skipped
        # with a count rather than failing the whole fan-out.
        me_subj = (me_row or {}).get("subject") or ""
        allowed, blocked = [], []
        for r in hits:
            ok, why = hierarchy_check(me_subj, r.get("subject") or "")
            (allowed if ok else blocked).append((r, why))
        if blocked:
            print(f"cx: policy '{policy()}' skipped {len(blocked)} target(s): "
                  + ", ".join(short_subject(r.get('subject') or '') for r, _ in blocked),
                  file=sys.stderr)
        if not allowed:
            die(f"policy '{policy()}' forbids every target matching '{target}' "
                f"({blocked[0][1]})")
        my_sid = (me_row or {}).get("session_id") or ""
        me_id = chain_id(me_row or {})
        chain = read_cause(my_sid) + ([me_id] if me_id else [])
        kept = []
        for r, _ in allowed:
            cok, cwhy = chain_check(chain, chain_id(r))
            if not cok:
                print(f"cx: skipped {short_subject(r.get('subject') or '')}: {cwhy}",
                      file=sys.stderr)
                continue
            record_send(me_subj, r.get("subject") or "")
            write_cause(r.get("session_id") or "", chain)
            kept.append(r)
        if not kept:
            die(f"every target matching '{target}' would close a message loop")
        hits = kept
        # One rate check for the whole fan-out. Counting each leg separately would
        # spend a 9-pane grid's worth of allowance on a single `cx send 'grid.*'`,
        # so two of them would trip the runaway guard.
        who_me = self_label(rows)
        ok, n = rate_check(who_me)
        if not ok:
            die(f"{who_me} has sent {n} messages in the last {SEND_WINDOW // 60} "
                f"minutes — refusing, in case two sessions are replying to each "
                f"other in a loop. Wait for the window to pass.")
        # Delivery goes straight to the helper rather than back through cmd_send.
        # Recursing would re-run the guards per leg, and the only way to suppress
        # that was a bypass token on the argv — which is exactly the per-call
        # override that was just removed for being trivially reusable by a sender.
        for r in hits:
            deliver_to(r, msg, who_me, force_queue)
        print(f"cx: sent to {len(hits)} pane(s) matching '{target}'")
        return 0

    dst = resolve(target, rows)
    me = self_row(rows)
    if me and dst["win"] and dst["win"] == me["win"]:
        die("refusing to send to this same pane")
    who = self_label(rows)
    # No brackets in the prefix: if the target pane happens to be a bare shell
    # rather than a Claude TUI, `[cx ...]` is a zsh glob and the line dies with
    # "bad pattern" instead of showing up.
    text = f"cx/{who}: {msg}"

    sid = dst.get("session_id") or ""
    state, _ = status_of(dst["win"], sid) if (dst["win"] or sid) else ("?", "")
    label = f"slot {dst['slot']} ({dst['name'] or dst['title'] or sid[:8] or '?'})"

    if state == "ended":
        die(f"{label} has ended — nothing there to receive the message")

    guard_send(rows, dst, label)

    return deliver_to(dst, msg, who, force_queue, label=label)


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

    target = argv[0]
    question = " ".join(argv[1:])
    rows = roster()
    dst = require_pane(resolve(target, rows))
    me = self_row(rows)
    if me and dst["win"] == me["win"]:
        die("refusing to ask this same pane")

    # Same gauntlet as cx send. Without this, ask was a way around the policy and
    # the loop guards entirely.
    guard_send(rows, dst, f"slot {dst['slot']} ({dst['name'] or dst['title']})")

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
    # Same delivery path as cx send: this used its own copy of the old
    # send-text-then-sleep-then-Enter sequence, which interprets escapes in the
    # message (mangling paths, and submitting early on an interpreted newline) and
    # guesses at a 200ms ingest delay.
    if not type_into(dst["win"], prompt):
        die(f"slot {dst['slot']} (win {dst['win']}) disappeared while asking")
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
    """Rename a pane, i.e. give it a new subject.

    Takes `<label>` or `<label>.<index>`: a bare label keeps the pane's current
    index, so renaming one pane of a grid does not collide with its siblings.
    Renaming rewrites the SUBJECT, because that is the address `cx ls` prints and
    `cx send` accepts — writing only the old `name` field would leave the pane
    looking unchanged.
    """
    if len(argv) != 2:
        die("usage: cx name <who> <new-label>[.<index>]")
    dst = resolve(argv[0])
    if not dst["win"]:
        die("cannot rename a session with no pane of its own")
    new = argv[1].strip().lstrip(".")
    if is_pattern(new):
        die("a name cannot contain '*' or '>' — those are pattern characters")

    old = dst.get("subject") or ""
    old_index = old.rsplit(".", 1)[-1] if old.count(".") >= 2 else "1"
    if "." in new:
        label, _, idx = new.rpartition(".")
        if not idx.isdigit():
            die(f"'{new}' must be <label> or <label>.<index> with a numeric index")
    else:
        label, idx = new, old_index
    subject = subject_of(label, int(idx))

    reg = registry()
    rec = reg.get(dst["win"]) or {
        "kitty_window_id": dst["win"],
        "session_id": dst.get("session_id", ""),
        "cwd": dst["cwd"],
        "started": int(time.time()),
    }
    taken = {r.get("subject") for w, r in reg.items() if w != dst["win"]}
    if subject in taken:
        die(f"'{short_subject(subject)}' is already used by another pane")
    rec["subject"] = subject
    rec["name"] = short_subject(subject)
    rec.setdefault("slot", dst["slot"])
    write_record(rec)
    # The title is not written here on purpose: kitty-agent-title owns it and
    # re-renders on every hook event, so anything set here would be overwritten
    # within seconds. It reads this registry record rather than the environment, so
    # it picks the new name up by itself — on the pane's next lifecycle event, which
    # for a session sitting at a prompt means its next turn.
    print(f"cx: win {dst['win']} is now '{short_subject(subject)}'"
          + (f" (was '{short_subject(old)}')" if old else "")
          + "\ncx: the tab title and statusline follow on this pane's next hook event.")
    return 0


def has_open_request(from_subject: str, to_subject: str) -> bool:
    """Did `from_subject` ask `to_subject` something that is still unanswered?

    This is what makes the `down-replies` policy real rather than decorative: an
    upward message is allowed only when the parent actually asked for one, and the
    request stops counting the moment it is answered — so a reply cannot be used as
    a standing licence to talk upward.
    """
    if not (from_subject and to_subject):
        return False
    want_from, want_to = short_subject(from_subject), short_subject(to_subject)
    try:
        names = os.listdir(MAIL_DIR)
    except OSError:
        return False
    for fn in names:
        if not fn.endswith(".json") or fn.endswith(".reply.json"):
            continue
        try:
            with open(os.path.join(MAIL_DIR, fn)) as fh:
                req = json.load(fh)
        except (OSError, ValueError):
            continue
        if req.get("from") != want_from or req.get("to") != want_to:
            continue
        if not os.path.exists(os.path.join(MAIL_DIR, f"{req.get('id')}.reply.json")):
            return True
    return False


def cmd_policy(argv: list[str]) -> int:
    """Show or set the hierarchy policy.

    Persisted as a plain file rather than in the pane registry: it governs every
    session on the machine, not one pane, and it must be readable before any
    registry exists.
    """
    if argv:
        want = argv[0].strip().lower()
        if want not in POLICIES:
            die(f"unknown policy '{want}' (choose one of: {', '.join(POLICIES)})")
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(os.path.join(STATE_DIR, "policy"), "w") as fh:
            fh.write(want + "\n")
        print(f"cx: policy set to '{want}'"
              + ("  (CX_POLICY is set in this environment and overrides it)"
                 if os.environ.get("CX_POLICY") else ""))
        return 0

    active = policy()
    src = ("CX_POLICY" if os.environ.get("CX_POLICY")
           else "policy file" if os.path.exists(os.path.join(STATE_DIR, "policy"))
           else "default")
    print(f"policy: {active}   (from {src})\n")
    print("  down-siblings  down to any descendant, sideways to a same-parent sibling.")
    print("                 Never up, never to a cousin. Parent->child->parent cannot")
    print("                 cycle; siblings still can, so the send rate cap stays.")
    print("  down-replies   down to any descendant, up only as a reply to a request")
    print("                 that session received.")
    print("  down           strictly down. Acyclic, but `cx ask` cannot answer.")
    print("  open           no restriction.")
    print("\n  set with: cx policy <name>   (or CX_POLICY=<name> for one session)")
    print("  There is no per-call override: widening is a policy change, not a flag.")
    print("\n  A pane with no subject is outside the tree and always reachable in both")
    print("  directions, so an agent can report to you and you can drive your grid.")
    print("  Give that pane a subject (cx name) to bring it under the rules.")
    return 0


def cmd_me(argv: list[str]) -> int:
    rows = roster()
    me = self_row(rows)
    if not me:
        die("cannot identify this pane (KITTY_WINDOW_ID unset and `kitty @ ls --self` failed)")
    # Subject first: it is the address other sessions use, and it is the thing a
    # session asked "who are you?" needs to answer. Asked that, four grid panes
    # instead went grepping the repo — the identity was in their environment and
    # on their statusline the whole time, but nothing here stated it plainly.
    subj = me.get("subject") or ""
    print(f"subject={short_subject(subj) or '-'} full={subj or '-'} slot={me['slot']} "
          f"win={me['win']} session={me['session_id'] or '-'} cwd={me['cwd']}")
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
    # Everything from here to write_record is a read-modify-write over the shared
    # registry, so it is done under the lock: concurrent grid registrations
    # otherwise read one snapshot and pick the same slot and index.
    with file_lock("register"):
        return _register_locked(wid_i, payload)


def _register_locked(wid_i: int, payload: dict) -> int:
    reg = registry()
    rec = reg.get(wid_i, {})
    cwd = payload.get("cwd") or os.getcwd()
    slot = rec.get("slot")
    if slot is None:
        used = {r.get("slot") for r in reg.values() if r.get("slot") is not None}
        # Deliberately NOT taken from the launcher's pane number. A slot is unique
        # across every session on the machine, while a pane number is unique only
        # within its grid, so the two cannot always agree: pane 2 of a grid wants
        # slot 2, which an unrelated session already holds. Concurrent grid
        # registrations also read this same snapshot and race, so honouring a
        # requested number would align sometimes and not others — and a number that
        # is only sometimes the pane number is worse than one that never is.
        #
        # The pane's NAME carries the pane number instead (CX_NAME, e.g. demo-2),
        # it is what the title shows, and `cx send demo-2` addresses by it. The slot
        # is just a short integer for typing.
        slot = next(i for i in range(1, 1000) if i not in used)
    name = rec.get("name")
    if not name:
        # The label names the group this pane belongs to: a launcher supplies it
        # via CX_NAME (kitty-grid passes the grid's label), otherwise it is the
        # cwd's basename. The index distinguishes panes within that label —
        # CX_INDEX when the launcher numbered them, otherwise the lowest free
        # index for this label so a lone pane still gets a well-formed subject.
        label = token(os.environ.get("CX_NAME", "").strip()
                      or os.path.basename(cwd.rstrip("/")) or "session")[:40]
        taken = {
            r.get("subject") for w, r in reg.items() if w != wid_i and r.get("subject")
        }
        want = os.environ.get("CX_INDEX", "")
        if want.isdigit() and subject_of(label, int(want)) not in taken:
            index = int(want)
        else:
            index = next(i for i in range(1, 10000) if subject_of(label, i) not in taken)
        subject = subject_of(label, index)
        name = short_subject(subject)
    else:
        subject = rec.get("subject") or subject_of(name, 1)
    # Tell the session who it is. Without this a pane has no idea it is part of a
    # grid, what its own subject is, or that cx exists: asked "what is your cx
    # subject?", four panes each went grepping the repo for an answer that was in
    # their own environment. SessionStart accepts additionalContext, which is the
    # only channel that reaches the model itself rather than just the terminal.
    #
    # Deliberately short — it is prepended to every session, so it costs tokens
    # whether or not that session ever talks to another one.
    peers = sorted(
        short_subject(r["subject"]) for w, r in reg.items()
        if w != wid_i and r.get("subject")
    )
    context = (
        f"You are one of several agent sessions sharing this machine, addressable "
        f"over `cx` (see `cx help`). Your own subject is `{short_subject(subject)}` "
        f"(fully qualified: `{subject}`).\n"
        f"- `cx ls` lists the others; a message that arrives prefixed `cx/<sender>:` "
        f"came from one of them, and you reply with `cx send <sender> \"...\"`.\n"
        # Taken from the subject, not from `label`, which only exists on the branch
        # that had to compute a new name.
        f"- Subjects are NATS-style `<label>.<index>`: "
        f"`{subject.split('.')[1] if len(subject.split('.')) > 2 else '<label>'}.*` "
        f"is every pane of your group, `>` is everything.\n"
        + (f"- Currently also running: {', '.join(peers)}.\n" if peers else "")
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))

    write_record(
        {
            "kitty_window_id": wid_i,
            "slot": slot,
            "name": name,
            "subject": subject,
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

# Runaway guard. Two sessions told to reply to each other will do so forever: each
# drain injects a turn, the turn sends back, the other drain injects again. Nothing
# in the loop is wrong from either side, so it never terminates on its own, and it
# spends tokens unattended.
#
# The cap is on the SENDING side and counts sends per sender in a rolling window,
# rather than tracking chain depth through the messages. Depth would need the model
# to propagate a hop count it has no reason to preserve; a rate limit needs no
# cooperation and bounds the loop whatever shape it takes. The cost is that a
# legitimately chatty orchestrator hits it too, hence a
# window sized well above conversational use.
MAX_SENDS_PER_WINDOW = 20
SEND_WINDOW = 300
RATE_DIR = os.path.join(STATE_DIR, "rate")


def rate_check(sender: str) -> tuple[bool, int]:
    """(allowed, sends_in_window). Records this send when allowed."""
    os.makedirs(RATE_DIR, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", sender or "unknown")[:64]
    path = os.path.join(RATE_DIR, f"{safe}.log")
    now = time.time()
    stamps = []
    try:
        with open(path) as fh:
            for line in fh:
                try:
                    ts = float(line.strip())
                except ValueError:
                    continue
                if now - ts < SEND_WINDOW:
                    stamps.append(ts)
    except OSError:
        pass
    if len(stamps) >= MAX_SENDS_PER_WINDOW:
        return False, len(stamps)
    stamps.append(now)
    try:
        # Rewrite pruned rather than append, so the file cannot grow without bound.
        with open(path, "w") as fh:
            fh.write("\n".join(f"{s:.3f}" for s in stamps) + "\n")
    except OSError:
        pass
    return True, len(stamps)


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

    # Rate logs are self-pruning per send, but a sender that stops sending leaves
    # one behind forever. Reciprocation markers stop mattering once their window has
    # passed, so they go on the same sweep.
    for d, keep in ((RATE_DIR, SEND_WINDOW * 4), (SENT_DIR, RECIPROCAL_WINDOW * 4),
                    (CAUSE_DIR, CAUSE_TTL * 2)):
        try:
            for fn in os.listdir(d):
                p = os.path.join(d, fn)
                try:
                    if now - os.path.getmtime(p) > keep and not dry:
                        os.remove(p)
                except OSError:
                    pass
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
        "  ls [pattern] [--all] [-q]  roster + live status (pattern: e.g. 'build.*')\n"
        "  send <who> <msg...>       deliver a message: typed in if the target is at a\n"
        "                            prompt, queued for its next Stop if it is busy\n"
        "                            [--queue: always queue]\n"
        "  ask <who> <q> [--timeout S]  ask and block for the answer (default 300s)\n"
        "  answer <req-id> <text>    answer a request you were asked (receiver side)\n"
        "  answers <req-id>          print an answer that arrived after a timeout\n"
        "  inbox                     list requests and whether they're answered\n"
        "  bcast <msg...>            send to every pane but this one\n"
        "  peek <who> [n] [--sidechain]  print its last n conversation turns\n"
        "                            [--screen: the raw pane instead] [--all: scrollback]\n"
        "  focus <who>               jump kitty focus there\n"
        "  name <who> <new>          rename a pane: <label> keeps its index,\n                            <label>.<index> sets both\n"
        "  me                        this pane's slot/name/session id\n"
        "  drain                     Stop-hook entry point: deliver queued messages\n"
        "  gc [-n]                   forget dead panes, old records and stale queues\n  policy [name]             show or set who may message whom (hierarchy rules)\n"
        "\n<who> is a subject (build.3), a subject pattern (build.*, *.1, >),\n"
        "a slot number, a name substring, or w<kitty-window-id>.\n"
        "A pattern sends to every match at once and always excludes this pane."
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
    "policy": cmd_policy,
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
