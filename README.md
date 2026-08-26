# NoNameplateNumbers

A tiny World of Warcraft addon that turns the cooldown countdown numbers on
**nameplate auras** on and off. Every other cooldown in the game — action bars,
buff frame, unit frames, everything — keeps its numbers exactly as it is.

Two Lua files, no libraries, no OnUpdate loops, no combat log parsing.

## What it does

The default nameplates draw the buffs/debuffs they show with a standard cooldown
widget, so if you have cooldown numbers enabled (`countdownForCooldowns`) or a
timer addon such as OmniCC, those tiny numbers end up stamped over every aura
icon above every enemy. This addon flags just those cooldown widgets as
"no countdown text" and leaves the rest of the UI alone.

## Install

Copy the `NoNameplateNumbers` folder into:

```
World of Warcraft/_retail_/Interface/AddOns/NoNameplateNumbers
```

so that `.../AddOns/NoNameplateNumbers/NoNameplateNumbers.toc` exists, then
reload the game (or `/reload`).

The `.toc` targets retail 12.1 (interface 120100). If a later patch marks the
addon as out of date, bump the `## Interface:` line to the number your client
reports (`/dump select(4, GetBuildInfo())`), or tick "Load out of date AddOns"
in the AddOns list.

## Options

Open **Game Menu → Options → AddOns → NoNameplateNumbers**, or type `/nnn`.

| Option | Default | What it does |
| --- | --- | --- |
| Hide cooldown numbers on nameplate auras | on | Master switch. Off means the addon does nothing at all. |
| Enemy nameplates | on | Auras on hostile and neutral nameplates. |
| Friendly nameplates | on | Auras on friendly nameplates. |
| Personal resource display | on | Auras on your own nameplate. |
| Also suppress timer addons | on | Marks the cooldowns with `noCooldownCount`, the flag OmniCC, ElvUI and friends honour, so their text stays off these icons too. |
| Also hide timer text drawn as plain text | on | Not every timer is the cooldown widget's own countdown — Blizzard draws the duration as ordinary text on some patches, and some timer addons ignore the opt-out flag. This hides that text too. Only text on a nameplate aura icon is touched, stack counts are left alone, and everything is shown again if you turn the addon off. |
| Also hide the cooldown swipe | off | Extra: removes the dark sweeping shade from nameplate aura icons as well. |

Settings are saved per account and take effect immediately — no reload needed.

### Slash commands

| Command | Effect |
| --- | --- |
| `/nnn` or `/nonameplatenumbers` | Open the options panel. |
| `/nnn toggle` | Flip the master switch. |
| `/nnn on` / `/nnn off` | Set the master switch. |
| `/nnn debug` | Prints what the addon sees on your target's nameplate: whether the hook is installed, how many aura cooldowns it found, their state, and any visible numeric text left on the plate along with the frame that owns it. |

## How it works

Blizzard renames nameplate frame keys between expansions, so the addon does not
look for `UnitFrame.BuffFrame` or `button.Cooldown` at all.

* `Cooldown:SetCooldown` is hooked once on the shared widget metatable. The
  first time any cooldown starts, its parent chain is walked to see whether it
  sits under a `NamePlate` frame, and the answer is cached on the widget. After
  that, a cooldown that is not on a nameplate costs one table lookup and is
  never touched again — action bars, buff frame and everything else are
  untouched.
* Nameplate ones get `SetHideCountdownNumbers(true)`, plus `noCooldownCount`
  for third party timers.
* Timer text that is *not* the cooldown widget's own countdown — a plain font
  string on the aura icon — is hidden by alpha and `Hide()`, so an `OnUpdate`
  that only calls `SetText` cannot bring it back. Font strings whose parent key
  looks like a stack count are left alone.
* Nameplates can contain forbidden frames, and touching one throws, so every
  walk skips them instead of dying halfway through.
* On 12.0 and later a lot of nameplate data is a **secret value**: an addon may
  hold it but not read, compare or even `type()` it, and trying throws. That
  covers aura text and duration, frame names, and the argument Blizzard passes
  to `SetHideCountdownNumbers`. So nothing here reads aura data to do its job —
  which font string is the duration and which is the stack count is decided
  from the key Blizzard stored it under — and every comparison of a value that
  came out of a Blizzard frame happens *inside* a `pcall`, never on the value
  it hands back. A secret value can never leave the addon half-applied or
  switched off for the rest of the session.
* `NAME_PLATE_UNIT_ADDED` walks the plate once to pick up auras that were
  already running (right after login, for instance) and to re-decide
  enemy/friendly/personal when a nameplate is recycled onto a new unit.
* `SetHideCountdownNumbers` is hooked too, so if Blizzard turns the numbers
  back on for a nameplate aura, the addon puts its answer back.
* No `CVar` is changed, so your cooldown-number settings everywhere else in the
  game stay exactly as they are.

Turning the addon off restores the nameplate aura cooldowns to their normal
behaviour right away, i.e. they follow your usual cooldown-number settings again.

## If numbers are still showing

Run `/nnn debug` while targeting the mob whose nameplate has the numbers and
read the output:

* **"cooldown hook: FAILED"** — the widget hook could not be installed on this
  client; please report it.
* **"0 cooldowns"** — the numbers are not being drawn by a cooldown widget on
  the nameplate at all, which usually means a nameplate addon (Plater, Kui,
  ElvUI nameplates) is drawing that nameplate instead of Blizzard. Use that
  addon's own aura settings.
* **`text "8" shown=true hiddenByUs=false on <frame>`** — something is drawing
  that number as plain text and the addon is not catching it. The frame name at
  the end of the line says exactly who owns it; that is the line to report.
* **"scan failed: ..."** — the walk hit something it could not read; report the
  message.
* **"errors seen so far:"** — anything the addon tried and the client refused.
  These are survived rather than fatal, but they are worth reporting: they say
  exactly which call the client is blocking.

## Notes

* Only the **default Blizzard nameplates** are handled. Nameplate addons such as
  Plater or Kui Nameplates draw their own auras and have their own settings for
  this.
* Third party timers only re-read the opt-out flag when a cooldown starts, so
  the addon restarts any cooldown that is already running when you flip that
  option, which makes the change visible immediately.
