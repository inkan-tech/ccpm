#!/bin/bash
# Fabro command hook for the ccpm-work-task workflow (event stage_complete).
# Fabro sets FABRO_RUN_ID and FABRO_NODE_ID.
#   node claim:     link the run to the issue in <git-dir>/ccpm-fabro-issue
#   node record_pr: link the PR in <git-dir>/ccpm-fabro-pr-url to the run
# Other nodes: does nothing.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${FABRO_RUN_ID:?FABRO_RUN_ID not set: run this as a Fabro hook}"
git_dir=$(git rev-parse --git-dir)

read_state() {
  local file="$git_dir/$1"
  [ -s "$file" ] || { echo "❌ $file is missing or empty." >&2; exit 1; }
  tr -d '[:space:]' < "$file"
}

case "${FABRO_NODE_ID:-}" in
  claim)
    issue=$(read_state ccpm-fabro-issue)
    bash "$here/fabro-link.sh" run "$issue" "$FABRO_RUN_ID"
    ;;
  record_pr)
    pr_url=$(read_state ccpm-fabro-pr-url)
    bash "$here/fabro-link.sh" pr "$FABRO_RUN_ID" "$pr_url"
    ;;
  *)
    exit 0
    ;;
esac
