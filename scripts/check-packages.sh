#!/usr/bin/env bash
# Checks the deploy manifest (packages.sh): every gno.land/p/aib or
# gno.land/r/aib package that a listed package's deployed code imports (its
# .gno files other than tests and filetests) must be listed earlier, so a
# deployment in manifest order never meets a missing import. Exits non-zero
# otherwise.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/packages.sh"
declare -A seen=()

# imports prints the gno.land/[pr]/aib import paths of the non-test .gno files
# directly in dir, from their import declarations (single or grouped).
imports() {
  for f in "$1"/*.gno; do
    case "$f" in *_test.gno | *_filetest.gno) continue ;; esac
    awk '
      /^import \(/ { block = 1; next }
      block && /^\)/ { block = 0; next }
      block || /^import / {
        if (match($0, /"gno\.land\/[pr]\/aib\/[^"]*"/)) print substr($0, RSTART + 1, RLENGTH - 2)
      }
    ' "$f"
  done | sort -u
}
fail=0
for entry in "${PACKAGES[@]}"; do
  pkg="${entry%%:*}"
  dir="$root/${entry#*:}"
  if [ ! -d "$dir" ]; then
    echo "missing directory for $pkg: $dir"
    fail=1
    continue
  fi
  # Imports of this package's own files (not of its subpackages).
  while read -r imp; do
    [ "$imp" = "$pkg" ] && continue
    if [ -z "${seen[$imp]:-}" ]; then
      echo "$pkg imports $imp, which the manifest does not list before it"
      fail=1
    fi
  done < <(imports "$dir")
  seen[$pkg]=1
done
if [ "$fail" = 0 ]; then
  echo "packages.sh: ${#PACKAGES[@]} entries, every aib import listed before its importer"
fi
exit "$fail"
