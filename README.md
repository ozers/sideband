# Kadran

A menu bar app for controlling external display brightness, contrast and colour
over DDC/CI on Apple silicon Macs.

Built because MSI's own control software is Windows-only, and because DDC/CI is
a standard the monitor speaks whether or not the vendor ships a Mac client.

<!-- TODO: screenshot -->

## What it does

- Controls whatever your display actually implements — brightness, contrast,
  colour temperature, colour presets, RGB gain and black level, picture mode,
  input, volume — and shows nothing it doesn't
- Reads the current values off the display, so the sliders start where the panel
  is, including changes made from the monitor's own menu
- Named profiles with brightness figures derived from published viewing
  standards, applied in one click
- Global keyboard shortcuts for brightness, contrast and profile cycling
- Time-based profile switching, e.g. Night at 20:00
- Launch at login, optionally into a chosen profile
- A CLI in the same binary, for scripting and for interrogating a display:
  `kadran caps`, `kadran get brightness`, `kadran set brightness 40`

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

## Shortcuts

Shortcuts are registered through Carbon's `RegisterEventHotKey` rather than a
global `NSEvent` monitor, so Kadran never asks for Accessibility permission.
A combination already owned by another app cannot be claimed; the Shortcuts tab
marks those with a warning triangle instead of failing quietly.

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

**A capability string is a claim, not a guarantee.** A display may list a feature
and then ignore every write to it — the MSI this was built against advertises
picture mode and never changes it. Kadran reads back after you change a menu
control, and a value that did not take marks the control as ignored, disables it
and says so. It never writes on your behalf to find this out.

**Reads can fail, and are retried.** The DDC bus is slow and half duplex, and an
individual reply gets dropped often enough that a single failure means nothing.
Reads are retried before a feature is treated as unanswered, and writes are
spaced 20 ms apart. A display that answers no capability request at all falls
back to brightness and contrast only, which the Settings window says explicitly
rather than leaving you to guess why a control is missing.

## Where the numbers come from

The built-in profiles are not chosen by eye. Brightness targets come from
published viewing standards and are converted through a panel maximum of roughly
260 cd/m², measured on the QD-OLED this was developed against:

| Profile | Basis | Target |
|---|---|---|
| Day | ISO 9241-303, typical office | 120–150 cd/m² |
| Dim | ISO 9241-303, dark room | 80–100 cd/m² |
| Movie | Rec.709 / BT.1886 reference white, dim surround | 100 cd/m² |
| Bright | ISO 9241-303, well-lit room | 200–250 cd/m² |
| Night | below the dark-room floor, at the warmest colour temperature available | — |

On a display with a different maximum these remain sensible starting points but
are no longer those luminances, which is why they are defaults you edit rather
than a claim of calibration.

Two things are deliberately absent:

**No Game profile.** Game modes change overdrive, black equalisation, sharpness
and saturation. None of that is reachable over DDC, so a "Game" profile could
only ever be a brightness change wearing a misleading name. Displays that expose
their own picture modes offer the real thing through the Picture mode control.

**No RGB gains in the built-in profiles.** A gain's neutral point is
display-specific and not guessable — on this panel it is 50, not the 100 that
looks like "full". Colour is set through colour temperature instead, which is
defined in kelvin and means the same thing everywhere.

## Adding your display

Nothing to add. Kadran asks the display what it implements and builds the UI from
the answer, so a monitor nobody has tested gets the right controls as long as it
answers a capability request. There is no per-model table to contribute to.

If something looks wrong, `kadran caps` prints the raw string — that plus
`kadran list` is everything an issue needs.

## Not covered

Anything a display does not expose over DDC. On the MSI this was built against
that means the entire Gaming OSD feature set — KVM, Smart Crosshair, Optix Scope,
Night Vision, AI Vision, PIP/PBP, Navi Key assignment — none of which appears in
the monitor's capability string, and none of which showed up in a read-only sweep
of the vendor-specific code range either. Those run over a USB HID protocol that
would have to be reverse engineered separately, with the monitor's USB upstream
cable connected.

HDR is not a DDC feature at all. MCCS defines no code for it; on a Mac it is
driven by the display mode the OS selects.

Peak brightness is capped by the panel, not by Kadran. On a QD-OLED, full-screen
white is limited by the automatic brightness limiter, so setting brightness to
100 asks for the maximum and the panel still lands near its sustained figure.

## Prior art

[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
[m1ddc](https://github.com/waydabber/m1ddc) solve the same access problem and
were the reference for the Apple silicon service lookup. Kadran differs in
being built around write-only displays and profile switching rather than around
replacing the system brightness keys.

## Licence

MIT. See [LICENSE](LICENSE).
