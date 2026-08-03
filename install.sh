#!/bin/sh
set -e
# Mosaico installation script.
#
# This script is intended as a convenient way to get Mosaico running on a
# single machine for evaluation or development. It installs mosaicod (the
# Mosaico daemon) and an embedded PostgreSQL instance using system-level
# Podman containers supervised by systemd (via Quadlet).
#
# This script is not recommended for production environments. Before running
# this script, make yourself familiar with potential risks and limitations,
# and refer to the official documentation at https://docs.mosaico.dev.
#
# The script:
#
# - Requires `root` or `sudo` privileges to run.
# - Attempts to detect your Linux distribution and installs Podman if missing.
# - Installs dependencies without asking for confirmation.
# - Guides you through the configuration interactively, or runs fully
#   unattended when `-y` / `--yes` is given.
# - Sets up systemd Quadlet configurations in /etc/containers/systemd/.
# - Generates a random PostgreSQL password on first run and reuses it on
#   subsequent runs — it is never printed to the terminal or the log.
# - Installs a host CLI wrapper at /usr/local/bin/mosaicod that forwards
#   commands into the container.
# - Copies itself to /usr/local/bin/mosaico-installer for future management.
#
# Source code is available at https://github.com/mosaico-labs/mosaico
#
# Usage
# ==============================================================================
#
# To install the latest stable version of Mosaico:
#
# 1. download the script
#
#   $ curl -fsSL https://get.mosaico.dev -o install-mosaico.sh
#
# 2. verify the script's content
#
#   $ cat install-mosaico.sh
#
# 3. run the script with --dry-run to verify the steps it executes
#
#   $ sh install-mosaico.sh --dry-run
#
# 4. run the script either as root, or using sudo to perform the installation.
#
#   $ sudo sh install-mosaico.sh
#
# Paired options
# ==============================================================================
#
# Several options only make sense together. Each feature toggle has a set of
# dependent options:
#
#   --store-backend obj  requires  --obj-endpoint, --obj-bucket,
#                                  --obj-access-key, --obj-secret-key
#   --store-backend fs   requires  --fs-dir
#   --enable-tls         requires  --domain
#   --cleanup            requires  --cleanup-retention, --cleanup-time-interval
#
# In an interactive session you may pass any subset of a group: whatever is
# missing is asked for at the prompt. With -y the run aborts with a list of the
# missing options, unless they have a documented default.
#
# Passing a dependent option also turns its feature on, so
# `--domain mosaico.example.com` implies --enable-tls.
#
# Command-line options
# ==============================================================================
#
# -y, --yes
# Run unattended: never prompt, apply the documented defaults for anything not
# passed explicitly, and fail fast if a mandatory option is missing.
#
#   $ sudo sh install-mosaico.sh -y --api-key
#
# --store-backend <fs|obj>
# Selects where dataset frames are stored. `fs` keeps them on a local
# filesystem path (see --fs-dir), `obj` uses an S3-compatible object store such
# as AWS S3, MinIO or Google Cloud Storage (see --obj-*). Default: fs.
#
# --fs-dir <PATH>
# Host directory used when --store-backend is `fs`.
# Default: /var/lib/mosaico/storage.
#
# --obj-endpoint <URL>
# Object store endpoint, for example https://s3.amazonaws.com or
# http://minio:9000. Required when --store-backend is `obj`.
#
# --obj-bucket <NAME>
# Object store bucket / container name. Default: mosaico.
#
# --obj-access-key <KEY>
# --obj-secret-key <SECRET>
# Credentials for the object store. Both are required when --store-backend
# is `obj`.
#
# --enable-tls
# Enables TLS with automatic ACME certificate issuance. Requires --domain and a
# public DNS record pointing at this host. Default: disabled.
#
# --domain <FQDN>
# Fully qualified domain name served by Mosaico, for example
# mosaico.example.com. Required when --enable-tls is used.
#
# --api-key
# Generates a master API key on first run, stores it under
# /var/lib/mosaico/secrets/master_api_key and prints it once at the end of the
# installation. Default: disabled with -y, asked for (and suggested) in an
# interactive session.
#
# --cleanup
# Enables the automated data retention routine that prunes old dataset frames.
# Default: disabled. See https://docs.mosaico.dev/config/cleanup
#
# --cleanup-retention <DURATION>
# How long dataset frames are kept before becoming eligible for deletion, for
# example 7d, 14d or 30d. Default: 30d.
#
# --cleanup-time-interval <DURATION>
# How often the cleanup routine runs. Default: 30d.
#
# --version <VERSION>
# Use the --version option to install a specific version, for example:
#
#   $ sudo sh install-mosaico.sh --version 0.8.0
#
# --uninstall
# Stops and removes the Mosaico services and the installed binaries, leaving
# stored data in place:
#
#   $ sudo sh install-mosaico.sh --uninstall
#   (or run `sudo mosaico-installer --uninstall` if already installed)
#
# --dry-run
# Prints every command this script would run as root, without running any
# of them or changing anything on the system.
#
# Environment variables
# ==============================================================================
#
# NON_INTERACTIVE
# Same as --yes above. Set to 1 to skip every prompt.
#
# MOSAICO_VERSION
# Same as --version above.
#
# ==============================================================================

SCRIPT_VERSION="1.0.0"

# --- Configuration ---

DATA_DIR="/var/lib/mosaico"
SECRETS_DIR="$DATA_DIR/secrets"
MOSAICOD_ENV_FILE="$SECRETS_DIR/mosaicod.env"
QUADLET_DIR="/etc/containers/systemd"
MOSAICO_VERSION="${MOSAICO_VERSION:-latest}"
POSTGRES_IMAGE="docker.io/library/postgres:18"
MOSAICOD_PORT="6726"
CLI_WRAPPER="/usr/local/bin/mosaicod"
INSTALLER_PATH="/usr/local/bin/mosaico-installer"
CLEANUP_DOCS_URL="https://docs.mosaico.dev/config/cleanup"
LOG_FILE="/tmp/mosaico-install-$(id -u).log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="$(mktemp -t mosaico-install.XXXXXX)"

UNINSTALL=0
DRY_RUN="${DRY_RUN:-}"

# --- Helpers ---

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

setup_colors() {
	# Enable colors only when the output is a real terminal.
	if [ -t 1 ]; then
		RESET=$(printf '\033[0m')
		BOLD=$(printf '\033[1m')
		DIM=$(printf '\033[2m')
		VIOLET=$(printf '\033[35m')
		GREEN=$(printf '\033[32m')
		YELLOW=$(printf '\033[33m')
		RED=$(printf '\033[31m')
	else
		RESET=""
		BOLD=""
		DIM=""
		VIOLET=""
		GREEN=""
		YELLOW=""
		RED=""
	fi
}

