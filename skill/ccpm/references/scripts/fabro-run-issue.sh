#!/bin/bash
# Start a Fabro run for a CCPM task issue, then link the run to the issue.
#   fabro-run-issue.sh <issue_number> <workflow> [target]
#     workflow  Fabro workflow name (resolved from FABRO_PROJECT_DIR, default: current dir)
#     target    OWNER/REPO[@BRANCH] the run works on (default: the git origin of the current dir)
# `fabro run` does not honor a workflow.toml run.environment id, so this script passes --environment itself.
# FABRO_ENVIRONMENT overrides; otherwise the workflow's [run.environment] id is used.
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

# Without --environment, fabro falls back to the server's "default" environment.
# Default to the id in the workflow's [run.environment], unless FABRO_ENVIRONMENT is set.
if [ -z "${FABRO_ENVIRONMENT:-}" ] && [ -f ".fabro/workflows/$workflow/workflow.toml" ]; then
  FABRO_ENVIRONMENT=$(awk '/^\[run.environment\]/{f=1;next} /^\[/{f=0} f && /^id *=/{gsub(/[" ]/,"",$3); print $3; exit}' ".fabro/workflows/$workflow/workflow.toml")
fi
out=$(fabro run --detach --target "$target" --goal-file "$goal_file" \
  --label "ccpm_issue=$issue" ${FABRO_ENVIRONMENT:+--environment "$FABRO_ENVIRONMENT"} "$workflow")
run_id=$(echo "$out" | grep -v '^[[:space:]]*$' | tail -1 | awk '{print $NF}')
[ -n "$run_id" ] || { echo "❌ No run id in fabro output:" >&2; echo "$out" >&2; exit 1; }
echo "$run_id"

cd - >/dev/null
bash "$here/fabro-link.sh" run "$issue" "$run_id"
