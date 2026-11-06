# Loop-Graphed-CCPM — Run an Epic as a Graph of Checked Units

This mode executes a synced epic end to end. Each open task is one unit. Each unit runs a Karpathy loop: make one change, measure it against a fixed check, keep it if it passes, revert it if it does not, log every attempt. GitHub is synced at every state change. The user approves only the final step.

**Trigger**: "/loop-graphed-ccpm <name>", "run the <name> epic with loop-graphed", "loop-graphed epic <name>", "execute <name> as checked units".

---

## Rules

1. **Check first.** Before any work, a separate verifier agent writes the pass condition as a program. The agent that does the work never writes it. "Looks good" never counts as a pass.
2. **Fixed check.** After step 1, `check.sh` is read-only (`chmod 444`). A unit that touches `check.sh` or an existing test fails, whatever its exit code. Only the user can approve a new check version, and only because the user changed the goal.
3. **Limits.** Max 3 failed attempts per task. After 3, stop: the plan is wrong. Exit 3 means unverified (CI-only test, shared service, human review, environment failure). Fix the environment once. A second unverified result goes to CI or to the user. `loop-log.sh` enforces both limits with exit 4. On exit 4, stop that task. Do not rename it or start a new task to get around the limit.
4. **Security stop.** Secret read, check tampering, out-of-scope write: stop at once, no retry.
5. **Merge with code.** Merge, dedupe, sort and compare with `jq`, `diff`, scripts. Spend model reasoning only on steps that judge or decide.
6. **Return only the failing task**: UNIT, VERDICT, REASON, EVIDENCE, SCOPE. Never redo tasks that passed.
7. **Learn.** When a fix passes, write its cause as one line in `.claude/epics/RULES.md`: `- <cause> -> <rule> (scope: task|repo, issue, date, review: date+30d)`. Apply it to every task brief after that.

---

## Preflight

- The epic is synced: `epic.md` and every open task have a `github:` URL. If not: "❌ Sync the epic first."
- The epic worktree `../epic-<name>` exists (see `sync.md`).
- `.claude/epics/*/loop/` is in `.gitignore`. A tracked `log.jsonl` would show in `git diff` and trip the tamper guard.

---

## Process

**Step 1 — Build the graph** (from the main checkout):

```bash
bash references/scripts/loop-graph.sh <name>
```

It writes `.claude/epics/<name>/loop/graph.json`: unit = issue number, edges from `depends_on` and `conflicts_with` (low issue before high issue). It refuses a cycle, an unsynced task or a work dir that git does not ignore. It creates the `in-progress` and `blocked` labels.

**Step 2 — Write the check** with a separate verifier `Agent`. Brief: `epic.md` and the acceptance criteria of each task file, nothing from the worker. Output `.claude/epics/<name>/loop/check.sh`:

- `check.sh` with no argument: the whole epic. `check.sh <N...>`: only those tasks. `check.sh <N...> SCOPE`: those tasks plus "the diff stays inside their files".
- Exit 0 pass, 3 unverified (never exit 0 for a criterion that cannot run here), any other code fail.
- Run it once on the unchanged worktree: it must fail, or it checks nothing. Then `chmod 444` it and write `sha256sum check.sh > check.sha256`.

**Step 3 — Run the units.** One `Agent` per task. Tasks whose `depends_on` in `graph.json` are passed go in the same message (parallel). Parallel tasks that touch the same repo use `isolation: "worktree"`, based on the epic branch. Task brief:

- the task file, its check command from `graph.json`, `RULES.md`, the work dir as an absolute path;
- work only in the epic worktree, commit as `Issue #<N>: <change>`, never `--force`;
- every attempt goes through `loop-log.sh` (below), attempts start at 1;
- max 3 failed attempts, stop on exit 4;
- tamper guard after each attempt: `git diff --name-only` must not list `check.sh` or an existing test file;
- return `UNIT/VERDICT/REASON/EVIDENCE/SCOPE`.

