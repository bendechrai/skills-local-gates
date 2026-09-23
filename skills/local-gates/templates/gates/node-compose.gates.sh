#!/usr/bin/env bash
#
# bin/preflight.gates.sh - Node + Docker Compose + Postgres project.
#
# Sourced by bin/preflight.sh with the exported commit as the working
# directory. It must define an ordered GATES array and one function per
# name in it. Nothing here may touch the developer's working tree, the
# running dev stack, or any long-lived database: a gate that reuses dev
# state proves only that dev state works.
#
# The runner exports:
#   PREFLIGHT_ID     name prefix for throwaway containers; the runner
#                    force-removes anything still named with it on exit,
#                    so a gate that dies half way leaves nothing behind
#   PREFLIGHT_NET    a docker network created for this run and removed
#                    after it, so service containers are reachable by
#                    name and by nothing else
#   PREFLIGHT_DIR    the archive directory (also the cwd of every gate)
#   PREFLIGHT_COMMIT / PREFLIGHT_TREE
#
# Adjust the block below and the commands; leave the gate names alone so
# `--only <gate>` means the same thing in every repo on this machine.
#
# Errexit is on while a gate runs, so a bare failing command ends the
# gate immediately. Where a gate has cleanup of its own to do, it catches
# the failure with `|| status=1` and returns that at the end.

# Images are pinned to exactly what the hosted workflow used. Changing one
# here without changing the workflow is how the two quietly stop agreeing
# about what "green" means - and the workflow is still the specification
# this file mirrors, which is the reason it is kept rather than deleted.
APP_DIR="webapp"
NODE_IMAGE="node:22-bookworm"
PG_IMAGE="postgres:17"
OSV_IMAGE="ghcr.io/google/osv-scanner:v2.0.1"
SEMGREP_IMAGE="semgrep/semgrep:latest"
GITLEAKS_IMAGE="zricethezav/gitleaks:latest"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v1.63.0-noble"
DB_NAME="app"
db_url_for() { echo "postgresql://postgres:postgres@$1:5432/$DB_NAME"; }

# node_modules is cached in a named volume keyed by the lockfile, so a run
# that changes no dependencies reuses the install and a run that changes
# one cannot possibly reuse the wrong install. A volume rather than a
# directory in the archive, because the archive is deleted after each run.
LOCK_HASH="$(sha256sum "$APP_DIR/package-lock.json" 2>/dev/null | cut -c1-16)"
: "${LOCK_HASH:=nolock}"
NODE_MODULES_VOL="local-gates-node-$LOCK_HASH"

# `tests` rather than `test`, because a shell function named test shadows
# the builtin for everything sourced alongside it.
# shellcheck disable=SC2034 # read by the runner after it sources this file
GATES=(deps compile lint tests secrets vulns sast migrations smoke)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

NODE_RUN_ENV=(-e "PREFLIGHT=1")

# Run a shell command in a throwaway node container over the archive.
# --user keeps everything it writes owned by the caller; without it npm
# writes as root into the bind mount and the archive cannot be cleaned up
# afterwards. A non-root npm needs a writable HOME and cache, hence the
# two environment variables.
node_run() {
  docker run --rm \
    --network "$PREFLIGHT_NET" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
    "${NODE_RUN_ENV[@]}" \
    -v "$PWD/$APP_DIR:/app" \
    -v "$NODE_MODULES_VOL:/app/node_modules" \
    -w /app "$NODE_IMAGE" sh -c "$1"
}

# Start a Postgres nobody else can reach, on the run's own network, and
# wait for it. Every gate that needs a database starts its own and throws
# it away: two gates sharing one would make the second depend on whatever
# the first left behind.
start_postgres() {
  local name="$PREFLIGHT_ID-$1"
  docker run -d --name "$name" --network "$PREFLIGHT_NET" \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB="$DB_NAME" "$PG_IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    if docker exec "$name" pg_isready -U postgres -q 2>/dev/null; then
      echo "$name"
      return 0
    fi
    sleep 1
  done
  docker logs "$name" 2>&1 | tail -20 >&2
  return 1
}

stop_container() { docker rm -f "$1" >/dev/null 2>&1 || true; }

# Optional, run once before any gate. The whole point of the archive is
# that it holds only tracked files; a generated file somebody committed
# defeats that silently, and the gate it would have broken is the one
# that then passes here and fails on a clean clone.
preflight_precheck() {
  [ -d "$APP_DIR" ] || { echo "the archive has no $APP_DIR/ - wrong commit?" >&2; return 1; }
  for generated in "$APP_DIR/node_modules" "$APP_DIR/next-env.d.ts" "$APP_DIR/.next"; do
    [ -e "$generated" ] && { echo "$generated is committed; it is meant to be generated" >&2; return 1; }
  done
  return 0
}

