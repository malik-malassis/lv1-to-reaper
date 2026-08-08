# LV1 → REAPER Track Importer

Connects to a Waves LV1 live mixer on the network and creates the tracks you
pick in the current REAPER project — carrying over **name**, **mono/stereo
width** and **color**, and optionally **pre-patching the record inputs**.

Built for the live multitrack workflow: fetch, tick what you need, create.
A 64-channel console goes from "nothing" to a fully named, colored, correctly
patched REAPER session in about ten seconds.

<!-- TODO: replace with a real screenshot of the window, e.g. docs/screenshot.png -->
```
┌──────────────────────────────────────────────────────────────────────────┐
│ LV1 -> REAPER   ● LV1-CLASSIC 192.168.1.40   [Fetch tracks][Scan][⚙]     │
├────────────┬─────────────────────────────────────────────────────────────┤
│ DEVICES    │ [Search...]  ☐ Hide unused   [All][None][Invert]  24/110    │
│ ● LV1-CLA. │  ☑ ▉ In 1   KICK IN     [Mono│Ster]   1                     │
│ ○ LV1-B    │  ☑ ▉ In 9   OH          [Mono│Ster]   9/10                  │
│            │  ☐ ▉ Grp 1  DRUMS       [Mono│Ster]   -                     │
│ GROUPS     │  ☑ ▉ LR 1   LR          [Mono│Ster]   31/32                 │
│ ☑ Inputs   │                                                             │
│ ☐ Groups   │                                                             │
├────────────┴─────────────────────────────────────────────────────────────┤
│ 24 tracks | 18 mono, 6 stereo | inputs 1-30   [Update existing][Create]  │
└──────────────────────────────────────────────────────────────────────────┘
```

## It never changes anything on your console

The helper only ever sends five messages to the LV1: `/handshake`,
`/device_name`, `/Get/Aux/Tracks`, `/Get/Layers` and `/pong`. Four are the
connection handshake and the keep-alive; two are read requests. **There is no
code path in this project that writes a value to the mixer** — no level, no
name, no routing, no scene recall. It registers as a remote-control client,
reads the topology the console broadcasts, and disconnects.

You can verify it yourself: every outgoing message is a `send(...)` call in
[lv1_fetch.js](lv1_fetch.js), and there are five of them.

## How it works

REAPER's ReaScript environment can't open raw TCP sockets, so the tool is
split in two:

1. **[lv1_fetch.js](lv1_fetch.js)** — a dependency-free Node.js helper. It
   discovers the LV1 via zDNS (UDP multicast `225.1.1.1:13337`), runs the
   `MyFOH`-style handshake over OSC-on-TCP, requests the topology and listens
   for the LV1's `/Channels` broadcast plus `/Notify/TrackColor` and
   `/Notify/Meters` events. It writes `lv1_tracks.json` — always, even on
   failure, with a machine-readable error so the UI can explain what happened.
