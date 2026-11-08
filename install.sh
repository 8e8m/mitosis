#!/bin/sh
# Installs mitosis: the program (bin/mitosis) and its celmag directory (digests + layers).
#
#   ./install.sh                       user install: ~/.local/bin, data in $XDG_DATA_HOME/mitosis/celmag
#   TARGET=/usr/local ./install.sh     bin in /usr/local/bin, data in /usr/local/share/mitosis/celmag
#   TARGET=/usr DATADIR=/etc/celmag ./install.sh
#   COPY=1 ./install.sh                copy instead of symlinking into this checkout (packagers)
#   DONTCARE=1 ./install.sh            skip the dependency checks
#
# mitosis finds the celmag directory through MITOSIS_EVAL_PATH (colon-separated, first wins) or,
# when that is unset, the XDG locations (see `mitosis --eval-path`).  DATADIR has to be on that
# path, and this script checks that at the end.
set -eu
cd "$(dirname "$0")"

die() { printf '%s\n' "$@" >&2; exit 2; }
HINT="Add DONTCARE=1 to the environment, if you know what you're doing."

DONTCARE="${DONTCARE:-0}"
if [ "$DONTCARE" = 0 ]; then
    command -v tclsh >/dev/null 2>&1 ||
        die "TCL not installed (no tclsh in PATH), need >=TCL8.6." "" "$HINT"
    command -v sha256sum >/dev/null 2>&1 ||
        die "sha256sum not installed (no sha256sum in PATH), you need GNU coreutils or an executable alias." "" "$HINT"
    TCLv=$(echo 'puts [info tclversion]' | tclsh)
    [ "$(echo $TCLv | tr -d .)" -ge 86 ] 2>/dev/null ||
        die "need >=TCL8.6, found: ${TCLv:-nothing}. please check:" \
            "echo 'puts [info tclversion]' | tclsh" "" "$HINT"
    echo "Found TCL $TCLv, we expect 8.6 however later versions probably work."
fi

# no TARGET means a user install, with data where mitosis looks first by default (XDG)
if [ -z "${TARGET:-}" ]; then
    TARGET="$HOME/.local"
    DATADIR="${DATADIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mitosis/celmag}"
else
    DATADIR="${DATADIR:-$TARGET/share/mitosis/celmag}"
fi

echo "Installing  To: $TARGET/bin"
echo "Data Directory: $DATADIR"

if [ "${COPY:-0}" != 1 ] && [ -d "$DATADIR" ] && [ ! -L "$DATADIR" ]; then
    die "$DATADIR is a real directory, not touching it." \
        "Remove it first, or use COPY=1 to copy into it."
fi

chmod +x mitosis.claude.tcl
mkdir -pv "$TARGET/bin" "$(dirname "$DATADIR")"
if [ "${COPY:-0}" = 1 ]; then
    cp -v mitosis.claude.tcl "$TARGET/bin/mitosis"
    mkdir -pv "$DATADIR"
    cp -Rv celmag/. "$DATADIR/"
else
    ln -sfv "$PWD/mitosis.claude.tcl" "$TARGET/bin/mitosis"
    ln -sfnv "$PWD/celmag" "$DATADIR"
fi

case ":$PATH:" in
    *":$TARGET/bin:"*) ;;
    *":$TARGET/bin/:"*) ;;
    *) echo "note: $TARGET/bin is not in PATH." ;;
esac

if [ -n "${MITOSIS_EVAL_PATH:-}" ]; then
    echo "note: MITOSIS_EVAL_PATH is set; make sure it includes $DATADIR."
else
    "$TARGET/bin/mitosis" --eval-path 2>/dev/null | grep -Fxq -- "$DATADIR" ||
        echo "note: $DATADIR is not on mitosis's default search path;" \
             "export MITOSIS_EVAL_PATH=\"$DATADIR\" (colon-separated, first wins)."
fi
