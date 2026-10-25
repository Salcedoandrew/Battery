#!/bin/bash

## ###############
## Update management
## variables are used by this binary as well at the update script
## ###############
BATTERY_CLI_VERSION="v1.5.2"

# If a script may run as root:
#   - Reset PATH to safe defaults at the very beginning of the script.
#   - Never include user-owned directories in PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Ensure Ctrl+C stops the entire script, not just the current command
trap 'exit 130' INT

## ###############
## Variables
## ###############
visudo_folder=/private/etc/sudoers.d
visudo_file=${visudo_folder}/battery
configfolder=$HOME/.battery
pidfile=$configfolder/battery.pid
logfile=$configfolder/battery.log
maintain_percentage_tracker_file=$configfolder/maintain.percentage
maintain_voltage_tracker_file=$configfolder/maintain.voltage
daemon_path=$HOME/Library/LaunchAgents/battery.plist
calibrate_pidfile=$configfolder/calibrate.pid
heat_threshold_file=$configfolder/heat.threshold
topup_file=$configfolder/topup
path_configfile=/etc/paths.d/50-battery

# Voltage limits
voltage_min="10.5"
voltage_max="12.6"
voltage_hyst_min="0.1"
voltage_hyst_max="2"

# SECURITY NOTES:
# - ALWAYS hardcode and use the absolute path to the battery executables to avoid PATH-based spoofing.
#   Think of the scenario where 'battery update_silent' running as root invokes 'battery visudo' as a
#   PATH spoofing opportunity example.
# - Ensure this script, smc binary and their parent folders are root-owned and not writable by
#   the user or others.
# - Ensure that you are not sourcing any user-writable scripts within this script to avoid overrides of
#   security critical variables.
binfolder="/usr/local/co.palokaj.battery"
battery_binary="$binfolder/battery"
smc_binary="$binfolder/smc"

# GitHub repo for releases. Updates come from GitHub *releases*, never from a
# moving branch: `battery update` downloads battery.sh for the latest release
# tag and checks its SHA-256 checksum (published with the release, see
# scripts/publish-cli-assets.sh) before installing. A checksum only proves the
# file matches the release — it does not protect against a compromised
# GitHub account. Signing the release (e.g. minisign) would be the next step.
# Security note: Do NOT allow github_user or github_repo to be injected via
#                environment variables or any other means. Keep them hardcoded.
github_user="Salcedoandrew"
github_repo="battery"
github_api_latest_release="https://api.github.com/repos/${github_user}/${github_repo}/releases/latest"
github_release_download="https://github.com/${github_user}/${github_repo}/releases/download"

## ###############
## Housekeeping
## ###############

# Create config folder if needed
mkdir -p $configfolder

# create logfile if needed
touch $logfile

# Trim logfile if needed (via a temp file: writing `tail` output straight back
# into the same file empties it, because the shell truncates the file first)
logsize=$(stat -f%z "$logfile")
max_logsize_bytes=5000000
if ((logsize > max_logsize_bytes)); then
	tail -n 100 "$logfile" >"$logfile.tmp" && mv "$logfile.tmp" "$logfile"
fi

# CLI help message
helpmessage="
Battery CLI utility $BATTERY_CLI_VERSION

Usage:

  battery status
    output battery SMC status, % and time remaining

  battery logs LINES[integer, optional]
    output logs of the battery CLI and GUI
    eg: battery logs 100

  battery maintain PERCENTAGE[10-100,stop] or RANGE[lower-upper]
    reboot-persistent battery level maintenance: turn off charging above, and on below a certain value
    it has the option of a --force-discharge flag that discharges even when plugged in (this does NOT work well with clamshell mode)
    eg: battery maintain 80           # maintain at 80%
    eg: battery maintain 70-80        # maintain between 70-80%
    eg: battery maintain stop

  battery maintain VOLTAGE[${voltage_min}V-${voltage_max}V,stop] (HYSTERESIS[${voltage_hyst_min}V-${voltage_hyst_max}V])
    reboot-persistent battery level maintenance: keep battery at a certain voltage
  default hysteresis: 0.1V
    eg: battery maintain 11.4V       # keeps battery between 11.3V and 11.5V
    eg: battery maintain 11.4V 0.3V  # keeps battery between 11.1V and 11.7V

  battery charging SETTING[on/off]
    manually set the battery to (not) charge
    eg: battery charging on

  battery adapter SETTING[on/off]
    manually set the adapter to (not) charge even when plugged in
    eg: battery adapter off

  battery calibrate [stop]
    calibrate the battery by discharging it to 15%, then recharging it to 100%, and keeping it there for 1 hour
    on Intel Macs (no forced discharge): charge to 100%, then you unplug and run the battery down to about 15%
    battery maintenance is restored upon completion
    menubar battery app execution, battery maintain, or battery calibrate stop will interrupt calibration

  battery heat THRESHOLD[20-60,off]
    while maintaining, pause charging when the battery is hotter than THRESHOLD °C (default 35)
    and resume once it is 2 °C cooler; without a value it prints the current setting
    eg: battery heat 35
    eg: battery heat off

  battery topup [stop]
    while maintaining, charge once to 100%, then go back to the maintained limit automatically
    eg: battery topup
    eg: battery topup stop

  battery charge LEVEL[10-100]
    charge the battery to a certain percentage; battery maintenance is restored upon completion
    eg: battery charge 90

  battery discharge LEVEL[10-100]
    block adapter power until the battery reaches the specified level; battery maintenance is restored upon completion
    eg: battery discharge 90

  battery check-update
    check whether a newer version is available on GitHub (downloads nothing, installs nothing)

  battery update
    update the battery utility to the latest version (downloaded from the latest GitHub release and checksum-verified first)

  battery reinstall
    reinstall the battery utility to the latest version (reruns the installation script from the latest release)

  battery uninstall
    enable charging, remove the smc tool, and the battery script

"

# Intel Macs: the firmware charge limit key BCLM accepts 20-100% (hex 14-64); allow exactly those writes
bclm_write_commands=$(for ((i = 20; i <= 100; i++)); do printf "%s, " "$smc_binary -k BCLM -w $(printf %02x $i)"; done)

# Visudo instructions
# File location: /etc/sudoers.d/battery
# Purpose:
# - Allows this script to execute 'sudo smc -w' commands without requiring a user password.
# - Allows passwordless updates.
visudoconfig="
# Visudo settings for the battery utility installed from https://github.com/actuallymentor/battery
# intended to be placed in $visudo_file on a mac

# Allow passwordless update (All battery app executables are owned by root to prevent privilege escalation attacks)
ALL ALL = NOPASSWD: $battery_binary update_silent
ALL ALL = NOPASSWD: $battery_binary update_silent is_enabled

# Allow passwordless battery-charging–related SMC write commands
Cmnd_Alias    CHARGING_OFF = $smc_binary -k CH0B -w 02, $smc_binary -k CH0C -w 02, $smc_binary -k CHTE -w 01000000
Cmnd_Alias    CHARGING_ON = $smc_binary -k CH0B -w 00, $smc_binary -k CH0C -w 00, $smc_binary -k CHTE -w 00000000
Cmnd_Alias    FORCE_DISCHARGE_OFF = $smc_binary -k CH0I -w 00, $smc_binary -k CHIE -w 00, $smc_binary -k CH0J -w 00
Cmnd_Alias    FORCE_DISCHARGE_ON = $smc_binary -k CH0I -w 01, $smc_binary -k CHIE -w 08, $smc_binary -k CH0J -w 01
Cmnd_Alias    BCLM_LIMIT = ${bclm_write_commands%, }
Cmnd_Alias    LED_CONTROL = $smc_binary -k ACLC -w 04, $smc_binary -k ACLC -w 03, $smc_binary -k ACLC -w 02, $smc_binary -k ACLC -w 01, $smc_binary -k ACLC -w 00
ALL ALL = NOPASSWD: CHARGING_OFF
ALL ALL = NOPASSWD: CHARGING_ON
ALL ALL = NOPASSWD: FORCE_DISCHARGE_OFF
ALL ALL = NOPASSWD: FORCE_DISCHARGE_ON
ALL ALL = NOPASSWD: LED_CONTROL
ALL ALL = NOPASSWD: BCLM_LIMIT
ALL ALL = NOPASSWD: $smc_binary -k BCLM -r

# Temporarily keep passwordless SMC reading commands so the old menubar GUI versions don't ask for password on each launch
# trying to execute 'battery visudo'. There is no harm in removing this, so do it as soon as you believe users are no
# longer using old versions.
ALL ALL = NOPASSWD: $smc_binary -k CH0C -r, $smc_binary -k CH0I -r, $smc_binary -k ACLC -r, $smc_binary -k CHIE -r, $smc_binary -k CHTE -r
"

# Get parameters
action=$1
setting=$2
subsetting=$3

## ###############
## Helpers
## ###############

function log() {
	echo -e "$(date +%D-%T) [$$]: $*"
}