info()  { printf "${VIOLET}Info:${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}Warning:${RESET} %s\n" "$*" >&2; }
fatal() { printf "${RED}Error:${RESET} %s\n" "$*" >&2; exit 1; }

is_dry_run() {
	[ -n "$DRY_RUN" ]
}

lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Normalizes a human-written boolean into 1 or 0.
to_bool() {
	case "$(lower "$1")" in
		1|y|yes|true|on)     echo 1 ;;
		""|0|n|no|false|off) echo 0 ;;
		*) fatal "invalid boolean value '$1' (expected true or false)." ;;
	esac
}

bool_str() {
	[ "$1" -eq 1 ] && echo true || echo false
}

setup_colors

# --- Configuration state ---
#
# Every option keeps a companion *_SET marker so that interactive mode can tell
# "the user asked for this value" apart from "this is just the default", and
# prompt only for what is still unknown.

# Read from the environment rather than reset, so that NON_INTERACTIVE=1 in the
# environment is honoured even though --yes may also set it later.
NON_INTERACTIVE="$(to_bool "${NON_INTERACTIVE:-0}")"

STORE_BACKEND="fs";           STORE_BACKEND_SET=0
FS_DIR="$DATA_DIR/storage";   FS_DIR_SET=0
OBJ_ENDPOINT="";              OBJ_ENDPOINT_SET=0
OBJ_BUCKET="mosaico";         OBJ_BUCKET_SET=0
OBJ_ACCESS_KEY="";            OBJ_ACCESS_KEY_SET=0
OBJ_SECRET_KEY="";            OBJ_SECRET_KEY_SET=0
ENABLE_TLS=0;                 ENABLE_TLS_SET=0
DOMAIN="";                    DOMAIN_SET=0
API_KEY=0;                    API_KEY_SET=0
CLEANUP=0;                    CLEANUP_SET=0
CLEANUP_RETENTION="30d";      CLEANUP_RETENTION_SET=0
CLEANUP_INTERVAL="30d";       CLEANUP_INTERVAL_SET=0

usage() {
	cat <<-EOF
	Mosaico Installer (v$SCRIPT_VERSION)

	This script installs Mosaico (mosaicod + embedded PostgreSQL) using
	system-level Podman containers supervised by systemd (via Quadlet).

	Usage:
	  \$ curl -fsSL https://get.mosaico.dev | sh
	  \$ mosaico-installer [options]

	General options:
	  -h, --help                      Show this help message and exit
	  -y, --yes                       Skip all prompts (unattended install)
	      --uninstall                 Remove Mosaico, leaving stored data in place
	      --dry-run                   Print commands without running them
	      --version <tag>             Install a specific image tag (default: latest)

	Storage options:
	      --store-backend <fs|obj>    Local filesystem or object store (default: fs)
	      --fs-dir <path>             Local storage path when backend is fs
	                                  (default: $DATA_DIR/storage)
	      --obj-endpoint <url>        Object store endpoint URL
	      --obj-bucket <name>         Object store bucket name (default: mosaico)
	      --obj-access-key <key>      Object store access key / key ID
	      --obj-secret-key <key>      Object store secret key

	TLS options:
	      --enable-tls                Enable TLS/ACME certificates (default: off)
	      --domain <fqdn>             Public domain name, required with --enable-tls

	Security options:
	      --api-key                   Generate a master API key on first run

	Data retention options:
	      --cleanup                   Enable the automated cleanup routine
	      --cleanup-retention <dur>   How long frames are kept (default: 30d)
	      --cleanup-time-interval <dur>
	                                  How often cleanup runs (default: 30d)

	Paired options — with -y all of a group must be given, interactively the
	missing ones are asked for:
	      --store-backend obj  ->  --obj-endpoint, --obj-bucket,
	                               --obj-access-key, --obj-secret-key
	      --enable-tls         ->  --domain
	      --cleanup            ->  --cleanup-retention, --cleanup-time-interval

	Environment variables:
	  NON_INTERACTIVE   Same as --yes
	  MOSAICO_VERSION   Same as --version

	Documentation: https://docs.mosaico.dev
	EOF
}

# --- Argument parsing ---

require_value() {
	if [ $# -lt 2 ] || [ -z "$2" ]; then
		fatal "option $1 requires a value."
	fi
}

# Normalizes the backend spelling. `object` is accepted as a synonym of `obj`
# because it appears in the published examples.
normalize_backend() {
	case "$(lower "$1")" in
		fs|local|filesystem) echo fs ;;
		obj|object|s3)       echo obj ;;
		*)                   echo "$1" ;;
	esac
}

