#!/usr/bin/env bash
#
# bin/preflight.gates.sh - .NET project (skeleton).
#
# Same nine gate names as every other stack here, because `--only lint`
# and "the tests gate is red" should mean the same thing in a C# repo as
# in a TypeScript one. Fill in the commands; keep the names.
#
# Sourced by bin/preflight.sh with the exported commit as the working
# directory. Exported for you: PREFLIGHT_ID (name prefix for throwaway
# containers, reaped by the runner), PREFLIGHT_NET (a docker network for
# this run), PREFLIGHT_DIR, PREFLIGHT_COMMIT, PREFLIGHT_TREE.
#
# Errexit is on while a gate runs. Where a gate starts a container it
# needs to stop afterwards, catch the failure with `|| status=1` and
# return that at the end rather than letting errexit skip the cleanup.

SLN="src/App.sln"
SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:9.0"
PG_IMAGE="postgres:17"
DB_NAME="app"

# NuGet packages are cached in a named volume keyed by the lock or props
# file, so an unchanged dependency set is restored once rather than per
# run, and a changed one cannot reuse the wrong cache.
LOCK_HASH="$(sha256sum packages.lock.json 2>/dev/null | cut -c1-16)"
: "${LOCK_HASH:=nolock}"
NUGET_VOL="local-gates-nuget-$LOCK_HASH"

# shellcheck disable=SC2034 # read by the runner after it sources this file
GATES=(deps compile lint tests secrets vulns sast migrations smoke)

# Extra `-e NAME=value` arguments a gate wants for the length of that
# gate. An array rather than a string, so a value containing a space
# cannot come apart on the way to docker.
RUN_ENV=(-e "PREFLIGHT=1")

dotnet_run() {
  docker run --rm \
    --network "$PREFLIGHT_NET" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
    -e NUGET_PACKAGES=/nuget \
    "${RUN_ENV[@]}" \
    -v "$PWD:/src" -v "$NUGET_VOL:/nuget" \
    -w /src "$SDK_IMAGE" sh -c "$1"
}

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

# 1. deps - restore exactly what the lock file pins, nothing newer.
#    Must prove: a clone with an empty package cache can build this.
deps() {
  docker volume create "$NUGET_VOL" >/dev/null
  docker run --rm -v "$NUGET_VOL:/vol" "$SDK_IMAGE" \
    chown -R "$(id -u):$(id -g)" /vol
  dotnet_run "dotnet restore $SLN --locked-mode"
}

# 2. compile - warnings are errors. A build that is merely green while
#    the log fills with warnings is the state every codebase drifts into.
compile() {
  dotnet_run "dotnet build $SLN --no-restore -warnaserror -c Release"
}

# 3. lint - formatting and analysers, verified rather than applied. The
#    gate has to fail on a badly formatted tree, not quietly fix it: a
#    hook that rewrites files changes what is about to be pushed.
lint() {
  dotnet_run "dotnet format $SLN --verify-no-changes --no-restore"
}

# 4. tests - unit and integration, against a real database rather than an
#    in-memory provider, because the provider is the thing most likely to
#    disagree with production.
tests() {
  local db status=0
  db="$(start_postgres db)" || return 1
  RUN_ENV=(-e "PREFLIGHT=1" -e "ConnectionStrings__Default=Host=$db;Username=postgres;Password=postgres;Database=$DB_NAME")
  dotnet_run "dotnet test $SLN --no-build -c Release" || status=1
  RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# 5. secrets - nothing credential-shaped in the pushed content. Identical
#    across stacks; there is nothing .NET-specific about a leaked key.
secrets() {
  docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:latest \
    detect --no-git --source /repo --redact --no-banner
}

# 6. vulns - known-vulnerable packages, transitive included.
#    `dotnet list package --vulnerable` exits 0 even when it finds some,
#    so the finding has to be turned into a failure explicitly.
vulns() {
  local out
  out="$(dotnet_run "dotnet list $SLN package --vulnerable --include-transitive")"
  echo "$out"
  if echo "$out" | grep -qiE '\b(High|Critical)\b'; then
    echo "high or critical advisories above" >&2
    return 1
  fi
}

# 7. sast - static analysis on the pushed content.
sast() {
  docker run --rm -v "$PWD:/src:ro" -w /src semgrep/semgrep:latest \
    semgrep scan --error --quiet --metrics=off \
      --config p/default --config p/csharp --config p/owasp-top-ten \
      --config p/secrets
}

# 8. migrations - replay on an empty database, twice. The first pass
#    proves they apply to a database that has never seen them; the second
#    proves the second run is a no-op, which is what makes them safe to
#    re-run on a deploy that retried.
migrations() {
  local db status=0
  db="$(start_postgres migrate)" || return 1
  RUN_ENV=(-e "PREFLIGHT=1" -e "ConnectionStrings__Default=Host=$db;Username=postgres;Password=postgres;Database=$DB_NAME")
  # TODO: replace with this project's migrator, e.g.
  #   dotnet ef database update --project src/App.Data
  # then assert the second pass applies nothing - read the migrations
  # history table before and after and compare the counts.
  dotnet_run "echo 'TODO: apply migrations'" || status=1
  dotnet_run "echo 'TODO: apply migrations again and assert a no-op'" || status=1
  RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# 9. smoke - the reserved slow gate: the end-to-end or browser suite,
#    against a build of this commit rather than a dev server. The runner
#    certifies the tree when it passes and skips it while the marker
#    matches, so it costs once per set of bytes.
smoke() {
  # TODO: publish the app, run it on $PREFLIGHT_NET as
  # "$PREFLIGHT_ID-app", wait for its health endpoint, then run the
  # Playwright or Selenium suite against http://$PREFLIGHT_ID-app:8080.
  echo "TODO: end-to-end suite" >&2
  return 1
}
