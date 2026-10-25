#!/bin/bash
set -euo pipefail
# Fail loudly instead of reporting success: any step that fails aborts the
# install before the "🎉 installed" line at the end can print.

#
# ‼️ SECURITY NOTES FOR MAINTAINERS:
#
# This app uses a visudo configuration that allows a background script running as
# an unprivileged user to execute battery management commands without requiring a
# user password. This requires careful installation and design to avoid potential
# privilege-escalation vulnerabilities.
#
# Rule of thumb:
# - Unprivileged users must not be able to modify, replace, or inject any code
#   that can be executed with root privileges.
#
# For this reason:
# - All battery-related binaries and scripts that can be executed via sudo,
#   including those that prompt for a user password, must be owned by root.
# - They must not be writable by group or others.
# - Their parent directories must also be owned by root and not be writable by
#   unprivileged users, to prevent the replacement of executables.
#

# Reset PATH to minimal safe defaults
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# User welcome message
echo -e "\n####################################################################"
echo '# 👋 Welcome, this is the setup script for the battery CLI tool.'
echo -e "# Note: this script may ask for your password."
echo -e "####################################################################\n\n"

# Determine unprivileged user name
if [[ -n "${1:-}" ]]; then
	calling_user="$1"
else
	if [[ -n "${SUDO_USER:-}" ]]; then
		calling_user=$SUDO_USER
	else
		calling_user=${USER:-}
	fi
fi
if [[ -z "$calling_user" || "$calling_user" == "root" ]]; then
	echo "❌ Failed to determine unprivileged username"
	exit 1
fi

# Set variables
binfolder=/usr/local/co.palokaj.battery
configfolder=/Users/$calling_user/.battery
pidfile=$configfolder/battery.pid
logfile=$configfolder/battery.log
launch_agent_plist=/Users/$calling_user/Library/LaunchAgents/battery.plist
path_configfile=/etc/paths.d/50-battery

# Ask for sudo once, in most systems this will cache the permissions for a bit
sudo echo "🔋 Starting battery installation"
echo "[  1 ] Superuser permissions acquired."

# Cleanup after versions 1_3_2 and below
sudo rm -f /usr/local/bin/battery
sudo rm -f /usr/local/bin/smc

echo "[  2 ] Allocate temp folder"
tempfolder="$(mktemp -d)"
function cleanup() { rm -rf "$tempfolder"; }
trap cleanup EXIT

echo "[  3 ] Downloading latest version of battery CLI"
# Which ref to install from: a release tag (vX.Y.Z) pins the install to
# that release and its assets are checksum-verified below. An explicit
# BATTERY_REF naming a branch (e.g. main) is user-initiated and installs
# the repo zip for that branch, unverified. When BATTERY_REF is unset,
# resolve the latest release tag instead of defaulting to main, so a
# plain `setup.sh | bash` install is pinned and verified too.
# Latest release tag (e.g. v1.5.1) from the GitHub Releases API, or empty
# when GitHub can't be reached or the tag isn't a plain vX.Y.Z. Same
# pattern as latest_release_tag() in battery.sh.
latest_release_tag() {
	# Always exits 0 (prints the tag only when valid): callers assign
	# its output, and under `set -e` a failing assignment would abort
	# the script before the clear error below can print.
	local tag=""
	tag="$(curl -fsSL "https://api.github.com/repos/Salcedoandrew/battery/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)" || true
	if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$tag"
	fi
	return 0
}
if [[ -n "${BATTERY_REF:-}" ]]; then
	update_ref="$BATTERY_REF"
else
	update_ref="$(latest_release_tag)"
	if [[ -z "$update_ref" ]]; then
		echo "❌ Can't determine the latest Battery release (GitHub unreachable?). Set BATTERY_REF=vX.Y.Z to install a specific release, or BATTERY_REF=main to install from the main branch."
		exit 1
	fi
