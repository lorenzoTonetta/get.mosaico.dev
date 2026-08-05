#!/bin/sh
set -e
# Mosaico installation script.
#
# This script is intended as a convenient way to get Mosaico running on a
# single machine for evaluation or development. It installs mosaicod (the
# Mosaico daemon) using a system-level Podman container supervised by systemd
# (via Quadlet), together with an embedded PostgreSQL instance in a second
# container — or, if you already run PostgreSQL, pointed at that instead.
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
#   subsequent runs, it is never printed to the terminal or the log. Only for the
#   embedded database: the credentials of an existing instance are asked for.
# - Installs a host CLI wrapper at /usr/local/bin/mosaicod that forwards
#   commands into the container.
# - Copies itself to /usr/local/bin/mosaico-installer for future management.
# - Installs a man page describing the installed commands, the file layout and
#   the uninstall procedure — see `man mosaico`. The page is a file of its own,
#   mosaico.7, taken from the installer's own directory when the script was run
#   from a checkout and downloaded from the repository otherwise. It is the only
#   step that needs the network beyond the container images, and the only one
#   that is skipped with a warning rather than failing the installation.
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
#   --postgres external  requires  --pg-host, --pg-password
#   --store-backend obj  requires  --obj-endpoint, --obj-bucket,
#                                  --obj-access-key, --obj-secret-key
#   --store-backend fs   requires  --fs-dir
#   --enable-tls         requires  --domain
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
# --postgres <embedded|external>
# Where mosaicod keeps its metadata. `embedded` runs PostgreSQL in a container of
# its own, supervised by systemd, with a password this script generates: nothing
# has to exist beforehand. `external` uses a PostgreSQL instance you already run
# — on this host, on another machine or hosted — and creates no database
# container at all. Default: embedded.
#
# `external` is not a migration: it points a fresh installation at an empty
# database. Switching an existing installation over stops and removes the
# embedded container and leaves its volume untouched, it does not move any data.
#
# --pg-host <HOST>
# Host name or address of the existing PostgreSQL instance. Required when
# --postgres is `external`. An IPv6 literal has to be given in brackets, as in
# [2001:db8::1].
#
# A loopback address is rewritten to `host.containers.internal`, because
# 127.0.0.1 inside the container is the container itself. PostgreSQL then has to
# listen on something other than the host loopback and accept the container
# network in pg_hba.conf — passing the host's LAN address avoids the indirection.
#
# --pg-port <PORT>
# Port of the existing instance. Default: 5432.
#
# --pg-db <NAME>
# --pg-user <NAME>
# Database and role mosaicod connects as. Both have to exist already, and the
# role needs enough privilege to create mosaicod's schema on first start.
# Default: mosaico for both.
#
# --pg-password <PASSWORD>
# Password of that role. Required when --postgres is `external`; asked for
# without echo in an interactive session, so that it stays out of the shell
# history. It is written only to the root-only environment file.
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
# Serves gRPC over TLS. mosaicod does not issue certificates itself, so the
# installer obtains one from Let's Encrypt with certbot and keeps it renewed,
# unless you pass a certificate of your own with --tls-cert / --tls-key.
# --domain is required either way. Default: disabled.
#
# Port 443 has to be open for the TLS challenge.
#
# Renewal is left to the certbot timer the distribution ships. The installer adds
# a deploy hook in /etc/letsencrypt/renewal-hooks/deploy/ that copies each
# renewed certificate into /var/lib/mosaico/secrets/tls/ and restarts
# mosaicod.service, because the daemon reads the material only at startup.
#
# --tls-cert <PATH>
# --tls-key <PATH>
# Host paths of the PEM-encoded certificate chain and of its private key, to use
# material you already hold (an internal CA, a corporate PKI) instead of Let's
# Encrypt. Give both or neither. They are copied into
# /var/lib/mosaico/secrets/tls/ and mounted read-only into the container; no
# renewal hook is installed for them, so to install a renewed certificate replace
# those two files and run `systemctl restart mosaicod.service`.
#
# --domain <FQDN>
# Fully qualified domain name served by Mosaico, for example
# mosaico.example.com. Required when --enable-tls is used: it is the name the
# certificate is issued for, so it is the name clients have to connect to for
# certificate validation to succeed. The installer also warns when it does not
# resolve to this host.
#
# --api-key
# Creates a master API key with `manage` permissions on first run, stores it
# under /var/lib/mosaico/secrets/master_api_key and prints it once at the end of
# the installation. It also starts the daemon with API key enforcement, so every
# client then needs a key. Default: disabled with -y, asked for (and suggested)
# in an interactive session.
#
# --no-cleanup
# Turns off the automated data retention routine that prunes obsolete store
# files. The routine runs by default, so this is the only switch it has: there is
# nothing for an --enable flag to turn on. Declining it writes
# MOSAICOD_CLEANUP_TIME_INTERVAL=0 explicitly, because a missing interval is what
# makes mosaicod fall back to running the routine on its own schedule.
# See https://docs.mosaico.dev/config/cleanup
#
# --sdk
# Installs the mosaicolabs Python SDK into a virtual environment at /opt/mosaico,
# created with the host's python3. Nothing is installed into the system
# interpreter: recent Debian and Fedora refuse that under PEP 668, and where they
# do not it leaves pip and the distribution's package manager owning the same
# files. The SDK needs Python 3.10 or newer; on Debian and Ubuntu the python3-venv
# package is installed too, since their python3 ships without ensurepip.
# Activate it with `. /opt/mosaico/bin/activate`. Default: not installed.
#
# --cleanup-retention <DURATION>
# How long obsolete files are kept before being deleted, for example 7d, 14d or
# 30d. When omitted, mosaicod applies its own default —
# see https://docs.mosaico.dev/config/cleanup
#
# --cleanup-time-interval <DURATION>
# How often the cleanup routine runs. When omitted, mosaicod applies its own
# default — see https://docs.mosaico.dev/config/cleanup
#
# --version <VERSION>
# Use the --version option to install a specific version, for example:
#
#   $ sudo sh install-mosaico.sh --version 0.6.0
#
# The default is currently the floating `latest` tag, which is a stopgap: no
# stable tag of the 0.5 line was ever published, so there is nothing to pin to.
# It should go back to a version tag as soon as one exists, because this installer
# generates a command line and a set of environment variables specific to one
# mosaicod release. 0.6.0 in particular renames the `run` subcommand to `server`,
# moves the cleanup routine into a subcommand of its own and changes the API key
# permission model, so the moment `latest` starts pointing at 0.6.x the generated
# unit stops working. See DEFAULT_MOSAICO_VERSION.
#
# --uninstall
# Stops and removes the Mosaico services, the installed binaries and the man
# page, leaving stored data in place:
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

SCRIPT_VERSION="1.1.0"

# --- Configuration ---

DATA_DIR="/var/lib/mosaico"
SECRETS_DIR="$DATA_DIR/secrets"
MOSAICOD_ENV_FILE="$SECRETS_DIR/mosaicod.env"
TLS_DIR="$SECRETS_DIR/tls"
# Paths of the certificate and key as seen from inside the container.
TLS_CERT_IN_CONTAINER="/certs/cert.pem"
TLS_KEY_IN_CONTAINER="/certs/key.pem"
QUADLET_DIR="/etc/containers/systemd"
# certbot's own layout. live/ holds symlinks into archive/, which is why the
# installer copies the material out rather than mounting either directory.
LE_DIR="/etc/letsencrypt"
RENEWAL_HOOK_DIR="$LE_DIR/renewal-hooks/deploy"
RENEWAL_HOOK="$RENEWAL_HOOK_DIR/mosaico.sh"
# The generated command line and environment variables track one mosaicod
# release: change this together with the flags in write_quadlets and the keys in
# write_secrets, never independently. Left on the floating tag because no stable
# tag of the 0.5 line was ever published — the release workflow's tag filter did
# not match v0.5.0 — so a pin would name an image that does not exist. Pin this
# to a version tag as soon as one is on the registry.
DEFAULT_MOSAICO_VERSION="latest"
MOSAICO_VERSION="${MOSAICO_VERSION:-$DEFAULT_MOSAICO_VERSION}"
POSTGRES_IMAGE="docker.io/library/postgres:18"
MOSAICOD_PORT="6726"
CLI_WRAPPER="/usr/local/bin/mosaicod"
# The Python SDK goes in a virtual environment of its own rather than into the
# system interpreter: pip installing into a distribution's python3 fights the
# package manager, and on recent Debian and Fedora it is refused outright
# (PEP 668). The directory is named for the environment, so the prompt reads
# "(mosaico)" once activated.
SDK_VENV="/opt/mosaico"
SDK_PACKAGE="mosaicolabs"
INSTALLER_PATH="/usr/local/bin/mosaico-installer"
MAN_DIR="/usr/local/share/man"
MAN_PAGE="$MAN_DIR/man7/mosaico.7"
MAN_LINK_CLI="$MAN_DIR/man1/mosaicod.1"
MAN_LINK_INSTALLER="$MAN_DIR/man8/mosaico-installer.8"
# The page lives next to this script in the repository rather than in a heredoc
# here: it is roff, it is long, and keeping it out of the installer means it can
# be read, diffed and rendered on its own. Run from a checkout the local copy is
# used; otherwise it is downloaded from the raw URL below.
MAN_PAGE_NAME="mosaico.7"
MAN_PAGE_URL="https://raw.githubusercontent.com/mosaico-labs/get.mosaico.dev/main/$MAN_PAGE_NAME"
# Set by install_man_page: print_success only points at `man mosaico` when the
# page actually made it onto the host.
MAN_PAGE_INSTALLED=0
DOCS_URL="https://docs.mosaico.dev"
CLEANUP_DOCS_URL="https://docs.mosaico.dev/config/cleanup"
# Shown to the user, never applied: the values themselves stay in mosaicod, and
# leaving MOSAICOD_CLEANUP_* out of the environment file is what lets the daemon
# use them. This string only lets the prompt say what "the defaults" are instead
# of asking the user to approve values it will not name — so if the daemon's
# defaults change, this line is stale but the installed behaviour is still right.
# It mirrors mosaicod's params.rs.
CLEANUP_DEFAULT_HINT="frames kept 1d, cleanup every 1d"
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