# Values may be passed either as `--flag value` or as `--flag=value`.
parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--uninstall) UNINSTALL=1 ;;
			--dry-run) DRY_RUN=1 ;;
			-y|--yes) NON_INTERACTIVE=1 ;;

			--version) require_value "$@"; MOSAICO_VERSION="${2#v}"; shift ;;
			--version=*) MOSAICO_VERSION="${1#*=}"; MOSAICO_VERSION="${MOSAICO_VERSION#v}" ;;

			# --storage-backend is an accepted alias for --store-backend.
			--store-backend|--storage-backend)
				require_value "$@"
				STORE_BACKEND="$(normalize_backend "$2")"; STORE_BACKEND_SET=1; shift ;;
			--store-backend=*|--storage-backend=*)
				STORE_BACKEND="$(normalize_backend "${1#*=}")"; STORE_BACKEND_SET=1 ;;

			--fs-dir) require_value "$@"; FS_DIR="$2"; FS_DIR_SET=1; shift ;;
			--fs-dir=*) FS_DIR="${1#*=}"; FS_DIR_SET=1 ;;

			--obj-endpoint) require_value "$@"; OBJ_ENDPOINT="$2"; OBJ_ENDPOINT_SET=1; shift ;;
			--obj-endpoint=*) OBJ_ENDPOINT="${1#*=}"; OBJ_ENDPOINT_SET=1 ;;

			--obj-bucket) require_value "$@"; OBJ_BUCKET="$2"; OBJ_BUCKET_SET=1; shift ;;
			--obj-bucket=*) OBJ_BUCKET="${1#*=}"; OBJ_BUCKET_SET=1 ;;

			--obj-access-key) require_value "$@"; OBJ_ACCESS_KEY="$2"; OBJ_ACCESS_KEY_SET=1; shift ;;
			--obj-access-key=*) OBJ_ACCESS_KEY="${1#*=}"; OBJ_ACCESS_KEY_SET=1 ;;

			--obj-secret-key) require_value "$@"; OBJ_SECRET_KEY="$2"; OBJ_SECRET_KEY_SET=1; shift ;;
			--obj-secret-key=*) OBJ_SECRET_KEY="${1#*=}"; OBJ_SECRET_KEY_SET=1 ;;

			--enable-tls|--tls) ENABLE_TLS=1; ENABLE_TLS_SET=1 ;;
			--enable-tls=*|--tls=*) ENABLE_TLS="$(to_bool "${1#*=}")"; ENABLE_TLS_SET=1 ;;

			--domain) require_value "$@"; DOMAIN="$2"; DOMAIN_SET=1; shift ;;
			--domain=*) DOMAIN="${1#*=}"; DOMAIN_SET=1 ;;

			# --generate-api-key is an accepted alias for --api-key.
			--api-key|--generate-api-key) API_KEY=1; API_KEY_SET=1 ;;
			--api-key=*|--generate-api-key=*) API_KEY="$(to_bool "${1#*=}")"; API_KEY_SET=1 ;;

			# --enable-cleanup is an accepted alias for --cleanup.
			--cleanup|--enable-cleanup) CLEANUP=1; CLEANUP_SET=1 ;;
			--cleanup=*|--enable-cleanup=*) CLEANUP="$(to_bool "${1#*=}")"; CLEANUP_SET=1 ;;

			--cleanup-retention) require_value "$@"; CLEANUP_RETENTION="$2"; CLEANUP_RETENTION_SET=1; shift ;;
			--cleanup-retention=*) CLEANUP_RETENTION="${1#*=}"; CLEANUP_RETENTION_SET=1 ;;

			--cleanup-time-interval|--cleanup-interval)
				require_value "$@"; CLEANUP_INTERVAL="$2"; CLEANUP_INTERVAL_SET=1; shift ;;
			--cleanup-time-interval=*|--cleanup-interval=*)
				CLEANUP_INTERVAL="${1#*=}"; CLEANUP_INTERVAL_SET=1 ;;

			-h|--help)
				usage
				exit 0
				;;
			*)
				printf "${RED}Error:${RESET} illegal option %s\n\n" "$1" >&2
				usage >&2
				exit 1
				;;
		esac
		shift
	done
}

# --- Option pairing ---
#
# Passing a dependent option is taken as intent to enable its feature, so that
# `--domain example.com` alone is enough to get TLS. When the toggle was given
# explicitly it always wins, and the ignored options are reported.

apply_pairings() {
	if [ "$STORE_BACKEND_SET" -eq 0 ]; then
		if [ "$OBJ_ENDPOINT_SET" -eq 1 ] || [ "$OBJ_BUCKET_SET" -eq 1 ] ||
		   [ "$OBJ_ACCESS_KEY_SET" -eq 1 ] || [ "$OBJ_SECRET_KEY_SET" -eq 1 ]; then
			STORE_BACKEND="obj"
			STORE_BACKEND_SET=1
			info "Object store options given — selecting --store-backend obj."
		fi
	elif [ "$STORE_BACKEND" = "fs" ]; then
		if [ "$OBJ_ENDPOINT_SET" -eq 1 ] || [ "$OBJ_ACCESS_KEY_SET" -eq 1 ] ||
		   [ "$OBJ_SECRET_KEY_SET" -eq 1 ]; then
			warn "--store-backend fs was requested; the --obj-* options are ignored."
		fi
	elif [ "$STORE_BACKEND" = "obj" ] && [ "$FS_DIR_SET" -eq 1 ]; then
		warn "--store-backend obj was requested; --fs-dir is ignored."
	fi

	if [ "$ENABLE_TLS_SET" -eq 0 ] && [ "$DOMAIN_SET" -eq 1 ]; then
		ENABLE_TLS=1
		ENABLE_TLS_SET=1
		info "--domain given — enabling TLS."
	elif [ "$ENABLE_TLS" -eq 0 ] && [ "$ENABLE_TLS_SET" -eq 1 ] && [ "$DOMAIN_SET" -eq 1 ]; then
		warn "TLS is disabled; --domain is ignored."
	fi

	if [ "$CLEANUP_SET" -eq 0 ]; then
		if [ "$CLEANUP_RETENTION_SET" -eq 1 ] || [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
			CLEANUP=1
			CLEANUP_SET=1
			info "Cleanup options given — enabling the cleanup routine."
		fi
	elif [ "$CLEANUP" -eq 0 ]; then
		if [ "$CLEANUP_RETENTION_SET" -eq 1 ] || [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
			warn "Cleanup is disabled; --cleanup-retention and --cleanup-time-interval are ignored."
		fi
	fi
}

# --- Validation ---

is_valid_backend() {
	case "$1" in
		fs|obj) return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_endpoint() {
	case "$1" in
		http://?*|https://?*) return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_domain() {
	echo "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$'
}

is_valid_duration() {
	echo "$1" | grep -Eq '^[1-9][0-9]*[hdwm]$'
}

is_valid_bucket() {
	echo "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{1,61}[A-Za-z0-9]$'
}

is_absolute_path() {
	case "$1" in
		/?*) return 0 ;;
		*) return 1 ;;
	esac
}

# Rejects a malformed value as soon as it is seen, so the user is not walked
# through a whole questionnaire before learning that a flag was wrong.
validate_flags() {
	is_valid_backend "$STORE_BACKEND" || \
		fatal "invalid --store-backend '$STORE_BACKEND' (expected 'fs' or 'obj')."

	if [ "$FS_DIR_SET" -eq 1 ] && ! is_absolute_path "$FS_DIR"; then
		fatal "--fs-dir must be an absolute path, got '$FS_DIR'."
	fi
	if [ "$OBJ_ENDPOINT_SET" -eq 1 ] && ! is_valid_endpoint "$OBJ_ENDPOINT"; then
		fatal "--obj-endpoint must start with http:// or https://, got '$OBJ_ENDPOINT'."
	fi
	if [ "$OBJ_BUCKET_SET" -eq 1 ] && ! is_valid_bucket "$OBJ_BUCKET"; then
		fatal "--obj-bucket '$OBJ_BUCKET' is not a valid bucket name."
	fi
	if [ "$DOMAIN_SET" -eq 1 ] && ! is_valid_domain "$DOMAIN"; then
		fatal "--domain '$DOMAIN' is not a valid fully qualified domain name."
	fi
	if [ "$CLEANUP_RETENTION_SET" -eq 1 ] && ! is_valid_duration "$CLEANUP_RETENTION"; then
		fatal "--cleanup-retention '$CLEANUP_RETENTION' is not a valid duration (e.g. 7d, 14d, 30d)."
	fi
	if [ "$CLEANUP_INTERVAL_SET" -eq 1 ] && ! is_valid_duration "$CLEANUP_INTERVAL"; then
		fatal "--cleanup-time-interval '$CLEANUP_INTERVAL' is not a valid duration (e.g. 7d, 14d, 30d)."
	fi
}

