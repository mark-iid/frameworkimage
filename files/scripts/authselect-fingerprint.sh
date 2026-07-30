#!/usr/bin/env bash
# DESIGN §2/§7: enable fingerprint authentication (Framework 13 reader) so login,
# sudo, and polkit accept fprintd. Runs at image build time.
#
# The base image uses authselect profile `local` (with-silent-lastlog,
# with-mdns4). enable-feature is additive — it preserves those and layers
# fingerprint PAM into the generated /etc/pam.d files. Actual enrollment is
# per-user at runtime (`fprintd-enroll`), not baked (DESIGN §10).
set -euo pipefail

authselect enable-feature with-fingerprint
authselect apply-changes
echo "authselect: with-fingerprint enabled"
