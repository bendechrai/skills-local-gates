---
name: local-gates
description: Wire a repository so every Definition-of-Done gate runs on this machine in a git pre-push hook, against a clean export of the pushed commit, and switch hosted CI to manual-trigger only - then revert it cleanly when the project leaves MVP mode. Use this skill whenever the user asks to run CI locally, set up or repair a pre-push hook, stop spending GitHub Actions / GitLab / Azure minutes, "wire the gates", gate a repo that is in heavy-PR or MVP mode, or to revert local gates, restore CI or take a project out of MVP mode. Use it too when the user is waiting on PR check marks, grumbling about CI minutes or billing, or asking for the gates to run before a push rather than after it.
---

# local-gates

While this skill is installed, a repository's Definition of Done is
enforced by the machine the code is written on, before anything leaves
it. Hosted CI stays in the repo, wired to manual trigger, so it can be
run on demand and restored in one edit.

Two procedures: **WIRE** a repo, and **REVERT** it. Read the contract
first - it is what both procedures are trying to achieve, and it is
what to check the result against.

## The contract

Full prose in `references/contract.md`. The short form:

1. **Every gate runs in `.githooks/pre-push`**, through
   `bin/preflight.sh <commit>`. The hook is the only enforcement point;
   nothing important is left to the reviewer's patience or to a check
   mark that arrives after the fact.
2. **Gates run against a clean export of the pushed commit**, never the
   working tree and never the dev container. `git archive` can only
   contain tracked files at that commit, so a gate that passes here
   passes for whoever clones it next. "It works in my container" is
   exactly the failure this design exists to catch: generated files,
   stale builds and a `node_modules` from a lockfile that has since
   changed all live in the container and in no clone.
3. **Hosted CI becomes manual-trigger only.** It is not deleted - a
   deleted workflow is a workflow nobody restores. `references/ci-manual-only.md`
   has the exact edit per provider, including the header comment that
   records the triggers to put back.
4. **Gate order is fixed**, cheapest and most diagnostic first:

   `deps` -> `compile` -> `lint` -> `tests` -> `secrets` -> `vulns` ->
   `sast` -> `migrations` -> `smoke`

   install dependencies from the lock file; compile or typecheck; lint
   with zero warnings tolerated; unit and integration tests with every
   service dependency in a throwaway container; secrets scan;
   dependency vulnerability scan; static security scan; migration
   replay on a fresh database twice, the second run a no-op; then the
   browser or end-to-end suite. A project with no database skips
   `migrations` by leaving it out of `GATES`; it does not redefine what
   the names mean.
5. **`smoke` is the reserved slow gate**, certified once per tree. When
   it passes, the runner writes `.git/local-gates-ok/<tree-sha>`; while
   that marker matches, the hook skips it. Keyed on the tree, so a
   rebase, an amended message or a second branch over the same content
   is already proven. Under `.git`, so it is never committed and never
   shared - another machine earns its own.
6. **The only waiver is `LOCAL_GATES_SKIP_SMOKE=1`**, and it is always
   reported, in the run and in the completion summary, as
   `Waived: smoke - <reason>`. Never quietly skip a gate.
7. **"Green" means the push succeeded and the marker exists, or a
   waiver was reported.** Never wait for a PR check mark, and never
   describe a change as done because a hosted run is queued: with CI on
   manual there is nothing to wait for.

## WIRE a repo

Work through these in order. Each step says what it must end up
proving, because the commands differ per stack and the proof does not.
`references/wire.md` has the full step-by-step with the exact edits.

1. **Read the repo's own instructions first.** `AGENTS.md` or
   `CLAUDE.md`, and the `DEFINITION_OF_DONE.md` it indexes. The
   project's DoD wins over any default: this skill moves *where* the
   gates run, never *what* they are. If the repo has no DoD, say so and
   agree the gate list with the user before writing anything.
2. **Detect the stack.** Lockfiles and project files answer it:
   `package-lock.json`/`pnpm-lock.yaml` (Node), `*.sln`/`*.csproj`
   (.NET), `uv.lock`/`poetry.lock`/`requirements.txt` (Python),
   `go.mod`, `Cargo.toml`, `Gemfile.lock`. Note the app directory - a
   monorepo rarely has its package at the root - and whether the tests
   need a database, a mail sink or any other service.
3. **Copy the runner and the hook** into the target repo:

       skills/local-gates/scripts/preflight.sh      -> bin/preflight.sh
       skills/local-gates/scripts/pre-push          -> .githooks/pre-push
       skills/local-gates/scripts/setup-git-hooks.sh -> bin/setup-git-hooks.sh

   (find the skill's own directory with the path this SKILL.md was read
   from). `chmod +x` all three. They are generic; do not edit them.
   Everything project-specific belongs in the gates file.
4. **Write `bin/preflight.gates.sh`.** Start from the closest template
   in `templates/gates/` (`node-compose.gates.sh` is complete;
   `dotnet.gates.sh` and `python.gates.sh` are skeletons with the same
   names and TODO commands). It defines an ordered `GATES` array and
   one bash function per name. The runner sources it **out of the
   archive**, with the archive as the working directory, and exports
   `PREFLIGHT_NET` (a docker network created for the run),
   `PREFLIGHT_ID` (name prefix for throwaway containers, reaped by the
   runner), `PREFLIGHT_DIR`, `PREFLIGHT_COMMIT` and `PREFLIGHT_TREE`.
   Lift the commands from the repo's DoD and its CI workflow - the
   workflow is the working record of what the gates actually are.