# Percent-encodes everything outside the unreserved set of RFC 3986. The database
# credentials end up inside a URL, where a password containing @ : / ? # would
# otherwise be parsed as part of the syntax — and those are exactly the
# characters a password generator likes. Only ASCII is handled: a byte outside it
# is encoded as whatever the shell reports for it, which is enough for the
# credentials this is used on.
urlencode() {
	_ue_rest="$1"
	_ue_out=""
	while [ -n "$_ue_rest" ]; do
		_ue_char="${_ue_rest%"${_ue_rest#?}"}"
		_ue_rest="${_ue_rest#?}"
		case "$_ue_char" in
			[A-Za-z0-9.~_-]) _ue_out="$_ue_out$_ue_char" ;;
			*) _ue_out="$_ue_out$(printf '%%%02X' "'$_ue_char")" ;;
		esac
	done
	printf '%s' "$_ue_out"
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

# Where the metadata database lives. "embedded" is the default because it needs
# nothing from the operator: the container, the role and the password are all
# created here. "external" only records a connection string.
PG_MODE="embedded";           PG_MODE_SET=0
PG_HOST="";                   PG_HOST_SET=0
PG_PORT="5432";               PG_PORT_SET=0
PG_USER="mosaico";            PG_USER_SET=0
PG_PASSWORD="";               PG_PASSWORD_SET=0
PG_DB="mosaico";              PG_DB_SET=0
# Derived in derive_pg_container_host, not passed by the user: the host as the
# container has to spell it, which differs from PG_HOST for a local instance.
PG_HOST_IN_CONTAINER=""
PG_HOST_IS_LOCAL=0

STORE_BACKEND="fs";           STORE_BACKEND_SET=0
FS_DIR="$DATA_DIR/storage";   FS_DIR_SET=0
OBJ_ENDPOINT="";              OBJ_ENDPOINT_SET=0
OBJ_BUCKET="mosaico";         OBJ_BUCKET_SET=0
OBJ_ACCESS_KEY="";            OBJ_ACCESS_KEY_SET=0
OBJ_SECRET_KEY="";            OBJ_SECRET_KEY_SET=0
ENABLE_TLS=0;                 ENABLE_TLS_SET=0
TLS_CERT="";                  TLS_CERT_SET=0
TLS_KEY="";                   TLS_KEY_SET=0
DOMAIN="";                    DOMAIN_SET=0
# Fixed, not an option: it is the address Let's Encrypt notifies about expiring
# certificates, and it belongs to whoever maintains Mosaico rather than to the
# operator running the installer.
CERTBOT_EMAIL="info@mosaico.dev"
# Derived in apply_pairings, not passed by the user: TLS with no certificate of
# its own is the signal to obtain one from Let's Encrypt.
USE_CERTBOT=0
API_KEY=0;                    API_KEY_SET=0
# On by default: an installation that never reclaims space fills its disk, which
# is a worse first experience than frames being pruned. --no-cleanup opts out.
CLEANUP=1;                    CLEANUP_SET=0
# Left empty on purpose: when the user does not pick a value, no
# MOSAICOD_CLEANUP_* key is written and mosaicod applies its own default. The
# installer deliberately does not restate those defaults, so it never has to be
# kept in sync with the daemon — see $CLEANUP_DOCS_URL.
CLEANUP_RETENTION="";         CLEANUP_RETENTION_SET=0
CLEANUP_INTERVAL="";          CLEANUP_INTERVAL_SET=0
SDK=0;                        SDK_SET=0

usage() {
	cat <<-EOF
	Mosaico Installer (v$SCRIPT_VERSION)

	This script installs Mosaico (mosaicod, plus an embedded PostgreSQL unless
	you already run one) using system-level Podman containers supervised by
	systemd (via Quadlet).

	Usage:
	  \$ curl -fsSL https://get.mosaico.dev | sh
	  \$ mosaico-installer [options]

	General options:
	  -h, --help                      Show this help message and exit
	  -y, --yes                       Skip all prompts (unattended install)
	      --uninstall                 Remove Mosaico, leaving stored data in place
	      --dry-run                   Print commands without running them
	      --version <tag>             Install a specific image tag
	                                  (default: $DEFAULT_MOSAICO_VERSION)

	Database options:
	      --postgres <embedded|external>
	                                  Run PostgreSQL in a container of its own
	                                  (default: embedded), or use an instance you
	                                  already have
	      --pg-host <host>            Host or address of the existing instance
	                                  (IPv6 in brackets)
	      --pg-port <port>            Port of the existing instance (default: 5432)
	      --pg-db <name>              Database name (default: mosaico)
	      --pg-user <name>            Role to connect as (default: mosaico)
	      --pg-password <password>    Password of that role

	Storage options:
	      --store-backend <fs|obj>    Local filesystem or object store (default: fs)
	      --fs-dir <path>             Local storage path when backend is fs
	                                  (default: $DATA_DIR/storage)
	      --obj-endpoint <url>        Object store endpoint URL
	      --obj-bucket <name>         Object store bucket name (default: mosaico)
	      --obj-access-key <key>      Object store access key / key ID
	      --obj-secret-key <key>      Object store secret key

	TLS options:
	      --enable-tls                Serve over TLS (default: off). A certificate
	                                  is obtained from Let's Encrypt with certbot,
	                                  and renewed automatically, unless you pass
	                                  one of your own
	      --domain <fqdn>             Name the certificate is issued for,
	                                  always required with TLS
	      --tls-cert <path>           PEM certificate chain, to use a certificate
	      --tls-key <path>            of your own instead of Let's Encrypt
	                                  (both together, or neither)

	  Port 443 has to be open for the TLS challenge.

	Security options:
	      --api-key                   Create a master API key on first run and
	                                  require API keys from every client

	Data retention options:
	      --no-cleanup                Do not run the automated cleanup routine
	                                  (default: it runs)
	      --cleanup-retention <dur>   How long frames are kept
	      --cleanup-time-interval <dur>
	                                  How often cleanup runs
	                                  Both fall back to the mosaicod defaults:
	                                  $CLEANUP_DOCS_URL

	SDK options:
	      --sdk                       Install the $SDK_PACKAGE Python SDK into a
	                                  virtual environment at $SDK_VENV
	                                  (default: not installed)

	Paired options — with -y all of a group must be given, interactively the
	missing ones are asked for:
	      --postgres external  ->  --pg-host, --pg-password
	      --store-backend obj  ->  --obj-endpoint, --obj-bucket,
	                               --obj-access-key, --obj-secret-key
	      --enable-tls         ->  --domain

	Environment variables:
	  NON_INTERACTIVE   Same as --yes
	  MOSAICO_VERSION   Same as --version

	Documentation: $DOCS_URL
	Installed commands and uninstall: man mosaico
	EOF
}

# --- Argument parsing ---

require_value() {
	if [ $# -lt 2 ] || [ -z "$2" ]; then
		fatal "option $1 requires a value."
	fi
}

# Normalizes the database mode. The synonyms are the words users reach for when
# describing the two cases: a database this installer creates, or one that is
# already running somewhere.
normalize_pg_mode() {
	case "$(lower "$1")" in
		embedded|internal|container|local|managed) echo embedded ;;
		external|existing|remote)                 echo external ;;
		*)                                        echo "$1" ;;
	esac
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

			# --postgres selects between the two arrangements; the two spelled-out
			# forms exist because they read better in a command line than
			# `--postgres external` does.
			--postgres|--postgres-mode|--db)
				require_value "$@"
				PG_MODE="$(normalize_pg_mode "$2")"; PG_MODE_SET=1; shift ;;
			--postgres=*|--postgres-mode=*|--db=*)
				PG_MODE="$(normalize_pg_mode "${1#*=}")"; PG_MODE_SET=1 ;;
			--external-postgres|--existing-postgres) PG_MODE="external"; PG_MODE_SET=1 ;;
			--embedded-postgres) PG_MODE="embedded"; PG_MODE_SET=1 ;;

			--pg-host|--postgres-host|--db-host)
				require_value "$@"; PG_HOST="$2"; PG_HOST_SET=1; shift ;;
			--pg-host=*|--postgres-host=*|--db-host=*) PG_HOST="${1#*=}"; PG_HOST_SET=1 ;;

			--pg-port|--postgres-port|--db-port)
				require_value "$@"; PG_PORT="$2"; PG_PORT_SET=1; shift ;;
			--pg-port=*|--postgres-port=*|--db-port=*) PG_PORT="${1#*=}"; PG_PORT_SET=1 ;;

			--pg-user|--postgres-user|--db-user)
				require_value "$@"; PG_USER="$2"; PG_USER_SET=1; shift ;;
			--pg-user=*|--postgres-user=*|--db-user=*) PG_USER="${1#*=}"; PG_USER_SET=1 ;;

			--pg-password|--postgres-password|--db-password)
				require_value "$@"; PG_PASSWORD="$2"; PG_PASSWORD_SET=1; shift ;;
			--pg-password=*|--postgres-password=*|--db-password=*)
				PG_PASSWORD="${1#*=}"; PG_PASSWORD_SET=1 ;;

			--pg-db|--pg-database|--postgres-db|--db-name)
				require_value "$@"; PG_DB="$2"; PG_DB_SET=1; shift ;;
			--pg-db=*|--pg-database=*|--postgres-db=*|--db-name=*)
				PG_DB="${1#*=}"; PG_DB_SET=1 ;;

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

			# --tls-certificate and --tls-private-key are accepted aliases.
			--tls-cert|--tls-certificate)
				require_value "$@"; TLS_CERT="$2"; TLS_CERT_SET=1; shift ;;
			--tls-cert=*|--tls-certificate=*) TLS_CERT="${1#*=}"; TLS_CERT_SET=1 ;;

			--tls-key|--tls-private-key)
				require_value "$@"; TLS_KEY="$2"; TLS_KEY_SET=1; shift ;;
			--tls-key=*|--tls-private-key=*) TLS_KEY="${1#*=}"; TLS_KEY_SET=1 ;;

			--domain) require_value "$@"; DOMAIN="$2"; DOMAIN_SET=1; shift ;;
			--domain=*) DOMAIN="${1#*=}"; DOMAIN_SET=1 ;;


			# --generate-api-key is an accepted alias for --api-key.
			--api-key|--generate-api-key) API_KEY=1; API_KEY_SET=1 ;;
			--api-key=*|--generate-api-key=*) API_KEY="$(to_bool "${1#*=}")"; API_KEY_SET=1 ;;

			# Only the opt-out exists: cleanup runs by default, so a flag asking for
			# it would have nothing to turn on.
			--no-cleanup|--disable-cleanup) CLEANUP=0; CLEANUP_SET=1 ;;

			--sdk|--install-sdk) SDK=1; SDK_SET=1 ;;
			--sdk=*|--install-sdk=*) SDK="$(to_bool "${1#*=}")"; SDK_SET=1 ;;
			--no-sdk) SDK=0; SDK_SET=1 ;;

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
# `--tls-cert /path/cert.pem` alone is enough to get TLS. When the toggle was
# given explicitly it always wins, and the ignored options are reported.