```bash
bash references/scripts/loop-log.sh <abs workdir> <N> <attempt> "<change>" -- bash <abs workdir>/check.sh <N>
```

**Step 4 — Merge.** When all tasks passed, run the whole-epic check on the merged epic branch:

```bash
bash references/scripts/loop-log.sh <abs workdir> MERGE 1 "merge" -- bash <abs workdir>/check.sh
```

If some tasks failed, are unverified or got exit 4, do a partial delivery at once, in the same turn. Build a tree with only the passed tasks, then:

```bash
bash references/scripts/loop-log.sh <abs workdir> MERGE-partial <n> "<N1> <N2> ..." -- bash <abs workdir>/check.sh <N1> <N2> ... SCOPE
```

Deliver only on `state: pass`. No `MERGE` or `MERGE-partial` line = the run is not finished.

**Step 5 — Gate.** Sort every change by cost to undo:

- cheap and contained: ship it;
- reversible but wide: ship only on hard evidence;
- irreversible (migrations, deletes, prod data, money): stop and wait for the user, whatever your confidence.

---

## GitHub Sync During the Run

`loop-log.sh` calls `loop-sync.sh` after each line. The agent never calls `gh` for these steps itself.

| Event | GitHub | Local files |
|---|---|---|
| Attempt 1 starts | task: label `in-progress`, assignee `@me` | task `status: in-progress` |
| Each attempt | task: comment with attempt, state, exit, change, check | task `updated:` |
| Attempt passes | task: close, remove `in-progress`; epic: tick `- [x] #N` | task `status: closed`, epic `progress:` |
| Exit 4 (limit) | task: label `blocked`, comment with the reason | task `status: open` |
| `MERGE` / `MERGE-partial` / `CHECK` | epic: comment with the line | — |
| `MERGE` fails or is unverified | reopen every task closed by this run, untick it | task `status: open`, epic `progress:` |
| `MERGE-partial` passes | reopen the closed tasks not in the delivered set | same |
| `MERGE-partial` fails | reopen every task closed by this run | same |

A task closed on its own pass is provisional: a task that passed alone proves nothing about the merged tree, so a failed merge reopens it.

A failed `gh` call never changes the check's exit code. It goes to `loop/sync-failures.jsonl`. Retry it with `loop-sync.sh <workdir> line <unit>` or list it in the summary.

**Pre-approved in this mode**: comments, labels, assignee, close and reopen on the project's own task and epic issues. **Still stop and ask**: push, PR, epic merge to main, branch or worktree delete, and any write to another repo.

---

## Work Dir

`.claude/epics/<name>/loop/` (git-ignored):

| File | Content |
|---|---|
| `graph.json` | `[{"unit","job","input","output","failure_state","check","depends_on":[]}]` from `loop-graph.sh` |
| `check.sh`, `check.sha256` | the verifier's check, read-only |
| `check.v2.sh` | only after the user approved a goal change; log `loop-log.sh <wd> CHECK 2 "<criterion> -> <fix>" --no-check --reason "goal changed by user: <what>"` |
| `log.jsonl` | one line per attempt, written only by `loop-log.sh`: `ts, unit, attempt, change, check, exit, kept, state, reason, skill` |
| `closed.txt` | tasks closed by this run, used to reopen them after a failed merge |
| `sync-failures.jsonl` | failed `gh` calls |

A user-cancelled change: `loop-log.sh <wd> <N> <n> "<change>" --no-check --reason "user"`.

---

## Stop and Summary

Stop when the check passes, after 2 rounds with nothing new, or when the budget runs out. Then show one summary:

```
CHECK: <command> -> exit <n>
CHANGED: <issue: file list, one line each>
VERIFIED: <what ran, observed result>
REJECTED: <n attempts reverted, see loop/log.jsonl>
SYNC: <"all synced" or the lines of loop/sync-failures.jsonl>
APPROVAL NEEDED: <push / PR / merge, irreversible items, undelivered tasks with their state, or "none">
```
