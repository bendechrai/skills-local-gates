# skills-local-gates

A Claude Code skill that wires a repository so every Definition-of-Done
gate runs on the machine the code is written on - in a git pre-push
hook, against a clean export of the pushed commit - and switches hosted
CI to manual trigger only. Install it while a project is in heavy-PR or
MVP mode, when waiting on hosted check marks costs more than it buys;
remove it when the project outgrows that.

## Install

    npx skills add bendechrai/skills-local-gates

## Remove

    npx skills remove local-gates

Removing the skill does not unwire a repo. Ask Claude to revert the
repo first ("we are out of MVP mode, put CI back") - the skill knows how
to restore the workflow triggers, drop the hook and the runner, and
prove hosted CI is green again.

## The contract

1. Every gate runs in `.githooks/pre-push`, through
   `bin/preflight.sh <commit>`.
2. Gates run against `git archive` of the pushed commit - never the
   working tree, never the dev container.
3. Hosted CI is switched to manual trigger, with a header comment
   recording exactly what to restore. Nothing is deleted.
4. Gate order is fixed: `deps`, `compile`, `lint`, `tests`, `secrets`,
   `vulns`, `sast`, `migrations`, `smoke`.
5. Service dependencies run in throwaway containers on a network
   created for the run and removed after it.
6. `smoke` is the reserved slow gate, certified once per tree by a
   marker under `.git/local-gates-ok/<tree-sha>`.
7. `bin/preflight.sh --only smoke` is the `smoke:certify` task; while
   the marker matches, the hook skips the suite.
8. The only waiver is `LOCAL_GATES_SKIP_SMOKE=1`, always reported as
   `Waived: smoke - <reason>`.
9. Green means the push succeeded and the marker exists, or a waiver
   was reported.
10. Never wait for a PR check mark. With CI on manual there is nothing
    to wait for.

## What is in here

    skills/local-gates/
      SKILL.md                      the contract, WIRE and REVERT
      scripts/preflight.sh          the generic, stack-agnostic runner
      scripts/pre-push              the generic hook
      scripts/setup-git-hooks.sh    one-shot core.hooksPath setup
      templates/gates/              per-stack gate definitions
      references/                   contract, wire, revert, CI triggers

The runner is generic and gets copied into a repo unedited. Everything
project-specific lives in one file, `bin/preflight.gates.sh`, which
defines an ordered `GATES` array and one shell function per gate.

## Licence

MIT - see `LICENSE`.
