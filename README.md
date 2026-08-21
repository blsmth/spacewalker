<div align="center">

# 🚀 Spacewalker

[![CI](https://github.com/blsmth/spacewalker/actions/workflows/ci.yml/badge.svg)](https://github.com/blsmth/spacewalker/actions/workflows/ci.yml)

### Your Mac's Spaces finally have names.

Stop counting invisible desktops. Give them names, icons, and colors —
then fly between them like you actually know where you're going.

*A native macOS menu-bar app. Fast, tiny, and quietly magical.*

</div>

---

## The problem you've learned to live with

macOS Spaces are great, until you have six of them. Then it's just
*Desktop 3… no, 4… where did my email go?* Apple gives you numbers.
Numbers are not a memory system.

**Spacewalker gives every Space a real identity** — a name, an icon, a color —
and puts it everywhere you look: the menu bar, a lightning-fast switcher, and
right on top of Mission Control itself.

## What you get

🏷️ **Name your Spaces** — "Email," "Deep Work," "Slack Jail," whatever. Pick an
icon and a color. Your current Space's name lives in the menu bar so you always
know where you are.

⚡ **Quick Switcher (⌘0)** — one hotkey, start typing, hit Enter. Jump anywhere
in a keystroke. Number keys leap straight to a Space. There's a **Jump Back** row
for bouncing between the two you actually use.

🪄 **Names inside Mission Control** — open Mission Control and your Space names
float right onto the thumbnails, in your colors. This is the trick everyone
wants and nobody ships. We ship it.

💨 **An instant heads-up** — every switch flashes the Space's name front and
center, so you never land somewhere and wonder where you are.

🎯 **Move windows between Spaces** *(on the way)* — send the focused window to
any Space without the drag-to-the-edge rain dance.

## How much?

**Free and open source.** No price, no catch, no account. It lives in your menu
bar, sips resources, and stays out of your way. Developed and verified on macOS 15
(Apple Silicon); the package targets macOS 13+, but 13, 14, and Intel Macs are untested.

---

## Wait — a robot wrote this?

🤖 **Yep. Every line.** Spacewalker was built **entirely by Claude**
([Anthropic's](https://www.anthropic.com/claude) coding agent) as an experiment
in fully agentic software development. A human pointed at a goal — *"give macOS
Spaces real names, from scratch"* — and Claude did the
rest: the research, the design, the notoriously gnarly private-API spelunking
that Apple has never documented, the code, the tests, and this very page.

The hard part isn't hype. macOS has **no official API for Spaces** — none, not
in 15+ years — so all of this rides on private system internals that break
between releases and fight back when you poke them. Claude figured out what
actually works by running real code against a live Mac and adjusting when the
system lied to it. (It does that. A lot.)

Curious how? The whole design diary lives in **[PLAN.md](PLAN.md)** — including
every dead end and hard-won gotcha, written by Claude as it went.

---

## For the tinkerers

Want to build it yourself? It's Swift 6 / AppKit — no `.xcodeproj` to open, but
you do need a Swift 6 toolchain (`Package.swift` declares
`swift-tools-version:6.0`), which in practice means **Xcode 16 or its Command
Line Tools**.

```bash
swift test                    # run the tests
```

```bash
./scripts/dev-cert.sh         # one-time: stable signing so macOS remembers its permission grants
```

```bash
./scripts/make-app.sh && open build/Spacewalker.app   # build & launch
```

First launch asks for **Accessibility** and **Automation** permissions — that's
how the switching works, and it's the only thing it needs them for. Your Space
names are saved to `~/Library/Application Support/Spacewalker/spaces.json` and
survive reboots.

### Signing and distribution

macOS ties the Accessibility/Automation grant to the app's code signature, not
just its bundle ID. An unsigned or ad-hoc-signed build gets a fresh identity
every time you rebuild, so macOS treats it as a new app and makes you
re-approve it — `./scripts/dev-cert.sh` exists to avoid that.

- **`dev-cert.sh`** creates a one-time, self-signed "Spacewalker Dev" identity
  in its own dedicated keychain (`~/Library/Keychains/spacewalker-dev.keychain-db`),
  protected by a randomly generated password that's never committed to the
  repo and never shared with anything else. This identity is for **local
  development only** — it's untrusted by Gatekeeper and must never sign
  anything you hand to someone else. Re-running it is safe (it detects the
  existing identity and does nothing); it refuses to create a duplicate.
- **`make-app.sh`** builds the bundle and signs it with that identity by
  default, with `--options runtime` (hardened runtime) so the entitlements in
  `App/Spacewalker.entitlements` are actually enforced. It fails loudly
  (`exit 1`) if no usable identity is found, rather than silently falling back
  to ad-hoc signing.
- **Release builds are notarized.** Point `make-app.sh` at a Developer ID
  identity instead of the dev cert, and it adds a secure Apple timestamp and
  (optionally) submits for notarization and staples the ticket:

  ```bash
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    NOTARIZE_PROFILE=spacewalker-notary \
    ./scripts/make-app.sh release
  ```

  `NOTARIZE_PROFILE` refers to credentials stored once via
  `xcrun notarytool store-credentials spacewalker-notary --apple-id ... --team-id ... --password ...`
  (an app-specific password, kept in your login keychain by `notarytool`
  itself — nothing release-related is stored by this repo's scripts). Neither
  a Developer ID certificate nor a Team ID is required for local dev builds;
  both env vars are opt-in.

> Heads up: changing how the app is signed (upgrading to hardened runtime, or
> regenerating the dev cert) changes its code signature, which invalidates any
> Accessibility/Automation grant you already gave it — macOS will ask you to
> re-approve Spacewalker in System Settings once, after that.

### Launch it automatically at login

It's a menu-bar app, so you'll want it to start with your Mac. The status-bar
menu has a **Launch at Login** toggle (backed by `SMAppService`) that does this
for you — it reflects whatever System Settings ▸ General ▸ Login Items &
Extensions actually says, so the two stay in sync no matter which one you use.
`SMAppService` only works from a properly bundled, signed `.app` (not a bare
`swift run` binary), so if you're building from source, use `make-app.sh` first.

If you'd rather add it by hand — **System Settings ▸ General ▸ Login Items &
Extensions**, click **＋** under "Open at Login," and pick
`build/Spacewalker.app`.

Or from the repo root in a terminal:

```bash
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$PWD/build/Spacewalker.app\", hidden:false}"
```

That login item points at the build output, which keeps the same path across
rebuilds. Prefer something more permanent? Copy the app into `/Applications`
first and add *that* to Login Items instead:

```bash
cp -R build/Spacewalker.app /Applications/ && open /Applications/Spacewalker.app
```

> Heads up: this uses private macOS APIs, so it can't ship on the Mac App Store
> (it'll be a signed, notarized direct download instead).
> The nerdy details are all in [PLAN.md](PLAN.md).

---

## Known limitations

**No auto-update.** Spacewalker checks GitHub Releases in the background (at
most once per launch, at most once every 24 hours) and, if something newer is
out, adds an **Update Available…** item to the status-bar menu — click it to
open the release page yourself. There is no Sparkle-style appcast and nothing
downloads or installs itself; you always choose when to grab a new build. This
matters more than it would for an ordinary app: Spacewalker rides on
undocumented private macOS APIs that Apple can change in any point release, so
a version that stops switching Spaces correctly needs a way to reach you,
not to silently update you. Use **Check for Updates…** in the menu to check on
demand.

That version check is the **only** network request Spacewalker makes. It's an
unauthenticated `GET` to the public GitHub Releases API, and it sends no
identifiers, no analytics, and no telemetry of any kind — GitHub sees an ordinary
anonymous API request. Nothing else in the app touches the network. If you'd
rather it never reached out at all, the app remains fully functional offline: the
check fails silently and no menu item appears.

**A system-wide keyboard tap runs for the app's entire lifetime.** Spacewalker
installs a listen-only `CGEventTap` at launch and keeps it live the whole time
the app is running — this is the most invasive use of the Accessibility grant,
so it's worth spelling out plainly. It exists because ⌃←/⌃→/⌃1–9 are *symbolic
hotkeys*: the WindowServer intercepts them upstream of Cocoa's normal event
dispatch, so the ordinary `NSEvent.addGlobalMonitorForEvents` API never sees
them at all (verified empirically — see `SwitchKeyTap`'s doc comment). The tap
is the only way to notice the instant one of those shortcuts is pressed, which
is what lets Spacewalker blank a stale Space name in the menu-bar HUD
immediately instead of waiting on the slower Space-change poll to catch up.

With equal weight, here's what it does *not* do: it is `.listenOnly`, so it
can never modify, delay, or swallow a keystroke — every event is handed back
unchanged, always. It only asks for `keyDown` events. The only things it reads
out of each event are whether the Control key was held, the numeric key code,
and a timestamp — no key content is read, logged, or written to disk anywhere,
and it uses the Accessibility grant Spacewalker already needs for switching
Spaces, so enabling it doesn't request any additional permission. There's no
separate on/off toggle for the tap today — declining or revoking Accessibility
trust disables it along with Space switching itself; a preference to turn off
HUD-blanking (and with it, the tap) independently doesn't exist yet.

**Multi-display is incomplete, and the safety margin around it is
narrower than it looks.** Switching to a Space on a *different* display than
the one you're currently on isn't supposed to work — `switchTo` returns
`.crossDisplayUnsupported` and does nothing — but that detection itself is
unreliable: it looks for a Space marked "current" on the target display, and
with "Displays have separate Spaces" on, every display has its own current
Space, so the check can pass even when the switch really does cross
displays. A menu item for a Space on another display therefore still just
looks like an ordinary, clickable item — nothing greys it out — because the
one obvious way to grey it out (comparing against "the current display") has
no reliable source for *which* display is actually focused in this codebase
today; disabling the wrong display's items would have been worse than
disabling none. A same-display switch with a second display attached falls
back to the slower ⌃←/⌃→ walk rather than the fast direct ⌃1…⌃9 jump the
moment *any* second display is attached, even if the switch never leaves the
display you're already on — intentionally conservative, because the walk is
relative (a hop count) while the direct jump uses an absolute per-display
desktop number, and there's no live two-display machine here to confirm that
number means the same thing to macOS once a second display is attached.
Real, verified cross-display detection needs a source for the actually-
focused display that doesn't exist yet; that's the prerequisite, tracked in
[#23](https://github.com/blsmth/spacewalker/issues/23), not something this
pass could safely shortcut.

The Mission Control name overlay **used to crash outright** the moment
Mission Control was opened on any machine with two or more displays
attached — a `SIGTRAP` from a dictionary key collision, not a cosmetic bug —
tracked and fixed in
[#64](https://github.com/blsmth/spacewalker/issues/64). It no longer crashes.

The first attempt at the #64 fix, in turn, **regressed the single-display
overlay worse than the crash it fixed** — this app's headline feature became
a silent no-op on the one topology this app is guaranteed to run on. That
regression is fixed too, and this time it's live-verified, not just
unit-tested against a synthetic fixture: `scripts/dump-mc-ax.swift` opens a
real Mission Control and dumps the Dock's AX tree, and that live capture is
what caught (and now regression-tests) two things a synthetic fixture had
never modeled — Mission Control's Spaces Bar resting *collapsed above the
physical screen's top edge* as its normal steady state (screen attribution
now uses horizontal overlap/nearest-screen, not strict center containment,
so this no longer drops every row), and a real window whose title happened
to end in a digit (`"agentctl · personal · brandon:2"`) almost being
promotable to a second, bogus "Spaces Bar" (row detection now prefers
Mission Control's own `AXIdentifier`s — `mc.spaces.list` and friends, which
turn out to exist and be stable — over geometry, and the geometric fallback
now requires at least two aligned buttons before it will even consider a
row a candidate).

What that fix does *not* establish: whether Mission Control genuinely
renders one Spaces Bar (one `mc.display`/`mc.spaces.list` pair) per physical
display in the first place (if it renders one shared row instead, only that
row's Spaces get a label), and whether the public API this uses to match a
screen to its Space-topology display identifier
(`CGDisplayCreateUUIDFromDisplayID`) stays correct once a second display
attaches or detaches — verified so far only by comparing it against a live
topology read on this single-display machine, not a real second monitor.
Both remain genuinely unverified without one.

The "Displays have separate Spaces" system setting (`com.apple.spaces` →
`spans-displays`) is read from the correct any-host preference domain and
shown in **Copy Diagnostics**, but the key is absent on this machine either
way, and what a set value would imply for Space topology or switching with
two displays attached is still unverified. It does, however, affect
single-display setups in one concrete way this pass fixed: when that
setting is off, CGS reports the literal string `"Main"` — not a UUID — for
the active display's own Space-topology entry (confirmed against this
machine's own `com.apple.spaces.plist`, and against Hammerspoon's `hs.spaces`,
which has handled the same case for years). The overlay now tries the
screen's UUID first, then `"Main"` for the menu-bar screen, so it resolves
either way instead of assuming one.

---

## License

Spacewalker is licensed under the [Apache License 2.0](LICENSE).

Apache-2.0 rather than MIT for one specific reason: this app is built on
undocumented private system APIs, and Apache-2.0 carries an explicit patent
grant. That's the more considerate license for anyone who wants to reuse the
private-API spelunking in [PLAN.md](PLAN.md) or the `CGSPrivate` layer.

## Security

Spacewalker requests **Accessibility** trust, which is a powerful permission.
If you find a security issue, please report it privately — see
[SECURITY.md](SECURITY.md) rather than opening a public issue.
