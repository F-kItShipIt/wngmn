#!/bin/bash
#
# Installs wngmn.app into /Applications and links the executable onto $PATH.
#
# For machines you own. It builds from this checkout rather than fetching anything, and it
# ad-hoc signs, so the result is trusted by this Mac and no other — distributing it would
# need a Developer ID certificate and notarisation, which this script deliberately does not
# set up.
#
# Why /Applications rather than leaving it in build/: TCC keys a permission grant to the
# bundle's path as well as its identity, so a bundle that moves is a new subject and the
# grant is asked for again. An installed app stays put.
#
#   Scripts/install.sh              install (or upgrade) to /Applications
#   PREFIX=~/Applications Scripts/install.sh
#   Scripts/install.sh --uninstall
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Default to wherever it is already installed rather than to a fixed path. Installing a
# second bundle somewhere else is not an upgrade: the shell keeps launching the old one via
# its existing link, so the new build appears to have no effect at all — and because TCC
# keys permission grants to the bundle path, the copy that does get launched later starts
# with none of them.
if [ -z "${PREFIX:-}" ]; then
    for candidate in "$HOME/Applications" /Applications; do
        if [ -d "$candidate/wngmn.app" ]; then PREFIX="$candidate"; break; fi
    done
fi
# Falling back to a directory we cannot write to fails the install at the very last step,
# after a full release build. Prefer /Applications, but only if it is actually writable —
# on a managed or non-admin Mac it is not, and ~/Applications works identically for TCC.
if [ -z "${PREFIX:-}" ]; then
    if [ -w /Applications ]; then PREFIX="/Applications"; else PREFIX="$HOME/Applications"; fi
fi

# Likewise for the link: replace the one on $PATH instead of adding a second.
if [ -z "${BINDIR:-}" ]; then
    existing="$(command -v wngmn || true)"
    [ -n "$existing" ] && BINDIR="$(dirname "$existing")"
fi
# Likewise: pick somewhere writable rather than defaulting to /usr/local/bin and telling the
# user to re-run under sudo. /usr/local/bin does not exist by default on Apple Silicon and is
# root-owned where it does; ~/.local/bin always works, at the cost of a PATH line.
if [ -z "${BINDIR:-}" ]; then
    for candidate in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then BINDIR="$candidate"; break; fi
    done
fi
BINDIR="${BINDIR:-$HOME/.local/bin}"
APP="$PREFIX/wngmn.app"
LINK="$BINDIR/wngmn"

if [ "${1:-}" = "--uninstall" ]; then
    echo "==> Removing $APP and $LINK"
    rm -rf "$APP"
    rm -f "$LINK"
    echo
    echo "    Permissions granted to it are still remembered. To clear them:"
    echo "      tccutil reset Microphone local.wngmn.Wngmn"
    echo "      tccutil reset ScreenCapture local.wngmn.Wngmn"
    echo "    The stored access token is left alone:"
    echo "      ~/Library/Application Support/wngmn/token"
    exit 0
fi

./Scripts/build-app.sh

echo "==> Installing to $APP"
# Replaced wholesale rather than copied over: a stale file left behind from an older build
# inside a signed bundle invalidates the signature, and the failure shows up much later as
# an unexplained permission prompt.
rm -rf "$APP"
mkdir -p "$PREFIX"
cp -R build/wngmn.app "$APP"

echo "==> Linking $LINK"
if mkdir -p "$BINDIR" 2>/dev/null && ln -sf "$APP/Contents/MacOS/wngmn" "$LINK" 2>/dev/null; then
    echo "    $LINK -> $APP/Contents/MacOS/wngmn"
    # A link nothing can resolve is the same as no link. Checked against $PATH rather than
    # assumed, because ~/.local/bin is on almost nobody's PATH by default and the symptom is
    # a bare `wngmn` reporting command not found immediately after a successful install.
    case ":$PATH:" in
        *":$BINDIR:"*) ;;
        *)
            echo
            echo "    NOTE  $BINDIR is not on your PATH, so \`wngmn\` will not resolve yet."
            echo "          Add it, then restart your shell:"
            echo "            echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc"
            ;;
    esac
else
    echo "    Could not write $BINDIR (try: sudo Scripts/install.sh, or set BINDIR)."
    echo "    Not fatal — run it directly:"
    echo "      $APP/Contents/MacOS/wngmn --serve"
fi

cat <<NOTE

==> Installed.

    Two ways to run it, and they differ in a way that matters:

      wngmn --serve --listen
          From a terminal. Permissions are inherited from the terminal app, exactly as
          before. Simplest, and stdout is right there.

      open -a "$APP" --stdout ~/wngmn.log --args --serve --listen
          Through LaunchServices. The parent is launchd rather than your shell, so macOS
          treats Wngmn as its own subject and grants it its own permissions, listed
          under its own name in System Settings. stdout has to be redirected.

    First run of the second form should prompt for Microphone and System Audio Recording.
    If it captures silence instead of prompting, it was denied — check
    System Settings > Privacy & Security, and confirm with:

      wngmn selftest

NOTE
