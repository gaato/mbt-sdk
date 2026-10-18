#!/usr/bin/env bash
# Checks the "Enforced limits" table of RESOURCE_BOUNDS.md against the tests.
#
# Every row's last cell ("Tests") names the tests that check its bound, as a
# backticked file path followed by the quoted names of that file's tests:
#
#   `http/src/sse/parser_test.mbt`: "first test", "second test"; `other_test.mbt`: "third"
#
# The check fails when a row names no test, a name comes before any file, a
# file does not exist, or a file declares no `test "<name>" {` or
# `async test "<name>" {` line with that exact name. It does not judge whether
# a test really drives the bound; that is the reviewer's job (see the ledger's
# header).
#
# Usage: scripts/bounds_check.sh [LEDGER]   (default: RESOURCE_BOUNDS.md)
#
# Exit status: 0 = every row names tests that exist, 1 = a row does not,
# 2 = the table is missing or has no Tests column.
#
# Plain bash and POSIX awk: CI's Debian image has mawk, not gawk.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ledger="${1:-$repo_root/RESOURCE_BOUNDS.md}"
[[ -f "$ledger" ]] || { echo "bounds_check.sh: no ledger at $ledger" >&2; exit 2; }

# One tab-separated record per finding:
#   HEADER <last header cell>   the table's header row
#   TEST <row> <file> <name>    a named test
#   ORPHAN <row> <name>         a name before any file in its cell
#   EMPTY <row>                 a row that names no test
records="$(awk '
  /^## / { in_table = ($0 == "## Enforced limits"); header = 0; next }
  !in_table || !/^\|/ { next }
  /^\|[-:| ]+\|$/ { next }
  {
    n = split($0, cells, "|")
    # A row starts and ends with "|", so the first and last fields are empty.
    first = cells[2]; last = cells[n - 1]
    gsub(/^ +| +$/, "", first); gsub(/^ +| +$/, "", last)
    if (!header) { header = 1; print "HEADER\t" last; next }
    label = first; sub(/ \(.*$/, "", label)
    file = ""; count = 0; rest = last
    while (match(rest, /`[^`]*`|"[^"]*"/)) {
      token = substr(rest, RSTART + 1, RLENGTH - 2)
      if (substr(rest, RSTART, 1) == "`") {
        file = token
      } else if (file == "") {
        print "ORPHAN\t" label "\t" token; count++
      } else {
        print "TEST\t" label "\t" file "\t" token; count++
      }
      rest = substr(rest, RSTART + RLENGTH)
    }
    if (count == 0) print "EMPTY\t" label
  }
' "$ledger")"

header="$(printf '%s\n' "$records" | awk -F '\t' '$1 == "HEADER" { print $2; exit }')"
if [[ "$header" != "Tests" ]]; then
  echo "bounds_check.sh: no \"Enforced limits\" table whose last column is Tests in $ledger" >&2
  exit 2
fi

bad=0; tests=0; rows=()
declare -A row_tests=()
while IFS=$'\t' read -r kind label file name; do
  case "$kind" in
    TEST)
      if [[ -z "${row_tests[$label]+set}" ]]; then rows+=("$label"); row_tests[$label]=0; fi
      if [[ ! -f "$repo_root/$file" ]]; then
        printf 'NO FILE     %s: %s\n' "$label" "$file"; bad=1
      elif grep -Fxq -e "test \"$name\" {" -e "async test \"$name\" {" "$repo_root/$file"; then
        row_tests[$label]=$(( row_tests[$label] + 1 )); tests=$(( tests + 1 ))
      else
        printf 'NO TEST     %s: %s has no test "%s"\n' "$label" "$file" "$name"; bad=1
      fi
      ;;
    ORPHAN)
      printf 'NO FILE     %s: "%s" follows no backticked file path\n' "$label" "$file"; bad=1
      ;;
    EMPTY)
      printf 'NO TESTS    %s: the row names no test\n' "$label"; bad=1
      ;;
  esac
done <<< "$records"

for label in "${rows[@]}"; do
  printf '%-56s %2d tests\n' "$label" "${row_tests[$label]}"
done
if (( bad )); then
  echo "bounds check: FAIL"
  exit 1
fi
echo "bounds check: OK - ${#rows[@]} enforced limits name $tests tests that exist"
