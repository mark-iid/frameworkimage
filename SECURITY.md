# Security policy

This is a personal OS image built for one laptop, but it is published publicly at
`ghcr.io/mark-iid/kb3lyb-sway` and signed with a key whose public half is committed
here. Anyone who rebases onto it is trusting that signature, so reports are welcome
even though the intended audience is one machine.

## Reporting a vulnerability

Use GitHub's **[private vulnerability reporting][pvr]** — the "Report a
vulnerability" button on the [Security tab][sec]. That opens a draft advisory only
visible to the maintainer.

Please do **not** open a public issue for anything touching the signing key, the
published image, or the build workflows. The laptop applies new builds
automatically (`rpm-ostreed-automatic` stages `latest` for the next boot, per
DESIGN §5), so a disclosed weakness in the trust chain is live until it is fixed,
not merely theoretical.

Ordinary bugs — a broken package, a bad config default — belong in a normal issue.

This is a one-person side project. Expect a reply in days, not hours, and no
coordinated-disclosure machinery beyond the advisory itself.

## Scope

**In scope** — anything this repo controls:

- `recipes/` and `modules/`, including the RPM Fusion codec swap.
- `files/scripts/` (build-time) and `files/system/usr/bin/` (on-host helpers),
  particularly the setuid, polkit, udev, sysctl and PAM material under
  `files/system/etc` and `files/system/usr/lib`.
- The Flatpak permission overrides in `files/system/usr/share/factory/`.
- `.github/workflows/` and the signing/publishing chain — a way to get the
  `SIGNING_SECRET` out of a workflow run is the highest-severity report possible
  here, since that key is what the laptop's `policy.json` trusts.

**Out of scope** — report these to their own projects, not here:

- Fedora, the `sway-atomic` base image, RPM Fusion, Flathub applications.
- BlueBuild and the `blue-build/github-action` used to build.
- The Framework hardware and its firmware.

A finding is still in scope if this repo's *configuration* of an upstream
component is what makes it exploitable — e.g. an over-broad Flatpak override or a
polkit rule that grants more than intended.

## Verifying an image

Builds are signed with [cosign](https://github.com/sigstore/cosign) using
[`cosign.pub`](cosign.pub) in this repo:

```sh
cosign verify --key cosign.pub ghcr.io/mark-iid/kb3lyb-sway
```

An unsigned or unverifiable image should be treated as untrusted regardless of
where it came from. The rotation procedure — for loss or for suspected compromise
— is [SETUP.md](SETUP.md) §1 (generate, back up, re-set `SIGNING_SECRET`) and §8
(get each host onto the new key).

**The key was rotated on 2026-08-27.** Not because of any compromise: the previous
private key existed only as a GitHub Actions secret, which cannot be read back
out, so it could be neither backed up nor audited. Images built before that date
are signed with the superseded key, kept here as
[`cosign-old.pub`](cosign-old.pub) and shipped in the image at
`/etc/pki/containers/kb3lyb-sway-old.pub`. Verifying one of those needs
`--key cosign-old.pub`; hosts no longer trust it for upgrades.

## Supported versions

Only the current `latest` build is supported. Older timestamped tags stay in the
registry so a bad build can be rolled back to a known-good one (DESIGN §5), but
they do not receive fixes — the fix ships in the next nightly.

[pvr]: https://github.com/mark-iid/frameworkimage/security/advisories/new
[sec]: https://github.com/mark-iid/frameworkimage/security