apply_pairings() {
	# Connection details are only meaningful for an instance this installer does
	# not create, so giving any of them selects `external`. --pg-port alone is not
	# taken as that signal: it has a default, and 5432 on its own says nothing
	# about which of the two arrangements was meant.
	if [ "$PG_MODE_SET" -eq 0 ]; then
		if [ "$PG_HOST_SET" -eq 1 ] || [ "$PG_USER_SET" -eq 1 ] ||
		   [ "$PG_PASSWORD_SET" -eq 1 ] || [ "$PG_DB_SET" -eq 1 ]; then
			PG_MODE="external"
			PG_MODE_SET=1
			info "PostgreSQL connection options given — selecting --postgres external."
		elif [ "$PG_PORT_SET" -eq 1 ]; then
			# The one --pg-* option that cannot stand alone, since the embedded
			# database is not published to the host and so has no port to move.
			warn "--pg-port alone does not select an existing instance: pass --pg-host as well. The embedded database is used, and the port is ignored."
		fi
	elif [ "$PG_MODE" = "embedded" ]; then
		if [ "$PG_HOST_SET" -eq 1 ] || [ "$PG_USER_SET" -eq 1 ] ||
		   [ "$PG_PASSWORD_SET" -eq 1 ] || [ "$PG_DB_SET" -eq 1 ] || [ "$PG_PORT_SET" -eq 1 ]; then
			warn "--postgres embedded was requested; the --pg-* options are ignored."
		fi
	fi

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

	if [ "$ENABLE_TLS_SET" -eq 0 ]; then
		if [ "$DOMAIN_SET" -eq 1 ] || [ "$TLS_CERT_SET" -eq 1 ] || [ "$TLS_KEY_SET" -eq 1 ]; then
			ENABLE_TLS=1
			ENABLE_TLS_SET=1
			info "TLS options given — enabling TLS."
		fi
	elif [ "$ENABLE_TLS" -eq 0 ]; then
		if [ "$DOMAIN_SET" -eq 1 ] || [ "$TLS_CERT_SET" -eq 1 ] || [ "$TLS_KEY_SET" -eq 1 ]; then
			warn "TLS is disabled; --domain, --tls-cert and --tls-key are ignored."
		fi
	fi

	# Which of the two TLS paths applies. Certificates supplied by hand win: an
	# operator who already has material does not want the installer talking to a
	# certificate authority, and a corporate PKI would not answer certbot's
	# challenge anyway. Decided here so that validation, the summary and the
	# install flow all read the same flag.
	if [ "$ENABLE_TLS" -eq 1 ] && [ -z "$TLS_CERT" ] && [ -z "$TLS_KEY" ]; then
		USE_CERTBOT=1
	fi

	# There is no enabling branch to mirror the TLS one: cleanup is already on, so
	# passing a retention or an interval only refines it. The one contradiction
	# worth reporting is asking to turn it off and tune it in the same run.
	if [ "$CLEANUP" -eq 0 ]; then
		if [ "$CLEANUP_RETENTION_SET" -eq 1 ] || [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
			warn "--no-cleanup given; --cleanup-retention and --cleanup-time-interval are ignored."
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

is_valid_pg_mode() {
	case "$1" in
		embedded|external) return 0 ;;
		*) return 1 ;;
	esac
}

# Looser than is_valid_domain, which insists on a dot: a database may well be
# reachable as `localhost`, as a bare short name or as an address. IPv6 literals
# are accepted only in brackets, which is also how they have to appear in the
# connection URL.
is_valid_host() {
	case "$1" in
		\[*\]) echo "$1" | grep -Eq '^\[[0-9A-Fa-f:]+\]$' && return 0
		       return 1 ;;
		*:*)   return 1 ;;
	esac
	echo "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'
}

is_valid_port() {
	echo "$1" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$1" -le 65535 ]
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

# A private key is typically unreadable by the invoking user, so the check falls
# back to a privileged probe — but only when something is actually being
# installed: making a dry run ask for a sudo password would be worse than not
# checking, and the plain test already covers a readable certificate.
is_readable_file() {
	is_absolute_path "$1" || return 1
	[ -r "$1" ] && return 0
	is_dry_run && return 0
	as_root_capture "test -r '$1' && echo yes" 2>/dev/null | grep -q '^yes$'
}

# Converts the durations accepted by is_valid_duration into the seconds that
# mosaicod expects. A month is taken as 30 days.
duration_to_seconds() {
	_num="${1%?}"
	case "${1#"$_num"}" in
		h) echo $((_num * 3600)) ;;
		d) echo $((_num * 86400)) ;;
		w) echo $((_num * 604800)) ;;
		m) echo $((_num * 2592000)) ;;
		*) fatal "internal error: unsupported duration '$1'." ;;
	esac
}

