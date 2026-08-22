# lib.sh — helpers shared by build-local.sh and the vm/ scripts.
# Sourced, not executed. Every caller cds to the repo root first.

# One top-level scalar field out of a BlueBuild recipe:  recipe_field <file> <key>
# Anchored at column 0 so it only ever matches the recipe's own header, never an
# indented module key.
recipe_field() {
  sed -n "s/^$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" | head -1
}

# The localhost image ref a recipe builds to: <name>:<image-version>.
#
# DERIVED, NEVER HARDCODED. The Fedora bump is automated
# (.github/workflows/fedora-version-bump.yml) and rewrites `image-version` in
# recipes/ and nothing else. A tag hardcoded here would keep saying 44 while the
# recipe built 45 — so the local build would tag new bits with the old version,
# and the vm/ scripts would go looking for that tag and either use a lying name or
# pick up a genuinely stale image still in podman storage. That would land on the
# one build that matters most: the VM validation of a major version bump, before
# the laptop is allowed anywhere near it.
recipe_tag() {
  _rt_name=$(recipe_field "$1" name)
  _rt_ver=$(recipe_field "$1" image-version)
  if [ -z "$_rt_name" ] || [ -z "$_rt_ver" ]; then
    echo "lib.sh: could not read name/image-version from $1" >&2
    return 1
  fi
  printf '%s:%s\n' "$_rt_name" "$_rt_ver"
}
