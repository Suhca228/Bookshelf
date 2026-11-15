#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"

./scripts/build.sh release

rm -rf dist
mkdir -p dist
ditto build/Bookshelf.app dist/Bookshelf.app
ditto -c -k --sequesterRsrc --keepParent dist/Bookshelf.app "dist/Bookshelf-1.0.0.zip"

echo "==> Готово: dist/Bookshelf.app"
echo "==> Архів: dist/Bookshelf-1.0.0.zip"