2. **[LV1_Track_Importer.lua](LV1_Track_Importer.lua)** — a REAPER ReaScript
   built on **[ReaImGui](https://github.com/cfillion/reaimgui)**. It launches
   the helper in the background (REAPER stays responsive), reads the result,
   and gives you a filterable track list with live record-input preview.

The LV1 wire protocol was reverse-engineered by the MIT-licensed
[bitfocus/companion-module-waves-lv1](https://github.com/bitfocus/companion-module-waves-lv1)
project, and the OSC codec in `lv1_fetch.js` is a JavaScript port of their
`src/osc.ts`. Those portions are used under the MIT License — see
[LICENSE](LICENSE) for the full attribution. Without that project this tool
would not exist.

## Requirements

- REAPER with ReaScript (Lua) enabled.
- **[ReaImGui](https://github.com/cfillion/reaimgui)** (author: cfillion),
  installed via [ReaPack](https://reapack.com): Extensions → ReaPack → Browse
  packages… → search "ReaImGui" → Install → restart REAPER. The script shows a
  reminder dialog if it's missing. Both the modern `require 'imgui'` API and
  the older `reaper.ImGui_*` one are supported.
- [Node.js](https://nodejs.org/) 16+ on `PATH` (or point the script at a full
  path in Settings → Connection).
- The LV1 and the REAPER machine on the same LAN/subnet, for zDNS multicast
  discovery to work.

> **Platform:** developed and tested on Windows only. The ReaScript builds
> POSIX-quoted commands and the Node helper has no Windows-specific code, so
> macOS and Linux should work — but neither has been run. `deploy.ps1` is
> PowerShell; on macOS/Linux, copy `LV1_Track_Importer.lua` and
> `lv1_fetch.js` into `~/Library/Application Support/REAPER/Scripts/` (or
> `~/.config/REAPER/Scripts/`) yourself. Reports welcome.

## Install

No build step, no npm, no command line needed.

1. Download the latest release archive from
   [Releases](https://github.com/malik-malassis/lv1-to-reaper/releases).
2. Unzip it into REAPER's `Scripts` folder, so you end up with a folder like:
   - Windows — `%APPDATA%\REAPER\Scripts\lv1-reaper\`
   - macOS — `~/Library/Application Support/REAPER/Scripts/lv1-reaper/`
   - Linux — `~/.config/REAPER/Scripts/lv1-reaper/`
3. In REAPER: Actions → Show action list → New action → **Load ReaScript…** →
   select `LV1_Track_Importer.lua`.
4. Run the action. (Assign it a keyboard shortcut or a toolbar button while
   you're in the action list — it's the kind of tool you reach for at the
   start of every session.)

> **`LV1_Track_Importer.lua` and `lv1_fetch.js` must sit in the same folder.**
> The ReaScript looks for the helper next to itself; a copy of only the `.lua`
> installs cleanly and then fails at fetch time.

<details>
<summary>Installing from a clone instead (contributors)</summary>

```powershell
npm run deploy
```

Copies the four distributed files to `%APPDATA%\REAPER\Scripts\lv1-reaper`,
verifies each one by SHA-256, and removes any stale result file left over from
a previous run. For a portable REAPER install:
`./deploy.ps1 -Portable "D:\REAPER"`. PowerShell only — on macOS and Linux,
copy the files by hand.

</details>

## Usage

1. **Fetch tracks** — connects and reads the console. With several LV1s on the
   network, hit **Scan network** first and pick the right one in the sidebar.
2. Filter with the search box, the group list, or **Hide unused** (which hides
   channels still carrying an LV1 factory name like `Channel 12` or `Fx 3`).
3. Tick what you want — **shift-click a checkbox to tick a whole range**.
   Adjust name, Mono/Stereo or color inline; the **Input** column shows live
   which hardware input each track will land on, and the footer turns red if
   the selection needs more inputs than your audio device actually has.
4. **Create N tracks**, or **Update existing** to refresh tracks a previous
   run already created.

The blue button is always the next step: **Scan network** until a console is
selected, then **Fetch tracks**. Fetch stays disabled while no console is
chosen. A console picked in an earlier session is restored from the settings
and stays listed, so you don't have to rescan at every REAPER launch.

Fetching runs in the background: REAPER stays usable, and the progress strip
shows the helper's live log. A typical fetch takes 2–3 s because the helper
stops as soon as the track list and meter frames have arrived, rather than
always waiting out its full timeout.

## Import options (Settings → Import)

| Option | What it does |
|---|---|
| **Pre-patch record inputs** | Assigns each `In` track's record input, mono/stereo aware. |
| **Console-accurate** | Hardware inputs follow the real console layout — skipped channels leave gaps, stereo channels consume two slots. |
| **Linear** | Selected channels are patched to a contiguous block starting at input 1. |
| **LR record input** | 1-based hardware channel your main-mix analog return is wired to. Blank = LR gets no input. Specific to your rig, so it can't be auto-detected. |
| **Prefix track names** | `01 KICK IN`, zero-padded so names sort correctly. |
| **Group into folders** | Creates `LV1 INPUTS`, `LV1 GROUPS`, … folder tracks. |
| **Arm for recording** | Record-arms every created track. |
| **Skip already imported** | Created tracks are tagged with their LV1 identity, so re-running never duplicates them. |

## Notes / limitations

- **DCA groups and internal `HidLink` channels are deliberately not imported**
  — DCAs carry no audio of their own, and `HidLink` is an LV1-internal
  pseudo-channel.
- Mono/stereo is detected from the LV1's meter frames: a channel only ever
  emits a right-channel VU if it really is a stereo pair. When no meter frame
  arrives for a channel in time, the tool falls back to the stereo-width value
  and **marks the row with `~`** so you know to check it. The LR bus is always
  forced to stereo.
- Colors come from `/Notify/TrackColor`. In practice the LV1 dumps them for
  every channel on connect; a channel that somehow arrives without one gets a
  grey swatch you can click to set manually.
- Only channels with a resolved name are listed.
- Record inputs are checked against `GetNumAudioInputs()`. REAPER accepts an
  input index past the end of the device and simply shows an unusable entry,
  which you'd discover when arming the track, so the footer flags the
  mismatch before anything is created.

### What has actually been tested

Development and testing were done against **one console: an LV1 in 64-channel
mode, on Windows**, with a 109-track session (64 inputs, 8 groups, 24 aux/FX,
8 matrix, LR/C/M, cue and talkback).

The 16, 32 and 80-channel modes, other LV1 versions, macOS and Linux are all
*expected* to work — nothing in the code is specific to a channel count or a
platform — but none of them has been run. If you try one, a report either way
is genuinely useful; the diagnostic log (Settings → Advanced → Verbose) is
what makes a bug report actionable.

The `/Channels` message layout is the part most likely to drift between LV1
firmware versions. The helper auto-detects the argument stride rather than
assuming the documented one, and says so in the log when it finds something
other than 19 — so a firmware change should degrade to a warning rather than
to an empty track list.

## Troubleshooting

**The LV1's OSC port is dynamic** — it changes every time the LV1 app restarts
or the mixer mode changes (16/32/64/80ch). There is no default port, so it is
always resolved from the zDNS announcement, even when you enter the IP by
hand. If a saved port turns out to be stale, the helper re-resolves it and
retries once automatically.

If nothing is found, check in order:

1. **Same subnet/VLAN.** zDNS multicast does not route across subnets, VLANs
   or a VPN. REAPER in a NAT-networked VM/WSL will also fail — use bridged
   networking.
2. **Windows Firewall.** The first time `node.exe` opens a UDP socket, Windows
   may prompt to allow it on Private networks — accept. If you never saw the
   prompt, add an inbound rule for `node.exe` on Private networks manually.
3. **Antivirus / third-party firewall** can silently drop multicast UDP.
4. **Port 13337 already in use** — another LV1 tool or a Companion instance
   holding it will be reported explicitly in the log.
5. **LV1 app running** with OSC/remote control enabled in its network prefs.
6. Turn on **Verbose diagnostic log** (Settings → Advanced) and re-fetch: the
   log shows every raw `/zDNS` packet and every OSC message, which tells you
   whether the problem is discovery (no packets at all) or the handshake (TCP
   connects but no `/handshake` ACK).
7. If the background launch fails silently, enable **blocking mode** (Settings
   → Advanced): it runs the helper synchronously and surfaces the OS error.

Run the helper straight from a terminal to see everything live:

```bash
node lv1_fetch.js --scan --verbose
```

```bash
node lv1_fetch.js --host 192.168.1.40 --verbose
```

## Development

```bash
npm test
```

33 checks: the OSC codec, the zDNS parser, the `/Channels` stride
auto-detection and the mono/stereo decision logic — the parts that can't be
verified by hand against a live console — plus a Lua parse of the ReaScript
and the cross-file invariants (both halves agreeing on the JSON schema
version, the ReaPack headers being present, the version matching
`package.json`).

The Lua parse matters more than it sounds: REAPER only reports a broken
script when you trigger the action, the message is a bare line number, and an
already-open script window keeps running the previous version — so a syntax
error looks like "my change had no effect" long before it looks like an
error. Run it alone with:

```bash
npm run lint:lua
```

Work on the UI with no mixer on the network by replaying a captured session:

```bash
npm run mock
```

This writes `lv1_tracks.json` from `test/fixtures/lv1_tracks.sample.json`
(a real 109-track capture), which the ReaScript then reads normally. The
window shows a red **REPLAYED CAPTURE** banner so a mock list can't be
mistaken for a live one.

### Publishing via ReaPack

The script already carries the headers ReaPack needs (`@description`,
`@author`, `@version`, `@provides`, `@about`, `@changelog`) — `npm test`
fails if any goes missing or if `@version` drifts from `package.json`.

To make the tool installable through ReaPack (in addition to the Releases
download above), generate the index with
[reapack-index](https://github.com/cfillion/reapack-index) (a Ruby gem) — the
repository must be public:

```bash
gem install reapack-index && reapack-index --commit
```

It reads the headers from the git history and writes `index.xml`; users then
add your repository's raw `index.xml` URL in ReaPack → Import repositories.
Bump `@version` **and** `package.json` together for each release — the index
keys off the header, and the test keys off both.

### Helper CLI

```
node lv1_fetch.js [--host <ip>] [--port <n>] [--scan] [--mock <file>]
                  [--discover-ms 6000] [--listen-ms 4000] [--min-listen-ms 1200]
                  [--out lv1_tracks.json] [--log <file>] [--verbose]
```

Exit codes: `0` ok · `1` connect failed · `2` no LV1 found · `3` host never
announced itself · `4` no handshake · `5` mock file unreadable.

## Support

Bugs and questions go to
[Issues](https://github.com/malik-malassis/lv1-to-reaper/issues).

For anything connection-related, attach the diagnostic log: Settings →
Advanced → tick **Verbose diagnostic log**, fetch again, then copy the
**Diagnostic log** panel. It contains every zDNS packet and OSC message
exchanged, which is what makes the difference between a guess and a fix.
Please also say which LV1 mode you're in (16/32/64/80 ch) and your OS.

This is a tool one person maintains alongside actual gigs — no response-time
promises. Pull requests are welcome; run `npm test` before opening one.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free to use, modify and share for
any noncommercial purpose: personal use, hobby projects, education, charities,
public research and government institutions all qualify. **Selling it, or any
part of it, or shipping it inside a commercial product or service, is not
permitted** without a separate licence.

Note that a restriction on commercial use means this is **source-available**
software, not open source in the strict sense — the Open Source Definition
does not allow restrictions on the field of use. The source is public, and it
is free for the people it is written for.

The OSC codec is used under the MIT License from
[bitfocus/companion-module-waves-lv1](https://github.com/bitfocus/companion-module-waves-lv1);
those portions remain under MIT. See [LICENSE](LICENSE) for details.

Waves and LV1 are trademarks of Waves Audio Ltd. REAPER is a trademark of
Cockos Incorporated. This project is not affiliated with, endorsed by, or
supported by either company. It reads from the console and never writes to it,
but it comes with no warranty of any kind — test it before you rely on it at
a show.