5. **Install the hooks:** `bin/setup-git-hooks.sh`. It sets
   `core.hooksPath` to `.githooks`; nothing is copied into `.git/hooks`,
   so there is no second copy to drift. Each clone runs it once, because
   git refuses to check `core.hooksPath` in - a hook that installed
   itself on clone would be code execution on `git clone`.
6. **Switch hosted CI to manual trigger**, with the header comment that
   records what to restore (`references/ci-manual-only.md`).
7. **Run the whole thing once, end to end:** `bin/preflight.sh`. Not
   `--only`, not `--skip-smoke` - the first run is the one that proves
   the wiring, and a gate nobody has ever seen pass is a gate nobody
   can trust. Expect it to be slow the first time: images pull,
   dependencies install into a fresh cache volume. Fix what it finds,
   including failures that predate the wiring, or report them
   explicitly.
8. **Record the commands** in the repo's `DEFINITION_OF_DONE.md` ("How
   Claude tests") and in its `CLAUDE.md`/`AGENTS.md`: that the gates run
   pre-push, `bin/preflight.sh [--list|--only <gate>|--skip-smoke]`,
   that `smoke` is certified per tree, that hosted CI is manual while
   the project is in MVP mode, and how to waive. Someone reading the
   repo in three weeks has to find this without reading the hook.
9. **Report**: the gate list, the end-to-end run's result and timing,
   any waiver line, and what the revert would touch.

## REVERT a repo

Triggered by "out of MVP mode", "put CI back", "we have minutes again".
`references/revert.md` has the step-by-step.

1. **Restore the hosted CI triggers** from the header comment the WIRE
   step left, or from git history (`git log --oneline -- <workflow>`,
   then `git show <sha>:<workflow>`). Delete the header comment.
2. **Remove the hook**: delete `.githooks/pre-push` and, if
   `.githooks/` now holds nothing, the directory and
   `bin/setup-git-hooks.sh` with it. Unset the config in every clone
   that has it: `git config --unset core.hooksPath`. The config is
   per-clone, so say plainly that anybody else's checkout needs the same
   line - a leftover `core.hooksPath` pointing at a directory that no
   longer exists is a confusing push failure later.
3. **Remove the runner**: `bin/preflight.sh` and
   `bin/preflight.gates.sh`.
4. **Delete the markers**: `rm -rf .git/local-gates-ok`. Optionally
   `docker volume rm` the `local-gates-*` caches, which is worth naming
   because they are the only thing that survives outside the repo.
5. **Update the docs** - the repo's DoD and `CLAUDE.md` - back to CI as
   the enforcement point. Leave a line saying the gates ran locally
   between which dates; the next person wondering why there are no CI
   runs for a fortnight deserves an answer.
6. **Run hosted CI once and confirm it is green** before calling the
   revert done. A workflow that has not run for a month is a workflow
   with a stale action version, an expired token or a missing secret,
   and finding that out during an incident is the worst possible time.

## Using the runner day to day

    bin/preflight.sh                  # every gate against HEAD
    bin/preflight.sh <commit-ish>     # against something else
    bin/preflight.sh --list           # the gate order for this repo
    bin/preflight.sh --only lint      # one gate, repeatable
    bin/preflight.sh --skip-smoke     # waive the slow gate (report it)

`--only smoke` is the `smoke:certify` task: it runs the slow suite and
writes the marker, so the next push skips it. Wire it as the project's
own script (`npm run smoke:certify`, a make target) so it is the same
one command whatever the stack. `LOCAL_GATES_NO_MARKER=1` runs it
without certifying, which is what you want while debugging the suite
itself.

The push path is the hook, and the hook needs no arguments: it reads
the refs git gives it, gates the commit each ref will put on the
remote, deduplicates by tree, ignores deletes, peels tags, and refuses
the push on the first failure. `git push --no-verify` bypasses it; that
is a thing to justify in the summary, not a habit.

## Files in this skill

- `scripts/preflight.sh` - the generic runner. Copy into `bin/`.
- `scripts/pre-push` - the generic hook. Copy into `.githooks/`.
- `scripts/setup-git-hooks.sh` - one-shot `core.hooksPath` setup.
- `templates/gates/node-compose.gates.sh` - complete Node + Postgres
  gates file, the one to read first even for another stack.
- `templates/gates/dotnet.gates.sh`, `templates/gates/python.gates.sh` -
  skeletons with the same gate names and TODO commands.
- `references/contract.md` - the contract in full, with the reasoning.
- `references/wire.md` - WIRE, step by step, with the exact edits.
- `references/revert.md` - REVERT, step by step.
- `references/ci-manual-only.md` - GitHub Actions, GitLab CI and Azure
  Pipelines: the trigger edit and the restore comment.

## Things that go wrong

- **A gate passes locally and would fail on a clone.** It is reading
  something the archive does not contain. Check the gate is using
  `$PWD` (the archive) rather than a path back into the repository, and
  that the file it wants is tracked.
- **Docker containers pile up.** A gate started one outside the
  `$PREFLIGHT_ID` prefix, so the runner could not reap it. Name every
  throwaway container `"$PREFLIGHT_ID-<role>"`.
- **The hook does not run.** `git config core.hooksPath` is per-clone
  and someone has a fresh clone. Run `bin/setup-git-hooks.sh`.
- **`smoke` reruns every push.** Something in the tree changed, which
  is correct, or the repo was cloned since (markers live under `.git`
  and do not travel). If it reruns on identical content, check the
  runner is not being passed `LOCAL_GATES_NO_MARKER`.
- **The first run is very slow.** Images and dependency caches are
  cold. It is once per image and once per lockfile, not once per push.
