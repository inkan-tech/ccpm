#!/usr/bin/env bash
# Sync a loop-graphed run to GitHub and to the local task files. Called by loop-log.sh and
# loop-graph.sh; call it by hand only to retry a failed sync.
#
#   loop-sync.sh <workdir> init                 create the in-progress and blocked labels
#   loop-sync.sh <workdir> start <N>            task N: label in-progress, assign @me, status in-progress
#   loop-sync.sh <workdir> line <unit>          sync the last log line of <unit>
#   loop-sync.sh <workdir> limit <N> "<msg>"    task N reached a limit (loop-log.sh exit 4)
#
# line, task N:  comment with the attempt; on pass close the issue, tick it in the epic issue,
#                set status closed and the epic progress, and note N in <workdir>/closed.txt.
# line, MERGE:   comment on the epic issue; on fail or unverified reopen every task in closed.txt.
# line, MERGE-partial: comment on the epic issue; on pass reopen the closed tasks that are not in
#                the delivered set (the "change" field); otherwise reopen all of them.
# line, CHECK:   comment on the epic issue.
# A failed gh call is appended to <workdir>/sync-failures.jsonl. Exit code is always 0.
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
source "$here/lib.sh"

workdir=$1 event=$2 unit=${3:-} msg=${4:-}
epic_dir=$(dirname "$workdir")
log="$workdir/log.jsonl"
closed="$workdir/closed.txt"
failures="$workdir/sync-failures.jsonl"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

fail() {
  jq -nc --arg ts "$now" --arg event "$event" --arg unit "$unit" --arg cmd "$1" \
    '{ts:$ts, event:$event, unit:$unit, cmd:$cmd}' >> "$failures"
  echo "SYNC FAILED ($event $unit): $1" >&2
}
gh_run() { gh "$@" >/dev/null 2>&1 || fail "gh $*"; }

# Repository safety check (references/conventions.md).
remote_url=$(git -C "$epic_dir" remote get-url origin 2>/dev/null || echo "")
if [ -z "$remote_url" ] || [[ $remote_url == *automazeio/ccpm* ]]; then
  fail "no allowed origin remote: '$remote_url'"; exit 0
fi
REPO=$(echo "$remote_url" | sed 's|.*github.com[:/]||; s|\.git$||')
epic_issue=$(frontmatter_field "$epic_dir/epic.md" github | grep -oE '[0-9]+$')
[ -n "$epic_issue" ] || { fail "epic.md has no github: issue"; exit 0; }

set_field() { # file field value
  [ -f "$1" ] || return 0
  sed -i.bak "s|^$2:.*|$2: $3|" "$1" && rm -f "$1.bak"
}
epic_progress() {
  local total=0 done_n=0 f
  for f in "$epic_dir"/*.md; do
    is_task_file "$f" || continue
    total=$((total + 1))
    is_done_status "$(frontmatter_field "$f" status)" && done_n=$((done_n + 1))
  done
  [ $total -gt 0 ] && set_field "$epic_dir/epic.md" progress "$((done_n * 100 / total))%"
  set_field "$epic_dir/epic.md" updated "$now"
}
epic_box() { # N x|space
  local body; body=$(mktemp)
  if gh issue view "$epic_issue" --repo "$REPO" --json body -q .body > "$body" 2>/dev/null; then
    if [ "$2" = x ]; then sed -E -i.bak "s/- \[ \] #$1([^0-9]|\$)/- [x] #$1\1/" "$body"
    else sed -E -i.bak "s/- \[x\] #$1([^0-9]|\$)/- [ ] #$1\1/" "$body"; fi
    gh_run issue edit "$epic_issue" --repo "$REPO" --body-file "$body"
  else
    fail "gh issue view $epic_issue --json body"
  fi
  rm -f "$body" "$body.bak"
}
reopen() { # N reason
  gh_run issue reopen "$1" --repo "$REPO" --comment "loop-graphed: reopened. $2"
  set_field "$epic_dir/$1.md" status open
  set_field "$epic_dir/$1.md" updated "$now"
  epic_box "$1" " "
  [ -f "$closed" ] && { grep -vx "$1" "$closed" > "$closed.tmp"; mv "$closed.tmp" "$closed"; }
}
comment() { # issue body
  gh_run issue comment "$1" --repo "$REPO" --body "$2"
}

case $event in
  init)
    gh_run label create in-progress --repo "$REPO" --color FBCA04 --description "Work in progress" --force
    gh_run label create blocked --repo "$REPO" --color B60205 --description "Blocked, needs a decision" --force
    ;;
  start)
    gh_run issue edit "$unit" --repo "$REPO" --add-label in-progress --add-assignee @me
    set_field "$epic_dir/$unit.md" status in-progress
    set_field "$epic_dir/$unit.md" updated "$now"
    ;;
  limit)
    gh_run issue edit "$unit" --repo "$REPO" --add-label blocked --remove-label in-progress
    comment "$unit" "loop-graphed STOP: $msg"
    set_field "$epic_dir/$unit.md" status open
    set_field "$epic_dir/$unit.md" updated "$now"
    ;;
  line)
    line=$(jq -c --arg u "$unit" 'select(.unit == $u)' "$log" | tail -1)
    [ -n "$line" ] || { fail "no log line for $unit"; exit 0; }
    state=$(jq -r .state <<<"$line")
    body=$(jq -r '"loop-graphed \(.unit) attempt \(.attempt): **\(.state)** (exit \(.exit))\n\n- change: \(.change)\n- check: `\(.check)`" + (if .reason != "" then "\n- reason: \(.reason)" else "" end) + "\n- skill: \(.skill)"' <<<"$line")
    case $unit in
      MERGE|MERGE-partial|CHECK)
        comment "$epic_issue" "$body"
        [ "$unit" = CHECK ] && exit 0
        keep=""
        [ "$unit" = MERGE ] && [ "$state" = pass ] && exit 0
        [ "$unit" = MERGE-partial ] && [ "$state" = pass ] && keep=$(jq -r .change <<<"$line" | tr -c '0-9' ' ')
        [ -f "$closed" ] || exit 0
        for n in $(cat "$closed"); do
          [[ " $keep " == *" $n "* ]] && continue
          reopen "$n" "$unit is $state; this task is not in a delivered tree."
        done
        epic_progress
        ;;
      *)
        comment "$unit" "$body"
        set_field "$epic_dir/$unit.md" updated "$now"
        if [ "$state" = pass ]; then
          gh_run issue edit "$unit" --repo "$REPO" --remove-label in-progress
          gh_run issue close "$unit" --repo "$REPO"
          set_field "$epic_dir/$unit.md" status closed
          epic_box "$unit" x
          grep -qx "$unit" "$closed" 2>/dev/null || echo "$unit" >> "$closed"
          epic_progress
        fi
        ;;
    esac
    ;;
  *) echo "unknown event: $event" >&2 ;;
esac
exit 0
