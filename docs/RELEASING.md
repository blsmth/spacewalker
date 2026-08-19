# Releasing Spacewalker

This is the checklist for cutting a signed, notarized `.dmg` and publishing it as a GitHub
Release. It assumes you (Brendan) are running it on a machine that has your **Developer ID
Application** certificate in the login keychain — that's the one piece of this pipeline that
can't be automated or verified by an agent, because it requires a real Apple Developer Program
membership and a private key that only you hold.

There is no CI for this repo (see "Why this isn't a GitHub Actions workflow" below) — every
step here runs locally.

## One-time setup (per machine)

1. **Developer ID Application certificate** in your login keychain (from Xcode ▸ Settings ▸
   Accounts, or the Apple Developer portal). Confirm it's there and note its exact name:

   ```bash
   security find-identity -p codesigning -v
   ```

   Expected output includes a line like:

   ```
   1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Brendan Smith (TEAMID)"
   ```

   That quoted string is your `SIGN_IDENTITY`.

2. **Notarization credentials**, stored once so `notarytool`/scripts never need your Apple ID
   password directly:

   ```bash
   xcrun notarytool store-credentials spacewalker-notary \
     --apple-id "<your-apple-id-email>" \
     --team-id "<TEAMID>" \
     --password "<app-specific-password>"
   ```

   Generate the app-specific password at <https://appleid.apple.com/account/manage> ("App-Specific
   Passwords"). This is stored in your **login keychain** by `notarytool` itself — nothing in
   this repo touches it. `spacewalker-notary` is the profile name; it's what `NOTARIZE_PROFILE`
   refers to below.

   Expected success output ends with something like:

   ```
   Profile "spacewalker-notary" saved successfully.
   ```

## Version bump locations

There is exactly **one** place the version lives in source:

- `App/Info.plist` — `CFBundleShortVersionString` (the marketing version, e.g. `0.2.0`) and
  `CFBundleVersion` (the build number — bump this too, even on a patch release).

Bump both, commit that change on `main` (e.g. `git commit -m "Bump version to 0.2.0"`), *then*
run the release. `scripts/release.sh` reads the version to tag from this file — if you forget
to bump it, the release will be tagged with the previous version and `release.sh` will refuse
to proceed (the tag already exists).

## Tagging convention

Tags are `vMAJOR.MINOR.PATCH` (e.g. `v0.2.0`), matching `CFBundleShortVersionString` exactly
with a `v` prefix. `scripts/release.sh` creates and pushes this tag for you — you should not
need to run `git tag` by hand in the normal flow. The only tag in the repo today is
`spike-archive`, which predates this convention and is unrelated to releases.

## The release checklist

Run from a clean `main` checkout:

- [ ] `App/Info.plist` version bumped and committed (see above)
- [ ] `security find-identity -p codesigning -v` shows your Developer ID Application identity
- [ ] `xcrun notarytool store-credentials` has been run at least once on this machine (step
      above) — or confirm it already has: `xcrun notarytool history --keychain-profile
      spacewalker-notary` should list past submissions without prompting for a password
- [ ] Run the release:

  ```bash
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    NOTARIZE_PROFILE=spacewalker-notary \
    ./scripts/release.sh
  ```

  This builds the app (`scripts/make-app.sh release`), which:
  1. Signs `Spacewalker.app` with `SIGN_IDENTITY` (hardened runtime on).
  2. Zips it, submits to `notarytool`, waits, staples the ticket to the `.app`.
  3. Packages the stapled `.app` into `build/Spacewalker-<version>.dmg` via
     `scripts/make-dmg.sh`.
  4. Signs the `.dmg` with the same identity.
  5. Submits the **`.dmg` itself** to `notarytool` (a second, separate submission — see
     `scripts/make-dmg.sh` for why the `.dmg` needs its own ticket, not just the app inside it),
     waits, and staples it.

  Then `release.sh` tags `vX.Y.Z`, pushes the tag, and creates a **draft** GitHub Release with
  the `.dmg` attached.

- [ ] Verify the artifact before publishing (see "Verifying a finished dmg" below)
- [ ] Publish the draft release: `gh release view vX.Y.Z --web`, review the auto-generated
      notes, edit if needed, then click Publish (or `gh release edit vX.Y.Z --draft=false`)

## Verifying a finished dmg

Once you have a real notarized `.dmg`, these are the checks worth running before publishing —
all but the notarization-dependent ones (2 and 4 below) were already exercised against an
unnotarized, self-signed build while building this pipeline, so this is confirming the *same*
commands now succeed against a real one, not learning new syntax under time pressure:

```bash
# 1. Signature is intact and satisfies its own designated requirement.
codesign --verify -vvv build/Spacewalker-<version>.dmg
# Expect: "valid on disk" / "satisfies its Designated Requirement"

# 2. Gatekeeper accepts the dmg itself (this is the one that will FAIL on a self-signed or
#    unnotarized dmg — "rejected" — and PASS on a properly notarized+stapled one).
spctl -a -t open --context context:primary-signature -v build/Spacewalker-<version>.dmg
# Expect: "accepted" and "source=Notarized Developer ID"

# 3. Gatekeeper accepts the app inside.
spctl -a -t exec -vv build/Spacewalker.app
# Expect: "accepted" and "source=Notarized Developer ID"

# 4. The notarization ticket is actually stapled (works fully offline).
xcrun stapler validate build/Spacewalker-<version>.dmg
# Expect: "The validate action worked!"

# 5. Sanity-check the mounted volume looks right.
hdiutil attach build/Spacewalker-<version>.dmg -nobrowse
ls "/Volumes/Spacewalker"   # expect: Spacewalker.app, Applications (symlink)
hdiutil detach "/Volumes/Spacewalker"
```

If step 2 or 4 fails, do not publish. For reference, against a self-signed/unnotarized build
(the furthest this repo's tooling can be verified without your cert), those two commands fail
like this:

```bash
$ spctl -a -t open --context context:primary-signature -v build/Spacewalker-0.1.0.dmg
build/Spacewalker-0.1.0.dmg: rejected

$ xcrun stapler staple build/Spacewalker-0.1.0.dmg
...
Could not find base64 encoded ticket in response for ...
The staple and validate action failed! Error 65.
```

A real notarized dmg must produce "accepted" / "The validate action worked!" instead — if you
see the failures above after `release.sh` reports success, notarization did not actually
happen and something upstream (credentials, network, an expired cert) needs investigating
before you publish.

## Why hdiutil instead of create-dmg

`scripts/make-dmg.sh` uses `hdiutil` (ships with every macOS install) rather than the popular
`create-dmg` Homebrew formula that PLAN.md §6 originally named. Reasoning:

- We don't need a custom background image, icon positions, or window chrome — just the `.app`
  next to an `/Applications` shortcut. `create-dmg`'s main value-add (visual layout) isn't
  needed here.
- `create-dmg` would be the first Homebrew dependency in the release pipeline. This repo has
  already been bitten once by assuming a specific tool flavor is on `PATH` — see
  `scripts/dev-cert.sh` and commit `61625e2`, where LibreSSL vs. Homebrew's `openssl@3` produced
  silently incompatible PKCS#12 output. A release script depending on whatever `create-dmg`
  version happens to be installed (or isn't) on the release machine is the same class of risk,
  for a feature we don't use.
- `hdiutil` is guaranteed present and stable across macOS versions because it ships with the OS.

## Why this isn't a GitHub Actions workflow

This repo has **zero CI today**. Two options were considered for turning a tag into a release
artifact:

1. A `.github/workflows/release.yml` triggered on `v*` tags, running on a `macos-latest`
   runner, that builds, signs, notarizes, and uploads to a GitHub Release.
2. A local script (`scripts/release.sh`) that Brendan runs by hand on his own machine.

**Option 2 (local script) is what this PR implements.** Reasoning:

- Signing and notarizing in CI requires exporting the Developer ID private key as a `.p12` and
  storing it, plus the notarization credentials, as GitHub Actions secrets — importing them into
  a temporary keychain on every run. That's real new secret-management surface (a leaked Actions
  log, a compromised workflow dependency, or a misconfigured `pull_request_target` trigger could
  exfiltrate a private key that's otherwise never off Brendan's machine) for a project that, per
  issue #32 itself, isn't ready for public advertisement yet.
- This would be the **first** workflow in the repo. Introducing "first CI ever" and "first
  release-signing secrets ever" in the same change multiplies what could go wrong with no
  existing pipeline to fall back on or compare against.
- The release cadence here doesn't need automation's main benefit (speed/consistency across many
  runs) yet — it's a manual, infrequent, human-gated action, which is exactly what a script run
  by hand is good at.
- If/when this project adds a real CI pipeline (lint/test/build on every PR — none of which
  needs the signing cert), *that* would be the natural place to also add release automation,
  reusing infrastructure instead of bootstrapping secrets management for release alone.

If this changes (e.g. release cadence increases, or a second person needs to cut releases), the
migration path is straightforward: `scripts/release.sh`'s logic maps almost directly onto
workflow steps, with the signing identity and notarization credentials as encrypted secrets and
a keychain-import step at the top of the job.

## Auto-update

Out of scope for this PR (owned by the parallel README/CHANGELOG work, and by PLAN.md's
Sparkle claim under review in PR #51). This doc only covers producing and publishing the dmg;
it does not yet make Spacewalker check for or apply updates.