function valid_percentage() {
	# 10-100, aligned with valid_percentage_range (whose lower bound must
	# be at least 10): 0 is not a maintainable level (maintain 0 would
	# disable charging immediately and forever). Calibration discharges to
	# 15%, so the floor cannot be higher than that.
	if ! [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" -lt 10 ]] || [[ "$1" -gt 100 ]]; then
		return 1
	else
		return 0
	fi
}

function valid_percentage_range() {
	# Check if input matches range format: NUMBER-NUMBER
	if ! [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]; then
		return 1
	fi

	# Extract lower and upper bounds
	local lower="${1%-*}"
	local upper="${1#*-}"

	# Validate both numbers are valid percentages
	if ! valid_percentage "$lower" || ! valid_percentage "$upper"; then
		return 1
	fi

	# Check lower < upper
	if [[ "$lower" -ge "$upper" ]]; then
		return 1
	fi

	# Check bounds are reasonable (lower >= 10, upper <= 100)
	if [[ "$lower" -lt 10 ]] || [[ "$upper" -gt 100 ]]; then
		return 1
	fi

	return 0
}

function valid_voltage() {
	if [[ "$1" =~ ^[0-9]+(\.[0-9]+)?V$ ]]; then
		return 0
	fi
	return 1
}

function smc_read_hex() {
	local key=$1
	local line
	# A failed smc read is not data: exit non-zero and print nothing, so
	# callers see "unknown" instead of parsing the error text as a value
	# (an smc error used to read as "disabled" charging).
	if ! line=$($smc_binary -k "$key" -r 2>/dev/null); then
		echo
		return 1
	fi
	if [[ "$line" =~ "no data" || "$line" =~ "Error" ]]; then
		echo
		return 1
	fi
	# Only well-formed hex is a reading; anything else is an error in disguise.
	local hex
	hex=$(echo "${line#*bytes}" | tr -d ' ' | tr -d ')')
	if [[ -z "$hex" || ! "$hex" =~ ^[0-9a-fA-F]+$ ]]; then
		echo
		return 1
	fi
	echo "$hex"
}

# smc_has_key KEY — true when the SMC binary reads KEY successfully.
# Checks the exit code and rejects error output, instead of regexing raw
# output (an smc failure used to look like a supported key).
function smc_has_key() {
	local output
	if ! output=$($smc_binary -k "$1" -r 2>/dev/null); then
		return 1
	fi
	[[ "$output" =~ "no data" || "$output" =~ "Error" ]] && return 1
	return 0
}

function smc_write_hex() {
	local key=$1
	local hex_value=$2
	if ! sudo $smc_binary -k "$key" -w "$hex_value" >/dev/null 2>&1; then
		log "⚠️ Failed to write $hex_value to $key"
		return 1
	fi
	return 0
}

## #########################
## Detect supported SMC keys
## #########################
smc_has_key CHTE && smc_supports_tahoe=true || smc_supports_tahoe=false
smc_has_key CH0B && smc_supports_legacy=true || smc_supports_legacy=false
smc_has_key CHIE && smc_supports_adapter_chie=true || smc_supports_adapter_chie=false
smc_has_key CH0I && smc_supports_adapter_ch0i=true || smc_supports_adapter_ch0i=false
smc_has_key CH0J && smc_supports_adapter_ch0j=true || smc_supports_adapter_ch0j=false
smc_has_key BCLM && smc_supports_bclm=true || smc_supports_bclm=false
# Intel Macs only have the firmware charge limit key BCLM: use it when the Apple Silicon charging keys are missing
[[ "$smc_supports_tahoe" == "false" && "$smc_supports_legacy" == "false" && "$smc_supports_bclm" == "true" ]] && smc_uses_bclm=true || smc_uses_bclm=false
[[ "$smc_supports_adapter_chie" == "true" || "$smc_supports_adapter_ch0i" == "true" || "$smc_supports_adapter_ch0j" == "true" ]] && smc_supports_discharge=true || smc_supports_discharge=false

function log_smc_capabilities() {
	log "SMC capabilities: tahoe=$smc_supports_tahoe legacy=$smc_supports_legacy BCLM=$smc_supports_bclm CHIE=$smc_supports_adapter_chie CH0I=$smc_supports_adapter_ch0i CH0J=$smc_supports_adapter_ch0j"
}

# Set the Intel firmware charge limit (BCLM, one byte, 20-100%).
# Returns non-zero when the write fails, so callers never report success
# for a limit that did not stick.
function set_bclm_limit() {
	local limit=$1
	((limit < 20)) && limit=20
	((limit > 100)) && limit=100
	log "🔋 Setting firmware charge limit (BCLM) to $limit%"
	if ! smc_write_hex BCLM "$(printf %02x "$limit")"; then
		log "❌ Failed to set firmware charge limit (BCLM) to $limit%"
		return 1
	fi
	return 0
}

function get_bclm_limit() {
	local hex=$(smc_read_hex BCLM)
	[[ -n "$hex" ]] && echo $((16#$hex))
}

# Actual charging state from ioreg; pmset lags behind SMC changes by up to minutes
function get_ioreg_charging_state() {
	local data=$(ioreg -rn AppleSmartBattery | grep '"ChargerData"')
	local current=$(echo "$data" | grep -oE '"ChargingCurrent"=[0-9]+' | cut -d= -f2)
	local reason=$(echo "$data" | grep -oE '"NotChargingReason"=[0-9]+' | cut -d= -f2)
	if [[ -z "$current" ]]; then
		echo "unknown"
	elif ((current > 0)) && [[ "${reason:-0}" == "0" ]]; then
		echo "charging (${current}mA)"
	else
		echo "not charging"
	fi
}

# AlDente writes the same SMC keys; two controllers fight each other
function warn_if_aldente_running() {
	if pgrep -qif "aldente"; then
		log "⚠️ AlDente is running. It controls the same charging keys as battery, so the two will override each other. Quit AlDente (and disable its charge limiter) to use battery."
	fi
}

# Heat protection threshold in °C, or "off" (default 35)
function get_heat_threshold() {
	local threshold=$(cat "$heat_threshold_file" 2>/dev/null)
	echo "${threshold:-35}"
}

# Battery temperature in hundredths of a °C, from ioreg
function get_battery_temperature() {
	ioreg -rn AppleSmartBattery | awk '/"Temperature" =/ { print $3; exit }'
}

function format_temperature() {
	printf "%d.%d°C" $(($1 / 100)) $(($1 % 100 / 10))
}

# "hot" above the threshold, "ok" again once 2 °C below it; $1 is the previous state
function get_heat_state() {
	local threshold=$(get_heat_threshold) temp=$(get_battery_temperature)
	if [[ "$threshold" == "off" || -z "$temp" ]]; then
		echo "ok"
	elif ((temp > threshold * 100)); then
		echo "hot"
	elif [[ "$1" == "hot" ]] && ((temp > (threshold - 2) * 100)); then
		echo "hot"
	else
		echo "ok"
	fi
}

function is_fully_charged() {
	ioreg -rn AppleSmartBattery | grep -q '"FullyCharged" = Yes' || [[ "$(get_battery_percentage)" -ge 100 ]]
}

# pid_is_alive PID — true when PID exists and is not a zombie (a zombie is
# already dead, waiting to be reaped; waiting on it would hang the stop).
function pid_is_alive() {
	local pid=$1
	kill -0 "$pid" 2>/dev/null || return 1
	[[ "$(ps -o stat= -p "$pid" 2>/dev/null)" =~ Z ]] && return 1
	return 0
}

# is_battery_pid PID KIND — true when PID is a battery process of KIND
# ("maintain": a synchronous maintain loop; "calibrate": a calibration run).
# The command line must contain the battery binary running that action: a
# stale pidfile whose PID was recycled by an unrelated process must never
# match. The match is not start-anchored: the kernel runs the script via
# its shebang, so the command line starts with the interpreter
# ("/bin/bash /usr/local/co.palokaj.battery/battery maintain_...").
function is_battery_pid() {
	local pid=$1 kind=$2
	local cmdline
	cmdline=$(ps -o args= -p "$pid" 2>/dev/null)
	case "$kind" in
		maintain)
			case "$cmdline" in
				*"$battery_binary maintain_synchronous"*|*"$battery_binary maintain_voltage_synchronous"*) return 0 ;;
			esac
			;;
		calibrate)
			case "$cmdline" in
				*"$battery_binary calibrate"*) return 0 ;;
			esac
			;;
	esac
	return 1
}

# stop_verified_pid PID KIND — stop a battery process, verified at every
# step. Only signals a PID that is alive and is really a battery process
# of KIND (see is_battery_pid): a stale pidfile never kills an unrelated
# process. SIGTERM first, wait up to ~5 seconds, then SIGKILL, and return
# non-zero (with a loud log) when the process will not die. Returns 0 when
# there was nothing to stop (dead PID, a stale PID that is not ours, or
# this process itself).
function stop_verified_pid() {
	local pid=$1 kind=$2
	[[ -n "$pid" ]] || return 0
	if [[ "$pid" == "$$" ]]; then
		log "⚠️ Not stopping PID $pid: it is this process"
		return 0
	fi
	if ! pid_is_alive "$pid"; then
		return 0
	fi
	if ! is_battery_pid "$pid" "$kind"; then
		log "⚠️ Not stopping PID $pid: it is not a battery $kind process (\"$(ps -o args= -p "$pid" 2>/dev/null)\")"
		return 0
	fi
	kill "$pid" 2>/dev/null
	local waited=0
	while pid_is_alive "$pid" && ((waited < 10)); do
		sleep 0.5
		((waited++))
	done
	if pid_is_alive "$pid"; then
		log "⚠️ PID $pid did not exit, sending SIGKILL"
		kill -9 "$pid" 2>/dev/null
		sleep 1
	fi
	if pid_is_alive "$pid"; then
		log "❌ PID $pid will not die, refusing to report success"
		return 1
	fi
	return 0
}

