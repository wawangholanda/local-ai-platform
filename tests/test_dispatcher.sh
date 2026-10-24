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
  fail "Bantuan tidak menampilkan daftar fase"
pass "--help menampilkan bantuan dengan status sukses"

run_case 0 "Opsi -h" -h ||
  fail "Opsi -h gagal"
grep -q 'Available phases:' "$TMP_DIR/output.txt" ||
  fail "Opsi -h tidak menampilkan daftar fase"
pass "-h menampilkan bantuan dengan status sukses"

run_case 1 "Fase tidak dikenal" fase-tidak-valid ||
  fail "Fase tidak dikenal tidak ditolak"
grep -q 'Available phases:' "$TMP_DIR/output.txt" ||
  fail "Fase tidak dikenal tidak menampilkan bantuan"
pass "Fase tidak dikenal ditolak tanpa provisioning"

run_case 2 "Argumen berlebih" test extra ||
  fail "Argumen berlebih tidak ditolak"
grep -q 'Hanya satu argumen fase' "$TMP_DIR/output.txt" ||
  fail "Pesan argumen berlebih tidak ditemukan"
pass "Argumen berlebih ditolak sebelum fase berjalan"

printf '\n%s\n' 'Semua tes dispatcher lulus.'
