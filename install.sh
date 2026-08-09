#!/bin/sh
# Installs the LV1 to REAPER importer and everything it needs, on macOS and
# Linux.
#
# Puts the two REAPER extensions (ReaPack and ReaImGui) in place, installs the
# importer itself, and checks for Node.js. After it finishes, restart REAPER
# and load the action.
#
# Nothing here needs sudo: everything is written inside REAPER's own resource
# folder, which belongs to your user account.
#
#   ./install.sh
#   ./install.sh --resource-path ~/some/portable/REAPER
#   ./install.sh --dry-run
#
# Plain POSIX sh on purpose, so it runs on a stock macOS and on any Linux
# without asking anyone to install a shell first.

set -eu

REPO='malik-malassis/lv1-to-reaper'
RESOURCE_PATH=''
DRY_RUN=0

step() { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    ! %s\n' "$1" >&2; }
good() { printf '    ok %s\n' "$1"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--resource-path) RESOURCE_PATH="${2:-}"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) warn "unknown option: $1"; exit 1 ;;
	esac
done

# ── REAPER must not be running ────────────────────────────────────────────
# Extensions are only read at start-up, so installing into a running REAPER
# looks like it worked and then changes nothing.
if pgrep -x reaper >/dev/null 2>&1 || pgrep -x REAPER >/dev/null 2>&1; then
	echo
	if [ "$DRY_RUN" -eq 1 ]; then
		warn "REAPER is running. A real run would stop here."
	else
		warn "REAPER is running. Quit it completely, then run this again."
		exit 1
	fi
fi

# ── where REAPER keeps its files ──────────────────────────────────────────
if [ -z "$RESOURCE_PATH" ]; then
	case "$(uname -s)" in
		Darwin) RESOURCE_PATH="$HOME/Library/Application Support/REAPER" ;;
		*)      RESOURCE_PATH="$HOME/.config/REAPER" ;;
	esac
fi

if [ ! -d "$RESOURCE_PATH" ]; then
	echo
	warn "REAPER's resource folder was not found at: $RESOURCE_PATH"
	info "Open REAPER, go to Options > Show REAPER resource path in explorer/finder,"
	info "then run this script again with:  ./install.sh --resource-path \"<that folder>\""
	exit 1
fi

step "REAPER folder: $RESOURCE_PATH"

# ── which build to download ───────────────────────────────────────────────
# Both extensions name their files reaper_<name>-<arch>.<ext>, so one lookup
# serves both.
OS="$(uname -s)"
MACHINE="$(uname -m)"
case "$OS" in
	Darwin)
		EXT='dylib'
		case "$MACHINE" in
			arm64) ARCH='arm64' ;;
			x86_64) ARCH='x86_64' ;;
			*) warn "unsupported Mac architecture: $MACHINE"; exit 1 ;;
		esac
		;;
	Linux)
		EXT='so'
		case "$MACHINE" in
			x86_64|amd64) ARCH='x86_64' ;;
			aarch64|arm64) ARCH='aarch64' ;;
			armv7l|armv7) ARCH='armv7l' ;;
			i686|i386) ARCH='i686' ;;
			*) warn "unsupported Linux architecture: $MACHINE"; exit 1 ;;
		esac
		;;
	*)
		warn "$OS is not supported by this script. On Windows, use install.ps1."
		exit 1
		;;
esac

step "System: $OS $ARCH"

PLUGINS="$RESOURCE_PATH/UserPlugins"
SCRIPTS="$RESOURCE_PATH/Scripts/lv1-reaper"

if command -v curl >/dev/null 2>&1; then
	DL='curl'
elif command -v wget >/dev/null 2>&1; then
	DL='wget'
else
	warn "neither curl nor wget is available, cannot download anything"
	exit 1
fi

# A partial download must never replace a working file, so write to a
# temporary name and move it into place only once it is complete.
fetch() {
	url="$1"; dest="$2"
	if [ "$DRY_RUN" -eq 1 ]; then info "would download $url"; return 0; fi
	mkdir -p "$(dirname "$dest")"
	if [ "$DL" = 'curl' ]; then
		curl -fsSL "$url" -o "$dest.part"
	else
		wget -q "$url" -O "$dest.part"
	fi
	mv "$dest.part" "$dest"
}

# ── extensions ────────────────────────────────────────────────────────────
for spec in "ReaPack:cfillion/reapack:reaper_reapack-$ARCH.$EXT" \
            "ReaImGui:cfillion/reaimgui:reaper_imgui-$ARCH.$EXT"; do
	name="${spec%%:*}"
	rest="${spec#*:}"
	repo="${rest%%:*}"
	file="${rest#*:}"
	if [ -f "$PLUGINS/$file" ]; then
		step "$name already installed"
		continue
	fi
	step "Installing $name"
	fetch "https://github.com/$repo/releases/latest/download/$file" "$PLUGINS/$file"
	good "$file"
done

# imgui.lua is optional: the importer works without it, through ReaImGui's
# older interface. Installing it lets the modern one be used instead.
IMGUI_LUA="$RESOURCE_PATH/Scripts/ReaTeam Extensions/API/imgui.lua"
if [ ! -f "$IMGUI_LUA" ]; then
	step "Installing the ReaImGui Lua module"
	if fetch 'https://github.com/cfillion/reaimgui/releases/latest/download/imgui.lua' "$IMGUI_LUA" 2>/dev/null; then
		good "imgui.lua"
	else
		warn "could not fetch imgui.lua, continuing without it (the importer does not need it)"
	fi
fi

# ── the importer ──────────────────────────────────────────────────────────
step "Installing the importer"
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
for f in LV1_Track_Importer.lua lv1_fetch.js; do
	if [ -f "$HERE/$f" ]; then
		# Running from a clone: use the files sitting next to this script.
		if [ "$DRY_RUN" -eq 0 ]; then
			mkdir -p "$SCRIPTS"
			cp "$HERE/$f" "$SCRIPTS/$f"
		fi
		good "$f (from this folder)"
	else
		fetch "https://raw.githubusercontent.com/$REPO/main/$f" "$SCRIPTS/$f"
		good "$f (downloaded)"
	fi
done

# A result file left over from an older install would be read as if it were
# fresh, so clear it.
if [ "$DRY_RUN" -eq 0 ]; then
	rm -f "$SCRIPTS/lv1_tracks.json" "$SCRIPTS/lv1_fetch.log"
fi

# ── Node.js ───────────────────────────────────────────────────────────────
# Deliberately not installed automatically: it is a system-wide program, and
# a script that silently installs those is a script you should not trust.
step "Checking Node.js"
if command -v node >/dev/null 2>&1; then
	good "$(node --version) at $(command -v node)"
else
	warn "Node.js is not installed. The importer needs it to reach your console."
	info "Download it from https://nodejs.org and run the installer,"
	if [ "$OS" = 'Darwin' ]; then
		info "or, if you use Homebrew:  brew install node"
	else
		info "or install the nodejs package from your distribution."
	fi
fi

# ── what is left to do ────────────────────────────────────────────────────
echo
step "Done. Two things left:"
info "1. Start REAPER."
info "2. Actions > Show action list > New action > Load ReaScript,"
info "   then pick:"
info "   $SCRIPTS/LV1_Track_Importer.lua"
echo
info "Give it a keyboard shortcut while you are there. Instructions and"
info "troubleshooting: https://github.com/$REPO"
[ "$DRY_RUN" -eq 1 ] && { echo; warn "dry run: nothing was actually written"; }
exit 0
