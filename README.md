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