# ------------------------------------------------------------------
# 1. deps - the install a fresh clone would get, from the lockfile only
# ------------------------------------------------------------------
# --ignore-scripts blocks post-install shell execution, the most common
# supply-chain vector. Native binaries ship as optionalDependencies and
# need no lifecycle scripts.
deps() {
  docker volume create "$NODE_MODULES_VOL" >/dev/null

  # A fresh named volume is root-owned and the containers above run as the
  # caller, so hand it over once before anything tries to write to it.
  docker run --rm -v "$NODE_MODULES_VOL:/vol" "$NODE_IMAGE" \
    chown -R "$(id -u):$(id -g)" /vol

  if [ -z "${LOCAL_GATES_FRESH_INSTALL:-}" ] \
     && node_run "test -f node_modules/.local-gates-installed" 2>/dev/null; then
    echo "reusing $NODE_MODULES_VOL (lockfile unchanged)"
    return 0
  fi

  node_run "npm ci --ignore-scripts && touch node_modules/.local-gates-installed"
  # Provenance coverage is not complete yet, so this is a trip-wire in the
  # log rather than a gate of its own.
  node_run "npm audit signatures || true"
  # An `npm install` can leave a lockfile tree npm itself considers
  # inconsistent, without complaining at the time. It surfaces later as a
  # failed SBOM step or a refusal to `npm ci` on a clean machine, so it is
  # cheaper to ask here.
  node_run "npm ls --all --package-lock-only >/dev/null"
}

# ------------------------------------------------------------------
# 2. compile - the type checker, with no escape hatches
# ------------------------------------------------------------------
compile() { node_run "npm run typecheck"; }

# ------------------------------------------------------------------
# 3. lint - zero errors and zero warnings
# ------------------------------------------------------------------
# A warning count nobody fails on is a warning count that only grows.
lint() { node_run "npm run lint -- --max-warnings=0"; }

