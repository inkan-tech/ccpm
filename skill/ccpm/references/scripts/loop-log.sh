#!/usr/bin/env bash
# Run a check, append one line to log.jsonl, sync the GitHub issue. Never write log.jsonl by hand.
#
#   loop-log.sh <workdir> <unit> <attempt> "<change>" [--reason "<text>"] -- <check command...>
#   loop-log.sh <workdir> <unit> <attempt> "<change>" --no-check --reason "<text>"
#
# <workdir> = .claude/epics/<epic>/loop (absolute path when called from a worktree).
# <unit> = a task issue number, or MERGE, MERGE-partial, CHECK.
# Line: ts, unit, attempt, change, check, exit, kept (exit == 0),
# state = pass (0) | unverified (3) | fail (other) | none (--no-check), reason, skill (git SHA of
# references/loop-graphed-ccpm.md, "-dirty" if changed locally).
# A (unit, attempt) pair already logged is refused (exit 2): a correction is a new attempt.
# A unit with 3 fail lines or 2 unverified lines is refused (exit 4): stop it, log MERGE-partial.
# Each line is synced to GitHub by loop-sync.sh. A sync error never changes the exit code; it is
# written to <workdir>/sync-failures.jsonl and the final summary must list it.
# Exit code = the check's exit code (2 usage error or duplicate, 4 limit reached).
set -uo pipefail

here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
usage() { sed -n '2,17p' "$0" >&2; exit 2; }
[ $# -ge 4 ] || usage
workdir=$1 unit=$2 attempt=$3 change=$4
shift 4
reason="" no_check=0
while [ $# -gt 0 ]; do
  case $1 in
    --reason) reason=${2:-}; shift 2 ;;
    --no-check) no_check=1; shift ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[[ $attempt =~ ^[1-9][0-9]*$ ]] || { echo "attempt must be an integer >= 1" >&2; exit 2; }
case $unit in
  MERGE|MERGE-partial|CHECK) ;;
  *) [[ $unit =~ ^[0-9]+$ ]] || { echo "unit must be a task issue number, MERGE, MERGE-partial or CHECK" >&2; exit 2; } ;;
esac
if [ $no_check -eq 1 ]; then
  [ -n "$reason" ] || { echo "--no-check needs --reason" >&2; exit 2; }
  [ $# -eq 0 ] || { echo "--no-check takes no command" >&2; exit 2; }
else
  [ $# -gt 0 ] || { echo "missing check command after --" >&2; exit 2; }
fi

mkdir -p "$workdir"
log="$workdir/log.jsonl"
if [ -f "$log" ] && jq -e --arg u "$unit" --argjson a "$attempt" \
     'select(.unit == $u and .attempt == $a)' "$log" >/dev/null 2>&1; then
  echo "duplicate: $unit attempt $attempt already logged; use attempt $((attempt + 1))" >&2
  exit 2
fi

# Limits (check runs only; --no-check lines stay allowed for user cancels and CHECK revisions).
if [ $no_check -eq 0 ] && [ -f "$log" ]; then
  count() { jq -s --arg u "$unit" --arg s "$1" '[.[] | select(.unit == $u and .state == $s)] | length' "$log"; }
  fails=$(count fail) unverified=$(count unverified)
  msg=""
  [ "$fails" -ge 3 ] && msg="$unit has $fails failed attempts. The plan is wrong: log MERGE-partial for the passed units, then the summary."
  [ -z "$msg" ] && [ "$unverified" -ge 2 ] && msg="$unit is unverified twice. Hand it to CI or the user (APPROVAL NEEDED); log MERGE-partial for the passed units."
  if [ -n "$msg" ]; then
    echo "STOP: $msg" >&2
    bash "$here/loop-sync.sh" "$workdir" limit "$unit" "$msg"
    exit 4
  fi
fi

refs_dir=$(cd "$here/.." && pwd)
skill_sha=$(git -C "$refs_dir" log -1 --format=%h -- loop-graphed-ccpm.md 2>/dev/null)
[ -n "$skill_sha" ] || skill_sha=uncommitted
[ -n "$(git -C "$refs_dir" status --porcelain -- loop-graphed-ccpm.md 2>/dev/null)" ] && skill_sha="$skill_sha-dirty"

# First attempt of a task: mark it in progress before the check runs.
[ "$attempt" = 1 ] && [ $no_check -eq 0 ] && [[ $unit =~ ^[0-9]+$ ]] && bash "$here/loop-sync.sh" "$workdir" start "$unit"

if [ $no_check -eq 1 ]; then
  check="none" exit_json=null
else
  check=$(printf '%q ' "$@"); check=${check% }
  "$@"
  rc=$?
  exit_json=$rc
fi

jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg unit "$unit" --argjson attempt "$attempt" \
  --arg change "$change" --arg check "$check" --argjson exit "$exit_json" \
  --arg reason "$reason" --arg skill "$skill_sha" \
  '{ts:$ts, unit:$unit, attempt:$attempt, change:$change, check:$check, exit:$exit,
    kept:($exit == 0),
    state:(if $exit == null then "none" elif $exit == 0 then "pass" elif $exit == 3 then "unverified" else "fail" end),
    reason:$reason, skill:$skill}' >> "$log"

bash "$here/loop-sync.sh" "$workdir" line "$unit"

[ $no_check -eq 1 ] && exit 0
exit "$rc"
