#!/bin/bash
# Development check on a Mac: build everything, run the tests, optionally benchmark.
# Output goes to .logs/ so it can be read afterwards.
#   bash scripts/mac-test.sh test    build all targets + swift test
#   bash scripts/mac-test.sh bench   synthetic 300k-file tree, new engine vs 3.2
#   bash scripts/mac-test.sh all     test, then bench if the build succeeded
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$root/.logs"
mkdir -p "$logs"
step="${1:-test}"
say() { echo "[KongSeek] $*"; }
cd "$root" || exit 1
if [ "$step" = "all" ]; then
  bash "$root/scripts/mac-test.sh" test
  if grep -q '^exit 0$' "$logs/build.log"; then bash "$root/scripts/mac-test.sh" bench; fi
  say "全部完成，结果在 $logs ，可以回到 Claude 了。"
  exit 0
fi
echo "running: $step $(date '+%F %T')" > "$logs/status.txt"
{ sw_vers; swift --version; } > "$logs/env.log" 2>&1

case "$step" in
  test)
    say "编译中…"
    swift build --build-tests > "$logs/build.log" 2>&1
    echo "exit $?" >> "$logs/build.log"
    if grep -q '^exit 0$' "$logs/build.log"; then
      say "运行测试…"
      swift test > "$logs/test.log" 2>&1
      echo "exit $?" >> "$logs/test.log"
      say "测试结束：$(tail -1 "$logs/test.log")"
    else
      say "编译未通过，错误已记录。"
    fi
    ;;
  bench)
    say "运行性能对比（约需数分钟）…"
    tree="${TMPDIR:-/tmp}kfbench-tree"
    files="${2:-300000}"
    swift build -c release --product ksbench > "$logs/bench-build.log" 2>&1
    echo "exit $?" >> "$logs/bench-build.log"
    bin="$(swift build -c release --show-bin-path)/ksbench"
    if [ ! -f "$tree/.done-$files" ]; then
      rm -rf "$tree"
      "$bin" synth "$tree" "$files" > "$logs/bench-synth.log" 2>&1 && touch "$tree/.done-$files"
    fi
    "$bin" new "$tree" > "$logs/bench-new.log" 2>&1
    echo "exit $?" >> "$logs/bench-new.log"
    "$bin" legacy "$tree" > "$logs/bench-legacy.log" 2>&1
    echo "exit $?" >> "$logs/bench-legacy.log"
    ;;
  *)
    echo "unknown step: $step" >> "$logs/status.txt"
    exit 2
    ;;
esac
echo "done: $step $(date '+%F %T')" >> "$logs/status.txt"
