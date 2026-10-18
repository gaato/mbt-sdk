#!/usr/bin/env bash
# Test-coverage report for the hand-written modules of the workspace.
#
# Runs the native test suites of the measured modules (MODULES below) with
# coverage instrumentation, plus the non-live packages of runtime-tests (they
# are where sdk-runtime's async behaviour is tested), writes a Coveralls JSON
# report, prints per-module and per-package tables, and checks every remaining
# uncovered file against the TEST_COVERAGE.md ledger: a file with uncovered
# lines must have a ledger row whose budget covers them.
#
# Usage: scripts/coverage_report.sh [--from-json FILE]
#   --from-json FILE  recheck an existing Coveralls JSON report against the
#                     ledger instead of re-running the instrumented tests.
#
# Exit status: 0 = every uncovered line is ledgered, 1 = unexplained coverage
# gaps or over-budget files, 2 = setup/run failure.
#
# Measurement pitfalls this script works around (see TEST_COVERAGE.md):
# - `moon coverage analyze` has no --target flag and, in this moon.work
#   workspace, tests every member, generated clients included. Run
#   `moon test --target native --enable-coverage <package dirs>` from the
#   workspace root instead (`moon -C <member> test` also runs every member).
# - Without explicit sources, the reporter loads every `.trace.source` under
#   the working directory, and github's generated package (a 2.5 MB trace map)
#   overflows its stack ("Fatal error: exception Stack overflow"). Pass the
#   measured modules' trace maps explicitly.
# - The reporter merges every `moonbit_coverage_*` counter file it is given or
#   finds; counters from earlier runs and trace maps of moved or deleted
#   packages corrupt the totals. Drop both before measuring.
# - `-f summary` omits fully covered files; use the Coveralls JSON.
# - moon's bundled tcc cannot link on some hosts (openSUSE); use the system cc.

set -euo pipefail

# Measured modules (workspace member directories).
MODULES=(http http-async sdk-runtime jsonrpc jsonrpc-async codex-app-server)
# Measured sources, as workspace-relative paths (how the reporter names them).
# Example binaries are excluded; JS-only files never appear in a native run.
LIBRARY='^(http|http-async|sdk-runtime|jsonrpc|jsonrpc-async|codex-app-server)/src/'
EXCLUDE='^codex-app-server/src/examples/'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ledger="$repo_root/TEST_COVERAGE.md"
json_file=""

if [[ "${1:-}" == "--from-json" ]]; then
  json_file="${2:?--from-json needs a file}"
else
  cd "$repo_root"
  json_file="$repo_root/_build/coverage_report.json"
  # Test drivers: every package of the measured modules, and every
  # runtime-tests package except the live API tests (they need credentials
  # and would make the numbers depend on the network).
  mapfile -t drivers < <(
    for m in "${MODULES[@]}"; do find "$m/src" -name moon.pkg -printf '%h\n'; done
    find runtime-tests/src -name moon.pkg -printf '%h\n' | grep -v '^runtime-tests/src/live$'
  )
  find _build -name 'moonbit_coverage_*' -delete 2>/dev/null || true
  rm -rf _build/native/debug/test
  MOON_CC="${MOON_CC:-cc}" moon test --target native --enable-coverage "${drivers[@]}" \
    >/dev/null || {
      echo "error: instrumented native test run failed" >&2
      exit 2
    }
  traces=()
  for m in "${MODULES[@]}"; do
    name="$(sed -nE 's/^name = "(.*)"$/\1/p' "$m/moon.mod")"
    while IFS= read -r f; do traces+=("$f"); done \
      < <(find "_build/native/debug/test/$name" -name '*.trace.source')
  done
  counters=()
  while IFS= read -r f; do counters+=(-t "$f"); done \
    < <(find _build -name 'moonbit_coverage_*')
  if [[ ${#traces[@]} -eq 0 || ${#counters[@]} -eq 0 ]]; then
    echo "error: no trace maps or counters after the instrumented run" >&2
    exit 2
  fi
  moon coverage report -- "${traces[@]}" "${counters[@]}" -f coveralls -o "$json_file" \
    >/dev/null 2>&1 || {
      echo "error: moon coverage report failed" >&2
      exit 2
    }
fi

# One "file<TAB>covered<TAB>total" line per measured source file.
jq -r --arg lib "$LIBRARY" --arg ex "$EXCLUDE" '
  .source_files[]
  | select((.name | test($lib)) and (.name | test($ex) | not))
  | [ .name,
      ([.coverage[] | select(. != null and . > 0)] | length),
      ([.coverage[] | select(. != null)] | length) ]
  | @tsv
' "$json_file" | sort | awk -F '\t' -v ledger="$ledger" -v lib="$LIBRARY" '
  # ---- ledger: rows like "| http/src/foo.mbt | 12 | reason |" -------------
  BEGIN {
    while ((getline line < ledger) > 0) {
      if (line !~ /^\|/) continue
      split(line, cell, /\|/)
      file = cell[2]; gsub(/^ +| +$/, "", file)
      if (file !~ lib) continue
      budget_str = cell[3]; gsub(/^ +| +$/, "", budget_str)
      if (budget_str + 0 == budget_str) budget[file] = budget_str + 0
    }
    close(ledger)
  }

  {
    file = $1; cov = $2 + 0; tot = $3 + 0
    if (tot == 0) next   # declaration-only files have no executable points
    pkg = file; sub(/\/[^\/]*$/, "", pkg)
    mod = file; sub(/\/.*$/, "", mod)
    pcov[pkg] += cov; ptot[pkg] += tot
    mcov[mod] += cov; mtot[mod] += tot
    lcov += cov; ltot += tot
    unc = tot - cov
    if (unc > 0) uncovered[file] = unc
    seen[file] = 1
  }

  END {
    printf "%-28s %11s %8s\n", "module", "covered", "%"
    n = asorti(mcov, keys)
    for (i = 1; i <= n; i++) {
      m = keys[i]
      printf "%-28s %5d/%-5d %7.1f%%\n", m, mcov[m], mtot[m], 100 * mcov[m] / mtot[m]
    }
    printf "%-28s %5d/%-5d %7.1f%%\n", "TOTAL", lcov, ltot, 100 * lcov / ltot
    print ""
    printf "%-28s %11s %8s\n", "package", "covered", "%"
    n = asorti(pcov, keys)
    for (i = 1; i <= n; i++) {
      p = keys[i]
      printf "%-28s %5d/%-5d %7.1f%%\n", p, pcov[p], ptot[p], 100 * pcov[p] / ptot[p]
    }
    print ""

    bad = 0
    n = asorti(uncovered, keys)
    for (i = 1; i <= n; i++) {
      f = keys[i]
      if (!(f in budget))
        { printf "UNEXPLAINED  %-44s %4d uncovered (no ledger row)\n", f, uncovered[f]; bad = 1 }
      else if (uncovered[f] > budget[f])
        { printf "OVER BUDGET  %-44s %4d uncovered > budget %d\n", f, uncovered[f], budget[f]; bad = 1 }
    }
    n = asorti(budget, keys)
    for (i = 1; i <= n; i++) {
      f = keys[i]
      if (!(f in seen))
        printf "STALE LEDGER %-44s file not in coverage output\n", f
      else if (!(f in uncovered))
        printf "STALE LEDGER %-44s fully covered; drop the row\n", f
      else if (uncovered[f] < budget[f])
        printf "note: budget slack %-33s %4d uncovered < budget %d\n", f, uncovered[f], budget[f]
    }
    if (bad) { print "\nledger check: FAIL"; exit 1 }
    print "ledger check: OK - every uncovered line is ledgered"
  }
'