fi
batteryfolder="$tempfolder/battery"
rm -rf $batteryfolder
mkdir -p $batteryfolder
if [[ "$update_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# Pinned release install: download the release assets and verify
	# them before touching anything on disk. Any failure refuses the
	# install instead of installing unverified code.
	release_base="https://github.com/Salcedoandrew/battery/releases/download/$update_ref"
	for file in battery.sh battery.sh.sha256 smc smc.sha256 setup.sh setup.sh.sha256; do
		if ! curl -fsSL -o "$batteryfolder/$file" "$release_base/$file"; then
			echo "❌ Failed to download $file for $update_ref. Refusing to install."
			exit 1
		fi
	done
	if ! (cd "$batteryfolder" && shasum -a 256 -c battery.sh.sha256 smc.sha256 setup.sh.sha256 >/dev/null 2>&1); then
		echo "❌ Checksum mismatch for $update_ref. Refusing to install."
		exit 1
	fi
	if ! grep -q "BATTERY_CLI_VERSION=\"$update_ref\"" "$batteryfolder/battery.sh"; then
		echo "❌ Downloaded battery.sh does not report version $update_ref. Refusing to install."
		exit 1
	fi
	smc_binary="$batteryfolder/smc"
	battery_script="$batteryfolder/battery.sh"
elif [[ "$update_ref" == v* ]]; then
	echo "❌ BATTERY_REF '$update_ref' is not a plain release tag (vX.Y.Z). Refusing to install."
	exit 1
else
	# Branch install (user-initiated): repo zip, with explicit failure
	# checks — a failed download or a bad zip must fail loudly, never
	# install half a tree and print success.
	# Note: github names zips by <reponame>-<refname>.replace( '/', '-' )
	in_zip_folder_name="battery-$update_ref"
	if ! curl -fsSL -o $batteryfolder/repo.zip "https://github.com/Salcedoandrew/battery/archive/refs/heads/$update_ref.zip"; then
		echo "❌ Failed to download battery $update_ref."
		exit 1
	fi
	if ! unzip -qq $batteryfolder/repo.zip -d $batteryfolder; then
		echo "❌ Failed to unpack battery $update_ref."
		exit 1
	fi
	cp -r $batteryfolder/$in_zip_folder_name/* $batteryfolder
	rm $batteryfolder/repo.zip
	smc_binary="$batteryfolder/dist/smc"
	battery_script="$batteryfolder/battery.sh"
fi

# Check which charging keys this Mac has instead of assuming Apple Silicon:
# CHTE (Apple Silicon, macOS 15+), CH0B (older Apple Silicon) or BCLM (Intel)
# smc_key_has_data KEY — true when `smc -k KEY -r` exits 0 and reports a
# real value. A key that prints "no data", an "Error" line, or no hex value
# counts as unsupported. (The old probe piped the output through
# `grep -qv "no data"`, which read any line that wasn't "no data" — an
# "Error" line included — as support, so a Mac with no supported charging
# key could pass this check and install a limiter that can never limit.)
smc_key_has_data() {
	local out hex
	if ! out="$("$smc_binary" -k "$1" -r 2>/dev/null)"; then
		return 1
	fi
	if [[ "$out" == *"no data"* || "$out" == *"Error"* ]]; then
		return 1
	fi
	# Same hex extraction as smc_read_hex in battery.sh: the value follows
	# "bytes" in the smc output line, e.g. "(bytes 64)" -> "64".
	hex="${out#*bytes}"
	hex="$(echo "$hex" | tr -d ' ' | tr -d ')')"
	[[ "$hex" =~ ^[0-9a-fA-F]+$ ]]
}
chmod 755 "$smc_binary"
if ! smc_key_has_data CHTE && ! smc_key_has_data CH0B && ! smc_key_has_data BCLM; then
	echo "❌ This Mac has none of the supported charging keys (CHTE, CH0B or BCLM), so battery can't limit charging here."
	exit 1
fi

echo "[  4 ] Make sure $binfolder is recreated and owned by root"
sudo rm -rf "$binfolder" # start with an empty $binfolder and ensure there is no symlink or file at the path
sudo install -d -m 755 -o root -g wheel "$binfolder"

echo "[  5 ] Install prebuilt smc binary into $binfolder"
sudo install -m 755 -o root -g wheel "$smc_binary" "$binfolder/smc"

echo "[  6 ] Install battery script into $binfolder"
sudo install -m 755 -o root -g wheel "$battery_script" "$binfolder/battery"

echo "[  7 ] Make sure the PATH environment variable includes '$binfolder'"
if ! grep -qF "$binfolder" $path_configfile 2>/dev/null; then
	printf '%s\n' "$binfolder" | sudo tee "$path_configfile" >/dev/null
fi
sudo chown -h root:wheel $path_configfile
sudo chmod -h 644 $path_configfile
# Create a symlink for rare shells that do not initialize PATH from /etc/paths.d (including the current one)
sudo mkdir -p /usr/local/bin
sudo ln -sf "$binfolder/battery" /usr/local/bin/battery
sudo chown -h root:wheel /usr/local/bin/battery
# Create a link to smc as well to silence older GUI apps running with updated background executables
# (consider removing in the next releases)
sudo ln -sf "$binfolder/smc" /usr/local/bin/smc
sudo chown -h root:wheel /usr/local/bin/smc

echo "[  8 ] Set ownership and permissions for $configfolder"
mkdir -p $configfolder
sudo chown -hRP $calling_user $configfolder
sudo chmod -h 755 $configfolder

touch $logfile
sudo chown -h $calling_user $logfile
sudo chmod -h 644 $logfile

touch $pidfile
sudo chown -h $calling_user $pidfile
sudo chmod -h 644 $pidfile

# Fix permissions for 'create_daemon' action
echo "[  9 ] Fix ownership and permissions for $(dirname "$launch_agent_plist")"
# The directory may not exist on a fresh account; create it first, or the
# chown/chmod below would fail (and, with `set -e`, abort the install).
sudo mkdir -p "$(dirname "$launch_agent_plist")"
sudo chown -h $calling_user "$(dirname "$launch_agent_plist")"
sudo chmod -h 755 "$(dirname "$launch_agent_plist")"
# Best effort only: the plist itself is created later by `battery
# create_daemon`, so it may not exist yet. The `|| true` keeps that
# expected failure from aborting the install under `set -e`.
sudo chown -hf $calling_user "$launch_agent_plist" 2>/dev/null || true

echo "[ 10 ] Setup visudo configuration"
sudo $binfolder/battery visudo

echo "[ 11 ] Remove temp folder $tempfolder"
rm -rf $tempfolder

echo -e "\n🎉 Battery tool installed. Type \"battery help\" for instructions.\n"

exit 0
