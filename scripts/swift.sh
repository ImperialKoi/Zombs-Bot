#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
task="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$task" == test ]]; then
  developer_dir="$(xcode-select -p)"
  framework_dir="$developer_dir/Library/Developer/Frameworks"
  test_flags=()
  if [[ -d "$framework_dir/Testing.framework" ]]; then
    test_flags=(-Xswiftc "-F$framework_dir" -Xlinker "-F$framework_dir" -Xlinker -rpath -Xlinker "$framework_dir" -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib")
  fi
  exec swift test --disable-xctest --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "${test_flags[@]}" "$@"
else
  exec swift "$task" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
fi
