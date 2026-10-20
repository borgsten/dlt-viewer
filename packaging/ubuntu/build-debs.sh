#!/usr/bin/env bash
# Build Ubuntu .deb packages of dlt-viewer for the Ubuntu release this runs
# on (taken from /etc/os-release; 24.04 noble and 26.04 resolute are tested).
#
# By default everything (viewer, commander, bundled plugins, libqdlt, headers
# and qdlt.pc) goes into a single dlt-viewer package. --split builds separate
# dlt-viewer, dlt-commander, dlt-viewer-plugins, libqdlt<M.m> and libqdlt-dev
# packages instead.
#
# The source tree is copied from the git checkout (tracked plus untracked,
# non-ignored files, so local changes are included) together with
# packaging/ubuntu/debian, and built with dpkg-buildpackage.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  -o, --output DIR    Where to put the .deb files (default: <repo>/dist)
  -j, --jobs N        Parallel build jobs (default: nproc-2)
      --split         Build separate packages instead of one bundle
      --no-strip      Keep the debug info in the packaged binaries
      --no-lto        Build without link time optimisation (much faster)
      --install-deps  Install missing build dependencies with sudo apt-get
  -h, --help          Show this help
EOF
}

OUTPUT=
JOBS=$(( $(nproc) > 3 ? $(nproc) - 2 : 1 ))
SPLIT=0
NOSTRIP=
export DLT_NO_LTO=0
INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)    OUTPUT=$2; shift 2 ;;
        -j|--jobs)      JOBS=$2; shift 2 ;;
        --split)        SPLIT=1; shift ;;
        --no-strip)     NOSTRIP=" nostrip"; shift ;;
        --no-lto)       DLT_NO_LTO=1; shift ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != ubuntu ]]; then
    echo "This builds Ubuntu packages and must run on Ubuntu (found ${PRETTY_NAME:-unknown})." >&2
    echo "On other hosts, run it inside an ubuntu:24.04 or ubuntu:26.04 container." >&2
    exit 1
fi
case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    *) echo "Warning: Ubuntu $VERSION_ID is untested (24.04 and 26.04 are)" >&2 ;;
esac
CODENAME=$VERSION_CODENAME

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
OUTPUT=$(realpath -m "${OUTPUT:-$REPO/dist}")
WORK="$REPO/build/deb-work"
DEBIAN_SRC="$REPO/packaging/ubuntu/debian"

# --- Version ----------------------------------------------------------------
# <version.h>-<commit>[.dirty].<codename>, e.g. 2.31.0-029a485c.resolute.
# The part after the "-" is the Debian revision, so no "~" is needed and the
# file name stays readable.
version_field() {
    sed -n "s/^#define $1 \"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$REPO/src/version.h"
}
MAJOR=$(version_field PACKAGE_MAJOR_VERSION)
MINOR=$(version_field PACKAGE_MINOR_VERSION)
PATCH=$(version_field PACKAGE_PATCH_LEVEL)
SOVER="$MAJOR.$MINOR"
SHA=$(git -C "$REPO" rev-parse --short=8 HEAD)
DIRTY=
git -C "$REPO" diff --quiet HEAD -- || DIRTY=.dirty
VERSION="$MAJOR.$MINOR.$PATCH-$SHA$DIRTY.$CODENAME"
MAINTAINER="${DEBFULLNAME:-$(git -C "$REPO" config user.name || echo Unknown)} <${DEBEMAIL:-$(git -C "$REPO" config user.email || echo unknown@localhost)}>"

echo "dlt-viewer $VERSION ($([[ $SPLIT -eq 1 ]] && echo split || echo bundle), $([[ $DLT_NO_LTO -eq 1 ]] && echo "no LTO" || echo LTO), $JOBS jobs)"