# stop_maintain_loops_by_command — stop maintain loops found by their exact
# command line, for when there is no pidfile (e.g. a loop started by launchd
# before this version wrote one). pgrep only nominates candidates; each one
# is verified by stop_verified_pid before it is signalled. Returns non-zero
# when a loop will not die.
function stop_maintain_loops_by_command() {
	local pid failed=0
	for pid in $(pgrep -f "maintain_synchronous" 2>/dev/null; pgrep -f "maintain_voltage_synchronous" 2>/dev/null); do
		stop_verified_pid "$pid" "maintain" || failed=1
	done
	return $failed
}

# Stop a running calibration, including the charge/discharge helper it started
function stop_calibration() {
	test -f "$calibrate_pidfile" || return 0
	local pid
	pid=$(cat "$calibrate_pidfile" 2>/dev/null)
	if [[ -n "$pid" ]]; then
		# Only the children of a real battery calibrate process may be
		# killed: a stale pidfile must never touch an unrelated process.
		if is_battery_pid "$pid" "calibrate"; then
			pkill -P "$pid" &>/dev/null
		fi
		if ! stop_verified_pid "$pid" "calibrate"; then
			log "❌ Calibration process $pid will not die"
			return 1
		fi
	fi
	rm -f "$calibrate_pidfile"
	log "🚨 Calibration process have been stopped"
}

## #################
## SMC Manipulation
## #################

# Change magsafe color
# see community sleuthing: https://github.com/actuallymentor/battery/issues/71
function change_magsafe_led_color() {
	local color=$1

	# Intel Macs have no ACLC LED key
	[[ "$smc_uses_bclm" == "true" ]] && return

	log "💡 Setting magsafe color to $color"

	if [[ "$color" == "green" ]]; then
		log "setting LED to green"
		sudo $smc_binary -k ACLC -w 03
	elif [[ "$color" == "orange" ]]; then
		log "setting LED to orange"
		sudo $smc_binary -k ACLC -w 04
	else
		# Default action: reset. Value 00 is a guess and needs confirmation
		log "resetting LED"
		sudo $smc_binary -k ACLC -w 00
	fi
}

# Re:discharging, we're using keys uncovered by @howie65: https://github.com/actuallymentor/battery/issues/20#issuecomment-1364540704
# CH0I seems to be the "disable the adapter" key
function enable_discharging() {
	if [[ "$smc_supports_discharge" == "false" ]]; then
		log "⚠️ Forced discharge is not supported on this Mac (no CHIE/CH0I/CH0J SMC key), skipping"
		return 1
	fi
	log "🔽🪫 Enabling battery discharging"
	if [[ "$smc_supports_adapter_chie" == "true" ]]; then
		smc_write_hex CHIE 08 || { log "❌ Failed to enable discharging (CHIE)"; return 1; }
	elif [[ "$smc_supports_adapter_ch0j" == "true" ]]; then
		smc_write_hex CH0J 01 || { log "❌ Failed to enable discharging (CH0J)"; return 1; }
	else
		smc_write_hex CH0I 01 || { log "❌ Failed to enable discharging (CH0I)"; return 1; }
	fi
	smc_write_hex ACLC 01 || { log "❌ Failed to set MagSafe LED (ACLC) while enabling discharging"; return 1; }
	return 0
}

function disable_discharging() {
	# Nothing to disable on Macs without a discharge key (Intel)
	[[ "$smc_supports_discharge" == "false" ]] && return
	log "🔼🪫 Disabling battery discharging"
	if [[ "$smc_supports_adapter_chie" == "true" ]]; then
		smc_write_hex CHIE 00 || { log "❌ Failed to disable discharging (CHIE)"; return 1; }
	elif [[ "$smc_supports_adapter_ch0j" == "true" ]]; then
		smc_write_hex CH0J 00 || { log "❌ Failed to disable discharging (CH0J)"; return 1; }
	elif [[ "$smc_supports_adapter_ch0i" == "true" ]]; then
		smc_write_hex CH0I 00 || { log "❌ Failed to disable discharging (CH0I)"; return 1; }
	else
		smc_write_hex CH0I 00 || { log "❌ Failed to disable discharging (CH0I)"; return 1; }
	fi
	# Keep track of status
	is_charging=$(get_smc_charging_status)

	# During a top-up the target is 100%
	local target=$setting
	test -f "$topup_file" && target=100

	if ! valid_percentage "$target"; then

		log "Disabling discharging: No valid maintain percentage set, enabling charging"
		# use direct commands since enable_charging also calls disable_discharging, and causes an eternal loop
		if [[ "$smc_supports_tahoe" == "true" ]]; then
			smc_write_hex CHTE 00000000 || { log "❌ Failed to enable charging (CHTE)"; return 1; }
		elif [[ "$smc_supports_legacy" == "true" ]]; then
			smc_write_hex CH0B 00 || { log "❌ Failed to enable charging (CH0B)"; return 1; }
			smc_write_hex CH0C 00 || { log "❌ Failed to enable charging (CH0C)"; return 1; }
		else
			log "⚠️ Unable to reset charging state"
			return 1
		fi
		change_magsafe_led_color "orange"

	elif [[ "$battery_percentage" -ge "$target" && "$is_charging" == "enabled" ]]; then

		log "Disabling discharging: Charge above $target, disabling charging"
		disable_charging || { log "❌ Failed to disable charging"; return 1; }
		change_magsafe_led_color "green"

	elif [[ "$battery_percentage" -lt "$target" && "$is_charging" == "disabled" ]]; then

		log "Disabling discharging: Charge below $target, enabling charging"
		# use direct commands since enable_charging also calls disable_discharging, and causes an eternal loop
		if [[ "$smc_supports_tahoe" == "true" ]]; then
			smc_write_hex CHTE 00000000 || { log "❌ Failed to enable charging (CHTE)"; return 1; }
		elif [[ "$smc_supports_legacy" == "true" ]]; then
			smc_write_hex CH0B 00 || { log "❌ Failed to enable charging (CH0B)"; return 1; }
			smc_write_hex CH0C 00 || { log "❌ Failed to enable charging (CH0C)"; return 1; }
		else
			log "⚠️ Unable to reset charging state"
			return 1
		fi
		change_magsafe_led_color "orange"

	fi

	battery_percentage=$(get_battery_percentage)
}

# Re:charging, Aldente uses CH0B https://github.com/davidwernhart/AlDente/blob/0abfeafbd2232d16116c0fe5a6fbd0acb6f9826b/AlDente/Helper.swift#L227
# but @joelucid uses CH0C https://github.com/davidwernhart/AlDente/issues/52#issuecomment-1019933570
# so I'm using both since with only CH0B I noticed sometimes during sleep it does trigger charging
function enable_charging() {
	log "🔌🔋 Enabling battery charging"
	if [[ "$smc_supports_tahoe" == "true" ]]; then
		smc_write_hex CHTE 00000000 || { log "❌ Failed to enable charging (CHTE)"; return 1; }
	elif [[ "$smc_supports_legacy" == "true" ]]; then
		smc_write_hex CH0B 00 || { log "❌ Failed to enable charging (CH0B)"; return 1; }
		smc_write_hex CH0C 00 || { log "❌ Failed to enable charging (CH0C)"; return 1; }
	elif [[ "$smc_uses_bclm" == "true" ]]; then
		set_bclm_limit 100 || return 1
	else
		log "⚠️ Unable to determine SMC keys for enabling charging"
		return 1
	fi
	disable_discharging
}

function disable_charging() {
	log "🔌🪫 Disabling battery charging"
	if [[ "$smc_supports_tahoe" == "true" ]]; then
		smc_write_hex CHTE 01000000 || { log "❌ Failed to disable charging (CHTE)"; return 1; }
	elif [[ "$smc_supports_legacy" == "true" ]]; then
		smc_write_hex CH0B 02 || { log "❌ Failed to disable charging (CH0B)"; return 1; }
		smc_write_hex CH0C 02 || { log "❌ Failed to disable charging (CH0C)"; return 1; }
	elif [[ "$smc_uses_bclm" == "true" ]]; then
		# Intel: cap the firmware limit at the current level so it stops charging
		set_bclm_limit "$(get_battery_percentage)" || return 1
	else
		log "⚠️ Unable to determine SMC keys for disabling charging"
		return 1
	fi
}

# Whether the SMC has ever been driven successfully by this process.
# A maintain loop uses it to tell a dead SMC (first write fails: abort)
# from a transient failure later (log and retry next minute).
smc_proven=false

# apply_charging_state enable|disable — drive charging once. The first
# charging write proves the SMC can be driven; if it fails, the process
# exits 1 instead of looping forever on a dead SMC. Later failures only
# log; the maintain loop retries them next minute. Returns 0 on success,
# 1 when a later write failed.
function apply_charging_state() {
	local action=$1
	if [[ "$action" == "disable" ]]; then
		if disable_charging; then
			smc_proven=true
			return 0
		fi
	else
		if enable_charging; then
			smc_proven=true
			return 0
		fi
	fi
	if [[ "$smc_proven" == "true" ]]; then
		log "⚠️ Failed to $action charging, will retry next minute"
		return 1
	fi
	log "❌ First charging write failed, stopping maintenance"
	exit 1
}

