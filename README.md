<div align="center">

# 🚀 Spacewalker

[![CI](https://github.com/blsmth/spacewalker/actions/workflows/ci.yml/badge.svg)](https://github.com/blsmth/spacewalker/actions/workflows/ci.yml)

### Your Mac's Spaces finally have names.

Stop counting invisible desktops. Name them, then fly between them like you
actually know where you're going.

*A native macOS menu-bar app. Fast, tiny, and quietly magical.*

</div>

---

## The problem you've learned to live with

macOS Spaces are great, until you have six of them. Then it's just
*Desktop 3… no, 4… where did my email go?* Apple gives you numbers.
Numbers are not a memory system.

**Spacewalker gives every Space a name** and puts it everywhere you look: the
menu bar, a fast switcher, and right on top of Mission Control itself.

## What you get

🏷️ **Name your Spaces** — "Email," "Deep Work," "Slack Jail," whatever. Rename
the one you're on from the menu bar (⌘R), and its name lives up there so you
always know where you are.

⚡ **Quick Switcher (⌘0)** — one hotkey, start typing, hit Enter. Fuzzy search,
so "dw" finds "Deep Work." Keys `1`–`9` jump straight to a row.

🪄 **Names inside Mission Control** — open Mission Control and your Space names
float right onto the thumbnails. This is the trick everyone wants and nobody
ships. We ship it. *(Only Spaces you've actually named get a label — unnamed
ones are left alone.)*

💨 **An instant heads-up** — every switch flashes the Space's name in the middle
of the screen, like the volume HUD, so you never land somewhere and wonder where
you are.

↩️ **Jump Back** — a menu-bar item that bounces you to the Space you came from.

🎯 **Move windows between Spaces** *(not yet)* — send the focused window to any
Space without the drag-to-the-edge rain dance. Planned, not built.

Icons and colors are in the data model and the app renders them if they're
present, but there's no picker yet — today you'd have to hand-edit
`spaces.json`. A real UI for it is planned.

## How much?

**Free and open source.** No price, no catch, no account. It lives in your menu
bar, sips resources, and stays out of your way.

Developed and verified on **macOS 15 (Apple Silicon)**. The package targets
macOS 13+, but macOS 13, macOS 14, and Intel Macs are untested. This is `0.1.0`
and **source-only** — there's no prebuilt download yet, because signing one
needs a Developer ID certificate this project doesn't have.

---

## Wait — a robot wrote this?

🤖 **Yep. Every line.** Spacewalker was built **entirely by Claude**
([Anthropic's](https://www.anthropic.com/claude) coding agent) as an experiment
in fully agentic software development. A human pointed at a goal — *"give macOS
Spaces real names, from scratch"* — and Claude did the rest: the research, the
design, the notoriously gnarly private-API spelunking that Apple has never
documented, the code, the tests, and this very page.

The hard part isn't hype. macOS has **no official API for Spaces** — none, not
in 15+ years — so all of this rides on private system internals that break
between releases and fight back when you poke them. Claude figured out what
actually works by running real code against a live Mac and adjusting when the
system lied to it. (It does that. A lot.)

Curious how? The design diary lives in **[PLAN.md](PLAN.md)**, dead ends
included. Release-by-release notes are in **[CHANGELOG.md](CHANGELOG.md)**.

---

## Building it

It's Swift 6 / AppKit — no `.xcodeproj` to open, but you do need a Swift 6
toolchain (`Package.swift` declares `swift-tools-version:6.0`), which in
practice means **Xcode 16 or its Command Line Tools**.

```bash
swift test                    # run the tests
./scripts/dev-cert.sh         # one-time: stable signing, so macOS remembers its permission grants
./scripts/make-app.sh && open build/Spacewalker.app
```

### What happens on first launch

1. **Accessibility** — the app asks for it up front, with a button that opens
   the right System Settings pane. It watches in the background and picks up the
   grant as soon as you give it, no restart needed.
2. **A prompt about system settings** — Spacewalker offers to fix up a couple of
   macOS settings it depends on. Details below; you can decline.
3. **Automation** — macOS asks for this the *first time you actually switch a
   Space*, not at launch, because that's when the Apple Event goes out.

Your Space names are saved to
`~/Library/Application Support/Spacewalker/spaces.json` and survive reboots.

Both permissions are genuinely required: macOS filters synthetic key events for
Space switching, so driving System Events is the only path the system honors.
Accessibility also powers the keyboard tap and the Mission Control overlay —
[SECURITY.md](SECURITY.md) documents every use with links to the code.

### The system settings it wants to change

Spacewalker asks once, and only if something actually needs changing:

- Bind **⌃1…⌃9** to "Switch to Desktop 1–9" (`com.apple.symbolichotkeys`)
- Bind **⌃←/⌃→** to "Move left/right a space" (same domain)
- Turn off **"Automatically rearrange Spaces based on most recent use"**
  (`com.apple.dock` → `mru-spaces`), which otherwise makes Space positions
  unstable underneath you

Applying these **restarts your Dock**. Shortcuts you've deliberately rebound are
left alone and reported as conflicts rather than overwritten. The old values are
backed up first, and **Restore System Settings…** in the menu puts everything
back. Decline and the app still works — it just uses the slower ⌃←/⌃→ walk.

> **Uninstalling?** Run **Restore System Settings…** *before* you delete the app.
> Those shortcut bindings live in your system preferences, not in the bundle, so
> deleting Spacewalker first leaves them in place with nothing left to undo them.
> The backup it reads from is at
> `~/Library/Application Support/Spacewalker/system-prefs-backup.plist`; delete
> that directory once you've restored.

### Signing and distribution

macOS ties the Accessibility/Automation grant to the app's code signature, not
just its bundle ID. An unsigned or ad-hoc-signed build gets a fresh identity
every time you rebuild, so macOS treats it as a new app and makes you
re-approve it — `./scripts/dev-cert.sh` exists to avoid that.

- **`dev-cert.sh`** creates a one-time, self-signed "Spacewalker Dev" identity
  in its own dedicated keychain (`~/Library/Keychains/spacewalker-dev.keychain-db`),
  protected by a randomly generated password that's never committed and never
  reused. This identity is for **local development only** — it's untrusted by
  Gatekeeper and must never sign anything you hand to someone else. Re-running
  it is safe; it detects the existing identity and refuses to create a duplicate.
- **`make-app.sh`** builds the bundle and signs it with that identity by
  default, with `--options runtime` (hardened runtime) so the entitlements in
  `App/Spacewalker.entitlements` are actually enforced. It fails loudly if no
  usable identity is found rather than silently falling back to ad-hoc signing.
  For local dev builds it skips the `.dmg` step; pass `MAKE_DMG=1` to force one.
- **Release builds are notarized.** Point it at a Developer ID identity and it
  adds a secure Apple timestamp, submits for notarization, and staples the
  ticket:

  ```bash
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    NOTARIZE_PROFILE=spacewalker-notary \
    ./scripts/make-app.sh
  ```

  `NOTARIZE_PROFILE` refers to credentials stored once via
  `xcrun notarytool store-credentials spacewalker-notary --apple-id ... --team-id ... --password ...`
  (an app-specific password, kept in your login keychain by `notarytool` itself
  — nothing release-related is stored by this repo's scripts). Both env vars are
  opt-in; neither is needed for local dev builds.

`scripts/release.sh` wraps the whole thing — notarized `.dmg` plus a GitHub
Release tagged from `App/Info.plist`. See
**[docs/RELEASING.md](docs/RELEASING.md)** for the full procedure, and
`docs/specs/` for the per-issue design notes.

> Heads up: changing how the app is signed invalidates any
> Accessibility/Automation grant you already gave it — macOS will ask you to
> re-approve Spacewalker in System Settings once, after that.

### Launch it automatically at login

It's a menu-bar app, so you'll want it to start with your Mac. The status-bar
menu has a **Launch at Login** toggle (backed by `SMAppService`) that reflects
whatever System Settings ▸ General ▸ Login Items & Extensions says, so the two
stay in sync no matter which one you use. `SMAppService` only works from a
properly bundled, signed `.app` (not a bare `swift run` binary), so build with
`make-app.sh` first.

Want it somewhere permanent? Copy it into `/Applications` and toggle from there:

```bash
cp -R build/Spacewalker.app /Applications/ && open /Applications/Spacewalker.app
```

> Heads up: this uses private macOS APIs, so it can't ship on the Mac App Store.
> It'll be a signed, notarized direct download instead. The nerdy details are
> all in [PLAN.md](PLAN.md).

---

## Known limitations

**Multi-display support is incomplete and largely unverified.** It was developed
on a single-display machine, and that shows:

- Switching to a Space on a *different* display isn't supported. Detection of
  that case is also unreliable — with "Displays have separate Spaces" on, every
  display has its own current Space, so the check can pass when the switch
  really does cross displays. Menu items for other displays' Spaces aren't
  greyed out, because there's no reliable source yet for *which* display is
  focused, and greying out the wrong ones would be worse.
- Direct ⌃1…⌃9 jumps are disabled whenever a second display is attached, even
  for a switch that stays on one display, falling back to the slower ⌃←/⌃→
  walk. Deliberately conservative: the walk is relative, the direct jump uses an
  absolute per-display desktop number, and there's no two-display machine here
  to confirm that number still means what it should.
- The Mission Control overlay now creates one window per attached screen, but
  that's never been exercised on real multi-display hardware.

Tracked in [#23](https://github.com/blsmth/spacewalker/issues/23).

**Fullscreen apps can confuse the overlay.** A Space occupied by a fullscreen
app is excluded from the internal index but still shows up as a Mission Control
thumbnail, so names can land on the wrong thumbnails
([#65](https://github.com/blsmth/spacewalker/issues/65)).

**Metadata accumulates forever.** Delete a Space and its saved name stays in
`spaces.json`. There's no expiry and no UI to review or clear it
([#33](https://github.com/blsmth/spacewalker/issues/33)).

**A system-wide keyboard tap runs for the app's entire lifetime.** It's
listen-only and reads three fields — whether Control was held, the key code, and
a timestamp — but it's the most invasive thing here, so it gets its own section
in [SECURITY.md](SECURITY.md) explaining exactly why it's needed and what it
can't do.

**No auto-update.** Spacewalker checks GitHub Releases at most once per launch,
throttled to once every 24 hours, and adds an **Update Available** item to the
menu if there's something newer — you click it, you get the release page, you
decide. Nothing downloads or installs itself. That's more deliberate than it
sounds: this app rides on undocumented APIs Apple can change in any point
release, so a version that stops working needs a way to *reach* you, not to
silently replace itself. **Check for Updates…** is always in the menu.

That version check is the **only** network request the app makes — an
unauthenticated `GET`, no identifiers, no analytics, no telemetry. Offline, it
fails silently and no menu item appears.

## Something broken?

**Copy Diagnostics** in the menu puts a snapshot on your clipboard that's safe
to paste into a public issue — it deliberately leaves out your Space names,
window titles, username, and absolute paths. Attach it to
[a new issue](https://github.com/blsmth/spacewalker/issues/new) and it saves a
round trip.

Found a *security* problem? Please don't open a public issue — see
[SECURITY.md](SECURITY.md) for private reporting.

## License

Spacewalker is licensed under the [Apache License 2.0](LICENSE).

Apache-2.0 rather than MIT for one specific reason: this app is built on
undocumented private system APIs, and Apache-2.0 carries an explicit patent
grant. That's the more considerate license for anyone who wants to reuse the
private-API spelunking in [PLAN.md](PLAN.md) or the `CGSPrivate` layer.