# Collected rather than reported one at a time, so a single run tells the user
# everything that is missing instead of one flag per attempt.
MISSING=""

add_missing() {
	MISSING="$MISSING  - $1
"
}

# Fail-fast check for unattended runs: nothing can be asked interactively, so
# every option of an enabled group must already have a value.
validate_non_interactive() {
	MISSING=""

	if [ "$STORE_BACKEND" = "obj" ]; then
		if [ -z "$OBJ_ENDPOINT" ] || [ -z "$OBJ_ACCESS_KEY" ] || [ -z "$OBJ_SECRET_KEY" ]; then
			add_missing "Storage backend 'obj' requires --obj-endpoint, --obj-access-key, and --obj-secret-key."
		fi
	elif [ -z "$FS_DIR" ]; then
		add_missing "Storage backend 'fs' requires --fs-dir."
	fi

	if [ "$ENABLE_TLS" -eq 1 ] && [ -z "$DOMAIN" ]; then
		add_missing "TLS is enabled, which requires --domain <fqdn>."
	fi

	if [ "$CLEANUP" -eq 1 ]; then
		if [ -z "$CLEANUP_RETENTION" ] || [ -z "$CLEANUP_INTERVAL" ]; then
			add_missing "Cleanup is enabled, which requires --cleanup-retention and --cleanup-time-interval."
		fi
	fi

	if [ -n "$MISSING" ]; then
		printf "${RED}Error:${RESET} Non-interactive mode (-y) active, but required parameters are missing:\n" >&2
		printf "%s" "$MISSING" >&2
		echo >&2
		echo "Please provide the missing flags or run without -y for interactive setup." >&2
		echo >&2
		exit 1
	fi
}

# --- Interactive prompts ---
#
# All prompts read from and write to /dev/tty rather than stdin/stdout so that
# `curl -fsSL https://get.mosaico.dev | sh` stays interactive: in that case
# stdin is the script itself, not the keyboard.

TTY="/dev/tty"

# The permission bits on /dev/tty say nothing about whether this process has a
# controlling terminal, so the device is actually opened. The probe runs in a
# subshell on purpose: a redirection failure on a special built-in such as `:`
# is fatal in dash and would kill the installer with a bare exit code 2, which
# is precisely the headless case this function exists to detect.
has_tty() {
	[ -r "$TTY" ] && [ -w "$TTY" ] && ( exec < "$TTY" ) 2>/dev/null
}

tty_print() {
	printf "%s\n" "$*" > "$TTY"
}

# ask_plain <rendered-prompt> [default] -> answer on stdout
#
# Writes the prompt exactly as given, with no "?" marker and no default
# decoration. Used where the prompt already spells out its own choices.
ask_plain() {
	printf '%s' "$1" > "$TTY"
	IFS= read -r _ans < "$TTY" || _ans=""
	[ -n "$_ans" ] || _ans="${2:-}"
	printf '%s' "$_ans"
}

# ask <question> [default] -> answer on stdout
ask() {
	_q="$1"
	_def="${2:-}"
	if [ -n "$_def" ]; then
		_rendered="$(printf "${BOLD}?${RESET} %s [${VIOLET}%s${RESET}]: " "$_q" "$_def")"
	else
		_rendered="$(printf "${BOLD}?${RESET} %s: " "$_q")"
	fi
	ask_plain "$_rendered" "$_def"
}

# ask_required <question> <validator|""> <error-hint> [default] -> answer on stdout
ask_required() {
	_q="$1"
	_validator="$2"
	_hint="$3"
	_def="${4:-}"
	while :; do
		_val="$(ask "$_q" "$_def")"
		if [ -z "$_val" ]; then
			tty_print "  ${RED}This value is required.${RESET}"
			continue
		fi
		if [ -z "$_validator" ] || "$_validator" "$_val"; then
			printf '%s' "$_val"
			return 0
		fi
		tty_print "  ${RED}$_hint${RESET}"
	done
}

# ask_secret <question> -> answer on stdout, echoed back to the terminal as
# asterisks so the value never appears on screen or in the scrollback.
ask_secret() {
	_q="$1"
	while :; do
		printf "${BOLD}?${RESET} %s: " "$_q" > "$TTY"
		_stty_saved=""
		if _stty_saved="$(stty -g < "$TTY" 2>/dev/null)"; then
			stty -echo < "$TTY" 2>/dev/null || _stty_saved=""
		fi
		IFS= read -r _secret < "$TTY" || _secret=""
		[ -n "$_stty_saved" ] && stty "$_stty_saved" < "$TTY" 2>/dev/null || true
		tty_print "$(mask_of "$_secret")"
		if [ -n "$_secret" ]; then
			printf '%s' "$_secret"
			return 0
		fi
		tty_print "  ${RED}This value is required.${RESET}"
	done
}

mask_of() {
	_m=""
	_i=0
	while [ "$_i" -lt "${#1}" ]; do
		_m="$_m*"
		_i=$((_i + 1))
	done
	printf '%s' "$_m"
}

# ask_yn_raw <rendered-prompt> <y|n default> -> exit status 0 for yes, 1 for no
#
# The [Y/n] hint is appended to the caller's prompt, which lets a question span
# several lines and still take its answer on the last one.
ask_yn_raw() {
	_q="$1"
	_def="$2"
	if [ "$_def" = "y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
	while :; do
		printf '%s %s: ' "$_q" "$_hint" > "$TTY"
		IFS= read -r _ans < "$TTY" || _ans=""
		[ -n "$_ans" ] || _ans="$_def"
		case "$(lower "$_ans")" in
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) tty_print "  ${RED}Please answer y or n.${RESET}" ;;
		esac
	done
}

# ask_yn <question> <y|n default> -> exit status 0 for yes, 1 for no
ask_yn() {
	ask_yn_raw "$(printf "${BOLD}?${RESET} %s" "$1")" "$2"
}

section() {
	echo
	echo "${BOLD}$1${RESET}"
	echo "${DIM}--------------------------------------------------------------------------------${RESET}"
}