function get_smc_charging_status() {
	# Intel: charging counts as "enabled" only when the firmware limit is off (100%)
	if [[ "$smc_uses_bclm" == "true" ]]; then
		local limit=$(get_bclm_limit)
		[[ -z "$limit" ]] && echo "unknown" && return
		[[ "$limit" == "100" ]] && echo "enabled" || echo "disabled"
		return
	fi
	local status_key="CH0B"
	if [[ "$smc_supports_tahoe" == "true" ]]; then
		status_key="CHTE"
	fi
	hex_status=$(smc_read_hex "$status_key")
	if [[ -z "$hex_status" ]]; then
		echo "unknown"
		return
	fi
	if [[ "$smc_supports_tahoe" == "true" ]]; then
		if [[ "$hex_status" == "00000000" ]]; then
			echo "enabled"
		else
			echo "disabled"
		fi
	elif [[ "$hex_status" == "00" ]]; then
		echo "enabled"
	else
		echo "disabled"
	fi
}

function get_smc_discharging_status() {
	[[ "$smc_supports_discharge" == "false" ]] && echo "not discharging" && return
	local status_key="CH0I"
	if [[ "$smc_supports_adapter_chie" == "true" ]]; then
		status_key="CHIE"
	elif [[ "$smc_supports_adapter_ch0j" == "true" ]]; then
		status_key="CH0J"
	fi
	hex_status=$(smc_read_hex "$status_key")
	if [[ -z "$hex_status" ]]; then
		echo "unknown"
		return
	fi
	if [[ "$hex_status" == "0" || "$hex_status" == "00" ]]; then
		echo "not discharging"
	else
		echo "discharging"
	fi
}

## ###############
## Statistics
## ###############

function get_battery_percentage() {
	battery_percentage=$(pmset -g batt | tail -n1 | awk '{print $3}' | sed s:\%\;::)
	echo "$battery_percentage"
}

function get_remaining_time() {
	time_remaining=$(pmset -g batt | tail -n1 | awk '{print $5}')
	echo "$time_remaining"
}

function get_charger_state() {
	ac_attached=$(pmset -g batt | tail -n1 | awk '{ x=match($0, /AC attached/) > 0; print x }')
	echo "$ac_attached"
}

function get_maintain_percentage() {
	maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
	echo "$maintain_percentage"
}

function get_voltage() {
	voltage=$(ioreg -l -n AppleSmartBattery -r | grep "\"Voltage\" =" | awk '{ print $3/1000 }' | tr ',' '.')
	echo "$voltage"
}

## ##################
## Miscellany helpers
## ##################

