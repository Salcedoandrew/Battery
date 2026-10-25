#!/bin/bash

# Standalone updater for the battery CLI. Prefer `battery update` — this
# script exists for use from a checkout and for old GUI versions that still
# call it. It never runs code from a branch: the new CLI is downloaded from
# the latest GitHub release and its SHA-256 checksum is verified before
# installing. Keep the download-and-verify steps in sync with
# `download_verified_cli` in battery.sh.

echo -e "🔋 Starting battery update\n"

# This script is running as root:
#   - Reset PATH to safe defaults at the very beginning of the script.
#   - Never include user-owned directories in PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Ensure Ctrl+C stops the entire script, not just the current command
trap 'exit 130' INT

# Define the installation directory for the battery background executables
binfolder="/usr/local/co.palokaj.battery"

github_user="Salcedoandrew"
github_repo="battery"
github_api_latest_release="https://api.github.com/repos/${github_user}/${github_repo}/releases/latest"
github_release_download="https://github.com/${github_user}/${github_repo}/releases/download"

# Latest release tag (e.g. v1.5.1) from the GitHub Releases API, or empty
# when GitHub can't be reached or the tag isn't a plain vX.Y.Z.
function latest_release_tag() {
	local tag
	tag="$(curl -fsSL "$github_api_latest_release" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$tag"
}

function is_launched_by_gui_app() {
	# Determine the process group ID (PGID) of the current process
	local this_process_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
	# Return 0 if any process in the same process group has battery.app or Electron.app in its command string
	ps -x -g $this_process_pgid -o command= -ww 2>/dev/null | grep -qE '(battery\.app|Electron\.app)' >&/dev/null
}

# If running as an unprivileged user and launched by GUI app
if [[ $EUID -ne 0 ]] && is_launched_by_gui_app; then
	# This execution path is taken when GUI app version 1_3_2 or earlier launches update using
	# the battery script of the same version. This is expected when a new version of battery.sh
	# is released but the GUI app has not been updated yet.
	# Exit successfully with a silent warning to avoid disrupting the existing installation.
	printf "%s\n%s\n" \
		"The update to the next version requires root privileges." \
		"Run the updated menu bar GUI app or issue the 'battery update' command in Terminal."
	exit 0
fi

# Trigger reinstall for Terminal users to update from version 1_3_2 or earlier.
# Consider removing the following if..fi block in future versions when you believe
# that users are no longer using versions 1_3_2 or earlier. New versions of battery.sh are using
# more comprehensive checks in 'battery update' in order to trigger 'battery reinstall' when needed.
if [[ $EUID -ne 0 && ! -x "$binfolder/battery" ]]; then
	echo -e "💡 This battery update requires a full reinstall...\n"
	latest="$(latest_release_tag)"
	if [[ -z "$latest" ]]; then
		echo "❌ Can't check for updates: no internet connection (or GitHub unreachable)."
		exit 1
	fi
	curl -sS "https://raw.githubusercontent.com/${github_user}/${github_repo}/${latest}/setup.sh" | BATTERY_REF="$latest" bash
	$binfolder/battery maintain recover
	exit 0
fi

# Latest installed version, or empty when nothing is installed yet
installed_version="$("$binfolder/battery" version 2>/dev/null || true)"

echo -n "[ 1 ] Checking for the latest release: "
latest="$(latest_release_tag)"
if [[ -z "$latest" ]]; then
	echo -e "\n❌ Can't check for updates: no internet connection (or GitHub unreachable).\n"
	exit 1
fi
echo "$latest (installed: ${installed_version:-none})"

if [[ "$installed_version" == "$latest" ]]; then
	echo -e "\n☑️  No updates found\n"
	exit 0
fi

echo -n "[ 2 ] Allocating temp folder: "
tempfolder="$(mktemp -d)"
echo "$tempfolder"
function cleanup() { rm -rf "$tempfolder"; }
trap cleanup EXIT

echo "[ 3 ] Downloading battery.sh $latest and its checksum"
script_url="${github_release_download}/${latest}/battery.sh"
if ! curl -fsSL -o "$tempfolder/battery.sh" "$script_url"; then
	echo -e "\n❌ Failed to download battery.sh for $latest.\n"
	exit 1
fi
if ! curl -fsSL -o "$tempfolder/battery.sh.sha256" "${script_url}.sha256"; then
	echo -e "\n❌ Failed to download the checksum for $latest. Refusing to install an unverified update.\n"
	exit 1
fi

echo "[ 4 ] Verifying checksum"
if ! (cd "$tempfolder" && shasum -a 256 -c battery.sh.sha256 >/dev/null 2>&1); then
	echo -e "\n❌ Checksum mismatch for battery.sh $latest. Refusing to install.\n"
	exit 1
fi
if ! grep -q "BATTERY_CLI_VERSION=\"$latest\"" "$tempfolder/battery.sh"; then
	echo -e "\n❌ Downloaded battery.sh does not report version $latest. Refusing to install.\n"
	exit 1
fi

echo "[ 5 ] Writing script to $binfolder/battery"
sudo install -d -m 755 -o root -g wheel "$binfolder"
sudo install -m 755 -o root -g wheel "$tempfolder/battery.sh" "$binfolder/battery"

echo "[ 6 ] Remove temporary folder"
rm -rf "$tempfolder";

echo -e "\n🎉 Battery tool updated to $latest.\n"
