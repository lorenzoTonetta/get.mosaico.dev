#!/bin/sh
set -e
# Mosaico bootstrap.
#
# The single entry point every user runs, whatever the machine: it looks at the
# operating system and hands over to the installer written for it, forwarding
# its arguments untouched. This is the file https://get.mosaico.dev is meant to
# serve, so the documented one-liner keeps working on any host:
#
#   $ curl -fsSL https://get.mosaico.dev | sh
#   $ curl -fsSL https://get.mosaico.dev | sh -s -- --dry-run
#   $ curl -fsSL https://get.mosaico.dev | sudo sh -s -- -y --api-key
#
# Options, prompts and exit codes belong to the installers: `--help`,
# `--dry-run`, `--uninstall` and the rest are passed through and documented
# there.
#
# Environment variables
# ==============================================================================
#
# MOSAICO_BASE_URL   Where the installers are fetched from. Override it to test a
#                    branch without editing this file.
#
# ==============================================================================

BOOTSTRAP_VERSION="1.0.0"

MOSAICO_BASE_URL="${MOSAICO_BASE_URL:-https://raw.githubusercontent.com/mosaico-labs/get.mosaico.dev/main}"
LINUX_INSTALLER="install.sh"
MACOS_INSTALLER="install-macos.sh"

VM_RECIPE="  brew install lima
  limactl start --name=mosaico --cpus 2 --memory 4 --disk 20 template://ubuntu-lts
  limactl shell mosaico
  curl -fsSL https://get.mosaico.dev | sudo sh"

# --- Helpers ---

if [ -t 1 ]; then
	BOLD="$(printf '\033[1m')"
	RED="$(printf '\033[31m')"
	DIM="$(printf '\033[2m')"
	RESET="$(printf '\033[0m')"
else
	BOLD=""
	RED=""
	DIM=""
	RESET=""
fi

fatal() {
	printf "${RED}Error:${RESET} %s\n" "$1" >&2
	exit 1
}

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

# Both are tried, not one or the other: curl can be present and still fail on a
# proxy or a missing CA bundle.
download() {
	_url="$1"
	_dest="$2"

	if command_exists curl; then
		curl -fsSL "$_url" -o "$_dest" && return 0
	fi
	if command_exists wget; then
		wget -qO "$_dest" "$_url" && return 0
	fi
	if ! command_exists curl && ! command_exists wget; then
		fatal "neither curl nor wget was found, so the installer cannot be downloaded. Install one of them and run this again."
	fi
	return 1
}

# --- Platform dispatch ---

# WSL reports Linux and takes the Linux path; what it may lack is systemd, which
# the Linux installer checks for itself.
os="$(uname -s 2>/dev/null || echo unknown)"

case "$os" in
	Linux)
		installer="$LINUX_INSTALLER"
		;;
	Darwin)
		installer="$MACOS_INSTALLER"
		;;
	CYGWIN* | MINGW* | MSYS* | Windows_NT)
		fatal "Windows is not supported directly. Install WSL2 with an Ubuntu distribution and run this command inside it."
		;;
	*)
		fatal "unsupported operating system: $os. Mosaico is installed on Linux (systemd) and on macOS; see https://docs.mosaico.dev."
		;;
esac

# --- Obtaining the installer ---

# A sibling file wins over the download, so an edit in a checkout is what runs.
# Piped in, $0 is not a file and only the download applies.
script=""
if [ -f "$0" ]; then
	sibling="$(dirname "$0")/$installer"
	[ -r "$sibling" ] && script="$sibling"
fi

tmp=""
cleanup() {
	[ -n "$tmp" ] && rm -f "$tmp"
	return 0
}
trap cleanup EXIT HUP INT TERM

if [ -z "$script" ]; then
	url="$MOSAICO_BASE_URL/$installer"
	tmp="$(mktemp 2>/dev/null)" || fatal "could not create a temporary file to download the installer into."

	printf "${DIM}Fetching %s for %s...${RESET}\n" "$installer" "$os"

	if ! download "$url" "$tmp" || [ ! -s "$tmp" ]; then
		if [ "$os" = "Darwin" ]; then
			printf "${RED}Error:${RESET} could not obtain %s from %s.\n" "$installer" "$url" >&2
			printf "\nA native macOS installation may not be available yet. Mosaico runs on a Mac\ninside a Linux VM, which the Linux installer supports as an ordinary host:\n\n%s\n\n" "$VM_RECIPE" >&2
			printf "The daemon then answers on localhost:6726 from macOS. See %s.\n" "https://docs.mosaico.dev" >&2
			exit 1
		fi
		fatal "could not obtain $installer from $url. Check the network connection and the DNS resolution of raw.githubusercontent.com, then run this again."
	fi

	script="$tmp"
fi

# --- Handover ---

# Run rather than exec, so the trap still removes the temporary file. The
# installer's exit code is passed on unchanged. It is given a real path, which is
# also what its copy of itself in /usr/local/bin is made from.
status=0
sh "$script" "$@" || status=$?
exit "$status"
