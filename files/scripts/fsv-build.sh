#!/usr/bin/env bash
# fsv — the 3D file system visualizer — built from source at image build time.
# Runs AFTER the dnf module that declares its runtime libraries (see recipe.yml).
#
# WHAT THIS IS
#
# fsv is the open clone of SGI's `fsn` ("fusion"), the 3D file manager from
# Jurassic Park's "It's a Unix system! I know this!" scene. fsn itself was IRIX
# only and was never open-sourced — the only way to run the actual article is
# IRIX on real hardware or under MAME's Indy/Indigo^2 emulation. fsv is the
# reimplementation, and it is the closest thing that exists on Linux.
#
# WHY IT IS BUILT HERE RATHER THAN INSTALLED
#
# Checked 2026-08-20: fsv is not in the Fedora 44 repos, not on Flathub, and not
# in any COPR. There is no package to install, on this distro or any other
# current one. Building it is the only option, which is why this is the ONLY
# thing in this image compiled from source — every other §1 exception buys a
# package from a repo, this one has no repo to buy from.
#
# WHICH FORK, AND WHY NOT UPSTREAM
#
# The original (Daniel Richard G., 1999, fsv.sourceforge.net) is GTK2 and
# OpenGL 1.x immediate mode, and has not been touched since ~2001. Fedora 44
# does still ship gtk2-2.24.33, so it would in fact build — that is a trap, not
# an opportunity. It is a dead codebase against a dead toolkit, and the fixed
# function pipeline it draws with is gone from core-profile GL.
#
# jabl/fsv is the live fork: ported to GTK3, and to OpenGL 3.1 core with GLSL
# 1.40 shaders and VBOs. Last commit 2026-03-26. There is GTK4 work in it too,
# but master still links gtk+-3.0, which is what this builds.
#
# Pinned to a COMMIT, never a branch (DESIGN §5, same rule as base-image). The
# tarball is content-addressed by that SHA, so no separate checksum is carried:
# GitHub's generated archives are not guaranteed byte-stable over time, and a
# hash pin on one would eventually fail the build for no security gain. The
# cglm tarball below IS hash-pinned, because that hash comes from WrapDB and is
# checked by meson against a mirror that does promise stability.
#
# THREE THINGS UPSTREAM GETS WRONG THAT THIS SCRIPT WORKS AROUND
#
#   1. `ninja install` DOES NOT INSTALL FSV. src/meson.build calls
#      executable('fsv', ...) with no `install: true`, so the only install
#      targets in the whole project belong to the cglm subproject — it would
#      scatter libcglm.so, its headers and its .pc file into /usr/local and
#      leave no fsv anywhere. The README's "sudo ninja -C builddir install" is
#      simply wrong for this fork. The binary is installed by hand below.
#
#   2. IT DOES NOT COMPILE ON GCC 16. gui.c passes real callbacks to parameters
#      declared `void (*callback)( )`. Under C23 — GCC 16's default — that is a
#      prototype taking ZERO arguments rather than "unspecified", so every
#      gui_button_add()/gui_entry_add() call site is a hard
#      -Wincompatible-pointer-types error. -Dc_std=gnu17 restores the old
#      meaning. Upstream builds on Ubuntu and has not hit this yet.
#
#   3. A DIRECTORY ARGUMENT SILENTLY DOES NOTHING. main() parses `rootdir` with
#      getopt_long and then ALSO hands argc/argv to g_application_run(). The
#      GtkApplication is created with default flags, so GApplication sees an
#      unconsumed non-option argument, prints "This application can not open
#      files" and returns without ever emitting ::activate — no window, exit 1,
#      and the root_dir it just parsed is thrown away. Verified: unpatched,
#      `fsv /etc` produces no window at all. Since fsv has already done its own
#      option parsing by that point, GApplication has nothing legitimate to do
#      with argv, so it is passed (0, NULL). One line, and it makes `fsv /etc`,
#      the .desktop's %f, and "Open with" from Thunar all work.
#
# BUILD DEPENDENCIES ARE INSTALLED AND THEN REMOVED AGAIN. gtk3-devel alone
# drags in a couple of hundred MB of -devel packages, and on an ostree image
# that is not a one-off cost — it is re-downloaded on every update. They are
# removed by exact name delta (see below) rather than `dnf autoremove`, which
# would be free to take orphans belonging to earlier modules.
#
# The RUNTIME libraries are deliberately NOT handled here. They are declared as
# ordinary packages in recipe.yml, which does two jobs: it marks them
# user-installed so the removal below cannot possibly drag them out, and it
# stops a base-image bump from silently dropping one and leaving a broken fsv
# in an otherwise-green build.
#
# gdk-pixbuf2-modules-extra is the non-obvious one and it is NOT optional: every
# toolbar button and file-type glyph in fsv is an XPM compiled into the binary
# (src/xmaps/*.xpm), and gdk-pixbuf's XPM loader lives in that subpackage. It is
# present in the base image today, but without it fsv starts with a chrome-less
# window and a stream of `Image type "xpm" is not supported` warnings.
#
# KNOWN COSMETIC NOISE, not worth patching: fsv asks for the legacy X11 cursor
# name `x_cursor`, which no modern cursor theme ships, so it prints
# "Unable to load x_cursor from the cursor theme" once at startup.
set -euo pipefail