# Rejects a malformed value as soon as it is seen, so the user is not walked
# through a whole questionnaire before learning that a flag was wrong.
validate_flags() {
	is_valid_pg_mode "$PG_MODE" || \
		fatal "invalid --postgres '$PG_MODE' (expected 'embedded' or 'external')."

	is_valid_backend "$STORE_BACKEND" || \
		fatal "invalid --store-backend '$STORE_BACKEND' (expected 'fs' or 'obj')."

	if [ "$PG_HOST_SET" -eq 1 ] && ! is_valid_host "$PG_HOST"; then
		fatal "--pg-host '$PG_HOST' is not a valid host name or address (an IPv6 literal needs brackets, as in [2001:db8::1])."
	fi
	if [ "$PG_PORT_SET" -eq 1 ] && ! is_valid_port "$PG_PORT"; then
		fatal "--pg-port '$PG_PORT' is not a valid port number."
	fi

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
	if [ "$TLS_CERT_SET" -eq 1 ] && ! is_readable_file "$TLS_CERT"; then
		fatal "--tls-cert '$TLS_CERT' is not an absolute path to a readable file."
	fi
	if [ "$TLS_KEY_SET" -eq 1 ] && ! is_readable_file "$TLS_KEY"; then
		fatal "--tls-key '$TLS_KEY' is not an absolute path to a readable file."
	fi
	if [ "$CLEANUP_RETENTION_SET" -eq 1 ]; then
		is_valid_duration "$CLEANUP_RETENTION" || \
			fatal "--cleanup-retention '$CLEANUP_RETENTION' is not a valid duration (e.g. 7d, 14d, 30d)."
		check_duration_fits --cleanup-retention "$CLEANUP_RETENTION"
	fi
	if [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
		is_valid_duration "$CLEANUP_INTERVAL" || \
			fatal "--cleanup-time-interval '$CLEANUP_INTERVAL' is not a valid duration (e.g. 7d, 14d, 30d)."
		check_duration_fits --cleanup-time-interval "$CLEANUP_INTERVAL"
	fi
}

# mosaicod stores both durations as a 32-bit number of seconds, so a value that
# parses correctly can still be out of range.
check_duration_fits() {
	if [ "$(duration_to_seconds "$2")" -ge 4294967296 ]; then
		fatal "$1 '$2' is too large (the limit is about 49700 days)."
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

	# Only the host and the password have no defaults. The role and the database
	# fall back to `mosaico`, which is what the embedded arrangement uses too.
	if [ "$PG_MODE" = "external" ]; then
		if [ -z "$PG_HOST" ] || [ -z "$PG_PASSWORD" ]; then
			add_missing "Database mode 'external' requires --pg-host and --pg-password."
		fi
	fi

	if [ "$STORE_BACKEND" = "obj" ]; then
		if [ -z "$OBJ_ENDPOINT" ] || [ -z "$OBJ_ACCESS_KEY" ] || [ -z "$OBJ_SECRET_KEY" ]; then
			add_missing "Storage backend 'obj' requires --obj-endpoint, --obj-access-key, and --obj-secret-key."
		fi
	elif [ -z "$FS_DIR" ]; then
		add_missing "Storage backend 'fs' requires --fs-dir."
	fi

	if [ "$ENABLE_TLS" -eq 1 ]; then
		# The domain is the only thing that must be supplied: it is the name the
		# certificate is issued for, and the name certbot proves control of. The
		# certificate itself needs nothing else from the user.
		if [ -z "$DOMAIN" ]; then
			add_missing "TLS is enabled, which requires --domain <fqdn>."
		fi
		if [ "$USE_CERTBOT" -eq 0 ] && { [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; }; then
			add_missing "--tls-cert and --tls-key must be given together; pass neither to obtain a Let's Encrypt certificate instead."
		fi
	fi

	# Cleanup needs nothing else: whatever is not passed is left to mosaicod's
	# own defaults.

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

	# --- [1/6] Database ---
	#
	# Asked first, and defaulted to the embedded container: it is the choice that
	# decides whether anything has to exist on the host before Mosaico can run, so
	# an evaluator pressing Enter through the questionnaire gets a working database
	# without having provisioned one.
	section "[1/6] PostgreSQL Database"
	if [ "$PG_MODE_SET" -eq 0 ]; then
		tty_print "${BOLD}?${RESET} Choose how mosaicod reaches PostgreSQL:"
		tty_print "  ${VIOLET}>${RESET} [1] Install an embedded PostgreSQL container (nothing needed beforehand)"
		tty_print "    [2] Use a PostgreSQL instance I already have"
		while :; do
			_choice="$(ask_plain "  Select [1-2] (default: 1): " "1")"
			case "$(lower "$_choice")" in
				1|embedded|internal|local) PG_MODE="embedded"; break ;;
				2|external|existing|remote) PG_MODE="external"; break ;;
				*) tty_print "  ${RED}Please enter 1 or 2.${RESET}" ;;
			esac
		done
		echo
	else
		info "Database mode '$PG_MODE' taken from the command line."
	fi

	if [ "$PG_MODE" = "external" ]; then
		echo "  The database and the role have to exist already; mosaicod creates its"
		echo "  own schema inside them on first start."
		[ "$PG_HOST_SET" -eq 1 ] || PG_HOST="$(ask_required \
			"PostgreSQL host or address (e.g., db.example.com or 10.0.0.5)" \
			is_valid_host "Enter a host name or an address; an IPv6 literal needs brackets.")"
		[ "$PG_PORT_SET" -eq 1 ] || PG_PORT="$(ask_required \
			"PostgreSQL port" is_valid_port "Enter a port number between 1 and 65535." "$PG_PORT")"
		[ "$PG_DB_SET" -eq 1 ] || PG_DB="$(ask_required \
			"Database name" "" "" "$PG_DB")"
		[ "$PG_USER_SET" -eq 1 ] || PG_USER="$(ask_required \
			"Database user" "" "" "$PG_USER")"
		[ "$PG_PASSWORD_SET" -eq 1 ] || PG_PASSWORD="$(ask_secret "Database password")"
	fi

	# --- [2/6] Storage ---
	section "[2/6] Storage Configuration"
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

	# --- [3/6] TLS & domain ---
	section "[3/6] TLS & Domain Setup"
	if [ "$ENABLE_TLS_SET" -eq 0 ]; then
		if ask_yn "Do you want to configure TLS/HTTPS?" "n"; then
			ENABLE_TLS=1
		else
			ENABLE_TLS=0
		fi
	fi
	if [ "$ENABLE_TLS" -eq 1 ]; then
		[ "$DOMAIN_SET" -eq 1 ] || DOMAIN="$(ask_required \
			"Enter your fully qualified domain name (e.g., mosaico.example.com)" \
			is_valid_domain "That does not look like a valid domain name.")"

		# Only asked when neither path has been pinned on the command line. The
		# suggested answer is the Let's Encrypt one, since an operator who already
		# holds a certificate normally passes --tls-cert/--tls-key rather than
		# arriving here.
		if [ "$TLS_CERT_SET" -eq 0 ] && [ "$TLS_KEY_SET" -eq 0 ]; then
			echo
			echo "  A certificate can be obtained automatically from Let's Encrypt, or you"
			echo "  can point the installer at one you already have."
			echo "  ${BOLD}Automatic issuance needs port 443 open${RESET} for the TLS challenge."
			if ask_yn "Obtain a certificate for $DOMAIN automatically with certbot?" "y"; then
				USE_CERTBOT=1
			else
				USE_CERTBOT=0
			fi
		fi

		if [ "$USE_CERTBOT" -eq 0 ]; then
			[ "$TLS_CERT_SET" -eq 1 ] || TLS_CERT="$(ask_required \
				"Path of the PEM certificate chain for $DOMAIN (e.g., /etc/ssl/mosaico/fullchain.pem)" \
				is_readable_file "That is not an absolute path to a readable file.")"
			[ "$TLS_KEY_SET" -eq 1 ] || TLS_KEY="$(ask_required \
				"Path of the matching PEM private key (e.g., /etc/ssl/mosaico/privkey.pem)" \
				is_readable_file "That is not an absolute path to a readable file.")"
		fi
	fi

	# --- [4/6] Security ---
	#
	# Note the asymmetry with -y: unattended runs default to *not* creating a
	# key (--api-key opts in), while here the suggested answer is yes, because
	# an evaluator following the prompts needs a key to talk to the daemon.
	section "[4/6] Security & API Keys"
	if [ "$API_KEY_SET" -eq 0 ]; then
		if ask_yn "Do you want to generate an initial Master API Key for clients?" "y"; then
			API_KEY=1
		else
			API_KEY=0
		fi
	fi

	# --- [5/6] Retention ---
	#
	# Stated before it is questioned: cleanup is on unless the user says otherwise,
	# so the first prompt is the opt-out, and the values are only revisited once
	# they have decided to keep the routine.
	section "[5/6] Data Retention & Cleanup"
	if [ "$CLEANUP_SET" -eq 0 ]; then
		echo "  The cleanup routine prunes obsolete dataset frames and runs by default,"
		echo "  with mosaicod's own settings: ${BOLD}$CLEANUP_DEFAULT_HINT${RESET}."
		echo "  ${DIM}$CLEANUP_DOCS_URL${RESET}"
		if ask_yn "Disable the automated cleanup routine?" "n"; then
			CLEANUP=0
		else
			CLEANUP=1
		fi
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		# Only offer the shortcut when neither value was given on the command
		# line; if one arrived from there, just ask for the other. Accepting the
		# shortcut writes no MOSAICOD_CLEANUP_* value at all, which is what
		# leaves mosaicod free to apply its own default.
		if [ "$CLEANUP_RETENTION_SET" -eq 0 ] && [ "$CLEANUP_INTERVAL_SET" -eq 0 ]; then
			if ask_yn "Keep those default values?" "y"; then
				CLEANUP_RETENTION_SET=1
				CLEANUP_INTERVAL_SET=1
			fi
		fi
		[ "$CLEANUP_RETENTION_SET" -eq 1 ] || CLEANUP_RETENTION="$(ask_required \
			"Custom retention policy (e.g., 7d, 14d, 90d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 14d).")"
		[ "$CLEANUP_INTERVAL_SET" -eq 1 ] || CLEANUP_INTERVAL="$(ask_required \
			"How often should the cleanup run (e.g., 1d, 7d, 30d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 7d).")"
	fi

	# --- [6/6] Python SDK ---
	section "[6/6] Python SDK"
	if [ "$SDK_SET" -eq 0 ]; then
		echo "  The Python SDK ($SDK_PACKAGE) is installed into a virtual environment"
		echo "  at $SDK_VENV, leaving the system interpreter untouched."
		if ask_yn "Install the Python SDK?" "n"; then
			SDK=1
		else
			SDK=0
		fi
	fi
}

# Describes the retention settings without ever naming a default value: an
# omitted option is reported as "default" and its actual value is only
# documented in $CLEANUP_DOCS_URL.
cleanup_summary() {
	_parts=""
	[ -n "$CLEANUP_RETENTION" ] && _parts="Retention: $CLEANUP_RETENTION"
	if [ -n "$CLEANUP_INTERVAL" ]; then
		[ -n "$_parts" ] && _parts="$_parts, "
		_parts="${_parts}Interval: $CLEANUP_INTERVAL"
	fi
	if [ -z "$_parts" ]; then
		echo "default retention and interval"
	else
		echo "$_parts"
	fi
}

# A container has a loopback address of its own, so 127.0.0.1 there is the
# container and not the host: an instance running on this machine has to be
# addressed as host.containers.internal, which Podman resolves to the host.
# Computed before the summary so that what is printed is what will be written.
derive_pg_container_host() {
	[ "$PG_MODE" = "external" ] || return 0

	PG_HOST_IN_CONTAINER="$PG_HOST"
	case "$(lower "$PG_HOST")" in
		localhost|localhost.localdomain|127.*|0.0.0.0|::1|"[::1]")
			PG_HOST_IS_LOCAL=1
			PG_HOST_IN_CONTAINER="host.containers.internal"
			;;
	esac
}

