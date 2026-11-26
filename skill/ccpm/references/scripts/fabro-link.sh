#!/bin/bash
# Link a Fabro run to a CCPM task issue.
#   fabro-link.sh run <issue_number> <run_id>   comment the run id on the issue, set board "In Progress"
#   fabro-link.sh pr  <run_id> <pr_url>         link the PR to the Fabro run (fabro pr link)
# Fabro is optional: exits 0 with a notice when the fabro CLI is missing.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
remote_url=$(git remote get-url origin 2>/dev/null || echo "")
REPO=$(echo "$remote_url" | sed 's|.*github.com[:/]||' | sed 's|\.git$||')

if ! command -v fabro >/dev/null 2>&1; then
  echo "ℹ️ fabro CLI not found, skipping Fabro link."
  exit 0
fi

case "${1:-}" in
  run)
    issue=${2:?issue number}
    run_id=${3:?run id}
    fabro inspect "$run_id" >/dev/null || { echo "❌ Fabro run $run_id not found." >&2; exit 1; }
    gh issue comment "$issue" --repo "$REPO" \
      --body "🔗 Fabro run: \`$run_id\` (\`fabro attach $run_id\`)" >/dev/null
    bash "$here/project-board.sh" status "$issue" "In Progress"
    echo "  ✅ Run $run_id linked to #$issue"
    ;;
  pr)
    run_id=${2:?run id}
    pr_url=${3:?pr url}
    fabro pr link "$run_id" "$pr_url"
    ;;
  *)
    echo "Usage: fabro-link.sh run <issue> <run_id> | pr <run_id> <pr_url>" >&2
    exit 2
    ;;
esac
