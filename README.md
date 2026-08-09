# LV1 → REAPER

**Build your REAPER recording session straight from your Waves LV1 — names,
colours, mono/stereo and input patching included. About ten seconds instead of
half an hour.**

![The importer after reading a console: 109 channels listed with their names,
colours, mono or stereo width and the hardware input each one will record from.
The sidebar groups them by Inputs, Groups, Aux, Matrix and Masters. The footer
warns in red that the selection needs 71 inputs while the sound card only has
64.](docs/tracks.png)

You pick which channels you want. It creates them in REAPER, already named,
already coloured the same as on the desk, already mono or stereo, already
patched to the right inputs.

---

## It reads your console. It never changes it.

This is worth being clear about, because you are going to run it on a desk
before a show.

The importer **only asks the console questions**. It introduces itself, asks
for the channel list, and hangs up. There is no part of it that can change a
level, a name, a routing, a scene or anything else on your LV1. Running it
during a soundcheck cannot alter your mix.

---

## Before you start

Three things, all free, all one-time.

**1. ReaImGui** — an add-on that lets scripts draw proper windows in REAPER.

In REAPER: `Extensions` → `ReaPack` → `Browse packages…` → type `ReaImGui` →
right-click the one by **cfillion** → `Install` → `OK` → restart REAPER.

