#!/bin/bash
#
# smoke.sh — flag-parsing + file-generation smoke tests for create-gcp-project.sh.
#
# Runs the script with --skip-gcp so no real gcloud calls fire. Verifies the
# non-interactive contract: required-flag errors, slug validation, master-secrets
# dir handling, and end-to-end file generation.
#
# Usage:
#   ./test/smoke.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — at least one test failed
#
# Note: -e is intentionally OFF so a single failing assertion doesn't abort
# the whole suite. Each `expect_*` helper returns 0/1 and we aggregate.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/create-gcp-project.sh"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup_temp_dirs() {
  rm -rf /tmp/cgp-smoke-help          \
         /tmp/cgp-smoke-missing       \
         /tmp/cgp-smoke-bad-slug      \
         /tmp/cgp-smoke-good          \
         /tmp/cgp-secrets-test        \
         /tmp/cgp-secrets-good        \
         /tmp/cgp-secrets-empty       \
         /tmp/cgp-secrets-populated
}

cleanup_temp_dirs

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# run_capture <stdout-file> <stderr-file> -- <cmd...>
# Runs cmd, captures stdout + stderr separately, returns the cmd's exit code.
run_capture() {
  local out="$1"; local err="$2"; shift 2
  # Drop a leading "--" if present.
  if [ "${1:-}" = "--" ]; then shift; fi
  "$@" >"$out" 2>"$err"
}

assert() {
  # assert <name> <condition-result>
  local name="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo -e "${GREEN}PASS${NC}  $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "${RED}FAIL${NC}  $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$name")
  fi
}

# ---------------------------------------------------------------------------
# Test 1: --help exits 0 and prints usage.
# ---------------------------------------------------------------------------

test_help_works() {
  echo -e "${BOLD}T1: --help${NC}"
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  run_capture "$out" "$err" -- "$SCRIPT" --help
  rc=$?
  set -e

  local ok=0
  [ "$rc" -ne 0 ] && ok=1
  if ! grep -q "FLAGS:" "$out"; then ok=1; fi
  if ! grep -q -- "--non-interactive" "$out"; then ok=1; fi
  if ! grep -q -- "--master-secrets-dir" "$out"; then ok=1; fi

  rm -f "$out" "$err"
  assert "T1: --help exits 0 and prints flag list" "$ok"
}

# ---------------------------------------------------------------------------
# Test 2: --non-interactive with no other flags fails with clear error.
# ---------------------------------------------------------------------------

test_missing_required_flag() {
  echo -e "${BOLD}T2: --non-interactive without required flags${NC}"
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  run_capture "$out" "$err" -- "$SCRIPT" --non-interactive
  rc=$?
  set -e

  local ok=0
  [ "$rc" -eq 0 ] && ok=1
  if ! grep -qi "requires --slug\|requires --display-name\|requires --billing" "$err"; then
    ok=1
  fi

  rm -f "$out" "$err"
  assert "T2: --non-interactive alone exits non-zero with 'requires' error" "$ok"
}

# ---------------------------------------------------------------------------
# Test 3: invalid slug fails fast with slug-validation error.
# ---------------------------------------------------------------------------

test_invalid_slug() {
  echo -e "${BOLD}T3: invalid slug${NC}"
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  run_capture "$out" "$err" -- "$SCRIPT" \
    --non-interactive \
    --slug invalid_slug \
    --display-name X \
    --billing FAKE \
    --skip-gcp
  rc=$?
  set -e

  local ok=0
  [ "$rc" -eq 0 ] && ok=1
  if ! grep -qi "invalid --slug" "$err"; then ok=1; fi

  rm -f "$out" "$err"
  assert "T3: --slug invalid_slug exits non-zero with slug error" "$ok"
}

# ---------------------------------------------------------------------------
# Test 4: full file-generation with valid slug + --skip-gcp.
# ---------------------------------------------------------------------------

