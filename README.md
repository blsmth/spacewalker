<div align="center">

# 🚀 Spacewalker

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
bar, sips resources, and stays out of your way. macOS 13 and up.

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

Want to build it yourself? It's Swift 6 / AppKit, no Xcode project needed.

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

It's a menu-bar app, so you'll want it to start with your Mac. There's no
built-in toggle yet (it's on the list — via `SMAppService`), so for now add it to
your Login Items. The app only needs the signing keychain to *build*, not to
*run*, so it starts cleanly at login with no password prompt.

The easy way — **System Settings ▸ General ▸ Login Items & Extensions**, click
**＋** under "Open at Login," and pick `build/Spacewalker.app`.

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
