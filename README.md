# Kadran

A menu bar app for controlling external display brightness, contrast and colour
over DDC/CI on Apple silicon Macs.

Built because MSI's own control software is Windows-only, and because DDC/CI is
a standard the monitor speaks whether or not the vendor ships a Mac client.

<!-- TODO: screenshot -->

## What it does

- Brightness, contrast and per-channel RGB gain sliders for every attached
  external display
- Named profiles (Day / Night / Movie / Game, plus your own) applied in one click
- A CLI in the same binary, for scripting: `kadran set brightness 40`
- Remembers values per display and can push them back at login

## Requirements

- Apple silicon Mac, macOS 14 or later
- A display connected over DisplayPort or USB-C

Displays behind the built-in HDMI port of entry-level M1/M2 Macs have no
reachable DDC bus. Built-in laptop panels are not DDC devices at all — use the
system brightness keys for those.

## Install

```sh
git clone https://github.com/ozers/kadran.git
cd kadran
Scripts/bundle.sh
cp -r dist/Kadran.app /Applications/
```

The app is signed ad-hoc, so the first launch needs a right-click → Open.

## CLI

The bundled executable doubles as a command line tool:

```sh
/Applications/Kadran.app/Contents/MacOS/Kadran list
/Applications/Kadran.app/Contents/MacOS/Kadran set brightness 40
/Applications/Kadran.app/Contents/MacOS/Kadran set contrast 55 --display 2
```

Features: `brightness`, `contrast`, `red`, `green`, `blue`, `volume`, `input`,
or a raw VCP code such as `0x12`.

## How it works, and what that costs

macOS exposes no public API for the DDC/CI I2C bus. The only route on Apple
silicon is `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C`, which are
private IOKit symbols. Kadran resolves them at runtime with `dlsym` rather than
linking against them, so a macOS release that removes them turns the app into a
polite "DDC unavailable" message instead of a launch-time crash.

Two consequences follow from that, and they are not bugs:

**No App Store.** Private API use disqualifies the app. Build it yourself or
take a release binary.

**Values are remembered, not read.** Many monitors — including the MPG 491C this
was developed against — accept DDC writes but never answer DDC reads. Every read
returns zero. So Kadran stores what it last wrote and shows that. Change
brightness from the monitor's own on-screen menu and the sliders will be wrong
until you move them, and nothing can detect the drift. A monitor that does answer
reads would allow a sync-on-launch; that is not implemented, because the hardware
on hand cannot be used to test it.

## Tested against

| Display | Brightness | Contrast | RGB gain | Volume | Read-back |
|---|---|---|---|---|---|
| MSI MPG 491C OLED (DisplayPort) | yes | yes | yes | untested | none |

Reports for other displays are welcome — open an issue with the output of
`kadran list` and which sliders moved the panel.

## Not covered

Vendor-specific features from MSI's Gaming OSD — Night Vision, crosshair
overlays, KVM switching — are not DDC. They run over a USB HID protocol that
would have to be reverse engineered separately, with the monitor's USB upstream
cable connected.

## Prior art

[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
[m1ddc](https://github.com/waydabber/m1ddc) solve the same access problem and
were the reference for the Apple silicon service lookup. Kadran differs in
being built around write-only displays and profile switching rather than around
replacing the system brightness keys.

## Licence

MIT. See [LICENSE](LICENSE).