print_summary() {
	echo
	echo "${DIM}--------------------------------------------------------------------------------${RESET}"
	echo "${BOLD}Configuration Summary:${RESET}"
	if [ "$PG_MODE" = "embedded" ]; then
		echo "  - Database        : Embedded PostgreSQL container (created and managed here)"
	else
		echo "  - Database        : Existing PostgreSQL at $PG_HOST:$PG_PORT/$PG_DB as $PG_USER"
		if [ "$PG_HOST_IS_LOCAL" -eq 1 ]; then
			echo "                      ${DIM}reached from the container as $PG_HOST_IN_CONTAINER${RESET}"
		fi
	fi
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "  - Storage Backend : Local Filesystem ($FS_DIR)"
	else
		echo "  - Storage Backend : Generic Object Storage ($OBJ_ENDPOINT / $OBJ_BUCKET)"
	fi
	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo "  - TLS / Domain    : Enabled ($DOMAIN)"
		if [ "$USE_CERTBOT" -eq 1 ]; then
			echo "  - Certificate     : Let's Encrypt, obtained now and renewed automatically"
		else
			echo "  - TLS Certificate : $TLS_CERT"
			echo "  - TLS Private Key : $TLS_KEY"
		fi
	else
		echo "  - TLS / Domain    : Disabled (plain HTTP)"
	fi
	if [ "$API_KEY" -eq 1 ]; then
		echo "  - Master API Key  : Yes (will be created, clients will need a key)"
	else
		echo "  - Master API Key  : No (the daemon accepts unauthenticated clients)"
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		echo "  - Cleanup Routine : Enabled ($(cleanup_summary))"
	else
		echo "  - Cleanup Routine : Disabled"
	fi
	if [ "$SDK" -eq 1 ]; then
		echo "  - Python SDK      : $SDK_PACKAGE in a venv at $SDK_VENV"
	else
		echo "  - Python SDK      : Not installed"
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


# Non-fatal sanity check: warn when the domain does not resolve to this host, so
# that a name clients cannot use is caught here rather than at the first
# connection attempt. Left as a warning even when the certificate is about to be
# obtained from Let's Encrypt: certbot reports the same problem in its own terms
# a few steps later, and stopping the install here would only pre-empt it.
check_domain_dns() {
	[ "$ENABLE_TLS" -eq 1 ] && [ -n "$DOMAIN" ] || return 0

	resolved=""
	if command_exists getent; then
		resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
	elif command_exists host; then
		resolved="$(host -t A "$DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}' || true)"
	fi

	if [ -z "$resolved" ]; then
		warn "could not resolve '$DOMAIN' — clients will not reach Mosaico by that name until DNS is configured."
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

install_python_packages() {
	pm="$(get_package_manager)"
	case "$pm" in
		# python3-venv is a separate package on Debian and Ubuntu: their python3
		# ships with ensurepip stripped out, so `python3 -m venv` exists but
		# produces an environment with no pip in it.
		apt)
			as_root "apt-get update -qq"
			as_root "env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq python3 python3-venv < /dev/null"
			;;
		dnf)
			as_root "dnf install -y python3"
			;;
		*)
			echo
			fatal "unsupported distribution: neither apt-get nor dnf found."
			;;
	esac
}

# $SDK_PACKAGE declares requires_python >=3.10, so an older interpreter would
# fail at pip time with a message about no matching distribution, which reads as
# a network or naming problem rather than a version one. Checked up front.
SDK_MIN_PYTHON="3.10"

check_python() {
	step "Checking Python for the SDK..."

	if ! command_exists python3; then
		step_ok "missing, installing"
		install_python_packages
		return
	fi

	if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
		step_ok "too old"
		echo
		fatal "$SDK_PACKAGE needs Python $SDK_MIN_PYTHON or newer, but python3 here is
       $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown).
       Install a newer interpreter, or re-run without --sdk and install the SDK
       yourself in an environment of your choosing."
	fi

	# A present python3 does not imply a usable venv module: see the apt note in
	# install_python_packages.
	if ! python3 -m venv --help >/dev/null 2>&1; then
		step_ok "venv module missing, installing"
		install_python_packages
		return
	fi

	step_ok "OK (v$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'))"
}

# Installs the SDK in a virtual environment of its own, never into the system
# interpreter: recent Debian and Fedora refuse that outright under PEP 668, and
# where it is allowed it leaves pip and the distribution's package manager
# managing the same files.
install_sdk() {
	[ "$SDK" -eq 1 ] || return 0

	check_python

	step_line "Installing the $SDK_PACKAGE SDK in $SDK_VENV"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} python3 -m venv $SDK_VENV"
		echo "  ${DIM}(dry-run)${RESET} $SDK_VENV/bin/pip install --upgrade $SDK_PACKAGE"
		return 0
	fi

	# The environment is only created when it is not already there, so re-running
	# the installer keeps whatever else was pip installed into it. --upgrade is
	# what makes the run meaningful in that case: a plain install would report the
	# requirement as already satisfied and leave an old SDK in place.
	if ! as_root_capture "test -x $SDK_VENV/bin/python && echo yes" | grep -q '^yes$'; then
		as_root "python3 -m venv $SDK_VENV"
	fi
	as_root "$SDK_VENV/bin/pip install --quiet --upgrade pip"
	as_root "$SDK_VENV/bin/pip install --quiet --upgrade $SDK_PACKAGE"
}

check_certbot() {
	step "Checking certbot..."
	if command_exists certbot; then
		step_ok "OK"
		return
	fi
	pm="$(get_package_manager)"
	case "$pm" in
		apt)
			step_ok "missing, installing via apt"
			as_root "apt-get update -qq"
			as_root "env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq certbot < /dev/null"
			;;
		dnf)
			step_ok "missing, installing via dnf"
			as_root "dnf install -y certbot"
			;;
		*)
			echo
			fatal "unsupported distribution: neither apt-get nor dnf found."
			;;
	esac
}

# Obtains the certificate and rewrites TLS_CERT/TLS_KEY to point at certbot's
# copies, so everything downstream — install_tls_material, the summary, the
# recorded configuration — is unaware of where the material came from.
#
# Port 443 has to be open for the TLS challenge.
obtain_certificate() {
	[ "$USE_CERTBOT" -eq 1 ] || return 0

	check_certbot

	# --keep-until-expiring is the one addition to the invocation: it reuses a
	# certificate that is still valid instead of asking for another one. Without
	# it, re-running the installer to change some unrelated setting would request a
	# duplicate every time, and Let's Encrypt allows five per week per domain.
	certbot_args="certonly --standalone -d $DOMAIN --non-interactive --agree-tos"
	certbot_args="$certbot_args --email $CERTBOT_EMAIL --preferred-challenges http"
	certbot_args="$certbot_args --keep-until-expiring"

	step "Obtaining a certificate for $DOMAIN from Let's Encrypt..."

	if is_dry_run; then
		echo
		echo "  ${DIM}(dry-run)${RESET} certbot $certbot_args"
		TLS_CERT="$LE_DIR/live/$DOMAIN/fullchain.pem"
		TLS_KEY="$LE_DIR/live/$DOMAIN/privkey.pem"
		return 0
	fi

	# Where the log ends before certbot runs, so that a failure can show exactly
	# what certbot printed and nothing else. Not /var/log/letsencrypt: that is the
	# debug log, and its tail is a Python traceback whose last line is the only
	# part that says what went wrong.
	log_mark="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"

	if $sh_c "certbot $certbot_args" >> "$LOG_FILE" 2>&1; then
		step_ok "Done"
	else
		step_ok "failed"
		echo
		printf "${RED}Error:${RESET} certbot could not obtain a certificate for %s.\n" "$DOMAIN" >&2
		echo >&2
		echo "${YELLOW}--- certbot output ---${RESET}" >&2
		sed -n "$((log_mark + 1)),\$p" "$LOG_FILE" >&2
		echo >&2
		echo "Full details: $LOG_FILE and /var/log/letsencrypt/letsencrypt.log" >&2
		echo >&2
		exit 1
	fi

	TLS_CERT="$LE_DIR/live/$DOMAIN/fullchain.pem"
	TLS_KEY="$LE_DIR/live/$DOMAIN/privkey.pem"
}

# Bridges certbot's renewals to the container. Without this the renewal succeeds
# in $LE_DIR and nothing else happens: the daemon keeps serving the copies made
# at install time, and TLS breaks roughly ninety days later with no failure
# anywhere to explain it.
#
# A deploy hook runs only when a certificate was actually replaced, so the
# restart happens on renewal days and not on every check. Renewal itself is
# already scheduled by the distribution's certbot package (a systemd timer, or a
# cron entry on systems without one), so the installer only has to make sure the
# timer is running where one exists.
install_renewal_hook() {
	[ "$USE_CERTBOT" -eq 1 ] || return 0

	step_line "Installing the certificate renewal hook in $RENEWAL_HOOK"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} write $RENEWAL_HOOK and chmod 700"
		echo "  ${DIM}(dry-run)${RESET} systemctl enable --now certbot.timer"
		return 0
	fi

	as_root "install -d -m 755 $RENEWAL_HOOK_DIR"

	# Quoted heredoc: resolved when the hook runs, except for the values the
	# installer has to bake in, which are substituted below.
	as_root "cat > $RENEWAL_HOOK" <<-HOOK_EOF
	#!/bin/sh
	# Generated by mosaico-installer v$SCRIPT_VERSION — do not edit by hand.
	#
	# Runs after certbot replaces a certificate. RENEWED_LINEAGE is set by certbot
	# to the live directory of the certificate that was just renewed; the guard
	# makes the hook a no-op for every other certificate on this host.
	set -e

	[ "\$RENEWED_LINEAGE" = "$LE_DIR/live/$DOMAIN" ] || exit 0

	install -m 600 "\$RENEWED_LINEAGE/fullchain.pem" $TLS_DIR/cert.pem
	install -m 600 "\$RENEWED_LINEAGE/privkey.pem" $TLS_DIR/key.pem

	# The daemon reads the material once at startup, so it has to be restarted to
	# pick up the new certificate.
	systemctl restart mosaicod.service
	HOOK_EOF

	as_root "chmod 700 $RENEWAL_HOOK"

	# Enabled rather than assumed: the package usually ships the timer enabled,
	# but a minimal image may not have started it, and a renewal that never runs
	# is the failure this whole function exists to prevent.
	if $sh_c "systemctl list-unit-files certbot.timer" >> "$LOG_FILE" 2>&1; then
		as_root_ignore_errors "systemctl enable --now certbot.timer"
	fi
}