readonly FSV_COMMIT='2465b055b18ac48e76b5046a8b74a81c892d1524'  # master, 2026-03-26
readonly FSV_URL="https://codeload.github.com/jabl/fsv/tar.gz/${FSV_COMMIT}"
readonly RETRIES=4

# Build-only. Everything else fsv needs to compile — gcc, make, ninja-build,
# pkgconf — is already a permanent part of the image (see the toolchain block in
# recipe.yml), so it is not listed here and must not be removed below.
readonly BUILD_DEPS=(
  meson
  gtk3-devel
  gdk-pixbuf2-devel
  libepoxy-devel
  glib2-devel     # glib-compile-resources, for the GLSL shader gresource
  gettext         # msgfmt/xgettext, which meson's i18n module looks for
  # Needed for the HEADER ONLY, and undeclared by meson.build. ogl.c still has a
  # leftover `#include <GL/glu.h> /* gluPickMatrix( ) */` from the OpenGL 1.x
  # days; no glu* symbol is referenced anywhere in src/ any more, and ldd on the
  # result confirms the binary does not link libGLU. So this is build-time only
  # and there is no matching runtime package. Without it the build dies on
  # ogl.c with "fatal error: GL/glu.h: No such file or directory" — 66 of 73
  # objects in, which is a slow way to find out.
  mesa-libGLU-devel
)

# Runtime. Asserted, not installed — if one of these is missing the recipe is
# wrong and the build should stop, not quietly produce an fsv that cannot start.
readonly RUNTIME_DEPS=(
  gtk3
  libepoxy
  gdk-pixbuf2
  gdk-pixbuf2-modules-extra
)

for pkg in "${RUNTIME_DEPS[@]}" gcc ninja-build pkgconf; do
  if ! rpm -q "$pkg" >/dev/null 2>&1; then
    echo "fsv-build: $pkg is not installed — this module is running before the dnf module that provides it" >&2
    exit 1
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- fetch source

tarball="$tmp/fsv.tar.gz"
got=0
for ((attempt = 1; attempt <= RETRIES; attempt++)); do
  if curl --fail --location --silent --show-error \
          --connect-timeout 15 --max-time 180 \
          --output "$tarball" "$FSV_URL"; then
    got=1
    break
  fi
  echo "fsv-build: attempt $attempt failed: $FSV_URL" >&2
  # Linear backoff, same shape as rpmfusion-release-retry.sh: codeload failures
  # here are far more likely to be transient rate-limiting or a blip than a
  # permanently bad URL, and the URL is a pinned SHA so retrying is always right.
  if [[ $attempt -lt $RETRIES ]]; then
    sleep $((attempt * 5))
  fi
done

if [[ $got -ne 1 ]]; then
  echo "fsv-build: exhausted $RETRIES attempts fetching $FSV_URL" >&2
  exit 1
fi

src="$tmp/src"
mkdir -p "$src"
tar -xzf "$tarball" -C "$src" --strip-components=1
echo "fsv-build: unpacked jabl/fsv at ${FSV_COMMIT:0:12}"

# ------------------------------------------------------------------- cglm wrap
#
# fsv's top-level meson.build does dependency('cglm', fallback: ['cglm', ...]),
# but the repo ships no subprojects/ directory at all, so a plain `meson setup`
# dies with "Attempted to resolve subproject without subprojects directory
# present". Fedora has no cglm package either (checked 2026-08-20; neither cglm
# nor cglm-devel exists in the repos), so there is nothing to satisfy it with.
#
# This is `meson wrap install cglm` done offline: the same file WrapDB would
# have written, committed here so the version and hash are pinned in git rather
# than resolved from whatever WrapDB serves on build day. source_fallback_url is
# WrapDB's own mirror of the tarball and is what the hash is really promising.

