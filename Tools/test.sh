#!/bin/zsh
# Build 番外 and run the unit tests on an iPhone simulator.
#   Tools/test.sh [simulator name]     (default: the first available iPhone)
set -e
cd "$(dirname "$0")/.."
command -v xcodegen > /dev/null || { echo "需要 XcodeGen：brew install xcodegen"; exit 1; }
xcodegen generate --quiet
name=${1:-$(xcrun simctl list devices available | grep -m1 -oE "iPhone[^(]+" | sed 's/ *$//')}
[[ -n $name ]] || { echo "没有可用的 iPhone 模拟器"; exit 1; }
mkdir -p build
echo "simulator: $name"
xcodebuild -project Pianwai.xcodeproj -scheme Pianwai -destination "platform=iOS Simulator,name=$name" \
  -derivedDataPath build/DerivedData test > build/test.log 2>&1 && code=0 || code=$?
grep -E "Executed [0-9]+ tests|\*\* (TEST|BUILD) (SUCCEEDED|FAILED)" build/test.log | tail -3
grep -E "Test Case .* failed" build/test.log | sed -E 's/ \([0-9.]+ seconds\)//' | sort -u | head -30
exit $code