function determine_unprivileged_user() {
	local username="$1"
	if [[ "$username" == "root" ]]; then
		log "⚠️ 'battery $action $setting $subsetting': argument user is root, trying to recover" >&2
		username=""
	fi
	if [[ -z "$username" && -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
		username="$SUDO_USER"
	fi
	if [[ -z "$username" && -n "$USER" && "$USER" != "root" ]]; then
		username="$USER"
	fi
	if [[ -z "$username" && "$HOME" == /Users/* ]]; then
		username="$(basename "$HOME")";
	fi
	if [[ -z "$username" ]]; then
		log "⚠️ 'battery $action $setting $subsetting': unable to determine unprivileged user; falling back to 'logname'" >&2
		username="$(logname 2>/dev/null || true)"
	fi
	echo "$username"
}

function assert_unprivileged_user() {
	local username="$1"
	if [[ -z "$username" || "$username" == "root" ]]; then
		log "❌ 'battery $action $setting $subsetting': failed to determine unprivileged user"
		exit 11
	fi
}

function assert_not_running_as_root() {
	if [[ $EUID -eq 0 ]]; then
		echo " ❌ The following command should not be executed with root privileges:"
		echo "        battery $action $setting $subsetting"
		echo "    Please, try running without 'sudo'"
		exit 1
	fi
}

function assert_running_as_root() {
	if [[ $EUID -ne 0 ]]; then
		log "❌ battery $action $setting $subsetting: must be executed with root privileges"
		exit 1
	fi
}

function ensure_owner() {
	local owner="$1" group="$2" path="$3"
	[[ -e $path ]] || { return 1; }
	local cur_owner=$(stat -f '%Su' "$path")
	local cur_group=$(stat -f '%Sg' "$path")
	if [[ $cur_owner != "$owner" || $cur_group != "$group" ]]; then
		sudo chown -h "${owner}:${group}" "$path"
	fi
}

function ensure_owner_mode() {
	local owner="$1" group="$2" mode="$3" path="$4"
	ensure_owner "$owner" "$group" "$path" || return
	local cur_mode=$(stat -f '%Lp' "$path")
	if [[ $cur_mode != "${mode#0}" ]]; then
		sudo chmod -h "$mode" "$path"
	fi
}

# Use the following function to apply any setup related fixes which require root permissions.
# This function is executed by 'update_silent' action with EUID==0.
function fixup_installation_owner_mode() {
	local username=$1

	ensure_owner_mode $username staff 755 "$(dirname "$daemon_path")"
	ensure_owner_mode $username staff 644 "$daemon_path"

	ensure_owner_mode $username staff 755 "$configfolder"
	ensure_owner_mode $username staff 644 "$pidfile"
	ensure_owner_mode $username staff 644 "$logfile"
	ensure_owner_mode $username staff 644 "$maintain_percentage_tracker_file"
	ensure_owner_mode $username staff 644 "$maintain_voltage_tracker_file"
	ensure_owner_mode $username staff 644 "$calibrate_pidfile"

	ensure_owner_mode root wheel 755 "$visudo_folder"
	ensure_owner_mode root wheel 440 "$visudo_file"

	ensure_owner_mode root wheel 755 "$binfolder"
	ensure_owner_mode root wheel 755 "$battery_binary"
	ensure_owner_mode root wheel 755 "$smc_binary"

	# Do some cleanup after previous versions
	sudo rm -f "$configfolder/visudo.tmp"
}

## ###############
## Updates (checked first, installed only if verified — like alic)
## ###############

# Latest release tag (e.g. v1.5.1) from the GitHub Releases API, or empty
# when GitHub can't be reached or the tag isn't a plain vX.Y.Z. Reads the
# API, downloads nothing.
function latest_release_tag() {
	local tag
	tag="$(curl -fsSL "$github_api_latest_release" 2>/dev/null \
		| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$tag"
}

# version_is_newer OLD NEW — true (exit 0) when NEW is a newer vX.Y.Z than OLD.
function version_is_newer() {
	local a="${1#v}" b="${2#v}"
	local -a av bv
	IFS=. read -ra av <<< "$a"
	IFS=. read -ra bv <<< "$b"
	local i x y
	for i in 0 1 2; do
		x="${av[i]:-0}"; y="${bv[i]:-0}"
		((10#$x < 10#$y)) && return 0
		((10#$x > 10#$y)) && return 1
	done
	return 1
}

# Download battery.sh and its checksum for release tag $1 into directory $2,
# verify the SHA-256, and print the path to the verified script.
# Refuses (exit 1) when anything fails to download, the checksum doesn't
# match, or the script doesn't report the version it claims to be.
# Keep in sync with update.sh, which carries the same check standalone.
function download_verified_cli() {
	local tag="$1" dir="$2"
	local script_url="${github_release_download}/${tag}/battery.sh"
	if ! curl -fsSL -o "$dir/battery.sh" "$script_url"; then
		echo "❌ Failed to download battery.sh for $tag."
		return 1
	fi
	if ! curl -fsSL -o "$dir/battery.sh.sha256" "${script_url}.sha256"; then
		echo "❌ Failed to download the checksum for $tag. Refusing to install an unverified update."
		return 1
	fi
	if ! (cd "$dir" && shasum -a 256 -c battery.sh.sha256 >/dev/null 2>&1); then
		echo "❌ Checksum mismatch for battery.sh $tag. Refusing to install."
		return 1
	fi
	if ! grep -q "BATTERY_CLI_VERSION=\"$tag\"" "$dir/battery.sh"; then
		echo "❌ Downloaded battery.sh does not report version $tag. Refusing to install."
		return 1
	fi
	echo "$dir/battery.sh"
	return 0
}

# Download setup.sh and its checksum for release tag $1 into directory $2,
# verify the SHA-256, and print the path to the verified script.
# Refuses (exit 1) when anything fails to download or the checksum doesn't
# match. Same pattern as download_verified_cli, for setup.sh.
function download_verified_setup() {
	local tag="$1" dir="$2"
	local script_url="${github_release_download}/${tag}/setup.sh"
	if ! curl -fsSL -o "$dir/setup.sh" "$script_url"; then
		echo "❌ Failed to download setup.sh for $tag."
		return 1
	fi
	if ! curl -fsSL -o "$dir/setup.sh.sha256" "${script_url}.sha256"; then
		echo "❌ Failed to download the checksum for $tag. Refusing to run an unverified setup script."
		return 1
	fi
	if ! (cd "$dir" && shasum -a 256 -c setup.sh.sha256 >/dev/null 2>&1); then
		echo "❌ Checksum mismatch for setup.sh $tag. Refusing to run it."
		return 1
	fi
	echo "$dir/setup.sh"
	return 0
}

## ###############
## Actions
## ###############

# If the config folder or log file were just created by the code above while
# running as root, set the correct ownership and permissions.
if [[ $EUID -eq 0 ]]; then
	username="$(determine_unprivileged_user "$SUDO_USER")"
	if [[ -n "$username" && "$username" != "root" ]]; then
		fixup_installation_owner_mode "$username"
	fi
fi

# Version message
if [[ "$action" == "version" ]] || [[ "$action" == "--version" ]]; then
	echo "$BATTERY_CLI_VERSION"
	exit 0
fi

# Help message
if [ -z "$action" ] || [[ "$action" == "help" ]] || [[ "$action" == "--help" ]]; then
	echo -e "$helpmessage"
	exit 0
fi

# Update '/etc/sudoers.d/battery' config if needed
if [[ "$action" == "visudo" ]]; then

	# Allocate temp folder
	tempfolder="$(mktemp -d)"
	function cleanup() { rm -rf "$tempfolder"; }
	trap cleanup EXIT

	# Write the visudo file to a tempfile
	visudo_tmpfile="$tempfolder/visudo.tmp"
	echo -e "$visudoconfig" >$visudo_tmpfile

	# If the visudo folder does not exist, make it
	if ! test -d "$visudo_folder"; then
		sudo mkdir -p "$visudo_folder"
	fi
	ensure_owner_mode root wheel 755 "$visudo_folder"

	# If the visudo file is the same (no error, exit code 0), set the permissions just
	if sudo cmp $visudo_file $visudo_tmpfile &>/dev/null; then

		echo "☑️  The existing battery visudo file is what it should be for version $BATTERY_CLI_VERSION"

		# Check if file permissions are correct, if not, set them
		ensure_owner_mode root wheel 440 "$visudo_file"

		# Delete tempfolder
		rm -rf "$tempfolder"

		# exit because no changes are needed
		exit 0

	fi

	# Validate that the visudo tempfile is valid
	if sudo visudo -c -f $visudo_tmpfile &>/dev/null; then

		# Copy the visudo file from tempfile to live location
		sudo cp $visudo_tmpfile $visudo_file

		# Set correct permissions on visudo file
		ensure_owner_mode root wheel 440 "$visudo_file"

		# Delete tempfolder
		rm -rf "$tempfolder"

		echo "✅ Visudo file updated successfully"

	else
		echo "❌ Error validating visudo file, this should never happen:"
		sudo visudo -c -f $visudo_tmpfile
	fi

	exit 0
fi

# Check whether a newer version is available, without downloading or
# installing anything. Exit 0 when the check ran; the message says whether
# an update is available. The menu bar app uses this for "Check for updates".
if [[ "$action" == "check-update" ]]; then
	latest="$(latest_release_tag)"
	if [[ -z "$latest" ]]; then
		echo "❌ Can't check for updates: no internet connection (or GitHub unreachable)."
		exit 1
	fi
	if version_is_newer "$BATTERY_CLI_VERSION" "$latest"; then
		echo "Update available: $latest (you have $BATTERY_CLI_VERSION)"
		echo "Run 'battery update' to install it."
	else
		echo "You're up to date ($BATTERY_CLI_VERSION)."
	fi
	exit 0
fi

# Reinstall helper
if [[ "$action" == "reinstall" ]]; then
	latest="$(latest_release_tag)"
	if [[ -z "$latest" ]]; then
		echo "❌ Can't check for updates: no internet connection (or GitHub unreachable)."
		exit 1
	fi
	echo "This will reinstall battery $latest from the release (setup script for $latest)"
	if [[ ! "$setting" == "silent" ]]; then
		echo "Press any key to continue"
		read
	fi
	# Never pipe an unverified script into bash: download setup.sh and its
	# published checksum from the release, verify, then run the local file.
	# (On failure the helper's error is captured in $verified_setup, so
	# print it: without this the reinstall would exit 1 silently.)
	tempfolder="$(mktemp -d)"
	function cleanup() { rm -rf "$tempfolder"; }
	trap cleanup EXIT
	verified_setup="$(download_verified_setup "$latest" "$tempfolder")" || { echo "$verified_setup"; exit 1; }
	BATTERY_REF="$latest" bash "$verified_setup"
	exit 0
fi

# Update helper for GUI app
if [[ "$action" == "update_silent" ]]; then

	assert_running_as_root

	# Exit with success when the GUI app just checks if passwordless updates are enabled
	if [[ "$setting" == "is_enabled" ]]; then
		exit 0
	fi

	# Try updating: download the latest release and verify its checksum first.
	latest="$(latest_release_tag)"
	if [[ -z "$latest" ]]; then
		echo "❌ Can't check for updates: no internet connection (or GitHub unreachable)."
		exit 1
	fi
	if version_is_newer "$BATTERY_CLI_VERSION" "$latest"; then
		tempfolder="$(mktemp -d)"
		function cleanup() { rm -rf "$tempfolder"; }
		trap cleanup EXIT
		verified="$(download_verified_cli "$latest" "$tempfolder")" || exit 1
		install -d -m 755 -o root -g wheel "$binfolder"
		install -m 755 -o root -g wheel "$verified" "$battery_binary"
		echo "✅ battery background script was updated to $latest."
		rm -rf "$tempfolder"
	else
		echo "☑️  No updates found (you have $BATTERY_CLI_VERSION, latest is $latest)"
	fi

	# Update the visudo configuration on each update ensuring that the latest version
	# is always installed.
	# Note: this will overwrite the visudo configuration file only if it is outdated.
	$battery_binary visudo

	# Determine the name of unprivileged user
	username="$(determine_unprivileged_user "")"
	assert_unprivileged_user "$username"

	# Use opportunity to fixup installation
	fixup_installation_owner_mode "$username"

	exit 0
fi

# Update helper for Terminal users
if [[ "$action" == "update" ]]; then

	assert_not_running_as_root

	# The older GUI versions 1_3_2 and below can not run silent passwordless update and
	# will complain with alert. Just exit with success and let them update themselves.
	# Remove this condition in future versions when you believe the old UI is not used anymore.
	if [[ "$setting" == "silent" ]]; then
		exit 0
	fi

	# The code below repeats integrity checks from GUI app, specifically from
	# app/modules/battery.js: 'initialize_battery'. Try keeping it consistent.

	function check_installation_integrity() (
		function not_link_and_root_owned() {
			[[ ! -L "$1" ]] && [[ $(stat -f '%u' "$1") -eq 0 ]]
		}

		not_link_and_root_owned "$binfolder" && \
		not_link_and_root_owned "$battery_binary" && \
		not_link_and_root_owned "$smc_binary" && \
		sudo -n "$battery_binary" update_silent is_enabled >/dev/null 2>&1
	)

	if ! check_installation_integrity; then
		version_before="0" # Force restart maintenance process
		echo -e "‼️ The battery installation seems to be broken. Forcing reinstall...\n"
		$battery_binary reinstall silent
	else
		version_before="$($battery_binary version)"
		sudo $battery_binary update_silent
	fi

	# Restart background maintenance process if update was installed
	if [[ -x $battery_binary ]] && [[ "$($battery_binary version)" != "$version_before" ]]; then
		printf "\n%s\n" "🛠️  Restarting 'battery maintain' ..."
		$battery_binary maintain recover
	fi

	exit 0
fi

# Uninstall helper
if [[ "$action" == "uninstall" ]]; then

	if [[ ! "$setting" == "silent" ]]; then
		echo "This will enable charging, and remove the smc tool and battery script"
		echo "Press any key to continue"
		read
	fi

	$battery_binary maintain stop
	$battery_binary remove_daemon

	enable_charging
	disable_discharging

	sudo rm -fv /usr/local/bin/battery
	sudo rm -fv /usr/local/bin/smc

	sudo rm -fv "$visudo_file"
	sudo rm -frv "$binfolder"
	sudo rm -frv "$configfolder"
	sudo rm -fv "$path_configfile"

	# Ensure no dangling battery processes are left running
	pkill -f "/usr/local/bin/battery.*|/usr/local/co\.palokaj\.battery/battery.*"

	exit 0
fi

# Charging on/off controller
if [[ "$action" == "charging" ]]; then

	log "Setting $action to $setting"
	warn_if_aldente_running

	# Disable running maintenance first: a loop that is still alive would
	# undo the charging change within a minute, so a failed stop is fatal.
	$battery_binary maintain stop || { log "❌ Could not stop maintenance, not changing the charging state"; exit 1; }

	# Set charging to on and off; a failed SMC write must exit non-zero
	# instead of reporting success.
	if [[ "$setting" == "on" ]]; then
		enable_charging || { log "❌ Failed to enable charging"; exit 1; }
	elif [[ "$setting" == "off" ]]; then
		disable_charging || { log "❌ Failed to disable charging"; exit 1; }
	else
		log "Error: $setting is not \"on\" or \"off\"."
		exit 1
	fi

	# Confirm with ioreg (pmset lags)
	sleep 5
	log "Battery is now $(get_ioreg_charging_state) (ioreg)"

	exit 0

fi

# Discharge on/off controller
if [[ "$action" == "adapter" ]]; then

	log "Setting $action to $setting"

	if [[ "$smc_supports_discharge" == "false" ]]; then
		log "⚠️ This Mac has no SMC key to disconnect the adapter (Intel), nothing to do"
		exit 0
	fi

	# Disable running maintenance first: a loop that is still alive would
	# fight the adapter change, so a failed stop is fatal.
	$battery_binary maintain stop || { log "❌ Could not stop maintenance, not changing the adapter state"; exit 1; }

	# Set adapter state; a failed SMC write must exit non-zero instead of
	# reporting success.
	if [[ "$setting" == "on" ]]; then
		disable_discharging || { log "❌ Failed to reconnect the adapter"; exit 1; }
	elif [[ "$setting" == "off" ]]; then
		enable_discharging || { log "❌ Failed to disconnect the adapter"; exit 1; }
	else
		log "Error: $setting is not \"on\" or \"off\"."
		exit 1
	fi

	exit 0

fi

# Charging on/off controller
if [[ "$action" == "charge" ]]; then

	if ! valid_percentage "$setting"; then
		log "Error: $setting is not a valid setting for battery charge. Please use a number between 10 and 100"
		exit 1
	fi

	# Stop battery maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain stop || { log "❌ Could not stop maintenance, not starting to charge"; exit 1; }
	fi

	# Start charging; a failed write must exit non-zero instead of looping
	# forever waiting for a level that will never rise.
	battery_percentage=$(get_battery_percentage)
	log "Charging to $setting% from $battery_percentage%"
	enable_charging || { log "❌ Failed to enable charging"; exit 1; } # also disables discharging

	# Loop until battery charging level is reached
	while [[ "$battery_percentage" -lt "$setting" ]]; do

		if [[ "$battery_percentage" -ge "$((setting - 3))" ]]; then
			sleep 20
		else
			caffeinate -is sleep 60
		fi

		battery_percentage=$(get_battery_percentage)

	done

	# Stop charging at the target; if the write fails, charging continues
	# past the target, so fail loudly — but still try to restore
	# maintenance below before exiting.
	charge_failed=false
	disable_charging || { log "❌ Failed to stop charging at $setting%, charging continues past the target"; charge_failed=true; }
	if [[ "$charge_failed" == "true" ]]; then
		log "Charging did not stop at $battery_percentage%"
	else
		log "Charging completed at $battery_percentage%"
	fi

	# Try restoring maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain recover
	fi

	[[ "$charge_failed" == "true" ]] && exit 1
	exit 0

fi

# Discharging on/off controller
if [[ "$action" == "discharge" ]]; then

	if ! valid_percentage "$setting"; then
		log "Error: $setting is not a valid setting for battery discharge. Please use a number between 10 and 100"
		exit 1
	fi

	if [[ "$smc_supports_discharge" == "false" ]]; then
		log "⚠️ Forced discharge is not supported on this Mac (no CHIE/CH0I/CH0J SMC key, e.g. Intel). Unplug the charger to discharge. Skipping."
		exit 0
	fi

	# Stop battery maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain stop || { log "❌ Could not stop maintenance, not starting to discharge"; exit 1; }
	fi

	# Start discharging; a failed write must exit non-zero instead of
	# looping forever waiting for a level that will never drop.
	battery_percentage=$(get_battery_percentage)
	log "Discharging to $setting% from $battery_percentage%"
	enable_discharging || { log "❌ Failed to enable discharging"; exit 1; }

	# Loop until battery charging level is reached
	while [[ "$battery_percentage" -gt "$setting" ]]; do

		log "Battery at $battery_percentage% (target $setting%)"
		caffeinate -is sleep 60
		battery_percentage=$(get_battery_percentage)

	done

	# Stop discharging at the target; if the write fails, the adapter stays
	# disconnected after the command "completes", so fail loudly — but
	# still try to restore maintenance below before exiting.
	discharge_failed=false
	disable_discharging || { log "❌ Failed to stop discharging at $setting%, the adapter stays disconnected"; discharge_failed=true; }
	if [[ "$discharge_failed" == "true" ]]; then
		log "Discharging did not stop at $battery_percentage%"
	else
		log "Discharging completed at $battery_percentage%"
	fi

	# Try restoring maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain recover
	fi

	[[ "$discharge_failed" == "true" ]] && exit 1
	exit 0

fi

# Maintain at level
if [[ "$action" == "maintain_synchronous" ]]; then

	log_smc_capabilities

	# Checking if the calibration process is running
	stop_calibration

	# Recover old maintain status if old setting is found
	if [[ "$setting" == "recover" ]]; then

		# Before doing anything, log out environment details as a debugging trail
		log "Debug trail. User: $USER, config folder: $configfolder, logfile: $logfile, file called with 1: $1, 2: $2"

		maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
		if [[ $maintain_percentage ]]; then
			log "Recovering maintenance percentage $maintain_percentage"
			setting=$(echo $maintain_percentage)
		else
			log "No setting to recover, exiting"
			exit 0
		fi
	fi

	# Parse setting - could be single value or range
	lower_bound=""
	upper_bound=""
	is_range=false

	if valid_percentage_range "$setting"; then
		# Range format: lower-upper
		is_range=true
		lower_bound="${setting%-*}"
		upper_bound="${setting#*-}"
	elif valid_percentage "$setting"; then
		# Single value format (backward compatible)
		is_range=false
		lower_bound="$setting"
		upper_bound="$setting"
	else
		log "Error: $setting is not a valid setting for battery maintain. Please use a number between 10 and 100, or a range like 70-80"
		exit 1
	fi

	# Check if the user requested that the battery maintenance first discharge to the desired level
	if [[ "$subsetting" == "--force-discharge" ]]; then
		# Before we start maintaining the battery level, first discharge to the target level
		discharge_target="$lower_bound"
		log "Triggering discharge to $discharge_target before enabling charging limiter"
		BATTERY_HELPER_MODE=1 $battery_binary discharge "$discharge_target"
		log "Discharge pre battery-maintenance complete, continuing to battery maintenance loop"
	else
		log "Not triggering discharge as it is not requested"
	fi

	# This process owns the pidfile from here on (also when started at login
	# by launchd, which writes no pidfile itself), and exits once 'maintain
	# stop' or a new 'maintain' replaces it, so a stale loop can never
	# re-apply an old limit.
	echo $$ >"$pidfile"

	# Intel: the firmware holds the limit itself, so write BCLM once instead of toggling charging.
	# BCLM can reset on reboot/wake, so check it every minute and re-apply only if it changed.
	if [[ "$smc_uses_bclm" == "true" ]]; then
		log "Maintaining battery at $upper_bound% via the firmware charge limit (BCLM)"
		# The first limit write proves the SMC can be driven; if it fails,
		# abort instead of looping forever on a dead SMC.
		set_bclm_limit "$upper_bound" || { log "❌ First charge-limit write failed, stopping maintenance"; exit 1; }
		heat_state=ok
		while [[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]]; do
			target=$upper_bound

			# Top-up: limit off (100%) until full, then back to the normal limit
			if test -f "$topup_file"; then
				if is_fully_charged; then
					rm -f "$topup_file"
					log "🔋 Top-up complete, back to $upper_bound%"
				else
					target=100
				fi
			fi

			# Heat protection: while hot, cap the limit at the level the battery had when it got hot
			previous_heat_state=$heat_state
			heat_state=$(get_heat_state "$heat_state")
			if [[ "$heat_state" == "hot" ]]; then
				[[ "$previous_heat_state" == "hot" ]] || hot_limit=$(get_battery_percentage)
				((hot_limit < target)) && target=$hot_limit
			fi
			[[ "$heat_state" != "$previous_heat_state" ]] && log "🌡️ Battery at $(format_temperature "$(get_battery_temperature)"), heat protection $([[ "$heat_state" == "hot" ]] && echo "pausing" || echo "resuming") charging"

			((target < 20)) && target=20
			[[ "$(get_bclm_limit)" == "$target" ]] || set_bclm_limit "$target"
			sleep 60
		done
		log "Maintenance was stopped or replaced, exiting"
		exit 0
	fi

	# Start charging
	battery_percentage=$(get_battery_percentage)

	if [[ "$is_range" == true ]]; then
		log "Maintaining battery between $lower_bound% and $upper_bound% from $battery_percentage%"
	else
		log "Charging to and maintaining at $setting% from $battery_percentage%"
	fi

	# The SMC must be readable before the loop starts: a loop that cannot
	# see the charging state cannot change it either.
	if [[ "$(get_smc_charging_status)" == "unknown" ]]; then
		log "❌ Cannot read the charging state from SMC, stopping maintenance"
		exit 1
	fi

	# Loop until battery percent is exceeded. The loop owns the pidfile:
	# it exits as soon as the pidfile no longer holds its own PID, so a
	# 'maintain stop' (or a new 'maintain') retires it even if the kill
	# that was supposed to stop it missed.
	heat_state=ok
	while [[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]]; do

		# Keep track of status
		is_charging=$(get_smc_charging_status)
		ac_attached=$(get_charger_state)

		# Top-up: charge to 100% once, then back to the normal limit
		lower=$lower_bound
		upper=$upper_bound
		if test -f "$topup_file"; then
			if is_fully_charged; then
				rm -f "$topup_file"
				log "🔋 Top-up complete, back to $upper_bound%"
			else
				lower=100
				upper=100
			fi
		fi

		# Heat protection: pause charging while hot, the normal rules apply again once cooled down
		previous_heat_state=$heat_state
		heat_state=$(get_heat_state "$heat_state")
		[[ "$heat_state" != "$previous_heat_state" ]] && log "🌡️ Battery at $(format_temperature "$(get_battery_temperature)"), heat protection $([[ "$heat_state" == "hot" ]] && echo "pausing" || echo "resuming") charging"

		if [[ "$heat_state" == "hot" ]]; then

			[[ "$is_charging" == "enabled" ]] && apply_charging_state disable

		elif [[ "$battery_percentage" -ge "$upper" && ("$is_charging" == "enabled" || "$ac_attached" == "1") ]]; then

			log "Charge at or above $upper%"
			if [[ "$is_charging" == "enabled" ]]; then
				apply_charging_state disable
			fi
			change_magsafe_led_color "green"

		elif [[ "$battery_percentage" -lt "$lower" && "$is_charging" == "disabled" ]]; then

			log "Charge below $lower%"
			apply_charging_state enable
			change_magsafe_led_color "orange"

		fi

		sleep 60

		battery_percentage=$(get_battery_percentage)

	done

	log "Maintenance was stopped or replaced, exiting"
	exit 0

fi

# Maintain at voltage
if [[ "$action" == "maintain_voltage_synchronous" ]]; then

	log_smc_capabilities

	# Recover old maintain status if old setting is found
	if [[ "$setting" == "recover" ]]; then

		# Before doing anything, log out environment details as a debugging trail
		log "Debug trail. User: $USER, config folder: $configfolder, logfile: $logfile, file called with 1: $1, 2: $2"

		maintain_voltage=$(cat $maintain_voltage_tracker_file 2>/dev/null)
		if [[ $maintain_voltage ]]; then
			log "Recovering maintenance voltage $maintain_voltage"
			setting=$(echo $maintain_voltage | awk '{print $1}')
			subsetting=$(echo $maintain_voltage | awk '{print $2}')
		else
			log "No setting to recover, exiting"
			exit 0
		fi
	fi

	# This process owns the pidfile from here on (also when started at login
	# by launchd, which writes no pidfile itself), and exits once 'maintain
	# stop' or a new 'maintain' replaces it.
	echo $$ >"$pidfile"

	voltage=$(get_voltage)
	lower_voltage=$(echo "$setting - $subsetting" | bc -l)
	upper_voltage=$(echo "$setting + $subsetting" | bc -l)
	log "Keeping voltage between ${lower_voltage}V and ${upper_voltage}V"

	# The SMC must be readable before the loop starts: a loop that cannot
	# see the charging state cannot change it either.
	if [[ "$(get_smc_charging_status)" == "unknown" ]]; then
		log "❌ Cannot read the charging state from SMC, stopping maintenance"
		exit 1
	fi

	# Loop. It exits as soon as the pidfile no longer holds its own PID, so
	# a 'maintain stop' (or a new 'maintain') retires it even if the kill
	# that was supposed to stop it missed.
	while [[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]]; do
		is_charging=$(get_smc_charging_status)

		if (($(echo "$voltage < $lower_voltage" | bc -l))) && [[ "$is_charging" == "disabled" ]]; then
			log "Battery at ${voltage}V"
			apply_charging_state enable
		fi
		if (($(echo "$voltage >= $upper_voltage" | bc -l))) && [[ "$is_charging" == "enabled" ]]; then
			log "Battery at ${voltage}V"
			apply_charging_state disable
		fi

		sleep 60

		voltage=$(get_voltage)

	done

	log "Maintenance was stopped or replaced, exiting"
	exit 0

fi

# Asynchronous battery level maintenance
if [[ "$action" == "maintain" ]]; then

	assert_not_running_as_root
	warn_if_aldente_running

	# Validate the setting BEFORE touching anything: an invalid setting must
	# not kill the running limiter first (it used to, then exit with an error
	# and leave the Mac unmaintained).
	is_voltage=false
	if valid_voltage "$setting"; then
		setting="${setting//V/}"

		if valid_voltage "$subsetting"; then
			subsetting="${subsetting//V/}"
		else
			subsetting="0.1"
		fi

		if (($(echo "$setting < $voltage_min" | bc -l) || $(echo "$setting > $voltage_max" | bc -l))); then
			log "Error: ${setting}V is not a valid setting. Please use a value between ${voltage_min}V and ${voltage_max}V"
			exit 1
		fi
		if (($(echo "$subsetting < $voltage_hyst_min" | bc -l) || $(echo "$subsetting > $voltage_hyst_max" | bc -l))); then
			log "Error: ${subsetting}V is not a valid setting. Please use a value between ${voltage_hyst_min}V and ${voltage_hyst_max}V"
			exit 1
		fi

		is_voltage=true

	# Check if setting is a percentage range or single value
	elif ! valid_percentage "$setting" && ! valid_percentage_range "$setting"; then
		log "Called with $setting $action"
		# If setting is not a valid percentage/range and not a special keyword, exit with an error.
		if ! { [[ "$setting" == "stop" ]] || [[ "$setting" == "recover" ]]; }; then
			log "Error: $setting is not a valid setting for battery maintain. Please use a number between 10 and 100, a range like 70-80, or an action keyword like 'stop' or 'recover'."
			exit 1
		fi

	fi

	# Intel firmware limit (BCLM) cannot go below 20%: a lower maintain
	# level would be clamped to 20% by set_bclm_limit while claiming a
	# lower one. Reject it here instead of reporting success for a limit
	# that cannot be kept. (On Intel the maintained level is the upper
	# bound of a range; the lower bound only decides when charging resumes
	# on Apple Silicon, so only the upper bound is checked.)
	if [[ "$smc_uses_bclm" == "true" && "$setting" != "stop" && "$setting" != "recover" && "$is_voltage" == "false" ]]; then
		if valid_percentage_range "$setting"; then
			if [[ "${setting#*-}" -lt 20 ]]; then
				log "Error: the Intel firmware charge limit (BCLM) cannot go below 20%; ${setting#*-}% is not maintainable on this Mac"
				exit 1
			fi
		elif valid_percentage "$setting"; then
			if [[ "$setting" -lt 20 ]]; then
				log "Error: the Intel firmware charge limit (BCLM) cannot go below 20%; $setting% is not maintainable on this Mac"
				exit 1
			fi
		fi
	fi

	disable_discharging

	# Stop any running maintain loop first: only signal a PID that is alive
	# and is really the battery maintain loop (see stop_verified_pid), and
	# wait for it to die. A stale pidfile never kills an unrelated process.
	# If the loop will not die, a new 'maintain' still proceeds (the new
	# pidfile retires the old loop at its next check), but 'maintain stop'
	# fails instead of reporting success.
	old_loop_ok=true
	if test -f "$pidfile"; then
		pid=$(cat "$pidfile" 2>/dev/null)
		if [[ -n "$pid" ]]; then
			log "Stopping old maintain process $pid"
			stop_verified_pid "$pid" "maintain" || old_loop_ok=false
		fi
	else
		# No pidfile (e.g. a loop started by launchd before this version
		# wrote one): find it by its exact command line instead.
		stop_maintain_loops_by_command || old_loop_ok=false
	fi

	stop_calibration

	if [[ "$setting" == "stop" ]]; then
		log "Stopping battery maintenance and enabling charging as default state"
		if [[ "$old_loop_ok" != "true" ]]; then
			# The loop is still alive: enabling charging now would be undone
			# by it. Remove the pidfile so it retires at its next check,
			# and fail loudly instead of reporting success.
			rm -f "$pidfile"
			log "❌ Could not stop the running maintain loop"
			exit 1
		fi
		rm -f "$pidfile" "$topup_file"
		$battery_binary disable_daemon
		# Enabling charging may fail (dead SMC); the verification below is
		# the arbiter, so a failed write is logged, not fatal by itself.
		enable_charging || log "⚠️ Failed to enable charging, verifying state anyway"
		# Verify before reporting success: the loop is gone (checked above)
		# and charging is actually enabled again.
		if [[ "$(get_smc_charging_status)" != "enabled" ]]; then
			log "❌ Charging is still not enabled after stopping maintenance (SMC reports $(get_smc_charging_status))"
			exit 1
		fi
		$battery_binary status
		exit 0
	fi

	# Prove the SMC can be read before starting a loop that depends on it:
	# a loop that cannot see the charging state cannot change it either.
	# (A failed first write is caught by the liveness check below.)
	if [[ "$(get_smc_charging_status)" == "unknown" ]]; then
		log "❌ Cannot read the charging state from SMC, not starting maintenance"
		exit 1
	fi

	# Start maintenance script. Both streams go to the logfile: a loop
	# holding the starter's stderr open would keep any caller that
	# captures the starter's output (GUI, scripts, $(...)) waiting forever.
	if [ "$is_voltage" = true ]; then
		log "Starting battery maintenance at ${setting}V ±${subsetting}V"
		nohup $battery_binary maintain_voltage_synchronous $setting $subsetting >>$logfile 2>&1 &
	else
		if valid_percentage_range "$setting"; then
			log "Starting battery maintenance between ${setting/-/% and }%"
		else
			log "Starting battery maintenance at $setting% $subsetting"
		fi
		nohup $battery_binary maintain_synchronous $setting $subsetting >>$logfile 2>&1 &
	fi

	# Store pid of maintenance process and setting
	echo $! >$pidfile
	pid=$(cat "$pidfile" 2>/dev/null)

	if ! [[ "$setting" == "recover" ]]; then

		rm "$maintain_percentage_tracker_file" "$maintain_voltage_tracker_file" 2>/dev/null

		if [[ "$is_voltage" = true ]]; then
			log "Writing new setting $setting $subsetting to $maintain_voltage_tracker_file"
			echo "$setting $subsetting" >$maintain_voltage_tracker_file
			log "Maintaining battery at ${setting}V ±${subsetting}V"

		else
			log "Writing new setting $setting to $maintain_percentage_tracker_file"
			echo $setting >$maintain_percentage_tracker_file
			if valid_percentage_range "$setting"; then
				log "Maintaining battery between ${setting/-/% and }%"
			else
				log "Maintaining battery at $setting%"
			fi
		fi

	fi

	# Enable the daemon that continues maintaining after reboot
	$battery_binary create_daemon

	# The loop proves it can drive the SMC before the starter reports
	# success: if it died on its first charging write, it is already gone.
	sleep 5
	if ! pid_is_alive "$pid"; then
		log "❌ The maintenance loop exited immediately, see $logfile for why"
		exit 1
	fi

	exit 0

fi

# Battery calibration
if [[ "$action" == "calibrate" ]]; then

	# Cancel a running calibration and go back to normal maintenance
	if [[ "$setting" == "stop" ]]; then
		stop_calibration
		$battery_binary maintain recover
		exit 0
	fi

	# Stop the maintaining
	$battery_binary maintain stop &>/dev/null

	# Kill old process silently
	stop_calibration &>/dev/null
	echo $$ >$calibrate_pidfile

	# Show progress in the terminal and in 'battery logs'
	function step() {
		echo "$*"
		log "Calibration: $*" >>"$logfile"
	}

	echo -e "Starting battery calibration\n"

	if [[ "$smc_supports_discharge" == "false" ]]; then

		# Intel: the adapter can't be switched off, so the user runs the battery down
		step "[ 1 ] Charging to 100% (charge limit off)"
		BATTERY_HELPER_MODE=1 $battery_binary charge 100 &>/dev/null

		step "[ 2 ] Full. Unplug the charger and use your Mac until the battery is at about 15% (checked every minute)"
		while [[ "$(get_battery_percentage)" -gt 15 ]]; do
			sleep 60
		done

		step "[ 3 ] Reached 15%. Plug the charger back in"

	else

		step "[ 1 ] Discharging battery to 15%"
		BATTERY_HELPER_MODE=1 $battery_binary discharge 15 &>/dev/null

		step "[ 2 ] Charging to 100%"
		BATTERY_HELPER_MODE=1 $battery_binary charge 100 &>/dev/null

		step "[ 3 ] Reached 100%, waiting for 1 hour"
		if ! enable_charging &>/dev/null; then
			step "❌ Failed to enable charging, calibration cannot continue"
			exit 1
		fi
		sleep 3600

		step "[ 4 ] Discharging battery to 80%"
		BATTERY_HELPER_MODE=1 $battery_binary discharge 80 &>/dev/null

	fi

	# Remove pidfile
	rm -f $calibrate_pidfile

	# Recover old maintain status
	step "[ 5 ] Restarting battery maintenance"
	$battery_binary maintain recover &>/dev/null

	echo -e "\n✅ Done\n"
	exit 0

fi

# Heat protection setting
if [[ "$action" == "heat" ]]; then

	if [[ -z "$setting" ]]; then
		get_heat_threshold
	elif [[ "$setting" == "off" ]] || [[ "$setting" =~ ^[0-9]+$ && "$setting" -ge 20 && "$setting" -le 60 ]]; then
		echo "$setting" >"$heat_threshold_file"
		[[ "$setting" == "off" ]] && log "🌡️ Heat protection off" || log "🌡️ Heat protection: pause charging above ${setting}°C (takes effect within a minute while maintaining)"
	else
		log "Error: $setting is not a valid heat threshold. Use a number of °C between 20 and 60, or 'off'"
		exit 1
	fi
	exit 0

fi

# Top up to 100% once
if [[ "$action" == "topup" ]]; then

	assert_not_running_as_root

	if [[ "$setting" == "stop" ]]; then
		rm -f "$topup_file"
		log "🔋 Top-up cancelled, back to the maintained limit within a minute"
	elif ! test -f "$pidfile"; then
		log "battery is not maintaining a limit, so charging already goes to 100%. Nothing to do."
	elif test -f "$maintain_voltage_tracker_file"; then
		log "Top-up only works while maintaining a percentage, not a voltage"
	else
		touch "$topup_file"
		log "🔋 Topping up to 100% once (starts within a minute), then back to $(get_maintain_percentage)%"
	fi
	exit 0

fi

# Status logger
if [[ "$action" == "status" ]]; then

	log "Battery at $(get_battery_percentage)% ($(get_remaining_time) remaining), $(get_voltage)V, smc charging $(get_smc_charging_status), $(get_ioreg_charging_state) (ioreg)"
	if [[ "$smc_uses_bclm" == "true" ]]; then
		log "Firmware charge limit (BCLM): $(get_bclm_limit)%"
	fi
	heat_threshold=$(get_heat_threshold)
	battery_temperature=$(get_battery_temperature)
	if [[ "$heat_threshold" == "off" ]]; then
		log "Heat protection: off (battery at $(format_temperature "${battery_temperature:-0}"))"
	elif ((${battery_temperature:-0} > heat_threshold * 100)); then
		log "Heat protection: battery at $(format_temperature "$battery_temperature"), above ${heat_threshold}°C, charging paused"
	else
		log "Heat protection: pauses charging above ${heat_threshold}°C (battery at $(format_temperature "${battery_temperature:-0}"))"
	fi
	test -f "$topup_file" && log "Top-up to 100% in progress, then back to the maintained limit"
	test -f "$calibrate_pidfile" && log "Calibration in progress, see 'battery logs' for the current step"
	warn_if_aldente_running
	if test -f $pidfile; then
		maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
		if [[ $maintain_percentage ]]; then
			if valid_percentage_range "$maintain_percentage"; then
				maintain_level="${maintain_percentage/-/% - }%"
			else
				maintain_level="$maintain_percentage%"
			fi
		else
			maintain_level=$(cat $maintain_voltage_tracker_file 2>/dev/null)
			maintain_level=$(echo "$maintain_level" | awk '{print $1 "V ±" $2 "V"}')
		fi
		log "Your battery is currently being maintained at $maintain_level"
	fi
	exit 0

fi

# Status logger in csv format
if [[ "$action" == "status_csv" ]]; then

	echo "$(get_battery_percentage),$(get_remaining_time),$(get_smc_charging_status),$(get_smc_discharging_status),$(get_maintain_percentage)"

fi

# launchd daemon creator, inspiration: https://www.launchd.info/
if [[ "$action" == "create_daemon" ]]; then

	assert_not_running_as_root

	call_action="maintain_synchronous"
	if test -f "$maintain_voltage_tracker_file"; then
		call_action="maintain_voltage_synchronous"
	fi

	daemon_definition="
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
	<dict>
		<key>Label</key>
		<string>com.battery.app</string>
		<key>ProgramArguments</key>
		<array>
			<string>$battery_binary</string>
			<string>$call_action</string>
			<string>recover</string>
		</array>
		<key>StandardOutPath</key>
		<string>$logfile</string>
		<key>StandardErrorPath</key>
		<string>$logfile</string>
		<key>RunAtLoad</key>
		<true/>
	</dict>
</plist>
"

	mkdir -p "${daemon_path%/*}"

	# check if daemon already exists
	if test -f "$daemon_path"; then

		log "Daemon already exists, checking for differences"
		daemon_definition_difference=$(diff --brief --ignore-space-change --strip-trailing-cr --ignore-blank-lines <(cat "$daemon_path" 2>/dev/null) <(echo "$daemon_definition"))

		# remove leading and trailing whitespaces
		daemon_definition_difference=$(echo "$daemon_definition_difference" | xargs)
		if [[ "$daemon_definition_difference" != "" ]]; then

			log "daemon_definition changed: replace with new definitions"
			echo "$daemon_definition" >"$daemon_path"

		fi
	else

		# daemon not available, create new launch deamon
		log "Daemon does not yet exist, creating daemon file at $daemon_path"
		echo "$daemon_definition" >"$daemon_path"

	fi

	# enable daemon
	launchctl enable "gui/$(id -u $USER)/com.battery.app"
	exit 0

fi

# Disable daemon
if [[ "$action" == "disable_daemon" ]]; then

	log "Disabling daemon at gui/$(id -u $USER)/com.battery.app"
	# Disabling alone does not stop a job that is already running: stop it
	# too, so 'maintain stop' really ends maintenance. Stopping a job that
	# is not running fails harmlessly (launchctl stop needs a loaded job).
	launchctl disable "gui/$(id -u $USER)/com.battery.app"
	launchctl stop "gui/$(id -u $USER)/com.battery.app" 2>/dev/null
	exit 0

fi

# Remove daemon
if [[ "$action" == "remove_daemon" ]]; then

	# Disable and stop first so no launchd job is left running after the
	# plist is gone, then remove the plist.
	launchctl disable "gui/$(id -u $USER)/com.battery.app" 2>/dev/null
	launchctl stop "gui/$(id -u $USER)/com.battery.app" 2>/dev/null
	rm -f "$daemon_path"
	exit 0

fi

# Display logs
if [[ "$action" == "logs" ]]; then

	amount="${2:-100}"

	echo -e "👾 Battery CLI logs:\n"
	tail -n $amount $logfile

	echo -e "\n🖥️	Battery GUI logs:\n"
	tail -n $amount "$configfolder/gui.log"

	echo -e "\n📁 Config folder details:\n"
	ls -lah $configfolder

	echo -e "\n⚙️	Battery data:\n"
	$battery_binary status
	$battery_binary | grep -E "v\d.*"

	exit 0

fi
