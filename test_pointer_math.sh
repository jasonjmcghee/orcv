#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build_tests"
BIN="$BUILD_DIR/pointer_math_tests"

mkdir -p "$BUILD_DIR"

swiftc \
  -O \
  -framework Foundation \
  -framework CoreGraphics \
  "$ROOT_DIR/PointerMath.swift" \
  "$ROOT_DIR/tests/PointerMathTests.swift" \
  -o "$BIN"

"$BIN"
