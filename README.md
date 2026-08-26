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

If the client marks the addon as out of date, tick "Load out of date AddOns" in
the AddOns list, or bump the `## Interface:` line in the `.toc` to the version
your client reports (`/dump select(4, GetBuildInfo())`).

## Options

Open **Game Menu → Options → AddOns → NoNameplateNumbers**, or type `/nnn`.

| Option | Default | What it does |
| --- | --- | --- |
| Hide cooldown numbers on nameplate auras | on | Master switch. Off means the addon does nothing at all. |
| Enemy nameplates | on | Auras on hostile and neutral nameplates. |
| Friendly nameplates | on | Auras on friendly nameplates. |
| Personal resource display | on | Auras on your own nameplate. |
| Also suppress timer addons | on | Marks the cooldowns with `noCooldownCount`, the flag OmniCC, ElvUI and friends honour, so their text stays off these icons too. |
| Also hide the cooldown swipe | off | Extra: removes the dark sweeping shade from nameplate aura icons as well. |

Settings are saved per account and take effect immediately — no reload needed.

### Slash commands

| Command | Effect |
| --- | --- |
| `/nnn` or `/nonameplatenumbers` | Open the options panel. |
| `/nnn toggle` | Flip the master switch. |
| `/nnn on` / `/nnn off` | Set the master switch. |

## How it works

* On `NAME_PLATE_CREATED` the addon hooks the nameplate's aura container so any
  aura button the container hands out is flagged as soon as it is laid out.
* On `NAME_PLATE_UNIT_ADDED` and on `UNIT_AURA` for nameplate units it walks
  that nameplate's aura buttons and calls `SetHideCountdownNumbers` on their
  cooldown widgets (plus `noCooldownCount` for third party timers).
* Nothing else is touched: no global hooks, no `CVar` changes, so cooldown text
  everywhere else in the game is unaffected.

Turning the addon off restores the nameplate aura cooldowns to their normal
behaviour right away, i.e. they follow your usual cooldown-number settings again.

## Notes

* Only the **default Blizzard nameplates** are handled. Nameplate addons such as
  Plater or Kui Nameplates draw their own auras and have their own settings for
  this.
* Third party timers only re-read the opt-out flag when a cooldown starts, so
  the addon restarts any cooldown that is already running when you flip that
  option, which makes the change visible immediately.