> No ReaPack menu? Install it first from [reapack.com](https://reapack.com),
> then restart REAPER.

**2. Node.js** — a small free program the importer uses to talk to your console
over the network. You will never open it yourself.

Download it from [nodejs.org](https://nodejs.org/) (the button on the left),
run the installer, click Next until it finishes.

**3. Your LV1 and your computer on the same network.** Same switch, same
router. Not through a VPN, not on a different Wi-Fi.

---

## Install

### The easy way — ReaPack

In REAPER: `Extensions` → `ReaPack` → `Import repositories…`, then paste this
line and click OK:

```
https://raw.githubusercontent.com/malik-malassis/lv1-to-reaper/main/index.xml
```

Then `Extensions` → `ReaPack` → `Browse packages…` → type `LV1` →
right-click → `Install` → `OK`.

You will get updates automatically from then on.

### Or by hand

1. Download **lv1-to-reaper-v2.1.0.zip** from the
   [Releases page](https://github.com/malik-malassis/lv1-to-reaper/releases).
2. In REAPER: `Options` → `Show REAPER resource path in explorer/finder`.
   A folder window opens.
3. Open the `Scripts` folder inside it, and unzip the download there. You
   should end up with a `Scripts/lv1-reaper/` folder containing four files.
4. In REAPER: `Actions` → `Show action list…` → `New action` →
   `Load ReaScript…` → pick **LV1_Track_Importer.lua**.

> Keep the two files together. `LV1_Track_Importer.lua` needs `lv1_fetch.js`
> sitting right next to it — a copy of only the first one installs fine and
> then fails when you try to fetch.

**Tip:** while you are in the action list, give it a keyboard shortcut or put
it on a toolbar. It is the kind of thing you reach for at the start of every
session.

---

## Using it

Run the action. The blue button always tells you what to do next.

![The window on first launch: empty track list, Scan network highlighted in
blue, Fetch tracks greyed out](docs/window.png)

### 1. Find your console

Click **Scan network**. Every LV1 on the network appears in the list on the
left. Click yours.

![The Devices list showing one console found, with its network
address](docs/scan.png)

It is remembered from then on, so next time you can go straight to step 2.

### 2. Read the channels

Click **Fetch tracks**. Takes two or three seconds. REAPER stays usable while
it works.

### 3. Pick what you want to record

- **Search box** — type a few letters to narrow the list.
- **Sidebar** — click a group (Inputs, Aux, Masters…) to show only that one,
  or tick its box to select the whole group at once.
- **Hide unused** — hides channels still named `Channel 34`, `Fx 2` and so on,
  the ones you never touched on the desk.
- **Shift-click** a tick box to select everything between it and your last
  click.

Channels you renamed on the desk are pre-selected for you, since a renamed
channel is usually a channel in use.

You can also fix anything before creating: rename a track, switch it between
Mono and Stereo, or click its colour square to change it.

The **Input** column shows you, live, which physical input of your sound card
each track will record from. The bar at the bottom sums it up, and turns red if
you have asked for more inputs than your sound card actually has.

### 4. Create them

Click **Create N tracks**. Done.

Run the importer again later and click **Update existing** instead: it
refreshes the names, colours and inputs of the tracks it created before,
without making duplicates.

---

## Settings worth knowing

![The Import tab of the Settings window, with record input pre-patching, its
console-accurate and linear modes, the LR record input box, and the naming,
folder, arming and skip options](docs/settings-import.png)

| Setting | What it means |
|---|---|
| **Pre-patch record inputs** | Each channel track is set to record from the matching input of your sound card. Stereo channels take two. |
| **Console-accurate** | Inputs follow the real desk layout. Skip channel 5 and input 5 stays empty — what you record matches your patch sheet. |
| **Linear** | The channels you picked go on inputs 1, 2, 3… with no gaps, whatever their number on the desk. |
| **LR record input** | If you loop your main mix back into two inputs of your sound card, put the first one's number here. Leave blank if you don't. |
| **Prefix track names** | Names come out as `01 KICK`, `02 SNARE`… so they stay in order. |
| **Group into folders** | Puts the created tracks in folders: Inputs, Groups, Aux… Handy above thirty tracks. |
| **Arm for recording** | Arms every created track straight away. |
| **Skip already imported** | Stops the importer creating a second copy of a track it already made. |

---

## If something doesn't work

**Scan network finds nothing.**
Check the LV1 software is running and that remote control is enabled in its
network settings. Then check both machines really are on the same network — a
VPN, a guest Wi-Fi or two different switches will each break it. On Windows,
the first time you run it you may get a firewall prompt: accept it. If you
clicked "Cancel" once, Windows will keep refusing silently.

**It finds the console but fetching fails.**
Try again — the console changes its connection number every time it restarts,
and the importer re-detects it automatically on the second try. If it still
fails, another program may already be connected to the desk as a remote.

**Nothing happens at all when you click Fetch.**
Node.js is probably not installed, or REAPER can't find it. Open `Settings` →
`Connection` and check the Node.js line. Then open `Settings` → `Advanced` and
tick **Blocking mode**: REAPER will freeze for a few seconds but will show you
the real error.

**The bar at the bottom is red.**
You have selected more channels than your sound card has inputs — counting two
for every stereo channel. Either select fewer, or switch to **Linear** in the
import settings, which packs them without gaps.

**A track came out mono and should be stereo (or the reverse).**
Just click Mono or Stereo on its row before creating. Rows marked with a small
`~` are ones the importer had to guess — those are worth a look.

Still stuck? Open `Settings` → `Advanced`, tick **Verbose diagnostic log**,
fetch again, then copy what appears in the **Diagnostic log** panel at the
bottom of the window into a
[bug report](https://github.com/malik-malassis/lv1-to-reaper/issues). That log
is what makes a problem fixable instead of guessable.

---

## Good to know

- **DCA groups are not imported.** They control other channels, they carry no
  audio of their own, so there is nothing to record.
- **Mono or stereo is detected from the desk's meters** — a channel only shows
  a right-hand meter if it really is stereo. When a channel stays silent long
  enough that no meter arrives, the importer guesses and marks the row with
  `~`. The main LR bus is always stereo.
- **Colours come from the desk.** A channel that arrives without one gets a
  grey square you can click.
- Only channels that have a name are listed.

### What has actually been tested

One console: an **LV1 in 64-channel mode, on Windows**, with a 109-channel
session. The 16, 32 and 80-channel modes, other LV1 versions, macOS and Linux
should all work — nothing in it is tied to a channel count or a system — but
none of them has been tried yet. If you run one of those, say so in the
[issues](https://github.com/malik-malassis/lv1-to-reaper/issues), whether it
worked or not. Both are useful.

---

## Questions, bugs, ideas

[Open an issue](https://github.com/malik-malassis/lv1-to-reaper/issues). For
anything connection-related, include the diagnostic log described above, plus
which mode your LV1 is in (16/32/64/80 channels) and whether you are on Windows
or Mac.

This is maintained by one person around actual gigs, so answers may take a
while.

---

## Licence

Free to use, share and modify for **anything non-commercial** — your own work,
your band, teaching, associations, public institutions.
**Selling it, or any part of it, or shipping it inside a product you sell, is
not allowed.** Full text in [LICENSE](LICENSE).

It comes with no warranty. Try it on a rehearsal before you rely on it at a
show.

The part that speaks the LV1's language was worked out by the
[bitfocus/companion-module-waves-lv1](https://github.com/bitfocus/companion-module-waves-lv1)
project and is reused here under their MIT licence. Without their work this
tool would not exist.

Waves and LV1 are trademarks of Waves Audio Ltd. REAPER is a trademark of
Cockos Incorporated. This project has nothing to do with either company.

---

*Working on the code? See [DEVELOPMENT.md](DEVELOPMENT.md).*
