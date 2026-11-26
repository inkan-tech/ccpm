#!/bin/bash
# GitHub Project V2 board for CCPM issues.
#   project-board.sh ensure                  find or create the board, print "<owner> <number>"
#   project-board.sh add <issue_number>      add the issue to the board (status Todo)
#   project-board.sh status <issue_number> <Todo|"In Progress"|Done>
# The board is stored in .claude/project-board as "<owner> <number>".
# Needs the gh "project" scope: gh auth refresh -s project
set -euo pipefail

STATE_FILE=".claude/project-board"

remote_url=$(git remote get-url origin 2>/dev/null || echo "")
REPO=$(echo "$remote_url" | sed 's|.*github.com[:/]||' | sed 's|\.git$||')
[ -n "$REPO" ] || { echo "❌ No git origin remote." >&2; exit 1; }
OWNER=${REPO%%/*}
NAME=${REPO##*/}

die() { echo "❌ $*" >&2; exit 1; }

gh auth status 2>&1 | grep -q "'project'" \
  || die "gh token has no 'project' scope. Run: gh auth refresh -s project"

board_number() {
  if [ -f "$STATE_FILE" ]; then
    awk '{print $2}' "$STATE_FILE"
    return
  fi
  local title="CCPM: $NAME" number
  number=$(gh project list --owner "$OWNER" --format json -L 100 \
    --jq ".projects[] | select(.title==\"$title\") | .number" | head -1)
  if [ -z "$number" ]; then
    number=$(gh project create --owner "$OWNER" --title "$title" --format json --jq .number)
    echo "  ✅ Created board '$title' (#$number)" >&2
  fi
  # Link the board to the repository. Ignore "already linked".
  gh project link "$number" --owner "$OWNER" --repo "$REPO" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$OWNER $number" > "$STATE_FILE"
  echo "$number"
}

cmd=${1:-}
case "$cmd" in
  ensure)
    n=$(board_number)
    echo "$OWNER $n"
    ;;
  add)
    issue=${2:?issue number}
    n=$(board_number)
    gh project item-add "$n" --owner "$OWNER" \
      --url "https://github.com/$REPO/issues/$issue" >/dev/null
    echo "  ✅ #$issue added to board #$n"
    ;;
  status)
    issue=${2:?issue number}
    value=${3:?Todo|In Progress|Done}
    n=$(board_number)
    project_id=$(gh project view "$n" --owner "$OWNER" --format json --jq .id)
    field=$(gh project field-list "$n" --owner "$OWNER" --format json \
      --jq '.fields[] | select(.name=="Status")')
    [ -n "$field" ] || die "Board #$n has no Status field."
    field_id=$(echo "$field" | jq -r .id)
    option_id=$(echo "$field" | jq -r --arg v "$value" '.options[] | select(.name==$v) | .id')
    [ -n "$option_id" ] || die "Status option '$value' not found on board #$n."
    item_id=$(gh project item-list "$n" --owner "$OWNER" --format json -L 500 \
      --jq ".items[] | select(.content.number==$issue) | .id" | head -1)
    if [ -z "$item_id" ]; then
      "$0" add "$issue" >/dev/null
      # The item list lags just after an add. Retry a few times.
      for _ in 1 2 3 4 5; do
        sleep 2
        item_id=$(gh project item-list "$n" --owner "$OWNER" --format json -L 500 \
          --jq ".items[] | select(.content.number==$issue) | .id" | head -1)
        [ -n "$item_id" ] && break
      done
    fi
    [ -n "$item_id" ] || die "Issue #$issue is not on board #$n."
    gh project item-edit --id "$item_id" --project-id "$project_id" \
      --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null
    echo "  ✅ #$issue → $value"
    ;;
  *)
    echo "Usage: project-board.sh ensure | add <issue> | status <issue> <Todo|In Progress|Done>" >&2
    exit 2
    ;;
esac