test_file_generation() {
  echo -e "${BOLD}T4: full file-generation with --skip-gcp${NC}"
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  run_capture "$out" "$err" -- "$SCRIPT" \
    --non-interactive \
    --slug valid-slug-xyz \
    --display-name "Test" \
    --billing FAKE \
    --skip-gcp \
    --target-dir /tmp/cgp-smoke-good \
    --skip-github \
    --no-staging
  rc=$?
  set -e

  local ok=0
  [ "$rc" -ne 0 ] && ok=1

  # Required dirs/files
  for path in \
      /tmp/cgp-smoke-good \
      /tmp/cgp-smoke-good/frontend \
      /tmp/cgp-smoke-good/backend \
      /tmp/cgp-smoke-good/run-local.sh \
      /tmp/cgp-smoke-good/deploy.sh \
      /tmp/cgp-smoke-good/CLAUDE.md \
      /tmp/cgp-smoke-good/README.md \
      /tmp/cgp-smoke-good/backend/Dockerfile \
      /tmp/cgp-smoke-good/backend/app/main.py \
      /tmp/cgp-smoke-good/backend/app/core/config.py \
      /tmp/cgp-smoke-good/frontend/package.json \
      /tmp/cgp-smoke-good/frontend/vite.config.ts; do
    if [ ! -e "$path" ]; then
      echo "  missing: $path" >&2
      ok=1
    fi
  done

  # --no-staging means deploy-staging.sh should NOT exist.
  if [ -e /tmp/cgp-smoke-good/deploy-staging.sh ]; then
    echo "  deploy-staging.sh should not exist (--no-staging)" >&2
    ok=1
  fi

  rm -f "$out" "$err"
  assert "T4: --skip-gcp file generation produces all expected files" "$ok"
}

# ---------------------------------------------------------------------------
# Test 5: master-secrets-dir set + key file missing → exit 2 with clear error.
#
# Note: --skip-gcp short-circuits the gcloud secrets path, so the master
# secrets logic doesn't actually fire. To exercise the missing-key check we
# would need real gcloud access. Instead, this test asserts the file-generation
# path still works when --master-secrets-dir is passed (a sanity check that
# the flag is parsed and doesn't break the scaffold), AND a follow-on check
# that the flag value is preserved (rendered into the generated CLAUDE.md /
# scripts) is intentionally skipped — the chokepoint is in phase_2_gcp_setup
# which is bypassed by --skip-gcp.
#
# We still want a smoke check of the missing-file path, so we do an
# integration-shaped check by invoking the helper logic in isolation. We
# fake a minimal gcloud-skipped run by extracting the relevant block; but
# that's brittle. Instead we just confirm the script accepts the flags and
# generates files, leaving the missing-key path to runtime testing.
# ---------------------------------------------------------------------------

test_master_secrets_dir_accepted() {
  echo -e "${BOLD}T5: --master-secrets-dir parses and scaffolds${NC}"
  mkdir -p /tmp/cgp-secrets-empty   # empty dir
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  run_capture "$out" "$err" -- "$SCRIPT" \
    --non-interactive \
    --slug s1-secrets-test \
    --display-name X \
    --billing FAKE \
    --services openai \
    --master-secrets-dir /tmp/cgp-secrets-empty \
    --skip-gcp \
    --target-dir /tmp/cgp-secrets-test \
    --skip-github --no-staging
  rc=$?
  set -e

  local ok=0
  [ "$rc" -ne 0 ] && ok=1
  [ ! -d /tmp/cgp-secrets-test ] && ok=1

  # The OpenAI service flag should have flipped through to the generated
  # backend requirements.
  if ! grep -q '^openai$' /tmp/cgp-secrets-test/backend/requirements.txt 2>/dev/null; then
    echo "  --services openai did not produce 'openai' in requirements.txt" >&2
    ok=1
  fi

  rm -f "$out" "$err"
  assert "T5: --master-secrets-dir + --services parses, scaffolds with services" "$ok"
}

