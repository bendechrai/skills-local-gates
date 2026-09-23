# Hosted CI, manual trigger only

The workflow file stays. Only its triggers change, and the header
comment is what makes the change reversible by somebody who was not
there. Deleted CI is CI nobody restores.

Rules that hold for every provider:

- **Record the original trigger block verbatim** in a comment at the
  top of the file, including branch filters and path filters. "It was
  on push and PR" is not enough to restore - the filters are the part
  people get wrong.
- **Date it and say why**, so the comment is evidence rather than
  folklore.
- **Change nothing else.** Jobs, matrices, caches and secrets stay
  exactly as they are, so the manual run and the restored automatic run
  are the same run. The file also keeps earning its place as the
  specification `bin/preflight.gates.sh` mirrors - images, service
  containers, environment variables and commands. Change one and change
  the other in the same commit, or "green" starts meaning two things.
- **Read the jobs before mirroring them.** A step wired to a
  third-party action is not automatically doing what its name says: an
  action pinned to a retired image can fail to parse its own rules and
  still exit 0, so the workflow reports a scan it never ran. Running the
  tool's current CLI locally is the fix, and finding this is a reason to
  mirror deliberately rather than transcribe.
- **Check the manual run still works** once after the edit. A trigger
  edit that made the workflow unparseable is silent until somebody
  needs it.

## GitHub Actions

Before:

```yaml
on:
  pull_request:
  push:
    branches: [main]
```

After:

```yaml
# LOCAL GATES: triggers replaced with workflow_dispatch on 2026-09-23
# while this project is in MVP mode - every Definition-of-Done gate runs
# in .githooks/pre-push via bin/preflight.sh. Restore by replacing the
# `on:` block below with exactly:
#
#   on:
#     workflow_dispatch:
#     pull_request:
#     push:
#       branches: [main]
#
on:
  workflow_dispatch:
```

`workflow_dispatch` alone means the workflow runs only when somebody
asks:

    gh workflow run ci.yml --ref <branch>
    gh run watch

Two things to check while editing:

- **A `schedule:` trigger is a trigger too.** A nightly run costs
  minutes exactly like a push does, so it goes in the comment and comes
  out of the `on:` block.
- **`workflow_dispatch` needs the workflow to exist on the default
  branch** before the GitHub UI and `gh workflow run` will offer it. If
  the switch is made on a side branch, dispatch it by branch after the
  merge, or expect "workflow does not have workflow_dispatch trigger".

Leave `concurrency:` and `permissions:` alone.

## GitLab CI

GitLab has no single trigger block; rules live per job, and the
cheapest correct switch is a workflow-level rule.

Before (implicit: everything runs on every push and MR):

```yaml
stages: [test]
```

After:

```yaml
# LOCAL GATES: pipelines restricted to manual web/API triggers on
# 2026-09-23 while this project is in MVP mode - every
# Definition-of-Done gate runs in .githooks/pre-push via
# bin/preflight.sh. Restore by deleting the `workflow:` block below;
# before the switch there was no workflow-level rule, so pipelines ran
# on every push and merge request.
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "web"
    - if: $CI_PIPELINE_SOURCE == "trigger"
    - when: never

stages: [test]
```

Run one from the UI (CI/CD -> Pipelines -> Run pipeline) or:

    glab ci run --branch <branch>

If the project already had a `workflow:` block, quote it in full in the
comment and replace it - do not try to merge the two rule sets, which
is how a "manual only" pipeline ends up still running on every push.

## Azure Pipelines

Before:

```yaml
trigger:
  branches:
    include: [main]
pr:
  branches:
    include: ['*']
```

After:

```yaml
# LOCAL GATES: CI and PR triggers disabled on 2026-09-23 while this
# project is in MVP mode - every Definition-of-Done gate runs in
# .githooks/pre-push via bin/preflight.sh. Restore by replacing the two
# lines below with exactly:
#
#   trigger:
#     branches:
#       include: [main]
#   pr:
#     branches:
#       include: ['*']
#
trigger: none
pr: none
```

`trigger: none` and `pr: none` both matter: omitting `pr:` does not
disable PR validation, it restores the default, which is to run on
every pull request. Run one by hand from the pipeline's **Run
pipeline** button or:

    az pipelines run --name <pipeline> --branch <branch>

## Anything else

Same three moves whatever the provider: find the block that says *when*
this runs, replace it with the provider's "only when asked", and put
the original in a dated comment directly above it. If the provider has
no manual trigger at all, disable the pipeline in its UI instead and
record in the repo's DoD where that switch is - a setting nobody can
find in the repo is a setting nobody will restore.