# Copies the certificate and the key into the secrets directory instead of
# mounting them from wherever they live on the host. Bind-mounting them directly
# would mean either relabelling files this installer does not own (breaking
# whatever else reads them under SELinux) or leaving the container unable to read
# them; a copy under $TLS_DIR is ours to label — and for a certbot certificate,
# $LE_DIR/live holds symlinks into $LE_DIR/archive, so a mount would need both
# directories to resolve.
#
# The cost is that renewals do not propagate on their own. For a certificate
# obtained here that is handled by install_renewal_hook; for one supplied by
# hand the two paths are stable and documented: replace the files and restart
# the service.
install_tls_material() {
	[ "$ENABLE_TLS" -eq 1 ] || return 0

	step_line "Installing TLS material in $TLS_DIR"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} copy $TLS_CERT to $TLS_DIR/cert.pem"
		echo "  ${DIM}(dry-run)${RESET} copy $TLS_KEY to $TLS_DIR/key.pem"
		return 0
	fi

	as_root "install -d -m 700 $TLS_DIR"
	as_root "install -m 600 '$TLS_CERT' $TLS_DIR/cert.pem"
	as_root "install -m 600 '$TLS_KEY' $TLS_DIR/key.pem"
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

# Set by create_master_api_key(), which runs after the daemon is up: only
# mosaicod itself can mint a valid key.
MASTER_API_KEY=""

write_secrets() {
	if is_dry_run; then
		step_line "Writing configuration secrets to $MOSAICOD_ENV_FILE"
		if [ "$PG_MODE" = "embedded" ]; then
			echo "  ${DIM}(dry-run)${RESET} generate PostgreSQL password and mosaicod.env"
		else
			echo "  ${DIM}(dry-run)${RESET} write mosaicod.env pointing at $PG_HOST_IN_CONTAINER:$PG_PORT/$PG_DB"
		fi
		return 0
	fi

	step_line "Writing configuration secrets to $MOSAICOD_ENV_FILE"

	# Built up incrementally so each optional feature contributes only the keys
	# it actually needs. This file is also what the CLI wrapper feeds back into
	# `podman exec --env-file`, so it must stay a plain KEY=VALUE list.
	#
	# The embedded database is addressed by container name on the internal
	# network, with a password generated once and reused; an existing instance is
	# addressed as the user described it. Either way the credentials are only ever
	# written to this file, which is root-only, and never to a command line.
	if [ "$PG_MODE" = "embedded" ]; then
		password="$(read_or_create_secret "$SECRETS_DIR/postgres_password" gen_password)"

		as_root "umask 077 && cat > $SECRETS_DIR/postgres.env" <<-EOF
		POSTGRES_USER=mosaico
		POSTGRES_DB=mosaico
		POSTGRES_PASSWORD=$password
		EOF

		env_body="MOSAICOD_DB_URL=postgresql://mosaico:$password@mosaico-postgres:5432/mosaico"
	else
		env_body="MOSAICOD_DB_URL=postgresql://$(urlencode "$PG_USER"):$(urlencode "$PG_PASSWORD")@$PG_HOST_IN_CONTAINER:$PG_PORT/$(urlencode "$PG_DB")"
	fi

	# The store backend is not a setting of its own: mosaicod derives it from the
	# scheme of the endpoint, so a local backend is a `file://` endpoint.
	if [ "$STORE_BACKEND" = "fs" ]; then
		env_body="$env_body
MOSAICOD_STORE_ENDPOINT=file:///data
MOSAICOD_STORE_BUCKET=mosaico"
	else
		env_body="$env_body
MOSAICOD_STORE_ENDPOINT=$OBJ_ENDPOINT
MOSAICOD_STORE_BUCKET=$OBJ_BUCKET
MOSAICOD_STORE_ACCESS_KEY=$OBJ_ACCESS_KEY
MOSAICOD_STORE_SECRET_KEY=$OBJ_SECRET_KEY"
	fi

	# TLS is switched on by the --tls flag on the command line; these two keys
	# only say where the material is. They are the container-side paths, which is
	# why they do not depend on where the files came from on the host.
	if [ "$ENABLE_TLS" -eq 1 ]; then
		env_body="$env_body
MOSAICOD_TLS_CERT_FILE=$TLS_CERT_IN_CONTAINER
MOSAICOD_TLS_PRIVATE_KEY_FILE=$TLS_KEY_IN_CONTAINER"
	fi

	# The cleanup routine runs inside the daemon and is driven entirely by these
	# two values, both expressed in seconds. There is no on/off switch: a zero
	# interval is what stops the routine, so it has to be written explicitly when
	# the user declined cleanup, or the daemon would silently run it once a day.
	if [ "$CLEANUP" -eq 0 ]; then
		env_body="$env_body
MOSAICOD_CLEANUP_TIME_INTERVAL=0"
	else
		# Whatever the user did not choose is left out, so that mosaicod applies
		# its own default rather than one this installer would have to track.
		if [ -n "$CLEANUP_INTERVAL" ]; then
			env_body="$env_body
MOSAICOD_CLEANUP_TIME_INTERVAL=$(duration_to_seconds "$CLEANUP_INTERVAL")"
		fi
		if [ -n "$CLEANUP_RETENTION" ]; then
			env_body="$env_body
MOSAICOD_CLEANUP_RETENTION_DURATION=$(duration_to_seconds "$CLEANUP_RETENTION")"
		fi
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
	# The database password is deliberately absent: this file is world-readable,
	# and the credentials belong in the root-only environment file. The other
	# connection details are only written for an external instance, so that the
	# record cannot suggest a host that is not in use.
	pg_record="PG_MODE=$PG_MODE"
	if [ "$PG_MODE" = "external" ]; then
		pg_record="$pg_record
PG_HOST=$PG_HOST
PG_HOST_IN_CONTAINER=$PG_HOST_IN_CONTAINER
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_DB=$PG_DB"
	fi

	as_root "umask 022 && cat > $DATA_DIR/install.conf" <<-EOF
	# Generated by mosaico-installer v$SCRIPT_VERSION — do not edit by hand.
	MOSAICO_VERSION=$MOSAICO_VERSION
	$pg_record
	STORE_BACKEND=$STORE_BACKEND
	FS_DIR=$FS_DIR
	OBJ_ENDPOINT=$OBJ_ENDPOINT
	OBJ_BUCKET=$OBJ_BUCKET
	ENABLE_TLS=$(bool_str "$ENABLE_TLS")
	TLS_CERT=$TLS_CERT
	TLS_KEY=$TLS_KEY
	DOMAIN=$DOMAIN
	USE_CERTBOT=$(bool_str "$USE_CERTBOT")
	CERTBOT_EMAIL=$CERTBOT_EMAIL
	API_KEY=$(bool_str "$API_KEY")
	CLEANUP=$(bool_str "$CLEANUP")
	CLEANUP_RETENTION=$CLEANUP_RETENTION
	CLEANUP_INTERVAL=$CLEANUP_INTERVAL
	SDK=$(bool_str "$SDK")
	EOF
}

write_quadlets() {
	step_line "Generating systemd Quadlet files in $QUADLET_DIR/"

	as_root "cat > $QUADLET_DIR/mosaico.network" <<-EOF
	[Unit]
	Description=Mosaico internal container network

	[Network]
	EOF

	# Only the embedded arrangement has a database unit. An external instance is
	# nobody's service here, so nothing is generated for it: it is a connection
	# string in the environment file and nothing more.
	if [ "$PG_MODE" = "embedded" ]; then
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
	fi

	# Storage and TLS each contribute lines to [Container]. The unit is assembled
	# in a variable so that a disabled feature adds nothing at all, rather than
	# leaving a blank line behind.
	#
	# --host is mandatory here: mosaicod binds the loopback address by default,
	# and rootful Podman publishes a port by DNAT'ing it to the container's
	# address, which a process listening on 127.0.0.1 inside the container never
	# sees. The port is passed explicitly so that it cannot drift from the
	# PublishPort line below.
	#
	# TLS and API key enforcement are command-line switches, not configuration
	# keys: without them the daemon ignores the material and the keys in the env
	# file and serves plain, unauthenticated traffic.
	exec_args="run --host 0.0.0.0 --port $MOSAICOD_PORT"
	[ "$ENABLE_TLS" -eq 1 ] && exec_args="$exec_args --tls"
	[ "$API_KEY" -eq 1 ] && exec_args="$exec_args --api-key"

	container="[Container]
Exec=$exec_args
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
		# Read-only: the daemon only ever reads this material. No extra port is
		# published: the TLS challenge is answered by certbot on the host, not by
		# anything inside this container, so nothing has to reach it.
		container="$container
Volume=$TLS_DIR:/certs:ro,Z"
	fi

	# The ordering and the dependency exist only where there is a local unit to
	# depend on. Keeping them for an external database would leave mosaicod
	# requiring a service that was never generated, and systemd refuses to start a
	# unit whose Requires= cannot be resolved.
	unit="[Unit]
Description=Mosaico Daemon"
	if [ "$PG_MODE" = "embedded" ]; then
		unit="$unit
After=mosaico-postgres.service
Requires=mosaico-postgres.service"
	fi

	as_root "cat > $QUADLET_DIR/mosaicod.container" <<-EOF
	$unit

	$container

	[Service]
	Restart=on-failure

	[Install]
	WantedBy=multi-user.target
	EOF
}

