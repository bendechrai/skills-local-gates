# REVERT a repo

Triggered by "we are out of MVP mode", "put CI back", "we have minutes
again", "remove the local gates". The job is to leave the repo as if it
had always been on hosted CI, with nothing dangling that will confuse
somebody in a month.

Do it as one commit, so the restore is one revert if it turns out to be
premature.

## 1. Restore the hosted CI triggers

The WIRE step left a header comment in the workflow file naming exactly
what the triggers were. Put those back and delete the comment.

If the comment is gone, git history has it:

    git log --oneline -- .github/workflows/ci.yml
    git show <sha-before-the-switch>:.github/workflows/ci.yml

Restore the trigger block only. Other changes made to the workflow
since the switch are somebody's work and stay.

`ci-manual-only.md` has the before/after per provider.

## 2. Remove the hook

    git rm .githooks/pre-push

If `.githooks/` is now empty, remove it and `bin/setup-git-hooks.sh`
too. If a `pre-commit` hook is still there, keep both: that hook is the
fast local lane and has nothing to do with this skill.

Then, in **every clone**, unset the config:

    git config --unset core.hooksPath

It lives in `.git/config`, which is per-clone and not something a
commit can reach. Say so plainly in the summary: a leftover
`core.hooksPath` pointing at a directory that no longer exists is a
push failure somebody will hit weeks later with no idea why.

## 3. Remove the runner and the gates

    git rm bin/preflight.sh bin/preflight.gates.sh

Keep them only if the user wants `bin/preflight.sh` as a manual
pre-push check - that is a legitimate half-way house, but say which one
was chosen, because "the gates still exist but nothing runs them" is
the worst of both.

## 4. Delete the markers and the caches

    rm -rf .git/local-gates-ok

Nothing was committed, so this is the only trace inside the repo. The
docker caches are the only thing outside it:

    docker volume ls --filter name=local-gates
    docker volume rm <the ones this project made>

Worth naming in the summary even if you leave them: they are a few
hundred megabytes per lockfile, and nobody would think to look.

## 5. Update the docs

- `DEFINITION_OF_DONE.md`: put CI back as the enforcement point, drop
  the `bin/preflight.sh` commands and the `smoke` marker paragraph, and
  keep the waiver convention - that was always the project's, not this
  skill's.
- `CLAUDE.md`/`AGENTS.md`: remove the local-gates paragraph.
- Leave one line saying the gates ran locally between which dates. The
  next person wondering why there are no CI runs for a fortnight
  deserves an answer that is not "nobody knows".

## 6. Prove CI still works

Run the restored workflow once and wait for it to be green before
calling the revert done:

    gh workflow run ci.yml --ref <branch>
    gh run watch

A workflow that has not run for a month has a stale action version, an
expired token or a secret somebody rotated. Finding that out now costs
one run; finding it out during an incident costs a great deal more.

If it comes back red, fix it as part of the revert. Handing back a repo
with no local gates *and* red CI is strictly worse than either
arrangement on its own.

## 7. Report

- what was removed and from where;
- the `git config --unset core.hooksPath` line, flagged as something
  every other clone needs;
- the CI run and its result, with a link;
- any docker volumes left behind;
- anything the local gates covered that hosted CI does not, so the user
  knows what they just gave up.
