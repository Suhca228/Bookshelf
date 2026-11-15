#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" = "--release" ]; then
    ./scripts/build.sh release
    open build/Bookshelf.app
else
    # Fast iteration: bare executable, still a regular windowed app.
    swift run Bookshelf
fi