# Installs the host-side CLI shim, which makes `mosaicod ...` on the host behave
# like a native binary by forwarding into the container, re-injecting the
# installer's env file so the CLI sees the same configuration as the daemon.
#
# The work itself needs root — the containers belong to root's podman, and the
# env file is readable only by root — but the wrapper re-executes itself under
# sudo instead of refusing, so `mosaicod ...` works from an unprivileged shell.
# See the COMMANDS section of the man page.
#
# There is no container health check, and none is possible: `podman exec` needs a
# running container, so the CLI only works while the daemon is up.
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
	SELF="/usr/local/bin/mosaicod"

	# 1. Re-exec under sudo when called unprivileged. Without this, podman would
	#    resolve the container name in the caller's own rootless namespace, where
	#    the daemon does not exist, and report it as missing even while the daemon
	#    is running — an error that says nothing about the real problem. The full
	#    path is used because sudo's secure_path excludes /usr/local/bin on Fedora
	#    and RHEL. No loop guard is needed: sudo is invoked without -u, so the
	#    re-executed copy always passes this check.
	if [ "$(id -u)" -ne 0 ]; then
	    if ! command -v sudo >/dev/null 2>&1; then
	        echo "mosaicod: needs root privileges, and sudo was not found" >&2
	        exit 1
	    fi
	    exec sudo -- "$SELF" "$@"
	fi

	# 2. TTY handling based on execution environment
	TTY_ARGS=""
	if [ -t 0 ] && [ -t 1 ]; then
	    TTY_ARGS="-it"
	fi

	# 3. Load environment variables dynamically from the installer's env file
	ENV_ARGS=""
	if [ -f "$ENV_FILE" ]; then
	    ENV_ARGS="--env-file=$ENV_FILE"
	fi

	# 4. Forward execution to podman exec with loaded environment
	exec podman exec $TTY_ARGS $ENV_ARGS mosaicod mosaicod "$@"
	WRAPPER_EOF
	as_root "chmod +x $CLI_WRAPPER"
}

# Documents the host-side surface of the installation — the two commands, the
# systemd units, where things live and how to remove everything — on the machine
# itself, so the installer's final output does not have to list commands that
# may change. Anything version-dependent is left to the online documentation.
#
# The page itself is not written here: it is $MAN_PAGE_NAME in the installer's
# repository, which keeps a hundred lines of roff out of this script and lets it
# be reviewed and rendered on its own. It is installed under
# /usr/local/share/man, which is on the default manpath. mosaicod(1) and
# mosaico-installer(8) are `.so` stubs pointing at the single mosaico(7) page, so
# `man` finds it under any of the three names.

# Puts the page in a temporary file and echoes its path, or returns 1 when it
# could not be obtained. A checkout is preferred over the network so that a local
# edit is what gets installed, and so that testing does not depend on the branch
# being pushed; when the script was piped in, $0 is not a file and only the
# download applies.
fetch_man_page() {
	_man_src=""
	if [ -f "$0" ]; then
		_man_local="$(dirname "$0")/$MAN_PAGE_NAME"
		[ -r "$_man_local" ] && _man_src="$_man_local"
	fi

	_man_tmp="$(mktemp 2>/dev/null)" || return 1

	if [ -n "$_man_src" ]; then
		cat "$_man_src" > "$_man_tmp" 2>> "$LOG_FILE" || { rm -f "$_man_tmp"; return 1; }
	elif command_exists curl; then
		curl -fsSL "$MAN_PAGE_URL" -o "$_man_tmp" 2>> "$LOG_FILE" || { rm -f "$_man_tmp"; return 1; }
	elif command_exists wget; then
		wget -qO "$_man_tmp" "$MAN_PAGE_URL" 2>> "$LOG_FILE" || { rm -f "$_man_tmp"; return 1; }
	else
		rm -f "$_man_tmp"
		return 1
	fi

	[ -s "$_man_tmp" ] || { rm -f "$_man_tmp"; return 1; }

	# The page carries a placeholder rather than a version of its own: the version
	# that matters is the installer's, and stamping it in here keeps the two from
	# drifting apart.
	if sed "s/@SCRIPT_VERSION@/$SCRIPT_VERSION/g" "$_man_tmp" > "$_man_tmp.stamped" 2>> "$LOG_FILE"; then
		mv "$_man_tmp.stamped" "$_man_tmp"
	else
		rm -f "$_man_tmp.stamped"
	fi

	printf '%s' "$_man_tmp"
}

install_man_page() {
	if is_dry_run; then
		step_line "Installing man page in $MAN_PAGE"
		echo "  ${DIM}(dry-run)${RESET} fetch $MAN_PAGE_NAME (from this directory, or $MAN_PAGE_URL)"
		echo "  ${DIM}(dry-run)${RESET} install it as $MAN_PAGE"
		echo "  ${DIM}(dry-run)${RESET} write $MAN_LINK_CLI and $MAN_LINK_INSTALLER"
		echo "  ${DIM}(dry-run)${RESET} refresh the man page index (mandb)"
		return 0
	fi

	# The only step allowed to fail without failing the installation: everything
	# the page describes is already installed and working, and the same text is
	# online. A host with no outbound network is the usual reason to get here.
	if ! _man_file="$(fetch_man_page)"; then
		warn "could not obtain $MAN_PAGE_NAME from $MAN_PAGE_URL — 'man mosaico' will not be available. Everything else is installed; see $DOCS_URL."
		return 0
	fi

	step_line "Installing man page in $MAN_PAGE"

	as_root "install -d -m 755 $MAN_DIR/man1 $MAN_DIR/man7 $MAN_DIR/man8"
	as_root "install -m 644 '$_man_file' $MAN_PAGE"
	rm -f "$_man_file"

	as_root "printf '.so man7/mosaico.7\n' > $MAN_LINK_CLI"
	as_root "printf '.so man7/mosaico.7\n' > $MAN_LINK_INSTALLER"
	as_root "chmod 644 $MAN_LINK_CLI $MAN_LINK_INSTALLER"

	MAN_PAGE_INSTALLED=1

	# Refreshing the index is a convenience, not a requirement: the page is
	# already readable, and minimal systems may ship no mandb at all.
	if command_exists mandb; then
		as_root_ignore_errors "mandb -q"
	fi
}

# `restart` rather than `start`: re-running the installer rewrites the Quadlet
# units and the env file, and `start` on an already-running service is a no-op,
# so the new configuration would silently never be applied.
start_service() {
	name="$1"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} systemctl restart $name"
		return 0
	fi

	verb="Starting"
	if $sh_c "systemctl is-active --quiet $name" >> "$LOG_FILE" 2>&1; then
		verb="Restarting"
	fi

	step "$verb $name..."
	if $sh_c "systemctl restart $name" >> "$LOG_FILE" 2>&1; then
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

# Re-running the installer with --pg-host against a host that had the embedded
# database would otherwise leave that container running and supervised, pointing
# at data nothing reads any more. The volume is kept: it is the old database, and
# switching back has to find it there.
drop_embedded_postgres() {
	[ "$PG_MODE" = "external" ] || return 0

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} remove any embedded PostgreSQL unit left from a previous run"
		return 0
	fi

	as_root_capture "test -f $QUADLET_DIR/mosaico-postgres.container && echo yes" \
		| grep -q '^yes$' || return 0

	step_line "Removing the embedded PostgreSQL container of the previous installation"
	as_root_ignore_errors "systemctl stop mosaico-postgres.service"
	as_root_ignore_errors "podman rm -f mosaico-postgres"
	as_root_ignore_errors "rm -f $QUADLET_DIR/mosaico-postgres.container"
	warn "the embedded database was removed; its data is still in the mosaico-postgres-data volume, which was left in place."
}

# Non-fatal: a probe from the host cannot prove what the container will manage,
# and the tools it needs may not be installed. It is here because a wrong host or
# a closed port is the likeliest mistake in this configuration, and saying so now
# is clearer than the daemon's own failure a few steps later.
check_external_postgres() {
	step "Checking the PostgreSQL instance at $PG_HOST:$PG_PORT..."

	if is_dry_run; then
		step_ok "skipped (dry-run)"
		return 0
	fi

	# Both probes run unprivileged: they only open a socket, and pg_isready reports
	# a server as accepting connections without authenticating, so neither of them
	# sees the password.
	if command_exists pg_isready; then
		if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -t 5 >> "$LOG_FILE" 2>&1; then
			step_ok "Accepting connections"
		else
			step_ok "unreachable"
			warn "pg_isready could not reach $PG_HOST:$PG_PORT from this host. The installation continues, but mosaicod will fail to start if the database is not reachable from the container."
		fi
	elif command_exists nc; then
		if nc -z -w 5 "$PG_HOST" "$PG_PORT" >> "$LOG_FILE" 2>&1; then
			step_ok "Port open"
		else
			step_ok "unreachable"
			warn "nothing is listening on $PG_HOST:$PG_PORT as seen from this host. The installation continues, but mosaicod will fail to start if the database is not reachable from the container."
		fi
	else
		step_ok "skipped (no pg_isready or nc on this host)"
	fi

	if [ "$PG_HOST_IS_LOCAL" -eq 1 ]; then
		warn "PostgreSQL is on this machine, so the container reaches it as $PG_HOST_IN_CONTAINER: it has to listen on an address other than the host loopback (listen_addresses) and accept the container network in pg_hba.conf. Passing the host's LAN address as --pg-host avoids this."
	fi
}

# Brings up whatever the database arrangement needs before the daemon starts. The
# daemon-reload is here rather than in start_postgres because it has to happen in
# both cases: it is what makes systemd see the units just written.
prepare_database() {
	as_root "systemctl daemon-reload"

	if [ "$PG_MODE" = "embedded" ]; then
		start_postgres
	else
		check_external_postgres
	fi
}

