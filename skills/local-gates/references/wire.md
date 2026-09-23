# WIRE a repo

Step by step, with the exact edits. Read `contract.md` first if you
have not; these steps are how the contract gets built, and when a step
does not fit the repo in front of you, the contract is what to preserve.

Throughout, `$SKILL` is this skill's directory - the one holding the
`SKILL.md` you are reading.

## 0. Read before writing

- The repo's `AGENTS.md` or `CLAUDE.md`, and the
  `DEFINITION_OF_DONE.md` it indexes. **The project's DoD wins.** This
  skill changes where the gates run, never what they are. A gate the
  DoD names and this skill's default order does not is still a gate.
- The hosted CI workflow. It is the working record of what the gates
  actually are, including the environment they need - service
  containers, placeholder credentials, a mail sink, a health endpoint
  to wait on. Lift those into the gates file rather than rediscovering
  them one failure at a time.
- If the repo has no DoD, say so, and agree the gate list with the user
  before writing anything. Inventing a bar and then enforcing it on
  somebody's pushes is not a decision to make quietly.

## 1. Detect the stack

| Marker | Stack | Template |
| --- | --- | --- |
| `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` | Node | `node-compose.gates.sh` |
| `*.sln`, `*.csproj`, `Directory.Packages.props` | .NET | `dotnet.gates.sh` |
| `uv.lock`, `poetry.lock`, `requirements.txt` | Python | `python.gates.sh` |
| `go.mod`, `Cargo.toml`, `Gemfile.lock` | other | start from `node-compose.gates.sh` for shape |

Also establish, because the gates file needs all of it:

- the **app directory** (`webapp/`, `src/Api/`, `.`) - a monorepo
  rarely has its package at the root;
- which gates need a **service** (a database, a mail sink, a cache) and
  what the app expects the connection string to be called;
- the **health endpoint** the smoke gate waits on;
- the **commands** for each gate, from `package.json` scripts, the
  `Makefile`, or the CI workflow.

## 2. Copy the three generic files

    mkdir -p bin .githooks
    cp "$SKILL/scripts/preflight.sh"       bin/preflight.sh
    cp "$SKILL/scripts/pre-push"           .githooks/pre-push
    cp "$SKILL/scripts/setup-git-hooks.sh" bin/setup-git-hooks.sh
    chmod +x bin/preflight.sh bin/setup-git-hooks.sh .githooks/pre-push

Do not edit them. Everything that knows what this project is belongs in
the gates file, so an improvement to the runner is one copy away in
every repo rather than a merge.

If the repo already has a `bin/setup-git-hooks.sh` and a `pre-commit`
hook (the usual case for a repo that had a fast lane before), keep
both: the pre-commit hook stays as the quick local check, and pre-push
becomes the full bar. Make sure the existing setup script still
`chmod +x`es everything in `.githooks/`.

## 3. Write `bin/preflight.gates.sh`

Copy the closest template and edit the configuration block at the top,
then the commands:

    cp "$SKILL/templates/gates/node-compose.gates.sh" bin/preflight.gates.sh

What the runner guarantees the file:

| Name | What it is |
| --- | --- |
| cwd | the archive directory - the exported commit |
| `PREFLIGHT_DIR` | the same path, absolute |
| `PREFLIGHT_NET` | a docker network created for this run, removed after |
| `PREFLIGHT_ID` | name prefix for throwaway containers; the runner force-removes anything still named with it on exit |
| `PREFLIGHT_COMMIT` / `PREFLIGHT_TREE` | the commit and tree being gated |
| `PREFLIGHT_REPO` | the checkout, for the rare gate that cannot use the archive |
| `PREFLIGHT_MARKER_DIR` | where smoke certifications are written |

What the file must define:

- `GATES=(...)`, ordered. Leave out a gate the project has no use for;
  do not rename one.
