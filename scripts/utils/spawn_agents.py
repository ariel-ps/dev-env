#!/usr/bin/env python3
"""Spawn one or more Claude agents in the background via generated bash scripts.

Wraps a task in an agent-identity prefix, generates a bash script per agent that
runs `claude -p` under nohup, and launches them detached.

Usage:
    ./spawn_agents.py "refactor the auth middleware"
    ./spawn_agents.py -n 3 "audit the RPC handshake code"
    ./spawn_agents.py -n 5 -o ~/work/results "explore edge cases"
    ./spawn_agents.py --dry-run "some task"
"""
import argparse
import os
import secrets
import stat
import string
import subprocess
import sys
import uuid
from pathlib import Path

PREFIX_TEMPLATE = (
    "[entropy-nonce: {nonce}] "
    "your name is agent-{id} and you need to do the following: {task} "
    "write everything into folder {out}/result_agent_{id}.md"
)

# High-entropy alphabet: full base62. secrets = CSPRNG.
_NONCE_ALPHABET = string.ascii_letters + string.digits


def make_nonce(length=32):
    """Per-agent high-entropy nonce. Injected into the prompt so that identical
    tasks diverge across agents (Claude CLI has no --seed / --temperature).
    ~log2(62)*length bits of entropy (~190 bits at length=32)."""
    return "".join(secrets.choice(_NONCE_ALPHABET) for _ in range(length))


def build_bash_script(agent_id, prompt, claude_bin, out_dir, result_path,
                      log_path, skip_perms):
    # Prompt passed via heredoc to sidestep quoting issues with arbitrary text.
    # --dangerously-skip-permissions is required for headless (nohup, no TTY)
    # runs: otherwise Write/Edit hit an unanswerable permission prompt and the
    # agent can't create result_agent_*.md.
    perms_flag = " --dangerously-skip-permissions" if skip_perms else ""
    return f"""#!/usr/bin/env bash
set -euo pipefail

AGENT_ID={agent_id!r}
OUT_DIR={out_dir!r}
RESULT_FILE={result_path!r}
LOG_FILE={log_path!r}

mkdir -p "$OUT_DIR"

read -r -d '' PROMPT <<'PS_EOF' || true
{prompt}
PS_EOF

echo "[agent-$AGENT_ID] starting $(date)" >> "$LOG_FILE"
{claude_bin} -p{perms_flag} "$PROMPT" >> "$LOG_FILE" 2>&1
echo "[agent-$AGENT_ID] done $(date)" >> "$LOG_FILE"
"""


def launch_agent(agent_id, task, out_dir, scripts_dir, claude_bin, dry_run,
                 nonce_len, skip_perms):
    result_path = str(out_dir / f"result_agent_{agent_id}.md")
    log_path = str(scripts_dir / f"agent_{agent_id}.log")

    nonce = make_nonce(nonce_len)
    prompt = PREFIX_TEMPLATE.format(
        nonce=nonce, id=agent_id, task=task, out=str(out_dir)
    )
    script_body = build_bash_script(
        agent_id, prompt, claude_bin, str(out_dir), result_path, log_path,
        skip_perms
    )

    script_path = scripts_dir / f"agent_{agent_id}.sh"
    script_path.write_text(script_body)
    script_path.chmod(script_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP)

    if dry_run:
        print(f"# --- agent-{agent_id} script: {script_path}")
        print(script_body)
        return

    with open(log_path, "a") as log:
        proc = subprocess.Popen(
            ["nohup", "bash", str(script_path)],
            stdout=log, stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    print(f"agent-{agent_id} launched (pid {proc.pid})")
    print(f"  script:  {script_path}")
    print(f"  log:     {log_path}")
    print(f"  result:  {result_path}")


def main():
    ap = argparse.ArgumentParser(description="Spawn background Claude agents.")
    ap.add_argument("task", help="The task/query for each agent.")
    ap.add_argument("-n", "--num", type=int, default=1,
                    help="Number of agents to spawn (default: 1).")
    ap.add_argument("-o", "--out-dir", default=".docs/results",
                    help="Output dir for result markdown (default: .docs/results).")
    ap.add_argument("--id-prefix", default=None,
                    help="Base for agent ids; appends -1..-n when num>1. "
                         "Default: short uuid.")
    ap.add_argument("--claude-bin", default="claude", help="Claude CLI binary.")
    ap.add_argument("--skip-permissions", dest="skip_perms",
                    action="store_true", default=True,
                    help="Pass --dangerously-skip-permissions to claude so "
                         "headless runs can write files (default: on).")
    ap.add_argument("--no-skip-permissions", dest="skip_perms",
                    action="store_false",
                    help="Do NOT skip permissions (agent may block on Write).")
    ap.add_argument("--nonce-len", type=int, default=32,
                    help="Length of per-agent high-entropy nonce injected into "
                         "the prompt to diversify outputs (default: 32, 0=off).")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print generated scripts; do not run.")
    args = ap.parse_args()

    if args.num < 1:
        ap.error("--num must be >= 1")

    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir = out_dir / "agent_scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    base = args.id_prefix or uuid.uuid4().hex[:8]
    ids = [base] if args.num == 1 else [f"{base}-{i}" for i in range(1, args.num + 1)]

    for agent_id in ids:
        launch_agent(agent_id, args.task, out_dir, scripts_dir,
                     args.claude_bin, args.dry_run, args.nonce_len,
                     args.skip_perms)

    if not args.dry_run:
        print(f"\n{len(ids)} agent(s) launched. Results -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