start_postgres() {
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

# Mints the master API key. This cannot be done while writing the env file: a key
# is a database row created by mosaicod itself, and `manage` is the permission at
# the top of the hierarchy (read + write + delete + key management). Re-running
# the installer reuses the key already on disk instead of piling up new ones.
create_master_api_key() {
	[ "$API_KEY" -eq 1 ] || return 0

	step "Creating master API key..."

	if is_dry_run; then
		echo
		echo "  ${DIM}(dry-run)${RESET} podman exec mosaicod mosaicod api-key create --permissions manage"
		return 0
	fi

	if as_root_capture "test -f '$SECRETS_DIR/master_api_key' && echo yes" | grep -q '^yes$'; then
		MASTER_API_KEY="$(as_root_capture "cat '$SECRETS_DIR/master_api_key'")"
		step_ok "Reused"
		return 0
	fi

	MASTER_API_KEY="$(as_root_capture "podman exec --env-file=$MOSAICOD_ENV_FILE mosaicod \
		mosaicod api-key create --permissions manage --description 'Master key created by mosaico-installer'" \
		| tr -d '\r\n')"

	if [ -z "$MASTER_API_KEY" ]; then
		echo
		printf "${RED}Error:${RESET} the daemon did not return an API key. See %s for the full output.\n" "$LOG_FILE" >&2
		exit 1
	fi

	as_root "umask 077 && printf '%s' '$MASTER_API_KEY' > '$SECRETS_DIR/master_api_key'"
	step_ok "Done"
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

# Reads a single key from the install record, or nothing when the file or the key
# is absent. `grep -s` keeps a missing file quiet, and the `|| true` keeps a
# missing key from tripping `set -e`.
read_install_conf() {
	as_root_capture "grep -s '^$1=' $DATA_DIR/install.conf | cut -d= -f2-" || true
}

do_uninstall() {
	print_logo
	echo "${YELLOW}Executing Mosaico uninstall script...${RESET}"
	echo

	# Recover what was recorded at install time, so the wipe hint below names the
	# storage actually in use rather than the default. Keys missing from the record
	# (or an installation made by an older installer) leave the defaults in place.
	if ! is_dry_run; then
		recorded="$(read_install_conf FS_DIR)"
		if [ -n "$recorded" ]; then FS_DIR="$recorded"; fi
		recorded="$(read_install_conf STORE_BACKEND)"
		if [ -n "$recorded" ]; then STORE_BACKEND="$recorded"; fi
		# Same reason as the storage keys above: the hint at the end must not offer
		# to delete a database volume that was never created, nor stay silent about
		# an external instance this command does not touch.
		recorded="$(read_install_conf PG_MODE)"
		if [ -n "$recorded" ]; then PG_MODE="$recorded"; fi
		recorded="$(read_install_conf PG_HOST)"
		if [ -n "$recorded" ]; then PG_HOST="$recorded"; fi
		recorded="$(read_install_conf PG_PORT)"
		if [ -n "$recorded" ]; then PG_PORT="$recorded"; fi
		recorded="$(read_install_conf PG_DB)"
		if [ -n "$recorded" ]; then PG_DB="$recorded"; fi
	fi

	as_root_ignore_errors "systemctl stop mosaicod.service"
	as_root_ignore_errors "systemctl stop mosaico-postgres.service"
	as_root_ignore_errors "podman rm -f mosaicod"
	as_root_ignore_errors "podman rm -f mosaico-postgres"
	as_root_ignore_errors "rm -f $QUADLET_DIR/mosaico-postgres.container $QUADLET_DIR/mosaicod.container $QUADLET_DIR/mosaico.network"
	as_root_ignore_errors "systemctl daemon-reload"
	as_root_ignore_errors "rm -f $CLI_WRAPPER"
	# The hook only ever restarts mosaicod.service, so it is dead weight once the
	# service is gone and would fail on every future renewal. The certificate
	# itself is deliberately left in place: it may be in use by something else on
	# this host, and revoking it is not this installer's call.
	as_root_ignore_errors "rm -f $RENEWAL_HOOK"
	# Only ever created by this installer, so removing it cannot take anything the
	# user put there first — unlike the certificate above.
	as_root_ignore_errors "rm -rf $SDK_VENV"
	as_root_ignore_errors "rm -f $INSTALLER_PATH"
	as_root_ignore_errors "rm -f $MAN_PAGE $MAN_LINK_CLI $MAN_LINK_INSTALLER"
	if command_exists mandb; then
		as_root_ignore_errors "mandb -q"
	fi

	echo
	echo "${GREEN}${BOLD}  Mosaico services have been successfully removed.${RESET}"
	echo
	echo "  Removed binaries:"
	echo "    $CLI_WRAPPER"
	echo "    $INSTALLER_PATH"
	echo
	echo "  Removed man page:"
	echo "    $MAN_PAGE"
	echo
	# Only the volume this installer actually creates is listed: naming one that was
	# never created makes `podman volume rm` fail on it. TLS material lives under
	# $SECRETS_DIR, which the first command below already removes.
	volumes="mosaico-postgres-data"

	echo "  To completely wipe all remaining data and secrets from this system,"
	echo "  execute the following commands:"
	echo
	echo "${BOLD}    sudo rm -rf $SECRETS_DIR $DATA_DIR/install.conf${RESET}"
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "${BOLD}    sudo rm -rf $FS_DIR${RESET}"
	fi
	# The volume exists only where the database was embedded. For an external
	# instance there is nothing local to remove, and dropping the schema is the
	# operator's call on a server this installer does not own.
	if [ "$PG_MODE" = "embedded" ]; then
		echo "${BOLD}    sudo podman volume rm $volumes${RESET}"
	fi
	if [ "$PG_MODE" != "embedded" ]; then
		echo
		echo "  The PostgreSQL instance at $PG_HOST:$PG_PORT is not touched by these"
		echo "  commands: drop the '$PG_DB' database there if you want the metadata gone."
	fi
	if [ "$STORE_BACKEND" != "fs" ]; then
		echo
		echo "  Dataset frames stored in the object store bucket are not touched by"
		echo "  these commands and must be removed there."
	fi
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

	# With TLS only the certified name is advertised: the daemon does answer on
	# every address of the host, but a client connecting to a bare IP would fail
	# certificate validation, so listing those addresses would be misleading.
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

	if [ "$PG_MODE" = "external" ]; then
		echo
		echo "  Database: PostgreSQL at $PG_HOST:$PG_PORT/$PG_DB as $PG_USER"
		echo "  ${DIM}Not managed by this installer — backups and upgrades are yours.${RESET}"
	fi

	echo
	echo "  Security credentials saved to $SECRETS_DIR/"
	if [ -n "$MASTER_API_KEY" ]; then
		echo "  ${VIOLET}➜${RESET}  Master API Key:  $(printf '%s' "$MASTER_API_KEY" | cut -c1-29)..."
		echo "     ${DIM}Full key: $SECRETS_DIR/master_api_key${RESET}"
	elif [ "$API_KEY" -eq 0 ]; then
		# Worth stating plainly: the daemon now answers on every address of the
		# host, so "no API key" is a reachable, unauthenticated endpoint.
		echo
		echo "  ${YELLOW}Note:${RESET} API keys are not required — anyone who can reach port"
		echo "        $MOSAICOD_PORT can read and write data. Re-run the installer with"
		echo "        --api-key to require them."
	fi

	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo
		if [ "$USE_CERTBOT" -eq 1 ]; then
			echo "  TLS enabled with a Let's Encrypt certificate, copied to:"
		else
			echo "  TLS enabled with the certificate you provided, copied to:"
		fi
		echo "    $TLS_DIR/cert.pem"
		echo "    $TLS_DIR/key.pem"
		if [ "$USE_CERTBOT" -eq 1 ]; then
			echo "  ${DIM}Renewal is automatic, via certbot and $RENEWAL_HOOK.${RESET}"
			echo "  ${YELLOW}Keep port 443 open${RESET} — every renewal repeats the TLS challenge."
		else
			echo "  ${DIM}Replace those two files and run 'systemctl restart mosaicod.service'"
			echo "  to install renewed certificates.${RESET}"
		fi
	fi

	if [ "$CLEANUP" -eq 1 ]; then
		echo
		echo "  Cleanup routine enabled — $(cleanup_summary)."
		echo "  ${DIM}$CLEANUP_DOCS_URL${RESET}"
	fi

	if [ "$SDK" -eq 1 ]; then
		echo
		echo "  Python SDK ($SDK_PACKAGE) installed in $SDK_VENV:"
		echo "    ${BOLD}. $SDK_VENV/bin/activate${RESET}"
	fi

	echo
	if [ "$MAN_PAGE_INSTALLED" -eq 1 ]; then
		echo "  Installed commands, file locations and how to uninstall:"
		echo "    ${BOLD}man mosaico${RESET}"
	else
		# The page could not be fetched, so pointing at `man mosaico` would send the
		# user to a page that is not there.
		echo "  Installed commands, file locations and how to uninstall:"
		echo "    ${BOLD}$MAN_PAGE_URL${RESET}"
	fi
	echo
	echo "  Documentation: ${DIM}$DOCS_URL${RESET}"
	echo
}

# --- Main execution ---

do_install() {
	if [ "$NON_INTERACTIVE" -eq 1 ]; then
		print_logo "Unattended Setup"
		validate_non_interactive
	else
		if ! has_tty; then
			fatal "no terminal available for interactive setup. Re-run with -y and the required flags (see --help)."
		fi
		print_logo "Interactive Setup"
		configure_interactive
	fi

	# After the configuration is complete either way, and before it is shown: the
	# host the container will use is part of what the summary has to report.
	derive_pg_container_host
	print_summary
	[ "$NON_INTERACTIVE" -eq 1 ] || confirm_summary

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
	obtain_certificate
	install_tls_material
	write_secrets
	write_install_conf
	# Before write_quadlets: it decides which units exist, so a leftover database
	# unit has to be gone before the new set is written and reloaded.
	drop_embedded_postgres
	write_quadlets
	install_cli_wrapper
	prepare_database
	start_mosaicod
	create_master_api_key
	# After the service exists and is running: the hook restarts it, so installing
	# it earlier would write a hook pointing at a unit that is not there yet.
	install_renewal_hook
	install_sdk
	install_installer
	install_man_page

	echo
	if is_dry_run; then
		echo "${YELLOW}Dry run complete — nothing was installed or changed.${RESET}"
	else
		print_success
	fi
}

parse_args "$@"
apply_pairings
# Before validate_flags: checking that a private key exists means reading a
# root-only path, which needs the escalation helper already in place.
setup_sh_c
validate_flags

if [ "$UNINSTALL" -eq 1 ]; then
	do_uninstall
else
	do_install
fi