configure_interactive() {
	info "Interactive configuration started. Press Enter to accept [default values]."

	# --- [1/4] Storage ---
	section "[1/4] Storage Configuration"
	if [ "$STORE_BACKEND_SET" -eq 0 ]; then
		tty_print "${BOLD}?${RESET} Choose storage backend:"
		tty_print "  ${VIOLET}>${RESET} [1] Local Filesystem (fs)"
		tty_print "    [2] Generic Object Storage (obj)"
		while :; do
			_choice="$(ask_plain "  Select [1-2] (default: 1): " "1")"
			case "$(lower "$_choice")" in
				1|fs)      STORE_BACKEND="fs"; break ;;
				2|obj|object) STORE_BACKEND="obj"; break ;;
				*) tty_print "  ${RED}Please enter 1 or 2.${RESET}" ;;
			esac
		done
		echo
	else
		info "Storage backend '$STORE_BACKEND' taken from the command line."
	fi

	if [ "$STORE_BACKEND" = "fs" ]; then
		[ "$FS_DIR_SET" -eq 1 ] || FS_DIR="$(ask_required \
			"Local storage directory" is_absolute_path \
			"Please enter an absolute path (starting with /)." "$FS_DIR")"
	else
		[ "$OBJ_ENDPOINT_SET" -eq 1 ] || OBJ_ENDPOINT="$(ask_required \
			"Object Storage Endpoint (e.g., https://s3.amazonaws.com or http://minio:9000)" \
			is_valid_endpoint "The endpoint must start with http:// or https://.")"
		[ "$OBJ_BUCKET_SET" -eq 1 ] || OBJ_BUCKET="$(ask_required \
			"Bucket name" is_valid_bucket "That is not a valid bucket name." "$OBJ_BUCKET")"
		[ "$OBJ_ACCESS_KEY_SET" -eq 1 ] || OBJ_ACCESS_KEY="$(ask_required \
			"Access Key / Key ID" "" "")"
		[ "$OBJ_SECRET_KEY_SET" -eq 1 ] || OBJ_SECRET_KEY="$(ask_secret "Secret Key")"
	fi

	# --- [2/4] TLS & domain ---
	section "[2/4] TLS & Domain Setup"
	if [ "$ENABLE_TLS_SET" -eq 0 ]; then
		if ask_yn "Do you want to configure TLS/HTTPS? (requires a public domain pointing to this server)" "n"; then
			ENABLE_TLS=1
		else
			ENABLE_TLS=0
		fi
	fi
	if [ "$ENABLE_TLS" -eq 1 ] && [ "$DOMAIN_SET" -eq 0 ]; then
		DOMAIN="$(ask_required \
			"Enter your fully qualified domain name (e.g., mosaico.example.com)" \
			is_valid_domain "That does not look like a valid domain name.")"
	fi

	# --- [3/4] Security ---
	#
	# Note the asymmetry with -y: unattended runs default to *not* creating a
	# key (--api-key opts in), while here the suggested answer is yes, because
	# an evaluator following the prompts needs a key to talk to the daemon.
	section "[3/4] Security & API Keys"
	if [ "$API_KEY_SET" -eq 0 ]; then
		if ask_yn "Do you want to generate an initial Master API Key for clients?" "y"; then
			API_KEY=1
		else
			API_KEY=0
		fi
	fi

	# --- [4/4] Retention ---
	section "[4/4] Data Retention & Cleanup"
	if [ "$CLEANUP_SET" -eq 0 ]; then
		if ask_yn "Enable automated cleanup routine for old dataset frames?" "n"; then
			CLEANUP=1
		else
			CLEANUP=0
		fi
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		# Only offer the shortcut when both values are still at their defaults;
		# if one arrived from the command line, just ask for the other.
		if [ "$CLEANUP_RETENTION_SET" -eq 0 ] && [ "$CLEANUP_INTERVAL_SET" -eq 0 ]; then
			tty_print "${BOLD}?${RESET} Use default cleanup parameters (retention: $CLEANUP_RETENTION, interval: $CLEANUP_INTERVAL)? "
			if ask_yn_raw "  ${DIM}(See docs for details: $CLEANUP_DOCS_URL)${RESET}" "y"; then
				CLEANUP_RETENTION_SET=1
				CLEANUP_INTERVAL_SET=1
			fi
		fi
		[ "$CLEANUP_RETENTION_SET" -eq 1 ] || CLEANUP_RETENTION="$(ask_required \
			"Custom retention policy (e.g., 7d, 14d, 90d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 14d)." "$CLEANUP_RETENTION")"
		[ "$CLEANUP_INTERVAL_SET" -eq 1 ] || CLEANUP_INTERVAL="$(ask_required \
			"How often should the cleanup run (e.g., 1d, 7d, 30d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 7d)." "$CLEANUP_INTERVAL")"
	fi
}

print_summary() {
	echo
	echo "${DIM}--------------------------------------------------------------------------------${RESET}"
	echo "${BOLD}Configuration Summary:${RESET}"
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "  - Storage Backend : Local Filesystem ($FS_DIR)"
	else
		echo "  - Storage Backend : Generic Object Storage ($OBJ_ENDPOINT / $OBJ_BUCKET)"
	fi
	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo "  - TLS / Domain    : Enabled ($DOMAIN)"
	else
		echo "  - TLS / Domain    : Disabled (plain HTTP)"
	fi
	if [ "$API_KEY" -eq 1 ]; then
		echo "  - Master API Key  : Yes (Will be generated)"
	else
		echo "  - Master API Key  : No"
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		echo "  - Cleanup Routine : Enabled (Retention: $CLEANUP_RETENTION, Interval: $CLEANUP_INTERVAL)"
	else
		echo "  - Cleanup Routine : Disabled"
	fi
	echo "  - Image Version   : $MOSAICO_VERSION"
	echo
}

confirm_summary() {
	if ! ask_yn "Proceed with installation using these settings?" "y"; then
		echo
		info "Installation cancelled — nothing was changed."
		exit 0
	fi
	echo
}

# Non-fatal sanity check: warn when the domain does not resolve to this host,
# because ACME issuance will fail later and the cause is easy to miss.
check_domain_dns() {
	[ "$ENABLE_TLS" -eq 1 ] || return 0

	resolved=""
	if command_exists getent; then
		resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
	elif command_exists host; then
		resolved="$(host -t A "$DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}' || true)"
	fi

	if [ -z "$resolved" ]; then
		warn "could not resolve '$DOMAIN' — ACME certificate issuance will fail until DNS is configured."
		return 0
	fi

	local_ips="$(hostname -I 2>/dev/null || true)"
	public_ip=""
	command_exists curl && public_ip="$(curl -s --max-time 2 ifconfig.me 2>/dev/null || true)"
	for ip in $local_ips $public_ip; do
		[ "$ip" = "$resolved" ] && return 0
	done
	warn "'$DOMAIN' resolves to $resolved, which does not match this host's addresses."
}

# --- Privilege escalation ---

user="$(id -un 2>/dev/null || true)"
sh_c="eval"

