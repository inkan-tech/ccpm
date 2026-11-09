#!/usr/bin/env bash
# Build the loop-graphed graph of a synced epic. Run it from the project root (main checkout).
#
#   loop-graph.sh <epic>
#
# Writes .claude/epics/<epic>/loop/graph.json: one unit per open task, unit = issue number.
# Edges: depends_on, plus conflicts_with oriented low issue -> high issue (same files = run in order).
# Closed tasks are left out; an edge to a closed task is dropped.
# Refuses (exit 1): epic or task not synced (no github:), loop dir not ignored by git, a cycle.
# Then creates the in-progress and blocked labels on GitHub (loop-sync.sh init).
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
source "$here/lib.sh"

epic=${1:?usage: loop-graph.sh <epic>}
epic_dir=".claude/epics/$epic"
workdir="$epic_dir/loop"
[ -f "$epic_dir/epic.md" ] || { echo "❌ $epic_dir/epic.md not found" >&2; exit 1; }
[ -n "$(frontmatter_field "$epic_dir/epic.md" github | grep -oE '[0-9]+$')" ] \
  || { echo "❌ Epic not synced. Sync the epic first." >&2; exit 1; }

mkdir -p "$workdir"
git check-ignore -q "$workdir/log.jsonl" \
  || { echo "❌ $workdir is not ignored by git. Add '.claude/epics/*/loop/' to .gitignore." >&2; exit 1; }

units=() missing=()
for f in "$epic_dir"/*.md; do
  is_task_file "$f" || continue
  is_done_status "$(frontmatter_field "$f" status)" && continue
  n=$(basename "$f" .md)
  [ -n "$(frontmatter_field "$f" github | grep -oE '[0-9]+$')" ] || missing+=("$n")
  units+=("$n")
done
[ ${#missing[@]} -eq 0 ] || { echo "❌ Tasks not synced: ${missing[*]}. Sync the epic first." >&2; exit 1; }
[ ${#units[@]} -gt 0 ] || { echo "❌ No open task in $epic_dir" >&2; exit 1; }

open=" ${units[*]} "
{
  for n in "${units[@]}"; do
    f="$epic_dir/$n.md"
    deps=""
    for d in $(frontmatter_list "$f" depends_on); do [[ $open == *" $d "* ]] && deps="$deps $d"; done
    for c in $(frontmatter_list "$f" conflicts_with); do
      [[ $open == *" $c "* ]] && [ "$c" -lt "$n" ] && deps="$deps $c"
    done
    jq -nc --arg unit "$n" --arg job "$(frontmatter_field "$f" name)" --arg input "$f" \
      --arg check "bash $(pwd)/$workdir/check.sh $n" --arg deps "$deps" \
      '{unit:$unit, job:$job, input:$input, output:"", failure_state:"", check:$check,
        depends_on:($deps | split(" ") | map(select(. != "")) | unique)}'
  done
} | jq -s . > "$workdir/graph.json"

# Cycle check: Kahn's algorithm on the graph.
if ! jq -e '
  def kahn: . as $g
    | ([$g[] | select(.depends_on | length == 0) | .unit]) as $ready
    | if ($ready | length) == 0 then ($g | length == 0)
      else [$g[] | select(.depends_on | length > 0) | .depends_on -= $ready] | kahn end;
  kahn' "$workdir/graph.json" >/dev/null; then
  echo "❌ Cycle in depends_on/conflicts_with. Fix the task files." >&2
  exit 1
fi

bash "$here/loop-sync.sh" "$(pwd)/$workdir" init
echo "✅ $workdir/graph.json: ${#units[@]} units"
jq -r '.[] | "  #\(.unit) \(.job)  <- \(.depends_on | map("#" + .) | join(", "))"' "$workdir/graph.json"
