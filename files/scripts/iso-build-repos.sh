#!/usr/bin/env bash
# Put Fedora's repo definitions back in /etc/yum.repos.d so an installer ISO can
# be built from this image.
#
# WHY. Fedora 45 moved the shipped .repo files out of /etc/yum.repos.d and into
# /usr/share/dnf5/repos.d; the /etc directory now ships EMPTY, there only so an
# admin can override a vendor repo by dropping a file of the same name in it.
# dnf5 reads both, /etc winning per filename, so for dnf nothing changed.
#
# bootc-image-builder's `anaconda-iso` type did not get the memo. To build the
# installer it has to depsolve ~22 packages of its own (lorax-templates-generic,
# grub2-*, shim-x64, xorriso, squashfs-tools, skopeo, plus glibc/coreutils/systemd
# for the build root) and it reads the repo configuration out of the image at the
# OLD path only. With an empty /etc/yum.repos.d it finds no repositories at all
# and every one of those 22 packages fails to resolve:
#
#     No match for argument: coreutils
#     No match for argument: lorax-templates-generic
#     error: cannot build manifest: cannot depsolve: ... missing packages: ...
#
# which is confusing, because the list makes it look like the IMAGE is broken.
# It is not: the image never needs those packages. Only the ISO build does.
#
# Upstream: osbuild/image-builder#2704 (open as of 2026-11-12). The maintainer's
# answer is that anaconda-iso is deprecated in favour of the generic bootc ISO
# path, so a fix there is unlikely. --force-repo lands in image-builder 89; the
# quay.io bootc-image-builder:latest we build with is 87 and has no such flag.
# So the only lever available is the image's own /etc/yum.repos.d.
#
# SYMLINKS, not copies: the content must not drift from what fedora-repos ships,
# and an identical filename in /etc is exactly the override dnf5 expects, so the
# repo is still defined once and `dnf repolist` does not double up.
#
# Only `fedora` and `fedora-updates` are linked. That is what the depsolve needs,
# and it keeps the blast radius at zero: both files are byte-identical to the
# vendor copy they shadow, so no repo changes state. Linking the rest would drag
# `updates-archive` (enabled, a very large baseurl repo with cost=10000) into
# every ISO depsolve for nothing.
#
# When Fedora or bootc-image-builder fixes this, delete this script and the
# matching assertion in image-assert.sh. It fails the build rather than
# no-opping if its premise stops holding.
set -euo pipefail

VENDOR_DIR=/usr/share/dnf5/repos.d
ETC_DIR=/etc/yum.repos.d
REPOS=(fedora.repo fedora-updates.repo)

echo "iso-build-repos: exposing Fedora repo definitions in $ETC_DIR"
mkdir -p "$ETC_DIR"

for f in "${REPOS[@]}"; do
  if [ -e "$ETC_DIR/$f" ] || [ -L "$ETC_DIR/$f" ]; then
    # Already there — either a future Fedora moved them back, or a module above
    # dropped its own override. Either way it is not ours to replace.
    echo "  keep   $ETC_DIR/$f (already present)"
    continue
  fi
  if [ ! -f "$VENDOR_DIR/$f" ]; then
    echo "!! $VENDOR_DIR/$f does not exist and $ETC_DIR/$f is absent." >&2
    echo "!! Fedora has moved its repo files again. The installer ISO build will" >&2
    echo "!! depsolve against nothing and report ~22 missing packages. Find the" >&2
    echo "!! new path (rpm -ql fedora-repos) and update this script." >&2
    exit 1
  fi
  ln -s "../../usr/share/dnf5/repos.d/$f" "$ETC_DIR/$f"
  echo "  link   $ETC_DIR/$f -> $VENDOR_DIR/$f"
done

# The point of the exercise is that the two repo IDs the ISO depsolve needs are
# reachable through the old path. Assert on the IDs, not on the filenames: a link
# that resolves to the wrong file would pass a filename check.
for id in fedora updates; do
  if ! grep -rhq "^\[$id\]" "$ETC_DIR"/*.repo 2>/dev/null; then
    echo "!! repo id [$id] is not defined anywhere under $ETC_DIR" >&2
    exit 1
  fi
done

echo "iso-build-repos: [fedora] and [updates] are visible at the old path"