- one bash function per name in `GATES`. Errexit is on while a gate
  runs, so a bare failing command ends the gate. Where the gate has
  cleanup of its own, catch the failure (`cmd || status=1`) and
  `return "$status"` at the end - errexit would otherwise skip the
  cleanup.
- optionally `preflight_precheck`, run once before any gate. It is
  where "`node_modules` / the generated type declaration / the build
  directory must not be committed" belongs: the archive's whole promise
  is that it holds only tracked files, and a generated file somebody
  committed defeats that silently.

Rules worth keeping while editing:

- **Name every throwaway container `"$PREFLIGHT_ID-<role>"`**, so a gate
  that dies half way leaves nothing behind.
- **Attach services to `$PREFLIGHT_NET`** and address them by container
  name. Do not publish ports to the host: two runs at once would
  collide, and dev's own stack may be holding the port.
- **Cache dependencies in a named volume keyed by a hash of the lock
  file.** An unchanged dependency set then installs once; a changed one
  cannot reuse the wrong install. A fresh named volume is root-owned,
  so hand it to the caller once with a `chown` container before
  anything runs `--user`.
- **Run containers `--user "$(id -u):$(id -g)"`** over the archive.
  Without it the container writes as root into the bind mount and the
  archive cannot be cleaned up afterwards.
- **Never touch the dev stack.** No `docker compose exec`, no dev
  database, no host port. A gate that reuses dev state proves only that
  dev state works.

## 4. Install the hooks

    bin/setup-git-hooks.sh

It sets `core.hooksPath` to `.githooks` and marks the hooks executable.
Nothing is copied into `.git/hooks`, so there is no second copy to
drift. Every clone runs it once: git deliberately refuses to check
`core.hooksPath` into the repo, because a hook that installed itself on
clone would be arbitrary code execution on `git clone`.

Check it took: `git config core.hooksPath` prints `.githooks`.

## 5. Switch hosted CI to manual

`ci-manual-only.md` has the edit per provider. The shape is always the
same: replace the trigger block with the provider's manual-only form,
and leave a header comment naming exactly what was there before, so the
revert is a paste rather than an excavation.

## 6. Prove it, end to end

    bin/preflight.sh

The whole suite, against HEAD, with no `--only` and no `--skip-smoke`.
A gate nobody has ever watched pass is a gate nobody can trust, and the
first run is the one that finds the missing service, the wrong
connection string and the health endpoint that is actually at a
different path.

The first run is slow - images pull, caches fill. That is once per
image and once per lockfile, not once per push.

Fix what it finds. Failures that predate the wiring are still failures:
fix them, or report them explicitly as preexisting with what you would
do about them. Do not wire a repo whose gates you have left red.

## 7. Write it down

In the repo's `DEFINITION_OF_DONE.md`, under "How Claude tests" (or
equivalent), replace the CI paragraph with the local arrangement:

- the gates run in the pre-push hook, against a clean export of the
  pushed commit;
- `bin/preflight.sh`, `--list`, `--only <gate>`, `--skip-smoke`;
- `smoke` is certified per tree under `.git/local-gates-ok/`, and the
  project's `smoke:certify` task is `bin/preflight.sh --only smoke`;
- hosted CI is manual-trigger only while the project is in MVP mode,
  and how to run it by hand;
- the waiver line: `Waived: smoke - <reason>`.

In `CLAUDE.md`/`AGENTS.md`, a short paragraph pointing at the same
thing, plus the one-line install for a fresh clone
(`bin/setup-git-hooks.sh`). Somebody reading the repo in three weeks
has to find this without reading the hook.

## 8. Report

- the gate list, in order;
- the result of the end-to-end run and how long it took;
- any waiver, in the `Waived: <gate> - <reason>` form;
- what a later revert would touch (the workflow file, the hook, the
  runner, the markers, the docs);
- anything about the repo that could not be gated locally and why -
  a scan that needs a hosted token, a device farm, a licence that only
  exists on the runner. Those stay in hosted CI and get named in the
  DoD as run-on-demand.
