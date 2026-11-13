#!/usr/bin/env bash
# Build fontconfig's system font cache into the image.
#
# WHY. Shipping a font file is not the same as making it findable. fontconfig
# resolves a family name through a per-directory binary cache and only falls back
# to scanning the directory when that cache is absent or stale. The base image
# ships a cache covering the fonts IT had — nine entries — and nothing in this
# recipe regenerated it after adding more. The result on the laptop:
#
#     $ fc-match "Symbols Nerd Font"
#     NotoSans[wght].ttf: "Noto Sans" "Regular"
#
# with SymbolsNerdFont-Regular.ttf sitting in /usr/share/fonts/nerd-fonts, valid,
# and fc-query reading the right family name straight out of it. fc-list saw 67
# font files across 9 families; the same directories scanned with a fresh cache
# yield 539. Every status glyph in waybar rendered as tofu, because style.css
# asks for "Symbols Nerd Font" by name and got a face with no Material Design
# Icon coverage.
#
# WHY IT DOES NOT SELF-HEAL. fontconfig invalidates a cached directory by
# comparing mtimes, and ostree zeroes every mtime under /usr to the epoch at
# commit time. A rebuild that adds a font directory therefore looks no newer than
# the stale cache, so nothing ever rescans and the breakage is permanent until
# someone runs fc-cache by hand. Those same epoch mtimes are what let the cache
# written here survive the commit: ostree zeroes the cache files and the font
# directories alike, and fontconfig accepts a cache that is not older than the
# directory it describes. That is why the base image's own nine entries were
# honoured rather than discarded.
#
# --system-only writes under /usr/lib/fontconfig/cache and touches no home
# directory. That matters beyond tidiness: with a complete system cache
# fontconfig never needs a per-user one for these fonts, so a stale
# ~/.cache/fontconfig cannot bring the bug back for a single account.
# /etc/fonts/fonts.conf lists the system cachedir before the xdg one, so it wins.
#
# MUST RUN AFTER every module that installs a font — the `fonts` module and the
# dnf font packages (carlito, caladea, cascadia-mono). A cache built before them
# is precisely the stale cache this script exists to replace.
set -euo pipefail

# The directory whose caching is the point of the exercise. Checked by name
# rather than trusting fc-cache's exit status, which is 0 for "scanned nothing".
nerd_dir=/usr/share/fonts/nerd-fonts/NerdFontsSymbolsOnly
want="Symbols Nerd Font"

echo "font-cache: rebuilding the system fontconfig cache"
# Captured rather than piped: this script runs under `set -o pipefail`, and the
# greps below must be free to not match without killing the build here.
out=$(fc-cache --force --system-only --verbose 2>&1)

# fc-cache reports one line per directory. "caching, new cache contents: N fonts"
# is what a successful scan of our directory looks like.
if ! printf '%s\n' "$out" | grep -q "^$nerd_dir: caching, new cache contents: [1-9]"; then
  echo "font-cache: FATAL: fc-cache cached no fonts for $nerd_dir" >&2
  echo "font-cache: either the fonts module did not run, or it ran after this" >&2
  printf '%s\n' "$out" | grep -F "$nerd_dir" >&2 || echo "  (no mention of the directory at all)" >&2
  exit 1
fi

# Prove the cache is usable, not merely that fc-cache exited 0. The family name
# is the contract — it is the string waybar's style.css asks for, and a silent
# fallback to another face is the exact failure being fixed.
got=$(fc-match --format='%{family}' "$want")
if [ "$got" != "$want" ]; then
  echo "font-cache: FATAL: '$want' resolves to '$got', not itself" >&2
  exit 1
fi

echo "font-cache: '$want' resolves to itself; $(fc-list | wc -l) font files cached"
