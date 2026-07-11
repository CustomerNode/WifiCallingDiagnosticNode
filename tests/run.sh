#!/usr/bin/env bash
# tests/run.sh — offline test harness (no network required).
# Unit-checks ip_class boundaries and asserts the analyze verdict on fixed
# capture fixtures. Fixtures use low voice thresholds so they stay tiny; the
# heuristic logic is what's under test, not the production default rates.
set -u
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=lib/common.sh
. lib/common.sh

pass=0; fail=0
eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s: output missing /%s/\n' "$1" "$3"; fi; }

echo "== ip_class boundaries =="
eq "172.16 private"  "$(ip_class 172.16.0.1)"  private
eq "172.15 public"   "$(ip_class 172.15.0.1)"  public
eq "172.31 private"  "$(ip_class 172.31.0.1)"  private
eq "172.32 public"   "$(ip_class 172.32.0.1)"  public
eq "100.64 cgnat"    "$(ip_class 100.64.0.1)"  cgnat
eq "100.127 cgnat"   "$(ip_class 100.127.0.1)" cgnat
eq "100.128 public"  "$(ip_class 100.128.0.1)" public
eq "169.254 lladdr"  "$(ip_class 169.254.9.9)" linklocal
eq "192.168 private" "$(ip_class 192.168.1.1)" private
eq "8.8.8.8 public"  "$(ip_class 8.8.8.8)"     public

echo "== analyze verdicts (fixtures) =="
export NO_COLOR=1 WCDIAG_VOICE_RATE=3 WCDIAG_VOICE_RUN=2
has "twoway"  "$(./wcdiag analyze tests/fixtures/twoway.log 2>&1)"      "two-way voice stream observed"
has "oneway"  "$(./wcdiag analyze tests/fixtures/oneway_down.log 2>&1)" "POSSIBLE one-way (they can't hear you)"
has "nocall"  "$(./wcdiag analyze tests/fixtures/nocall.log 2>&1)"      "no sustained two-way voice"

echo "== analyze endpoint detection =="
has "endpoint local" "$(./wcdiag analyze tests/fixtures/twoway.log 2>&1)" "phone (local): 10.42.0.5"
has "endpoint epdg"  "$(./wcdiag analyze tests/fixtures/twoway.log 2>&1)" "carrier ePDG:  203.0.113.10"

printf '\n%s%d passed, %d failed%s\n' "$([ "$fail" -eq 0 ] && printf '%s' "${C_GRN:-}" || printf '%s' "${C_RED:-}")" "$pass" "$fail" "${C_RESET:-}"
[ "$fail" -eq 0 ]
