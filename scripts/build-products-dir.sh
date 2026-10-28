#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo 'Usage: build-products-dir.sh <project> <scheme> <configuration>' >&2
    exit 2
fi

settings=$(xcodebuild -project "$1" -scheme "$2" -configuration "$3" -showBuildSettings)
directory=$(printf '%s\n' "$settings" | awk '!found && /^[[:space:]]*BUILT_PRODUCTS_DIR = / { sub(/^[[:space:]]*BUILT_PRODUCTS_DIR = /, ""); print; found = 1 }')
if [ -z "$directory" ]; then
    echo 'Xcode did not report a build products directory.' >&2
    exit 1
fi
printf '%s\n' "$directory"