setup_sh_c() {
	if [ "$user" != "root" ]; then
		if command_exists sudo; then
			sh_c="sudo -E sh -c"
		elif command_exists su; then
			sh_c="su -c"
		else
			fatal "this installer needs the ability to run commands as root, but neither sudo nor su was found."
		fi
	fi
}

as_root() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} $*"
		return 0
	fi
	printf '+ %s\n' "$*" >> "$LOG_FILE"
	if ! $sh_c "$*" >> "$LOG_FILE" 2>&1; then
		echo
		echo "${RED}Error: command failed:${RESET} $*" >&2
		echo "See $LOG_FILE for the full output." >&2
		exit 1
	fi
}

as_root_ignore_errors() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} $*"
		return 0
	fi
	printf '+ %s\n' "$*" >> "$LOG_FILE"
	$sh_c "$*" >> "$LOG_FILE" 2>&1 || true
}

as_root_capture() {
	$sh_c "$*" 2>> "$LOG_FILE"
}

get_package_manager() {
	if command_exists apt-get; then
		echo apt
	elif command_exists dnf; then
		echo dnf
	else
		echo none
	fi
}

# --- Step output ---
#
# step() leaves the line open so that step_ok() can complete it in place,
# producing the "+ Doing something... OK" shape.

step() {
	printf "${VIOLET}+${RESET} %s" "$*"
}

step_ok() {
	printf " ${GREEN}%s${RESET}\n" "${1:-OK}"
}

step_line() {
	printf "${VIOLET}+${RESET} %s\n" "$*"
}

# --- Install Steps ---

check_systemd() {
	step "Checking systemd..."
	command_exists systemctl || { echo; fatal "systemd not found. This installer requires systemd."; }
	step_ok
}

check_podman() {
	step "Checking podman..."
	if command_exists podman; then
		step_ok "OK (v$(podman --version | awk '{print $NF}'))"
		return
	fi
	pm="$(get_package_manager)"
	case "$pm" in
		apt)
			step_ok "missing, installing via apt"
			as_root "apt-get update -qq"
			as_root "env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq podman < /dev/null"
			;;
		dnf)
			step_ok "missing, installing via dnf"
			as_root "dnf install -y podman"
			;;
		*)
			echo
			fatal "unsupported distribution: neither apt-get nor dnf found."
			;;
	esac
}

check_quadlet_support() {
	if ! command_exists podman; then
		is_dry_run && return
		fatal "podman not found."
	fi
	version="$(podman --version | awk '{print $NF}')"
	major="$(echo "$version" | cut -d. -f1)"
	minor="$(echo "$version" | cut -d. -f2)"
	if [ "$major" -lt 4 ] 2>/dev/null || { [ "$major" -eq 4 ] 2>/dev/null && [ "$minor" -lt 4 ] 2>/dev/null; }; then
		fatal "Podman $version does not support Quadlet (needs >= 4.4)."
	fi
}

setup_directories() {
	as_root "install -d -m 755 $QUADLET_DIR"
	as_root "install -d -m 700 $SECRETS_DIR"
	if [ "$STORE_BACKEND" = "fs" ]; then
		step_line "Preparing local storage directory $FS_DIR"
		as_root "install -d -m 750 '$FS_DIR'"
	fi
}

# Reads a secret from disk when it already exists, otherwise generates it and
# persists it with 0600 permissions. Secrets never reach the terminal or the log.
read_or_create_secret() {
	_file="$1"
	_generator="$2"

	if as_root_capture "test -f '$_file' && echo yes" | grep -q '^yes$'; then
		as_root_capture "cat '$_file'"
		return
	fi

	_value="$($_generator)"
	as_root "umask 077 && printf '%s' '$_value' > '$_file'"
	printf '%s' "$_value"
}

gen_password() {
	tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

gen_api_key() {
	printf 'msk_live_%s' "$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"
}

MASTER_API_KEY=""

write_secrets() {
	if is_dry_run; then
		step_line "Writing configuration secrets to $MOSAICOD_ENV_FILE"
		echo "  ${DIM}(dry-run)${RESET} generate PostgreSQL password and mosaicod.env"
		[ "$API_KEY" -eq 1 ] && \
			echo "  ${DIM}(dry-run)${RESET} generate master API key in $SECRETS_DIR/master_api_key"
		return 0
	fi

	password="$(read_or_create_secret "$SECRETS_DIR/postgres_password" gen_password)"

	if [ "$API_KEY" -eq 1 ]; then
		MASTER_API_KEY="$(read_or_create_secret "$SECRETS_DIR/master_api_key" gen_api_key)"
	fi

	step_line "Writing configuration secrets to $MOSAICOD_ENV_FILE"

	as_root "umask 077 && cat > $SECRETS_DIR/postgres.env" <<-EOF
	POSTGRES_USER=mosaico
	POSTGRES_DB=mosaico
	POSTGRES_PASSWORD=$password
	EOF

	# Built up incrementally so each optional feature contributes only the keys
	# it actually needs. This file is also what the CLI wrapper feeds back into
	# `podman exec --env-file`, so it must stay a plain KEY=VALUE list.
	env_body="MOSAICOD_DB_URL=postgresql://mosaico:$password@mosaico-postgres:5432/mosaico"

	if [ "$STORE_BACKEND" = "fs" ]; then
		env_body="$env_body
MOSAICOD_STORE_BACKEND=fs
MOSAICOD_STORE_ENDPOINT=file:///data
MOSAICOD_STORE_BUCKET=mosaico"
	else
		env_body="$env_body
MOSAICOD_STORE_BACKEND=obj
MOSAICOD_STORE_ENDPOINT=$OBJ_ENDPOINT
MOSAICOD_STORE_BUCKET=$OBJ_BUCKET
MOSAICOD_STORE_ACCESS_KEY=$OBJ_ACCESS_KEY
MOSAICOD_STORE_SECRET_KEY=$OBJ_SECRET_KEY"
	fi

	env_body="$env_body
MOSAICOD_TLS_ENABLED=$(bool_str "$ENABLE_TLS")"
	if [ "$ENABLE_TLS" -eq 1 ]; then
		env_body="$env_body
MOSAICOD_TLS_DOMAIN=$DOMAIN
MOSAICOD_TLS_ACME_CACHE=/certs"
	fi

	if [ -n "$MASTER_API_KEY" ]; then
		env_body="$env_body
MOSAICOD_MASTER_API_KEY=$MASTER_API_KEY"
	fi

	env_body="$env_body
MOSAICOD_CLEANUP_ENABLED=$(bool_str "$CLEANUP")"
	if [ "$CLEANUP" -eq 1 ]; then
		env_body="$env_body
MOSAICOD_CLEANUP_RETENTION=$CLEANUP_RETENTION
MOSAICOD_CLEANUP_INTERVAL=$CLEANUP_INTERVAL"
	fi

	as_root "umask 077 && cat > $MOSAICOD_ENV_FILE" <<-EOF
	$env_body
	EOF
}

# Non-secret record of the choices made, so that a later --uninstall (or a
# human) can tell how this host was configured.
write_install_conf() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} record configuration in $DATA_DIR/install.conf"
		return 0
	fi
	as_root "umask 022 && cat > $DATA_DIR/install.conf" <<-EOF
	# Generated by mosaico-installer v$SCRIPT_VERSION — do not edit by hand.
	MOSAICO_VERSION=$MOSAICO_VERSION
	STORE_BACKEND=$STORE_BACKEND
	FS_DIR=$FS_DIR
	OBJ_ENDPOINT=$OBJ_ENDPOINT
	OBJ_BUCKET=$OBJ_BUCKET
	ENABLE_TLS=$(bool_str "$ENABLE_TLS")
	DOMAIN=$DOMAIN
	API_KEY=$(bool_str "$API_KEY")
	CLEANUP=$(bool_str "$CLEANUP")
	CLEANUP_RETENTION=$CLEANUP_RETENTION
	CLEANUP_INTERVAL=$CLEANUP_INTERVAL
	EOF
}

