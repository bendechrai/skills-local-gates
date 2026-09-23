# The contract

What a repo wired by this skill guarantees, and why each clause is
there. If a decision during WIRE or REVERT is not obvious, this file is
the tie-breaker.

## 1. The pre-push hook is the enforcement point

Every Definition-of-Done gate runs in `.githooks/pre-push`, through
`bin/preflight.sh <commit>`.

Pre-push rather than pre-commit, because a commit is a private act and
a push is a public one. Gating commits makes people commit less, which
makes the history worse and the gates more annoying without making the
remote any safer. Pre-push is the last moment the work is still only
yours.

Pre-push rather than a hosted check, because a check that reports after
the push has already let the bad commit onto the branch everybody else
pulls, and because waiting for a check mark is dead time somebody pays
for twice - once in minutes, once in attention.

The hook refuses the push on the first failure. There is no partial
pass and no "it was only the lint job".

## 2. A clean export of the pushed commit

`git archive <commit>` into a temporary directory; every gate runs with
that directory as its working directory; the directory is deleted on
exit.

`git archive` can only contain tracked files at that commit. That rules
out, in one move, every "works on my machine" failure that is really a
state failure:

- a generated file the dev container has and a clone does not (a
  generated type declaration is the classic, and it fails typecheck on
  a fresh checkout while passing locally for months);
- a build directory left by a previous run, so the build being tested
  is not the build being shipped;
- an installed dependency tree from a lockfile that has since changed;
- a file somebody forgot to `git add`, which is invisible locally and
  fatal everywhere else.

It also means the gates test *the pushed commit*, not `HEAD` and not
the working tree. When several branches go up in one push, each one is
gated as what the remote will hold.

The corollary is a rule for gates: read the repo through `$PWD` (the
archive), never through a path back into the checkout. A gate that
reaches back into the working tree has quietly reintroduced everything
above.

## 3. Hosted CI goes manual, not away

The workflow file stays, with its triggers replaced by the provider's
manual-only trigger and a header comment recording exactly what to put
back. See `ci-manual-only.md`.

Deleted CI is CI that nobody restores, and a repo with no workflow file
gives the next person nothing to restore *from*. Manual CI can also be
run on demand - which is precisely what the REVERT procedure does to
prove the restore worked.

## 4. The gate order

    deps -> compile -> lint -> tests -> secrets -> vulns -> sast
         -> migrations -> smoke

The order is cheapest-and-most-diagnostic first, so the thing that
fails most often fails soonest. Nobody wants to discover a typo after
twelve minutes of browser tests.

- **deps** - install from the lock file, nothing resolved afresh, no
  lifecycle scripts (`npm ci --ignore-scripts`, `dotnet restore
  --locked-mode`, `uv sync --frozen`). Proves a clone with an empty
  cache can build this. Resolving versions here would test today's
  registry rather than the commit.
- **compile** - the compiler or type checker, warnings included where
  the stack can be told to (`-warnaserror`). No escape hatches.
- **lint** - zero errors *and* zero warnings. A warning count nobody
  fails on only grows. Verified, never auto-fixed: a hook that rewrites
  files changes what is about to be pushed.
- **tests** - unit and integration together, with every service
  dependency in a throwaway container on the run's own network. Never
  against the dev database: a test that passes on rows dev happens to
  hold has proven nothing. Never against an in-memory substitute for
  the real engine, which is the component most likely to disagree with
  production.
- **secrets** - a secrets scan over the exported content. This proves
  the bytes about to reach the remote are clean; scanning full history
  is a different job, worth running once when the repo is wired.
- **vulns** - known-vulnerable dependencies, transitive included. A
  vulnerable transitive dependency whose parent has not released a fix
  gets pinned forward in the manifest, never allowlisted in the
  scanner: an allowlist hides the advisory from the next person too.
- **sast** - static analysis over the exported content.
- **migrations** - replay on a database that has never seen them, then
  replay again and assert the second pass applies nothing. The first
  proves they work on a fresh deploy, the second proves they are
  forward-only and safe on a deploy that retried.
- **smoke** - the browser or end-to-end suite, against a build of this
  commit rather than a dev server. A dev server compiles on demand, and
  the first request to a cold route is slow enough to look like a flaky
  test.

A project without one of these leaves that name out of `GATES`. It does
not repurpose a name: `--only lint` has to mean the same thing in every
repo on the machine, and "the tests gate is red" has to mean the same
thing in every conversation.

## 5. `smoke` is certified per tree

When the smoke gate passes, the runner writes
`.git/local-gates-ok/<tree-sha>`. While a marker for the tree being
pushed exists, the hook skips the gate and says so.

Keyed on the **tree**, not the commit: a rebase, an amended message, a
cherry-pick that lands identical content, or a second branch pointing
at the same bytes are all the same content, and the suite has already
proven it. Keyed on content rather than time, so the marker cannot go
stale while claiming otherwise.

Under `.git`, so it is never committed, never pushed, and never
believed on somebody else's machine. A marker that travelled would be a
green badge for a suite that never ran on the hardware it is claiming
about.

The marker is what makes the whole arrangement affordable. Without it,
the slow suite runs on every push of a branch, and a hook people resent
is a hook people bypass.

## 6. Waivers are named out loud

The only skip is `LOCAL_GATES_SKIP_SMOKE=1` (or `--skip-smoke`), and it
is always reported - by the runner, and in the completion summary, as:

    Waived: smoke - <reason>

The reason travels in `LOCAL_GATES_SKIP_SMOKE_REASON` so the run's own
output says it too.

No other gate has a skip, deliberately. Type errors, lint, secrets,
advisories and migrations are all either fast or important enough that
"just this once" is how a project stops having gates at all. If one of
them genuinely cannot run - a scanner's service is down - that is a
temporary failure to report to the user, not a flag to add.

A waiver is also not a verdict. It hands the decision to the person
reading the summary, which is the whole point of writing it down.

## 7. What "green" means

A change is green when **the push succeeded and the tree's marker
exists**, or when a waiver was reported.

Never "CI is running". Never "the checks should pass". With hosted CI
on manual trigger there is no check mark to wait for, and waiting for
one is how a task gets abandoned half done. The evidence is local and
it is available the moment the push returns.

Say which commit was gated, which gates ran, how long it took, and any
waiver. That is the whole report.
