#!/usr/bin/env bash
# Runs tools/regress.gd across all CPU cores and prints a per-island + overall summary.
#   tools/regress.sh [extra regress.gd options, e.g. --runs=20 --brain]
# Set GODOT=/path/to/godot if it isn't on PATH as "godot".
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
JOBS="${JOBS:-$(nproc)}"
if ! command -v "$GODOT" >/dev/null 2>&1; then
  echo "error: Godot binary '$GODOT' not found. Set GODOT=/path/to/Godot_v4.7-stable_linux.x86_64" >&2
  exit 1
fi
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
for ((i = 0; i < JOBS; i++)); do
  "$GODOT" --headless --path . -s res://tools/regress.gd -- --shard="$i/$JOBS" "$@" 2>/dev/null | grep '^RUN' >>"$OUT" &
done
wait
if [[ ! -s "$OUT" ]]; then
  echo "error: no rounds completed; run tools/regress.gd directly to see the error" >&2
  exit 1
fi
sort -t= -k2,2n -k3,3n "$OUT"
awk '
  { for (i = 2; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
    n[f["island"]]++; all++
    if (f["outcome"] == "STEWARD") { w[f["island"]]++; wins++ }
    ms += f["ms_per_tick"] * f["tick"]; ticks += f["tick"] }
  END {
    print "----"
    for (k in n) printf "island %-11s steward %2d/%-2d (%3.0f%%)\n", k, w[k], n[k], 100 * w[k] / n[k]
    printf "OVERALL steward %d/%d (%.0f%%)  mean %.2f ms/tick\n", wins, all, 100 * wins / all, ms / ticks
  }' "$OUT"