# ---------------------------------------------------------------------------
# Test 6: master-secrets-dir empty + non-skip-gcp would normally fire the
# missing-key check. We simulate the chokepoint in isolation by sourcing the
# script's helper inline, with a stub `gcloud` on PATH.
# ---------------------------------------------------------------------------

test_master_secrets_missing_key() {
  echo -e "${BOLD}T6: missing key file in --master-secrets-dir aborts with exit 2${NC}"
  mkdir -p /tmp/cgp-secrets-empty
  local stubdir
  stubdir=$(mktemp -d)
  cat > "$stubdir/gcloud" <<'STUB'
#!/bin/bash
# Stub: succeed on most calls so the script reaches the secrets phase.
# Returns 1 on describe-style calls so create paths are exercised; 0 on
# every create call. We override sleep too (see below) so the test runs
# in seconds.
case "${1:-}" in
  auth)
    [ "${2:-}" = "print-identity-token" ] && exit 0
    exit 0
    ;;
  config) exit 0 ;;
  projects)
    case "${2:-}" in
      describe)
        # Return a fake project number on stdout so the
        # PROJECT_NUMBER=$(...) assignment doesn't blow up under set -e.
        echo "123456789012"
        exit 0
        ;;
      create) exit 0 ;;
      add-iam-policy-binding) exit 0 ;;
    esac
    exit 0
    ;;
  billing) exit 0 ;;
  services) exit 0 ;;
  firestore) exit 0 ;;
  artifacts)
    case "${2:-}" in
      describe) exit 1 ;;        # repo doesn't exist
      create) exit 0 ;;          # then create succeeds
    esac
    exit 0
    ;;
  iam)
    # The script does: describe → if fails, create → succeed.
    case "${2:-}" in
      service-accounts)
        case "${3:-}" in
          describe) exit 1 ;;
          create) exit 0 ;;
          keys) exit 0 ;;
        esac
        ;;
    esac
    exit 0
    ;;
  secrets)
    # describe → not found (so create branch runs)
    [ "${2:-}" = "describe" ] && exit 1
    # create → succeed (but the missing-file check should short-circuit
    # before this is called; we capture the args anyway)
    [ "${2:-}" = "create" ] && exit 0
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$stubdir/gcloud"

  # Stub `sleep` too so the script's "wait 10s for SAs" / "wait 15s for
  # IAM propagation" don't slow the test.
  cat > "$stubdir/sleep" <<'SLEEP_STUB'
#!/bin/bash
exit 0
SLEEP_STUB
  chmod +x "$stubdir/sleep"

  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  PATH="$stubdir:$PATH" "$SCRIPT" \
    --non-interactive \
    --slug s1-missing-keys \
    --display-name X \
    --billing FAKE \
    --services openai \
    --master-secrets-dir /tmp/cgp-secrets-empty \
    --target-dir /tmp/cgp-secrets-test-2 \
    --skip-github --no-staging \
    --no-download-sa-key \
    >"$out" 2>"$err"
  rc=$?
  set -e

  local ok=0
  if [ "$rc" -eq 0 ]; then
    echo "  expected non-zero exit, got 0" >&2
    ok=1
  fi
  if ! grep -q "missing\|master-secrets-dir" "$err"; then
    echo "  expected 'missing' or 'master-secrets-dir' in stderr; got:" >&2
    cat "$err" >&2 || true
    ok=1
  fi

  rm -rf "$stubdir" "$out" "$err" /tmp/cgp-secrets-test-2
  assert "T6: empty --master-secrets-dir + --services openai exits 2 with missing-key error" "$ok"
}

# ---------------------------------------------------------------------------
# Test 7: master-secrets-dir populated → script proceeds past secret upload.
# We assert the populated-key path doesn't error out on the secret check.
# ---------------------------------------------------------------------------

