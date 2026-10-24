#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

run_case() {
  local expected_status="$1"
  local label="$2"
  shift 2

  local actual_status=0
  if bash "$ROOT_DIR/quick-start.sh" "$@" \
      >"$TMP_DIR/output.txt" 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi

  if [[ "$actual_status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s (status %s, diharapkan %s)\n' \
      "$label" "$actual_status" "$expected_status" >&2
    cat "$TMP_DIR/output.txt" >&2
    return 1
  fi
}

run_case 0 "Opsi --help" --help ||
  fail "Opsi --help gagal"
grep -q 'Available phases:' "$TMP_DIR/output.txt" ||
  fail "Help does not display the phase list"
pass "--help displays help and exits successfully"

run_case 0 "Opsi -h" -h ||
  fail "Opsi -h gagal"
grep -q 'Available phases:' "$TMP_DIR/output.txt" ||
  fail "The -h option does not display the phase list"
pass "-h displays help and exits successfully"

run_case 1 "Unknown phase" invalid-phase ||
  fail "Unknown phase was not rejected"
grep -q 'Available phases:' "$TMP_DIR/output.txt" ||
  fail "Unknown phase does not display help"
pass "Unknown phase is rejected without provisioning"

run_case 2 "Extra arguments" test extra ||
  fail "Extra arguments were not rejected"
grep -q 'Hanya satu argumen fase' "$TMP_DIR/output.txt" ||
  fail "Extra-argument error message was not found"
pass "Extra arguments are rejected before the phase runs"

printf '\n%s\n' 'All dispatcher tests passed.'
