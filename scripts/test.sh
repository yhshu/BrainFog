#!/bin/zsh
# Runs the test suite with only the Command Line Tools installed.
set -euo pipefail
cd "${0:A:h}/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
export SDKROOT=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}
swift test --build-system native -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F "$@" 2>&1 \
  | grep -v "has been deprecated"
