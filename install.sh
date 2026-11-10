#!/bin/sh
# Installs mitosis: bin/mitosis, mitosis(1), and the celmag directory.
#
#   ./install.sh                       user install: ~/.local/bin, manual under
#                                      $XDG_DATA_HOME/man, data under
#                                      $XDG_DATA_HOME/mitosis/celmag
#   TARGET=/usr/local ./install.sh     bin in /usr/local/bin, manual and data
#                                      under /usr/local/share
#   TARGET=/usr DATADIR=/etc/celmag ./install.sh
#   MANDIR=/somewhere/man ./install.sh override the manual hierarchy
#   COPY=1 ./install.sh                copy instead of symlinking (packagers)
#   DONTCARE=1 ./install.sh            skip dependency checks
#
# Mitosis finds its celmag directory through MITOSIS_EVAL_PATH (colon-separated,
# first wins) or its default XDG locations (see `mitosis --eval-path`). DATADIR
# must be on that path; this script checks that at the end.
#
# The manual is installed as MANDIR/man1/mitosis.1. man-db normally derives
# manual paths from PATH, mapping ~/.local/bin to ~/.local/share/man. An
# explicitly set MANPATH overrides that automatic search.
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
    [ "$(echo "$TCLv" | tr -d .)" -ge 86 ] 2>/dev/null ||
        die "need >=TCL8.6, found: ${TCLv:-nothing}. please check:" \
            "echo 'puts [info tclversion]' | tclsh" "" "$HINT"
    echo "Found TCL $TCLv, we expect 8.6 however later versions probably work."
fi

[ -f mitosis.tcl ] || die "mitosis.tcl not found in $(pwd)."
[ -f mitosis.1 ] || die "mitosis.1 not found in $(pwd)."
[ -d celmag ] || die "celmag directory not found in $(pwd)."

# No TARGET means a user install; as root it means a system install instead.
# Keep user data locations XDG-aware, including a custom XDG_DATA_HOME for man.
if [ -z "${TARGET:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        TARGET=/usr/local
        DATADIR="${DATADIR:-/etc/celmag}"
        MANDIR="${MANDIR:-$TARGET/share/man}"
    else
        TARGET="$HOME/.local"
        DATADIR="${DATADIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mitosis/celmag}"
        MANDIR="${MANDIR:-${XDG_DATA_HOME:-$HOME/.local/share}/man}"
    fi
else
    DATADIR="${DATADIR:-$TARGET/share/mitosis/celmag}"
    MANDIR="${MANDIR:-$TARGET/share/man}"
fi
MANUAL_DIR="$MANDIR/man1"

case "$MANDIR" in
    /*) ;;
    *) die "MANDIR must be an absolute path: $MANDIR" ;;
esac

echo
echo "Installing  To: $TARGET/bin"
echo "Manual Page: $MANUAL_DIR/mitosis.1"
echo "Data Directory: $DATADIR"
echo

if [ "${COPY:-0}" != 1 ] && [ -d "$DATADIR" ] && [ ! -L "$DATADIR" ]; then
    die "$DATADIR is a real directory, not touching it." \
        "Remove it first, or use COPY=1 to copy into it."
fi

chmod +x mitosis.tcl
mkdir -pv "$TARGET/bin" "$(dirname "$DATADIR")" "$MANUAL_DIR"
if [ "${COPY:-0}" = 1 ]; then
    cp -v mitosis.tcl "$TARGET/bin/mitosis"
    cp -v mitosis.1 "$MANUAL_DIR/mitosis.1"
    mkdir -pv "$DATADIR"
    cp -Rv celmag/. "$DATADIR/"
else
    ln -sfv "$PWD/mitosis.tcl" "$TARGET/bin/mitosis"
    ln -sfv "$PWD/mitosis.1" "$MANUAL_DIR/mitosis.1"
    ln -sfnv "$PWD/celmag" "$DATADIR"
fi

case ":$PATH:" in
    *":$TARGET/bin:"*) ;;
    *":$TARGET/bin/:"*) ;;
    *) echo "note: $TARGET/bin is not in PATH; add it to use 'mitosis' by name." ;;
esac

# Diagnose MANPATH conflicts where man-db's helper is available.
if [ "${MANPATH+x}" = x ]; then
    case ":${MANPATH}:" in
        *":$MANDIR:"*) ;;
        *) echo "note: MANPATH is set and does not include $MANDIR." \
               "For man-db, append it while retaining the default paths, e.g.:" \
               "export MANPATH=\"$MANDIR:\$MANPATH:\"" ;;
    esac
elif command -v manpath >/dev/null 2>&1; then
    MANPATH_NOW=$(manpath 2>/dev/null || true)
    case ":$MANPATH_NOW:" in
        *":$MANDIR:"*) ;;
        *) echo "note: 'manpath' does not currently include $MANDIR." \
               "Add it to MANPATH; a trailing ':' retains man-db's default paths." ;;
    esac
elif [ "$MANDIR" != "$TARGET/share/man" ]; then
    echo "note: $MANDIR is outside the prefix-derived manual path." \
         "Add it to MANPATH; a trailing ':' retains man-db's default paths."
fi

if [ -n "${MITOSIS_EVAL_PATH:-}" ]; then
    echo "note: MITOSIS_EVAL_PATH is set; make sure it includes $DATADIR."
else
    "$TARGET/bin/mitosis" --eval-path 2>/dev/null | grep -Fxq -- "$DATADIR" ||
        echo "note: $DATADIR is not on mitosis's default search path;" \
             "export MITOSIS_EVAL_PATH=\"$DATADIR\" (colon-separated, first wins)."
fi

cat <<EOF

Consider adding a global .gitignore to your git:

git config --global core.excludesfile $HOME/.gitignore
echo ".mitosis" >> $HOME/.gitignore

Also, make sure to add this to project .gitignore, for non-psychos.
EOF