mkdir -p "$src/subprojects"
cat > "$src/subprojects/cglm.wrap" <<'WRAP'
[wrap-file]
directory = cglm-0.9.6
source_url = https://github.com/recp/cglm/archive/refs/tags/v0.9.6.tar.gz
source_filename = cglm-0.9.6.tar.gz
source_hash = be5e7d384561eb0fca59724a92b7fb44bf03e588a7eae5123a7d796002928184
source_fallback_url = https://github.com/mesonbuild/wrapdb/releases/download/cglm_0.9.6-1/cglm-0.9.6.tar.gz
wrapdb_version = 0.9.6-1

[provide]
cglm = cglm_dep
WRAP

# ------------------------------------------------------------------ patch (3.)

before="$(grep -c 'g_application_run(G_APPLICATION (app), argc, argv)' "$src/src/fsv.c" || true)"
if [[ $before -ne 1 ]]; then
  echo "fsv-build: expected exactly 1 g_application_run(argc, argv) call in src/fsv.c, found $before" >&2
  echo "fsv-build: upstream has changed — re-check whether the directory-argument bug still needs patching" >&2
  exit 1
fi
sed -i 's/g_application_run(G_APPLICATION (app), argc, argv)/g_application_run(G_APPLICATION (app), 0, NULL)/' \
  "$src/src/fsv.c"

# ----------------------------------------------------------- install build deps
#
# Snapshot package NAMES (not NEVRAs) either side of the transaction, so the
# removal below takes exactly what was added and never something that was merely
# upgraded in place.

mapfile -t names_before < <(rpm -qa --qf '%{NAME}\n' | sort -u)
dnf install -y "${BUILD_DEPS[@]}"
mapfile -t names_after < <(rpm -qa --qf '%{NAME}\n' | sort -u)
mapfile -t added < <(comm -13 \
  <(printf '%s\n' "${names_before[@]}") \
  <(printf '%s\n' "${names_after[@]}"))
echo "fsv-build: ${#added[@]} package(s) added for the build"

# ------------------------------------------------------------------------ build
#
# -Ddefault_library=static applies to the cglm subproject: left shared it builds
# a libcglm.so that fsv links against by rpath, which would have to be installed
# alongside it. Static gives a single self-contained ~275 KB binary and puts
# nothing else on the system.

meson setup "$src/builddir" "$src" \
  --buildtype=release \
  -Dc_std=gnu17 \
  -Ddefault_library=static
ninja -C "$src/builddir"

[[ -x "$src/builddir/src/fsv" ]] || {
  echo 'fsv-build: build produced no src/fsv binary' >&2
  exit 1
}

# ---------------------------------------------------------------------- install

install -Dm0755 "$src/builddir/src/fsv" /usr/bin/fsv
# Legacy pixmaps path on purpose: the only icon upstream ships is a 64x64 XPM,
# and /usr/share/pixmaps/<name>.xpm is the freedesktop fallback that icon lookup
# still honours. Same gdk-pixbuf XPM loader requirement as the toolbar glyphs.
install -Dm0644 "$src/src/xmaps/fsv-icon.xpm" /usr/share/pixmaps/fsv.xpm

# Written here rather than in files/system because fsv is entirely script-owned
# — binary, icon and launcher all come from this one file and all go away with
# it. %f is safe only because of patch (3.) above; without it a launcher that
# passes an argument would open nothing at all.
install -d /usr/share/applications
cat > /usr/share/applications/fsv.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=fsv
GenericName=3D File System Visualizer
Comment=Browse the filesystem as 3D geometry
Exec=fsv %f
TryExec=fsv
Icon=fsv
Terminal=false
Categories=System;FileTools;
Keywords=filesystem;disk;usage;3d;visualizer;fsn;
StartupNotify=false
StartupWMClass=fsv
DESKTOP

# ------------------------------------------------- remove build deps and verify

if [[ ${#added[@]} -gt 0 ]]; then
  # --no-autoremove so the transaction is bounded by the list computed above and
  # cannot cascade into packages earlier modules installed.
  dnf remove -y --no-autoremove "${added[@]}"
fi

# The check that matters, and the reason it runs AFTER the removal: fsv links
# against libraries that only recipe.yml keeps alive, so this is what would
# catch the removal having taken one of them with it.
missing="$(ldd /usr/bin/fsv | grep 'not found' || true)"
if [[ -n $missing ]]; then
  echo 'fsv-build: /usr/bin/fsv has unresolved libraries after build-dep removal:' >&2
  echo "$missing" >&2
  exit 1
fi

echo "fsv-build: installed /usr/bin/fsv ($(stat -c '%s' /usr/bin/fsv) bytes) from jabl/fsv ${FSV_COMMIT:0:12}"