# --- Stage the source tree --------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/src" "$OUTPUT"
# Tracked and untracked-but-not-ignored files, minus deletions in the
# worktree and our own output directory.
mapfile -d '' FILES < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard)
for f in "${FILES[@]}"; do
    [[ "$REPO/$f" == "$OUTPUT"/* ]] && continue
    [[ -e "$REPO/$f" || -L "$REPO/$f" ]] && printf '%s\0' "$f"
done | tar -C "$REPO" --null -T - -cf - | tar -xf - -C "$WORK/src"

D="$WORK/src/debian"
mkdir -p "$D"
cp -r "$DEBIAN_SRC/rules" "$DEBIAN_SRC/copyright" "$DEBIAN_SRC/source" "$DEBIAN_SRC/cmake" "$D/"
if [[ $SPLIT -eq 1 ]]; then
    CONTROL=control-split.in
    cp "$DEBIAN_SRC"/install/*.install "$D/"
    mv "$D/libqdlt.install" "$D/libqdlt$SOVER.install"
else
    CONTROL=control-bundle.in
    cat "$DEBIAN_SRC"/install/*.install > "$D/dlt-viewer.install"
fi
sed -e "s/@SOVER@/$SOVER/g" -e "s/@MAINTAINER@/$MAINTAINER/g" \
    "$DEBIAN_SRC/$CONTROL" > "$D/control"
cat > "$D/changelog" <<EOF
dlt-viewer ($VERSION) $CODENAME; urgency=medium

  * Local build of $(git -C "$REPO" describe --always --dirty --tags 2>/dev/null || echo "$SHA").

 -- $MAINTAINER  $(date -R)
EOF

# --- Build dependencies -----------------------------------------------------
if ! command -v dpkg-checkbuilddeps >/dev/null || ! (cd "$WORK/src" && dpkg-checkbuilddeps); then
    if [[ $INSTALL_DEPS -eq 1 ]]; then
        SUDO=
        [[ $(id -u) -eq 0 ]] || SUDO=sudo
        $SUDO apt-get install -y --no-install-recommends dpkg-dev
        $SUDO apt-get build-dep -y --no-install-recommends "$WORK/src"
    else
        echo "Missing build dependencies. Install them with --install-deps, or:" >&2
        echo "  sudo apt-get install dpkg-dev && sudo apt-get build-dep $WORK/src" >&2
        exit 1
    fi
fi

# --- Build ------------------------------------------------------------------
(cd "$WORK/src" && DEB_BUILD_OPTIONS="parallel=$JOBS nocheck$NOSTRIP" dpkg-buildpackage -b -uc -us)

shopt -s nullglob
DEBS=("$WORK"/*.deb)
[[ ${#DEBS[@]} -gt 0 ]] || { echo "No packages produced" >&2; exit 1; }
for deb in "${DEBS[@]}"; do
    rm -f "$OUTPUT/$(basename "$deb" | cut -d_ -f1)"_*.deb
done
mv "${DEBS[@]}" "$OUTPUT/"

# Detached debug symbols (from dh_strip) are kept out of dist/, extracted in
# the build directory for later debugging of exactly this build.
DDEBS=("$WORK"/*.ddeb)
if [[ ${#DDEBS[@]} -gt 0 ]]; then
    DEBUG_DIR="$REPO/build/debug/$VERSION"
    rm -rf "$DEBUG_DIR"
    mkdir -p "$DEBUG_DIR"
    for ddeb in "${DDEBS[@]}"; do dpkg-deb -x "$ddeb" "$DEBUG_DIR"; done
    mv "${DDEBS[@]}" "$DEBUG_DIR/"
fi
echo
echo "Packages in $OUTPUT:"
for deb in "${DEBS[@]}"; do echo "  $(basename "$deb")"; done
if [[ -n "${DEBUG_DIR:-}" ]]; then
    echo "Debug symbols in $DEBUG_DIR, use with:"
    echo "  gdb -iex 'set debug-file-directory $DEBUG_DIR/usr/lib/debug' dlt-viewer"
fi