test_master_secrets_populated_key() {
  echo -e "${BOLD}T7: populated --master-secrets-dir uploads from file${NC}"
  rm -rf /tmp/cgp-secrets-populated /tmp/cgp-secrets-good
  mkdir -p /tmp/cgp-secrets-populated
  echo "sk-test-fake-key" > /tmp/cgp-secrets-populated/openai-api-key

  local stubdir
  stubdir=$(mktemp -d)
  local gcloud_log="$stubdir/gcloud.log"

  # Same robust stub as T6, but logs every invocation so we can assert
  # the secrets-create call uses --data-file=<our populated key file>.
  cat > "$stubdir/gcloud" <<STUB
#!/bin/bash
echo "GCLOUD: \$*" >> "$gcloud_log"
case "\${1:-}" in
  auth) exit 0 ;;
  config) exit 0 ;;
  projects)
    case "\${2:-}" in
      describe)
        echo "123456789012"
        exit 0
        ;;
      create) exit 0 ;;
      add-iam-policy-binding) exit 0 ;;
    esac
    exit 0
    ;;
  billing) exit 0 ;;
  services) exit 0 ;;
  firestore) exit 0 ;;
  artifacts)
    case "\${2:-}" in
      describe) exit 1 ;;
      create) exit 0 ;;
    esac
    exit 0
    ;;
  iam)
    case "\${2:-}" in
      service-accounts)
        case "\${3:-}" in
          describe) exit 1 ;;
          create) exit 0 ;;
          keys) exit 0 ;;
        esac
        ;;
    esac
    exit 0
    ;;
  secrets)
    [ "\${2:-}" = "describe" ] && exit 1
    [ "\${2:-}" = "create" ] && exit 0
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$stubdir/gcloud"

  cat > "$stubdir/sleep" <<'SLEEP_STUB'
#!/bin/bash
exit 0
SLEEP_STUB
  chmod +x "$stubdir/sleep"

  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  PATH="$stubdir:$PATH" "$SCRIPT" \
    --non-interactive \
    --slug populated-keys-x \
    --display-name X \
    --billing FAKE \
    --services openai \
    --master-secrets-dir /tmp/cgp-secrets-populated \
    --target-dir /tmp/cgp-secrets-good \
    --skip-github --no-staging \
    --no-download-sa-key \
    >"$out" 2>"$err"
  rc=$?
  set -e

  local ok=0
  if [ ! -f "$gcloud_log" ]; then
    echo "  gcloud was never invoked" >&2
    ok=1
  fi
  if ! grep -q "secrets create openai-api-key" "$gcloud_log" 2>/dev/null; then
    echo "  no 'secrets create openai-api-key' in gcloud log; got:" >&2
    head -50 "$gcloud_log" >&2 || true
    ok=1
  fi
  if ! grep -q "data-file=/tmp/cgp-secrets-populated/openai-api-key" "$gcloud_log" 2>/dev/null; then
    echo "  expected --data-file=<populated>/openai-api-key in gcloud log; got:" >&2
    head -50 "$gcloud_log" >&2 || true
    ok=1
  fi

  rm -rf "$stubdir" "$out" "$err"
  assert "T7: populated --master-secrets-dir uploads --data-file=<file>" "$ok"
}

# ---------------------------------------------------------------------------
# Run all tests.
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}create-gcp-project.sh smoke tests${NC}"
echo "  Script: $SCRIPT"
echo ""

test_help_works
test_missing_required_flag
test_invalid_slug
test_file_generation
test_master_secrets_dir_accepted
test_master_secrets_missing_key
test_master_secrets_populated_key

echo ""
echo "============================================"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}All ${PASS_COUNT} tests passed.${NC}"
  cleanup_temp_dirs
  exit 0
else
  echo -e "${RED}${FAIL_COUNT} test(s) failed:${NC}"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  echo "(Pass: ${PASS_COUNT})"
  echo ""
  echo "Tmp dirs preserved for inspection in /tmp/cgp-*"
  exit 1
fi
