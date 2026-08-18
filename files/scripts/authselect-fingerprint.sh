#!/usr/bin/env bash
# DESIGN §2/§7: scope fingerprint authentication to the SCREEN LOCK only.
# Runs at image build time.
#
# This script used to run `authselect enable-feature with-fingerprint`, which put
#
#     auth  sufficient  pam_fprintd.so
#
# at the top of system-auth — the stack that login (greetd), sudo and polkit all
# include. That had a consequence that was not obvious:
#
#   `sufficient` short-circuits the stack on success, so pam_unix never runs and
#   PAM never captures a password token. `pam_gnome_keyring`, which sits in
#   /etc/pam.d/greetd and unlocks the login keyring FROM that token, therefore had
#   nothing to work with. The documented workaround (SETUP §6) was to give the
#   login keyring a BLANK password — "Use Unsafe Storage" — which left every
#   Secret Service credential (Evolution's M365 OAuth tokens, Nextcloud, VS Code)
#   encrypted with the empty string, readable by any process running as the user.
#
# So the global feature is deliberately NOT enabled. Instead /etc/pam.d/gtklock
# adds pam_fprintd for the locker alone (files/system/etc/pam.d/gtklock). That
# keeps the finger where the convenience actually is — the screen unlock, which
# happens dozens of times a day — while login goes back through pam_unix, which
# means a real password is captured and the keyring can be properly encrypted.
#
# Deliberate consequences:
#   * greetd login now wants your password. Once per boot. This is the one that
#     matters — it is what captures the token pam_gnome_keyring needs.
#   * Screen unlock still takes the finger (or the password as fallback).
#
# SUDO IS NOT AMONG THEM, as of 2026-08-18. This script used to claim sudo had
# to fall back to a password too, on the grounds that "a fingerprint is not a
# secret, it can be lifted and compelled". That reasoning was never mark's call
# and does not reflect his preference; it also conflated two separate things.
# The keyring breakage is specific to the LOGIN path — sudo does not unlock the
# login keyring and never did — so the finger can be scoped to sudo at no cost
# to any of the above. See files/scripts/sudo-fingerprint.sh, which runs after
# this one and does exactly that. What stays off is the GLOBAL feature, because
# it cannot be enabled for sudo without also enabling it for login.
#
# Enrollment is unaffected and still per-user at runtime (`fprintd-enroll`);
# nothing about the reader or fprintd itself is disabled here.
#
# NOTE FOR EXISTING MACHINES: /etc/authselect is machine-owned, so this build-time
# state does NOT retroactively apply to an already-installed system. Run it there
# by hand — see SETUP §6.
set -euo pipefail

# Idempotent: the feature is absent on a clean base, and disable-feature on an
# already-disabled feature is a no-op. Guarded so a future base image that drops
# the feature entirely cannot fail the build.
authselect disable-feature with-fingerprint || echo "authselect: with-fingerprint already absent"
authselect apply-changes
echo "authselect: with-fingerprint NOT enabled (fingerprint is scoped to gtklock)"
