#!/bin/bash
# Publish battery.sh and its SHA-256 checksum as assets on a GitHub release.
# `battery update` downloads these two files for the latest release and
# refuses to install when the checksum doesn't match, so run this every time
# a release is cut. Usage: ./scripts/publish-cli-assets.sh v1.5.1
# The release must already exist (created by hand, or by pushing the tag).
set -euo pipefail
tag="${1:?Usage: $0 <tag, e.g. v1.5.1>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version="$(grep -m1 '^BATTERY_CLI_VERSION=' battery.sh | sed 's/.*="//; s/"//')"
if [[ "$version" != "$tag" ]]; then
	echo "battery.sh reports $version, not $tag — bump BATTERY_CLI_VERSION first"
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp battery.sh "$tmp/battery.sh"
(cd "$tmp" && shasum -a 256 battery.sh > battery.sh.sha256)
gh release upload "$tag" "$tmp/battery.sh" "$tmp/battery.sh.sha256" --clobber
echo "Published battery.sh + battery.sh.sha256 on $tag"