write_quadlets() {
	step_line "Generating systemd Quadlet files in $QUADLET_DIR/"

	as_root "cat > $QUADLET_DIR/mosaico.network" <<-EOF
	[Unit]
	Description=Mosaico internal container network

	[Network]
	EOF

	as_root "cat > $QUADLET_DIR/mosaico-postgres.container" <<-EOF
	[Unit]
	Description=Mosaico embedded PostgreSQL

	[Container]
	Image=$POSTGRES_IMAGE
	ContainerName=mosaico-postgres
	Network=mosaico.network
	Volume=mosaico-postgres-data:/var/lib/postgresql:Z
	EnvironmentFile=$SECRETS_DIR/postgres.env

	[Service]
	Restart=on-failure
	TimeoutStartSec=60

	[Install]
	WantedBy=multi-user.target
	EOF

	# Storage and TLS each contribute lines to [Container]. The unit is assembled
	# in a variable so that a disabled feature adds nothing at all, rather than
	# leaving a blank line behind.
	container="[Container]
Exec=run
Image=ghcr.io/mosaico-labs/mosaicod:$MOSAICO_VERSION
ContainerName=mosaicod
Network=mosaico.network
EnvironmentFile=$MOSAICOD_ENV_FILE
PublishPort=$MOSAICOD_PORT:$MOSAICOD_PORT"

	if [ "$STORE_BACKEND" = "fs" ]; then
		container="$container
Volume=$FS_DIR:/data:Z"
	fi

	if [ "$ENABLE_TLS" -eq 1 ]; then
		# Port 80 is needed for the ACME HTTP-01 challenge; /certs persists the
		# issued certificates across restarts.
		container="$container
Volume=mosaico-certs:/certs:Z
PublishPort=80:80"
	fi

	as_root "cat > $QUADLET_DIR/mosaicod.container" <<-EOF
	[Unit]
	Description=Mosaico Daemon
	After=mosaico-postgres.service
	Requires=mosaico-postgres.service

	$container

	[Service]
	Restart=on-failure

	[Install]
	WantedBy=multi-user.target
	EOF
}

# Installs the host-side CLI shim, which makes `mosaicod ...` on the host behave
# like a native binary by forwarding into the container. It deliberately does no
# container health check, so CLI commands can be issued whether or not the
# daemon is up, and it re-injects the installer's env file so the CLI sees the
# same configuration as the daemon.
install_cli_wrapper() {
	step_line "Creating CLI wrapper in $CLI_WRAPPER"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} write $CLI_WRAPPER and chmod +x"
		return 0
	fi

	# Quoted heredoc: the body is written verbatim, its variables are resolved
	# when the wrapper runs, not now.
	as_root "cat > $CLI_WRAPPER" <<-'WRAPPER_EOF'
	#!/bin/sh
	set -e

	ENV_FILE="/var/lib/mosaico/secrets/mosaicod.env"

	# 1. TTY handling based on execution environment
	TTY_ARGS=""
	if [ -t 0 ] && [ -t 1 ]; then
	    TTY_ARGS="-it"
	fi

	# 2. Load environment variables dynamically from the installer's env file
	ENV_ARGS=""
	if [ -f "$ENV_FILE" ]; then
	    ENV_ARGS="--env-file=$ENV_FILE"
	fi

	# 3. Forward execution to podman exec with loaded environment
	exec podman exec $TTY_ARGS $ENV_ARGS mosaicod mosaicod "$@"
	WRAPPER_EOF
	as_root "chmod +x $CLI_WRAPPER"
}

start_service() {
	name="$1"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} systemctl start $name"
		return 0
	fi

	step "Starting $name..."
	if $sh_c "systemctl start $name" >> "$LOG_FILE" 2>&1; then
		step_ok "Done"
		return 0
	fi

	echo
	printf "${RED}Error:${RESET} %s failed to start. Diagnostics:\n" "$name" >&2
	echo
	echo "${YELLOW}--- System Logs (journalctl) ---${RESET}" >&2
	$sh_c "journalctl -u $name -n 20 --no-pager" 2>&1 | tee -a "$LOG_FILE" >&2
	echo
	exit 1
}

start_postgres() {
	as_root "systemctl daemon-reload"
	start_service "mosaico-postgres.service"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} wait for PostgreSQL to accept connections"
		return 0
	fi

	step "Waiting for PostgreSQL to accept connections..."
	tries=0
	while [ "$tries" -lt 30 ]; do
		if $sh_c "podman exec mosaico-postgres pg_isready -U mosaico" >> "$LOG_FILE" 2>&1; then
			step_ok "Ready"
			return 0
		fi
		tries=$((tries + 1))
		sleep 2
	done

	echo
	printf "${RED}Error:${RESET} PostgreSQL did not become ready in time. Container logs:\n" >&2
	$sh_c "podman logs --tail 40 mosaico-postgres" 2>&1 | tee -a "$LOG_FILE" >&2
	exit 1
}

start_mosaicod() {
	start_service "mosaicod.service"
	is_dry_run || sleep 3
}

