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
# - Sets up systemd Quadlet configurations in /etc/containers/systemd/.
# - Generates a random PostgreSQL password on first run and reuses it on
#   subsequent runs — it is never printed to the terminal or the log.
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
# Command-line options
# ==============================================================================
#
# --version <VERSION>
# Use the --version option to install a specific version, for example:
#
#   $ sudo sh install-mosaico.sh --version 0.8.0
#
# --uninstall
# Stops and removes the Mosaico services, leaving stored data in place:
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
# MOSAICO_VERSION
# Same as --version above, settable as an environment variable instead.
#
# ==============================================================================

SCRIPT_VERSION="1.0.0"

# --- Configuration ---

DATA_DIR="/var/lib/mosaico"
QUADLET_DIR="/etc/containers/systemd"
MOSAICO_VERSION="${MOSAICO_VERSION:-latest}"
POSTGRES_IMAGE="docker.io/library/postgres:18"
LOG_FILE="/tmp/mosaico-install-$(id -u).log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="$(mktemp -t mosaico-install.XXXXXX)"

UNINSTALL=0
DRY_RUN="${DRY_RUN:-}"

while [ $# -gt 0 ]; do
	case "$1" in
		--uninstall) UNINSTALL=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--version)
			MOSAICO_VERSION="${2#v}"
			shift
			;;
		-h|--help)
			cat <<-EOF
			Mosaico Installer (v$SCRIPT_VERSION)

			This script installs Mosaico (mosaicod + embedded PostgreSQL) using
			system-level Podman containers supervised by systemd (via Quadlet).
			
			Usage:
			  $ curl -fsSL https://get.mosaico.dev | sh
			  $ mosaico-installer [options]
			
			Options:
			  -h, --help       Show this help message and exit
			  --uninstall      Stop and remove Mosaico services, leaving data in place
			  --dry-run        Print commands without running them
			  --version <tag>  Install a specific image tag (default: latest)
			
			Environment variables:
			  MOSAICO_VERSION  Same as --version
			EOF
			exit 0
			;;
		--*)
			echo "Illegal option $1" >&2
			exit 1
			;;
	esac
	shift $(( $# > 0 ? 1 : 0 ))
done

# --- Helpers ---

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

setup_colors() {
	# Abilita i colori solo se l'output è un terminale reale
	if [ -t 1 ]; then
		RESET=$(printf '\033[0m')
		BOLD=$(printf '\033[1m')
		VIOLET=$(printf '\033[35m')
		GREEN=$(printf '\033[32m')
		YELLOW=$(printf '\033[33m')
		RED=$(printf '\033[31m')
	else
		RESET=""
		BOLD=""
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

user="$(id -un 2>/dev/null || true)"
sh_c="eval"
if [ "$user" != "root" ]; then
	if command_exists sudo; then
		sh_c="sudo -E sh -c"
	elif command_exists su; then
		sh_c="su -c"
	else
		fatal "this installer needs the ability to run commands as root, but neither sudo nor su was found."
	fi
fi

as_root() {
	if is_dry_run; then
		echo "+ (dry-run) $*"
		return 0
	fi
	echo "+ $*"
	if ! $sh_c "$*" >> "$LOG_FILE" 2>&1; then
		echo
		echo "${RED}Error: command failed:${RESET} $*" >&2
		echo "See $LOG_FILE for the full output." >&2
		exit 1
	fi
}

as_root_ignore_errors() {
	if is_dry_run; then
		echo "+ (dry-run) $*"
		return 0
	fi
	echo "+ $*"
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

# --- Install Steps ---

check_systemd() {
	command_exists systemctl || fatal "systemd not found. This installer requires systemd."
}

check_podman() {
	if command_exists podman; then
		return
	fi
	pm="$(get_package_manager)"
	case "$pm" in
		apt)
			as_root "apt-get update -qq"
			as_root "env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq podman < /dev/null"
			;;
		dnf)
			as_root "dnf install -y podman"
			;;
		*)
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
	as_root "install -d -m 700 $DATA_DIR/secrets"
}

generate_db_password() {
	pw_file="$DATA_DIR/secrets/postgres_password"

	if as_root_capture "test -f $pw_file && echo yes" | grep -q '^yes$'; then
		password="$(as_root_capture "cat $pw_file")"
	else
		password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
		as_root "umask 077 && printf '%s' '$password' > $pw_file"
	fi

	as_root "umask 077 && cat > $DATA_DIR/secrets/postgres.env" <<-EOF
	POSTGRES_USER=mosaico
	POSTGRES_DB=mosaico
	POSTGRES_PASSWORD=$password
	EOF

	as_root "umask 077 && cat > $DATA_DIR/secrets/mosaicod.env" <<-EOF
	MOSAICOD_DB_URL=postgresql://mosaico:$password@mosaico-postgres:5432/mosaico
	MOSAICOD_STORE_ENDPOINT=file:///data
	MOSAICOD_STORE_BUCKET=mosaico
	EOF
}

write_quadlets() {
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
	EnvironmentFile=$DATA_DIR/secrets/postgres.env

	[Service]
	Restart=on-failure
	TimeoutStartSec=60

	[Install]
	WantedBy=multi-user.target
	EOF

	as_root "cat > $QUADLET_DIR/mosaicod.container" <<-EOF
	[Unit]
	Description=Mosaico Daemon
	After=mosaico-postgres.service
	Requires=mosaico-postgres.service

	[Container]
	Exec=run
	Image=ghcr.io/mosaico-labs/mosaicod:$MOSAICO_VERSION
	ContainerName=mosaicod
	Network=mosaico.network
	Volume=mosaico-storage:/data:Z
	EnvironmentFile=$DATA_DIR/secrets/mosaicod.env
	PublishPort=6726:6726

	[Service]
	Restart=on-failure

	[Install]
	WantedBy=multi-user.target
	EOF
}

start_user_service() {
	name="$1"
	container="${name%.service}"

	if is_dry_run; then
		echo "+ (dry-run) systemctl start $name"
		return
	fi

	echo "+ systemctl start $name"
	if $sh_c "systemctl start $name" >> "$LOG_FILE" 2>&1; then
		return
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
	start_user_service "mosaico-postgres.service"

	if is_dry_run; then
		echo "+ (dry-run) would wait for PostgreSQL to accept connections"
		return
	fi

	echo "+ waiting for PostgreSQL to accept connections"
	tries=0
	while [ "$tries" -lt 30 ]; do
		if $sh_c "podman exec mosaico-postgres pg_isready -U mosaico" >> "$LOG_FILE" 2>&1; then
			return
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
	start_user_service "mosaicod.service"
	is_dry_run || sleep 3
}

install_installer() {
	if is_dry_run; then
		echo "+ (dry-run) copy installer to /usr/local/bin/mosaico-installer"
		return
	fi

	if [ -f "$0" ] && [ -s "$0" ]; then
		as_root "cp \"$0\" /usr/local/bin/mosaico-installer"
		as_root "chmod +x /usr/local/bin/mosaico-installer"
	else
		as_root "curl -fsSL https://get.mosaico.dev -o /usr/local/bin/mosaico-installer"
		as_root "chmod +x /usr/local/bin/mosaico-installer"
	fi
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
	echo "    ${BOLD}The Data Platform for Robotics and Physical AI${RESET}"
	echo
}

# --- Uninstall ---

do_uninstall() {
	setup_colors
	print_logo
	echo "${YELLOW}Executing Mosaico uninstall script...${RESET}"
	echo

	as_root_ignore_errors "systemctl stop mosaicod.service"
	as_root_ignore_errors "systemctl stop mosaico-postgres.service"
	as_root_ignore_errors "podman rm -f mosaicod"
	as_root_ignore_errors "podman rm -f mosaico-postgres"
	as_root_ignore_errors "rm -f $QUADLET_DIR/mosaico-postgres.container $QUADLET_DIR/mosaicod.container $QUADLET_DIR/mosaico.network"
	as_root_ignore_errors "systemctl daemon-reload"

	echo
	echo "${GREEN}${BOLD}  Mosaico services have been successfully removed.${RESET}"
	echo
	echo "  To completely wipe all remaining data and secrets from this system,"
	echo "  execute the following commands:"
	echo
	echo "${BOLD}    sudo rm -rf $DATA_DIR/secrets${RESET}"
	echo "${BOLD}    sudo podman volume rm mosaico-postgres-data mosaico-storage${RESET}"
	echo
	echo "  To remove the installer itself:"
	echo "${BOLD}    sudo rm -f /usr/local/bin/mosaico-installer${RESET}"
	echo
}

# --- Main execution ---

do_install() {
	setup_colors
	print_logo

	is_dry_run && echo "${YELLOW}# --dry-run: no changes will be made${RESET}"

	if [ "$user" != "root" ]; then
		info "Not running as root — this script will use '$sh_c' for the steps that need it."
		echo
	fi

	check_systemd
	check_podman
	check_quadlet_support
	setup_directories
	generate_db_password
	write_quadlets
	start_postgres
	start_mosaicod
	install_installer

	echo
	if is_dry_run; then
		echo "${YELLOW}Dry run complete — nothing was installed or changed.${RESET}"
	else
		echo
		echo "${GREEN}${BOLD}  Mosaico is up and running!${RESET}"
		echo
		echo "  ${VIOLET}➜${RESET}  Local:    http://127.0.0.1:6726"
		
		# Print local IPs
		if command_exists hostname; then
			for ip in $(hostname -I 2>/dev/null); do
				echo "  ${VIOLET}➜${RESET}  Network:  http://$ip:6726"
			done
		fi

		# Try to fetch public IP quickly (2 seconds timeout)
		if command_exists curl; then
			public_ip=$(curl -s --max-time 2 ifconfig.me 2>/dev/null || true)
			if [ -n "$public_ip" ]; then
				echo "  ${VIOLET}➜${RESET}  Public:   http://$public_ip:6726"
			fi
		fi

		echo
		echo "  Management commands:"
		echo "    ${BOLD}sudo journalctl -u mosaicod -f${RESET}   # View live logs"
		echo "    ${BOLD}sudo systemctl status mosaicod${RESET}   # Check service status"
		echo "    ${BOLD}sudo systemctl restart mosaicod${RESET}  # Restart the daemon"
		echo
		echo "  To remove Mosaico from this system:"
		echo "    ${BOLD}mosaico-installer --uninstall${RESET}"
		echo
	fi
}

if [ "$UNINSTALL" -eq 1 ]; then
	do_uninstall
else
	do_install
fi
