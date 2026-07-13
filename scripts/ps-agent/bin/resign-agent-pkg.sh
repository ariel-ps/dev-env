#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  resign-agent-pkg.sh <unsigned.pkg> [output.pkg]

Re-signs the binaries inside an unsigned Prompt Security agent installer .pkg
with a local Prompt-team (J7M9U73T5B) code-signing identity, so the Mac Guard
system extension trusts the agent as a signed writer.

Why: CI test builds ship the agent PyInstaller-signed ad-hoc (no team). The
guard only trusts writers signed by team J7M9U73T5B / 4AYE5J54KN, so an ad-hoc
agent is denied (e.g. cannot open its own log). Re-signing with a J7M9U73T5B
Apple Development cert satisfies the guard's caller requirement:
  anchor apple generic and certificate leaf[subject.OU] = "J7M9U73T5B"

Only the agent binaries are re-signed. The bundled guard app (team 4AYE5J54KN)
is left untouched. The output .pkg is not itself signed (the guard checks the
binary team, not the pkg); install it with:  installer -allowUntrusted -pkg ...

Environment:
  PSAGENT_SIGN_ID   codesign identity to use. Default: auto-pick a codesigning
                    identity whose team (subject OU) is J7M9U73T5B.

Exit codes:
  0  re-signed pkg written
  1  bad usage / input not found
  2  no suitable signing identity
  3  signing or repackaging failed
EOF
}

case "${1:-}" in
  -h|--help|help|"") usage; [[ -z "${1:-}" ]] && exit 1 || exit 0 ;;
esac

PKG="$1"
[[ -f "$PKG" ]] || { echo "resign-agent-pkg: input pkg not found: $PKG" >&2; exit 1; }
OUT="${2:-${PKG%.pkg}-resigned.pkg}"

# --- resolve a Prompt-team (J7M9U73T5B) signing identity -----------------------
TRUSTED_TEAM="J7M9U73T5B"

identity_team() {
  # print the subject OU (team id) of a codesigning identity by name
  security find-certificate -c "$1" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p' | head -1
}

SIGN_ID="${PSAGENT_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$(identity_team "$name")" == "$TRUSTED_TEAM" ]]; then SIGN_ID="$name"; break; fi
  done < <(security find-identity -v -p codesigning 2>/dev/null \
             | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*[0-9A-F]*[[:space:]]*"\(.*\)"$/\1/p')
fi
[[ -n "$SIGN_ID" ]] || {
  echo "resign-agent-pkg: no codesigning identity with team $TRUSTED_TEAM found." >&2
  echo "  Set PSAGENT_SIGN_ID, or import an Apple Development cert for that team." >&2
  exit 2
}
echo "==> signing identity: $SIGN_ID (team $(identity_team "$SIGN_ID"))"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXP="$WORK/expand"

echo "==> expand $PKG"
pkgutil --expand "$PKG" "$EXP" || { echo "resign-agent-pkg: expand failed" >&2; exit 3; }
COMP="$(find "$EXP" -maxdepth 1 -name '*.pkg' -type d | head -1)"
[[ -n "$COMP" ]] || { echo "resign-agent-pkg: no component pkg in payload" >&2; exit 3; }
ROOT="$COMP/root"; mkdir -p "$ROOT"
( cd "$ROOT" && gunzip -dc "$COMP/Payload" | cpio -id --quiet ) \
  || { echo "resign-agent-pkg: payload extract failed" >&2; exit 3; }

PS="$ROOT/usr/local/bin/prompt_security"
[[ -d "$PS" ]] || { echo "resign-agent-pkg: prompt_security tree not found in payload" >&2; exit 3; }

# re-sign a single Mach-O, preserving its existing entitlements when present
sign_one() {
  local f="$1" ents="$WORK/ent.plist"
  if codesign -d --entitlements :- "$f" >"$ents" 2>/dev/null && [[ -s "$ents" ]]; then
    codesign --force --options runtime --entitlements "$ents" -s "$SIGN_ID" "$f"
  else
    codesign --force --options runtime -s "$SIGN_ID" "$f"
  fi
}

echo "==> re-sign agent binaries"
# Every Mach-O loaded into the process must carry the SAME team id as the
# entrypoint, or dyld refuses it ("different Team IDs"). The layout is entrypoint
# binaries at the top level plus a shared libs/ tree (Python.framework, *.so,
# *.dylib). Detect Mach-O by content (catches framework binaries like
# Python.framework/Versions/3.13/Python: no extension, not +x).
ENTRYPOINTS=(prompt_agent prompt_security_mcp ps-secrets ps-sensitive-data)
is_entrypoint() {
  local rel="${1#"$PS"/}"
  for e in "${ENTRYPOINTS[@]}"; do [[ "$rel" == "$e" ]] && return 0; done
  return 1
}
# 1. sign every nested Mach-O (libs, frameworks) first, without entitlements
signed=0
while IFS= read -r -d '' f; do
  is_entrypoint "$f" && continue
  if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
    codesign --force --options runtime -s "$SIGN_ID" "$f" 2>/dev/null || true
    signed=$((signed + 1))
  fi
done < <(find "$PS" -type f -print0)
echo "    signed $signed nested Mach-O files"
# 2. sign the entrypoints last, with their preserved entitlements
for bin in "${ENTRYPOINTS[@]}"; do
  [[ -f "$PS/$bin" ]] && sign_one "$PS/$bin"
  [[ -f "$PS/$bin/$bin" ]] && sign_one "$PS/$bin/$bin"   # onedir layout fallback
done

echo "==> verify prompt_agent"
AGENT="$PS/prompt_agent"; [[ -d "$PS/prompt_agent" ]] && AGENT="$PS/prompt_agent/prompt_agent"
codesign --verify --strict "$AGENT" || { echo "resign-agent-pkg: agent failed verify" >&2; exit 3; }
codesign -dv "$AGENT" 2>&1 | grep -iE 'Identifier=|TeamId'

echo "==> repack (preserve scripts + identifier + version)"
IDENT="$(sed -n 's/.*identifier="\([^"]*\)".*/\1/p' "$COMP/PackageInfo" | head -1)"
VER="$(sed -n 's/.*version="\([^"]*\)".*/\1/p' "$COMP/PackageInfo" | head -1)"
SCRIPTS=(); [[ -d "$COMP/Scripts" ]] && SCRIPTS=(--scripts "$COMP/Scripts")
pkgbuild --root "$ROOT" --identifier "${IDENT:-com.prompt.agent}" \
  --version "${VER:-0}" --install-location / "${SCRIPTS[@]}" "$WORK/component.pkg" \
  || { echo "resign-agent-pkg: pkgbuild failed" >&2; exit 3; }
productbuild --package "$WORK/component.pkg" "$OUT" \
  || { echo "resign-agent-pkg: productbuild failed" >&2; exit 3; }

echo "==> done: $OUT"
echo "    install on target with:  sudo installer -allowUntrusted -pkg \"$OUT\" -target /"
