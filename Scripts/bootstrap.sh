#!/bin/bash
#
# One-line installer. Fetches the source, builds it, and puts `wngmn` on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash
#
# It builds on your machine rather than downloading a binary, and that is not laziness.
# A released binary would be ad-hoc signed, so Gatekeeper quarantines it and — worse for this
# tool specifically — the microphone entitlement is not honoured for a signature the local
# machine did not produce. The failure would be silent: Core Audio returns success and hands
# back digital silence. Shipping real binaries needs a Developer ID certificate and
# notarisation. Until then, compiling locally is the only way the permissions actually work.
#
# Knobs, all optional:
#   WNGMN_REF=v1.2.3     branch, tag or commit to install (default: main)
#   PREFIX=~/Applications where wngmn.app goes
#   BINDIR=~/.local/bin   where the `wngmn` link goes
#   WNGMN_KEEP_SRC=1      keep the downloaded source instead of deleting it
#
# To remove it again:
#   curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash -s -- --uninstall
#
set -euo pipefail

REPO="${WNGMN_REPO:-skhan75/wngmn}"
REF="${WNGMN_REF:-main}"
TARBALL="https://codeload.github.com/$REPO/tar.gz/$REF"

say()  { printf '==> %s\n' "$*"; }
warn() { printf '    %s\n' "$*"; }
die()  { printf 'wngmn install: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
#
# Checked before downloading anything. Each of these fails the build several minutes in
# otherwise, with an error that does not name the real cause.

[ "$(uname -s)" = "Darwin" ] || die "this is a macOS tool; uname says $(uname -s)."

macos="$(sw_vers -productVersion)"
if [ "${macos%%.*}" -lt 26 ]; then
    die "needs macOS 26 or newer, found $macos. Package.swift pins it and there is no fallback path."
fi

command -v swift >/dev/null 2>&1 || die \
    "no Swift toolchain on PATH. Install Xcode 26 (or its command line tools), then re-run."

# `swift --version` prints the driver version first and the language version second, so the
# number that matters is the one after "Apple Swift version".
swiftver="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$swiftver" ] || die "could not read a Swift version from \`swift --version\`."
swiftmaj="${swiftver%%.*}"; swiftmin="${swiftver#*.}"
if [ "$swiftmaj" -lt 6 ] || { [ "$swiftmaj" -eq 6 ] && [ "$swiftmin" -lt 2 ]; }; then
    die "needs Swift 6.2 or newer, found $swiftver. The package is swift-tools-version 6.2."
fi

say "macOS $macos, Swift $swiftver — ok"

# ---------------------------------------------------------------- fetch
#
# Downloaded to a temp directory and removed on the way out, including on failure. The build
# products that matter are installed elsewhere; nothing here needs to survive.

work="$(mktemp -d "${TMPDIR:-/tmp}/wngmn-install.XXXXXX")"
cleanup() {
    if [ -n "${WNGMN_KEEP_SRC:-}" ]; then
        printf '    source kept at %s\n' "$work"
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

say "Fetching $REPO @ $REF"
if ! curl -fsSL "$TARBALL" -o "$work/src.tar.gz"; then
    die "could not download $TARBALL — check the ref name and your connection."
fi

tar -xzf "$work/src.tar.gz" -C "$work" || die "the download was not a readable tarball."

# GitHub names the extracted directory <repo>-<ref>, and a ref with a slash in it becomes a
# name we cannot predict. Find it rather than reconstruct it.
src="$(find "$work" -maxdepth 1 -type d -name 'wngmn-*' | head -1)"
[ -n "$src" ] && [ -f "$src/Package.swift" ] || die "the tarball did not contain a wngmn checkout."

# ---------------------------------------------------------------- uninstall
#
# Handled after the fetch because the uninstall logic lives in the repo, so there is exactly
# one copy of it rather than a second one here that drifts.

if [ "${1:-}" = "--uninstall" ]; then
    exec bash "$src/Scripts/install.sh" --uninstall
fi

# ---------------------------------------------------------------- build and install

say "Building (this takes a few minutes on a cold machine)"
bash "$src/Scripts/install.sh"

# ---------------------------------------------------------------- next steps
#
# The install is not usable yet and saying so is the point. A speech model is a hard
# prerequisite, not a lazy download: the run aborts without it rather than transcribing
# silence for the length of a call.

resolved="$(command -v wngmn 2>/dev/null || true)"

cat <<NEXT

==> Installed. Two steps left before it can do anything.

    1. Install the speech model (396 MB, from Apple):

         wngmn install-model --locale en-US

    2. Prove the audio tap actually works:

         wngmn selftest

       This plays a tone and asserts the tap heard it. If it fails, macOS denied System
       Audio Recording. That grant belongs to the app you launch wngmn from, and a denial
       is silent — every Core Audio call still returns success and the stream is digital
       silence. Grant it in System Settings > Privacy & Security.

    Then:

         wngmn --serve

NEXT

if [ -z "$resolved" ]; then
    warn "\`wngmn\` does not resolve on this shell yet — see the PATH note above,"
    warn "or open a new terminal and try again."
fi
