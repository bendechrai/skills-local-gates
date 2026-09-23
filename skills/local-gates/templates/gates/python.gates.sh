#!/usr/bin/env bash
#
# bin/preflight.gates.sh - Python project (skeleton).
#
# Same nine gate names as every other stack here, because `--only lint`
# and "the tests gate is red" should mean the same thing in a Python repo
# as in a TypeScript one. Fill in the commands; keep the names.
#
# Sourced by bin/preflight.sh with the exported commit as the working
# directory. Exported for you: PREFLIGHT_ID (name prefix for throwaway
# containers, reaped by the runner), PREFLIGHT_NET (a docker network for
# this run), PREFLIGHT_DIR, PREFLIGHT_COMMIT, PREFLIGHT_TREE.
#
# Errexit is on while a gate runs. Where a gate starts a container it
# needs to stop afterwards, catch the failure with `|| status=1` and
# return that at the end rather than letting errexit skip the cleanup.

PY_IMAGE="python:3.13-slim"
PG_IMAGE="postgres:17"
DB_NAME="app"

# The virtualenv lives in a named volume keyed by the lock file, so an
# unchanged dependency set installs once and a changed one cannot reuse
# the wrong environment.
LOCK_HASH="$( { sha256sum uv.lock || sha256sum poetry.lock || sha256sum requirements.txt; } 2>/dev/null | head -1 | cut -c1-16)"
: "${LOCK_HASH:=nolock}"
VENV_VOL="local-gates-venv-$LOCK_HASH"

# shellcheck disable=SC2034 # read by the runner after it sources this file
GATES=(deps compile lint tests secrets vulns sast migrations smoke)

# Extra `-e NAME=value` arguments a gate wants for the length of that
# gate. An array rather than a string, so a value containing a space
# cannot come apart on the way to docker.
RUN_ENV=(-e "PREFLIGHT=1")

py_run() {
  docker run --rm \
    --network "$PREFLIGHT_NET" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e VIRTUAL_ENV=/venv -e PATH=/venv/bin:/usr/local/bin:/usr/bin:/bin \
    "${RUN_ENV[@]}" \
    -v "$PWD:/src" -v "$VENV_VOL:/venv" \
    -w /src "$PY_IMAGE" sh -c "$1"
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

# 1. deps - install exactly what the lock file pins, nothing resolved
#    afresh. A gate that resolves versions is testing today's PyPI, not
#    the commit.
deps() {
  docker volume create "$VENV_VOL" >/dev/null
  docker run --rm -v "$VENV_VOL:/vol" "$PY_IMAGE" \
    chown -R "$(id -u):$(id -g)" /vol
  # TODO: pick the project's installer, e.g.
  #   uv sync --frozen        (uv)
  #   poetry install --sync   (poetry)
  #   pip install -r requirements.txt --require-hashes
  py_run "python -m venv /venv 2>/dev/null || true; echo 'TODO: install from the lock file'"
}

# 2. compile - the type checker. Python has no build step to lean on, so
#    this gate is the only thing standing between a typo in a rarely
#    exercised branch and production.
compile() {
  # TODO: mypy --strict . / pyright / ty
  py_run "echo 'TODO: type check'"
}

# 3. lint - errors and warnings both, checked rather than fixed: a hook
#    that rewrites files changes what is about to be pushed.
lint() {
  # TODO: ruff check . && ruff format --check .
  py_run "echo 'TODO: lint'"
}

# 4. tests - unit and integration, against a real database rather than
#    sqlite or a mock, because the substitute is the thing most likely to
#    disagree with production.
tests() {
  local db status=0
  db="$(start_postgres db)" || return 1
  RUN_ENV=(-e "PREFLIGHT=1" -e "DATABASE_URL=postgresql://postgres:postgres@$db:5432/$DB_NAME")
  py_run "python -m pytest -q" || status=1
  RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# 5. secrets - nothing credential-shaped in the pushed content.
secrets() {
  docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:latest \
    detect --no-git --source /repo --redact --no-banner
}

# 6. vulns - known-vulnerable dependencies, transitive included.
vulns() {
  docker run --rm -v "$PWD:/repo:ro" ghcr.io/google/osv-scanner:latest \
    scan source --recursive /repo
}

# 7. sast - static analysis on the pushed content.
sast() {
  docker run --rm -v "$PWD:/src:ro" -w /src semgrep/semgrep:latest \
    semgrep scan --error --quiet --metrics=off \
      --config p/default --config p/python --config p/django \
      --config p/flask --config p/owasp-top-ten --config p/secrets
}

# 8. migrations - replay on an empty database, twice. The first pass
#    proves they apply to a database that has never seen them; the second
#    proves the second run is a no-op, which is what makes them safe to
#    re-run on a deploy that retried.
migrations() {
  local db status=0
  db="$(start_postgres migrate)" || return 1
  RUN_ENV=(-e "PREFLIGHT=1" -e "DATABASE_URL=postgresql://postgres:postgres@$db:5432/$DB_NAME")
  # TODO: alembic upgrade head / python manage.py migrate, then run it
  # again and assert nothing was applied - compare the version table, or
  # assert `alembic current` is unchanged.
  py_run "echo 'TODO: apply migrations'" || status=1
  py_run "echo 'TODO: apply migrations again and assert a no-op'" || status=1
  RUN_ENV=(-e "PREFLIGHT=1")
  stop_container "$db"
  return "$status"
}

# 9. smoke - the reserved slow gate: the end-to-end or browser suite,
#    against a build of this commit rather than a dev server. The runner
#    certifies the tree when it passes and skips it while the marker
#    matches, so it costs once per set of bytes.
smoke() {
  # TODO: run the app on $PREFLIGHT_NET as "$PREFLIGHT_ID-app", wait for
  # its health endpoint, then drive the browser suite against
  # http://$PREFLIGHT_ID-app:8000.
  echo "TODO: end-to-end suite" >&2
  return 1
}
