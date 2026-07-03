#!/bin/bash
# Download a build artifact from Jenkins
# Usage: ./download-artifact.sh <job> <branch> <artifact-path> [output-file]
#
# Example:
#   ./download-artifact.sh ps-agent-mac-guard bootstrap-from-fork \
#     artifacts/macos/Release/PSAgentMacGuardHost.app.signed.zip

set -euo pipefail

JENKINS_URL="${JENKINS_URL:?JENKINS_URL not set (add to ~/.zshrc from .env.template)}"
JENKINS_USER="${JENKINS_USER:?JENKINS_USER not set (add to ~/.zshrc from .env.template)}"
JENKINS_TOKEN="${JENKINS_TOKEN:?JENKINS_TOKEN not set (add to ~/.zshrc from .env.template)}"

JOB="${1:?Usage: $0 <job> <branch> <artifact-path> [output-file]}"
BRANCH="${2:?Usage: $0 <job> <branch> <artifact-path> [output-file]}"
ARTIFACT="${3:?Usage: $0 <job> <branch> <artifact-path> [output-file]}"
OUTPUT="${4:-$(basename "$ARTIFACT")}"

curl -u "$JENKINS_USER:$JENKINS_TOKEN" \
  "$JENKINS_URL/job/$JOB/job/$BRANCH/lastBuild/artifact/$ARTIFACT" \
  -o "$OUTPUT" \
  -w "\nHTTP status: %{http_code}\nSaved to: $OUTPUT\nSize: %{size_download} bytes\n"
