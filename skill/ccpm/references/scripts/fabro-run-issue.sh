#!/bin/bash
# Start a Fabro run for a CCPM task issue, then link the run to the issue.
#   fabro-run-issue.sh <issue_number> <workflow> [target]
#     workflow  Fabro workflow name (resolved from FABRO_PROJECT_DIR, default: current dir)
#     target    OWNER/REPO[@BRANCH] the run works on (default: the git origin of the current dir)
# Set FABRO_ENVIRONMENT to pick a server environment (a workflow.toml run.environment id is not honored by `fabro run`).
# The issue title and body become the run goal. The run id is printed, and
# fabro-link.sh comments it on the issue and moves the board card to In Progress.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
issue=${1:?issue number}
workflow=${2:?workflow name}
remote_url=$(git remote get-url origin 2>/dev/null || echo "")
REPO=$(echo "$remote_url" | sed 's|.*github.com[:/]||' | sed 's|\.git$||')
target=${3:-$REPO}

command -v fabro >/dev/null 2>&1 || { echo "❌ fabro CLI not found in PATH." >&2; exit 1; }

goal_file=$(mktemp)
trap 'rm -f "$goal_file"' EXIT
{
  printf 'Issue #%s: ' "$issue"
  gh issue view "$issue" --repo "$REPO" --json title,body --jq '.title + "\n\n" + .body'
} > "$goal_file"
printf '\n\nResolve issue #%s. Put "Closes #%s" in the pull request body.\n' "$issue" "$issue" >> "$goal_file"

cd "${FABRO_PROJECT_DIR:-.}"
out=$(fabro run --detach --target "$target" --goal-file "$goal_file" \
  --label "ccpm_issue=$issue" ${FABRO_ENVIRONMENT:+--environment "$FABRO_ENVIRONMENT"} "$workflow")
run_id=$(echo "$out" | grep -v '^[[:space:]]*$' | tail -1 | awk '{print $NF}')
[ -n "$run_id" ] || { echo "❌ No run id in fabro output:" >&2; echo "$out" >&2; exit 1; }
echo "$run_id"

cd - >/dev/null
bash "$here/fabro-link.sh" run "$issue" "$run_id"