# ------------------------------------------------------------------
# 4. tests - unit and integration, against a real database
# ------------------------------------------------------------------
# The integration suite talks to Postgres, so it gets one of its own for
# the length of the gate. Against the dev database a test could pass on
# rows dev happens to hold.
tests() {
  local db url status=0
  db="$(start_postgres db)" || return 1
  url="$(db_url_for "$db")"
  NODE_RUN_ENV=(-e "PREFLIGHT=1" -e "DATABASE_URL=$url" -e "NODE_ENV=test")
  node_run "npm run test" || status=1
  NODE_RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# ------------------------------------------------------------------
# 5. secrets - nothing credential-shaped in the pushed content
# ------------------------------------------------------------------
# `gitleaks dir` rather than `detect`: the archive has no history, and
# this gate proves the bytes about to reach the remote are clean.
# Scanning full history is a different job, worth running once when the
# repo is wired rather than on every push.
secrets() {
  docker run --rm -v "$PWD:/repo:ro" "$GITLEAKS_IMAGE" \
    dir /repo --redact --no-banner
}

# ------------------------------------------------------------------
# 6. vulns - known-vulnerable dependencies
# ------------------------------------------------------------------
# Two readers of the same lockfile, because they disagree usefully:
# osv-scanner reads OSV and GHSA, npm audit reads the npm advisory feed.
# A transitive dependency whose parent has not released a fix gets pinned
# forward with an `overrides` entry, never an allowlist entry in the
# scanner - an allowlist hides the advisory from the next person too.
vulns() {
  docker run --rm -v "$PWD:/repo:ro" "$OSV_IMAGE" \
    --lockfile="/repo/$APP_DIR/package-lock.json"
  node_run "npm audit --audit-level=high"
}

# ------------------------------------------------------------------
# 7. sast - static analysis on the pushed content
# ------------------------------------------------------------------
# The current CLI, not the semgrep GitHub Action: that action pulls a
# retired image from 2023 which cannot parse today's registry rules. It
# dies on the first rule with a MEDIUM severity and the wrapper still
# exits 0, so a workflow using it has been reporting success without
# scanning anything. A local gate that did the same would be worse than
# no gate.
#
# --severity ERROR is the "no HIGH severity findings" bar. Drop it to see
# the WARNING and INFO findings as well.
sast() {
  docker run --rm -v "$PWD:/src:ro" -w /src "$SEMGREP_IMAGE" \
    semgrep scan --error --quiet --metrics=off --severity ERROR \
      --config p/default \
      --config p/typescript \
      --config p/react \
      --config p/nodejs \
      --config p/owasp-top-ten \
      --config p/secrets
}

# ------------------------------------------------------------------
# 8. migrations - replay on an empty database, twice
# ------------------------------------------------------------------
# The first pass proves the migrations apply to a database that has never
# seen them. The second proves they are forward-only and idempotent under
# the tracking table: if the applied count moves, a migration would run
# again in production.
migrations() {
  local db url before after status=0
  db="$(start_postgres migrate)" || return 1
  url="$(db_url_for "$db")"
  NODE_RUN_ENV=(-e "PREFLIGHT=1" -e "DATABASE_URL=$url")

  applied_count() {
    docker exec "$db" psql -U postgres -d "$DB_NAME" -tAc \
      "SELECT count(*) FROM drizzle.__drizzle_migrations"
  }

  if node_run "npx drizzle-kit migrate"; then
    before="$(applied_count)" || before="first"
    if node_run "npx drizzle-kit migrate"; then
      after="$(applied_count)" || after="second"
      echo "applied before=$before after=$after"
      if [ "$before" != "$after" ]; then
        echo "a migration re-applied on the second pass - it is not forward-only" >&2
        status=1
      fi
    else
      status=1
    fi
  else
    status=1
  fi

  NODE_RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# ------------------------------------------------------------------
# 9. smoke - the browser matrix (the reserved slow gate)
# ------------------------------------------------------------------
# The runner certifies the tree when this passes and skips it while the
# marker matches, so the cost is paid once per set of bytes however many
# times they are pushed.
#
# It runs against a production build rather than the dev server: a dev
# server compiles on demand, and the first request to a cold route is slow
# enough to look like a flaky test.
#
# If a project's suite genuinely cannot run against the archive - it
# drives the running dev stack through a public hostname, or needs
# services only compose brings up - the gate may drive the working tree
# instead, using $PREFLIGHT_REPO. It must then refuse unless the working
# tree matches the commit:
#
#   git -C "$PREFLIGHT_REPO" diff --quiet "$PREFLIGHT_COMMIT" -- \
#     && [ -z "$(git -C "$PREFLIGHT_REPO" ls-files --others --exclude-standard)" ] \
#     || { echo "the working tree differs from the commit being gated" >&2; return 1; }
#
# Without that check the marker certifies a tree the suite never
# exercised, which is worse than having no marker at all.
smoke() {
  local db url app ready="" status=0
  db="$(start_postgres smoke-db)" || return 1
  url="$(db_url_for "$db")"
  app="$PREFLIGHT_ID-app"

  NODE_RUN_ENV=(-e "PREFLIGHT=1" -e "DATABASE_URL=$url")
  if ! node_run "npx drizzle-kit migrate && npm run build"; then
    NODE_RUN_ENV=(-e "PREFLIGHT=1")
    stop_container "$db"
    return 1
  fi

  docker run -d --name "$app" --network "$PREFLIGHT_NET" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e "DATABASE_URL=$url" \
    -e "NEXT_PUBLIC_APP_URL=http://$app:3000" \
    -v "$PWD/$APP_DIR:/app" \
    -v "$NODE_MODULES_VOL:/app/node_modules" \
    -w /app "$NODE_IMAGE" npm run start >/dev/null

  for _ in $(seq 1 60); do
    if docker run --rm --network "$PREFLIGHT_NET" "$NODE_IMAGE" \
        node -e "fetch('http://$app:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 2
  done

  if [ -n "$ready" ]; then
    # The Playwright image is only the browser host; the code under test is
    # the container above. Browsers are baked into that image, so nothing
    # downloads a browser on the push path.
    docker run --rm --network "$PREFLIGHT_NET" \
      --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -e "PW_BASE_URL=http://$app:3000" \
      -e "DATABASE_URL=$url" \
      -v "$PWD/$APP_DIR:/work" \
      -v "$NODE_MODULES_VOL:/work/node_modules" \
      -w /work "$PLAYWRIGHT_IMAGE" \
      npx playwright test --config playwright.smoke.config.ts || status=1
  else
    docker logs "$app" 2>&1 | tail -30 >&2
    echo "the application did not serve within 120s" >&2
    status=1
  fi

  NODE_RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$app"
  stop_container "$db"
  return "$status"
}