install_installer() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} copy installer to $INSTALLER_PATH"
		return 0
	fi

	step_line "Installing management CLI in $INSTALLER_PATH"
	if [ -f "$0" ] && [ -s "$0" ]; then
		as_root "cp \"$0\" $INSTALLER_PATH"
	else
		# Reached when the script was piped in (curl | sh) and so has no
		# readable path on disk.
		as_root "curl -fsSL https://get.mosaico.dev -o $INSTALLER_PATH"
	fi
	as_root "chmod +x $INSTALLER_PATH"
}

print_logo() {
	echo
	echo "${VIOLET}${BOLD}███╗   ███╗ ██████╗ ███████╗ █████╗ ██╗ ██████╗ ██████╗${RESET}"
	echo "${VIOLET}${BOLD}████╗ ████║██╔═══██╗██╔════╝██╔══██╗██║██╔════╝██╔═══██╗${RESET}"
	echo "${VIOLET}${BOLD}██╔████╔██║██║   ██║███████╗███████║██║██║     ██║   ██║${RESET}"
	echo "${VIOLET}${BOLD}██║╚██╔╝██║██║   ██║╚════██║██╔══██║██║██║     ██║   ██║${RESET}"
	echo "${VIOLET}${BOLD}██║ ╚═╝ ██║╚██████╔╝███████║██║  ██║██║╚██████╗╚██████╔╝${RESET}"
	echo "${VIOLET}${BOLD}╚═╝     ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝ ╚═════╝ ╚═════╝${RESET}"
	echo
	echo "     ${BOLD}The Data Platform for Robotics and Physical AI${RESET}"
	if [ -n "$1" ]; then
		echo "                  ${BOLD}$1${RESET}"
	fi
	echo
}

# --- Uninstall ---

do_uninstall() {
	print_logo
	echo "${YELLOW}Executing Mosaico uninstall script...${RESET}"
	echo

	# Recover the storage path recorded at install time so the wipe hint below
	# names the directory actually in use rather than the default.
	if ! is_dry_run; then
		recorded_fs_dir="$(as_root_capture "grep -s '^FS_DIR=' $DATA_DIR/install.conf | cut -d= -f2-" || true)"
		[ -n "$recorded_fs_dir" ] && FS_DIR="$recorded_fs_dir"
	fi

	as_root_ignore_errors "systemctl stop mosaicod.service"
	as_root_ignore_errors "systemctl stop mosaico-postgres.service"
	as_root_ignore_errors "podman rm -f mosaicod"
	as_root_ignore_errors "podman rm -f mosaico-postgres"
	as_root_ignore_errors "rm -f $QUADLET_DIR/mosaico-postgres.container $QUADLET_DIR/mosaicod.container $QUADLET_DIR/mosaico.network"
	as_root_ignore_errors "systemctl daemon-reload"
	as_root_ignore_errors "rm -f $CLI_WRAPPER"
	as_root_ignore_errors "rm -f $INSTALLER_PATH"

	echo
	echo "${GREEN}${BOLD}  Mosaico services have been successfully removed.${RESET}"
	echo
	echo "  Removed binaries:"
	echo "    $CLI_WRAPPER"
	echo "    $INSTALLER_PATH"
	echo
	echo "  To completely wipe all remaining data and secrets from this system,"
	echo "  execute the following commands:"
	echo
	echo "${BOLD}    sudo rm -rf $SECRETS_DIR $DATA_DIR/install.conf${RESET}"
	echo "${BOLD}    sudo rm -rf $FS_DIR${RESET}"
	echo "${BOLD}    sudo podman volume rm mosaico-postgres-data mosaico-certs${RESET}"
	echo
}

# --- Final report ---

print_success() {
	scheme="http"
	[ "$ENABLE_TLS" -eq 1 ] && scheme="https"

	echo
	echo "${GREEN}${BOLD}  Mosaico is up and running!${RESET}"
	echo
	echo "  ${VIOLET}➜${RESET}  Local:    $scheme://127.0.0.1:$MOSAICOD_PORT"

	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo "  ${VIOLET}➜${RESET}  Domain:   $scheme://$DOMAIN:$MOSAICOD_PORT"
	else
		if command_exists hostname; then
			for ip in $(hostname -I 2>/dev/null); do
				echo "  ${VIOLET}➜${RESET}  Network:  $scheme://$ip:$MOSAICOD_PORT"
			done
		fi
		if command_exists curl; then
			public_ip=$(curl -s --max-time 2 ifconfig.me 2>/dev/null || true)
			if [ -n "$public_ip" ]; then
				echo "  ${VIOLET}➜${RESET}  Public:   $scheme://$public_ip:$MOSAICOD_PORT"
			fi
		fi
	fi

	echo
	echo "  Security credentials saved to $SECRETS_DIR/"
	if [ -n "$MASTER_API_KEY" ]; then
		echo "  ${VIOLET}➜${RESET}  Master API Key:  $(printf '%s' "$MASTER_API_KEY" | cut -c1-29)..."
		echo "     ${DIM}Full key: $SECRETS_DIR/master_api_key${RESET}"
	fi

	if [ "$CLEANUP" -eq 1 ]; then
		echo
		echo "  Cleanup routine enabled — retention $CLEANUP_RETENTION, running every $CLEANUP_INTERVAL."
		echo "  ${DIM}$CLEANUP_DOCS_URL${RESET}"
	fi

	echo
	echo "  Management CLI:"
	echo "    ${BOLD}mosaicod status${RESET}"
	echo "    ${BOLD}mosaicod logs -f${RESET}"
	echo
	echo "  To uninstall Mosaico from this system:"
	echo "    ${BOLD}mosaico-installer --uninstall${RESET}"
	echo
}

# --- Main execution ---

do_install() {
	if [ "$NON_INTERACTIVE" -eq 1 ]; then
		print_logo "Unattended Setup"
		validate_non_interactive
		print_summary
	else
		if ! has_tty; then
			fatal "no terminal available for interactive setup. Re-run with -y and the required flags (see --help)."
		fi
		print_logo "Interactive Setup"
		configure_interactive
		print_summary
		confirm_summary
	fi

	is_dry_run && echo "${YELLOW}# --dry-run: no changes will be made${RESET}"

	if [ "$user" != "root" ]; then
		info "Not running as root — this script will use '$sh_c' for the steps that need it."
		echo
	fi

	check_domain_dns
	check_systemd
	check_podman
	check_quadlet_support
	setup_directories
	write_secrets
	write_install_conf
	write_quadlets
	install_cli_wrapper
	start_postgres
	start_mosaicod
	install_installer

	echo
	if is_dry_run; then
		echo "${YELLOW}Dry run complete — nothing was installed or changed.${RESET}"
	else
		print_success
	fi
}

parse_args "$@"
apply_pairings
validate_flags
setup_sh_c

if [ "$UNINSTALL" -eq 1 ]; then
	do_uninstall
else
	do_install
fi
