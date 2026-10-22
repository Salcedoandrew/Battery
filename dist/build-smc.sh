#!/bin/bash
# Rebuild dist/smc as a universal (arm64 + x86_64) binary from hholtmann/smcFanControl (GPL-2).
# Needs only the Xcode Command Line Tools. Usage: ./dist/build-smc.sh [commit]
set -euo pipefail
commit="${1:-e1bd672}"
dist="$(cd "$(dirname "$0")" && pwd)"
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT

git clone -q https://github.com/hholtmann/smcFanControl.git "$src"
git -C "$src" checkout -q "$commit"
cd "$src/smc-command"
for arch in arm64 x86_64; do
	# -DCMD_TOOL_BUILD enables the command line main()
	clang -O2 -arch $arch -mmacosx-version-min=11.0 -DCMD_TOOL_BUILD -Wno-deprecated-declarations -Wno-format-security \
		-o "smc-$arch" smc.c -framework IOKit -framework CoreFoundation
done
lipo -create -output "$dist/smc" smc-arm64 smc-x86_64
cp "$src/LICENSE" "$dist/LICENSE"
lipo -info "$dist/smc"
