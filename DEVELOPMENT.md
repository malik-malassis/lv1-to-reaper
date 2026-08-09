# Development

Everything in here is for working on the tool. If you just want to use it, the
[README](README.md) is the whole story.

## How it is put together

REAPER's scripting environment cannot open a network socket, so the tool is
split in two halves that talk through a JSON file.

| | |
|---|---|
| **`lv1_fetch.js`** | Dependency-free Node.js helper. Discovers the console (zDNS multicast on `225.1.1.1:13337`), runs the `MyFOH`-style handshake over OSC-on-TCP, asks for the topology, and listens for the `/Channels` broadcast plus `/Notify/TrackColor` and `/Notify/Meters`. Always writes its result file, even on failure, with a machine-readable error so the UI can explain what happened. |
| **`LV1_Track_Importer.lua`** | The REAPER side, built on [ReaImGui](https://github.com/cfillion/reaimgui). Launches the helper detached and polls its output, so REAPER never freezes. |

The result file is written atomically (temp file then rename), and the ReaScript
deletes it before every run - otherwise a failed fetch would silently display
the previous run's track list.

The LV1 protocol was reverse-engineered by
[bitfocus/companion-module-waves-lv1](https://github.com/bitfocus/companion-module-waves-lv1),
and the OSC codec here is a port of their `src/osc.ts`, used under MIT. See
[LICENSE](LICENSE).

## Tests

```bash
npm install   # once, for luaparse
npm test
```

33 checks covering the OSC codec, the zDNS parser, the `/Channels` stride
auto-detection and the mono/stereo decision logic - the parts that cannot be
verified by hand against a live console - plus a Lua parse of the ReaScript and
the cross-file invariants: both halves agreeing on the JSON schema version, the
ReaPack headers being present, `@version` matching `package.json`.

That last check has already caught a real drift on its first run.

The Lua parse matters more than it sounds. REAPER only reports a broken script
when you trigger the action, the message is a bare line number, and an
already-open script window keeps running the previous version - so a syntax
error looks like "my change had no effect" long before it looks like an error.

```bash
npm run lint:lua
```

## Working without a console

```bash
npm run mock
```

Replays `test/fixtures/lv1_tracks.sample.json`, a real 109-track capture, into
the result file the ReaScript reads. The window shows a red **REPLAYED
CAPTURE** banner so a mock list cannot be mistaken for a live one.

## Deploying to REAPER while you work

```bash
npm run deploy
```

Copies the four distributed files into `%APPDATA%\REAPER\Scripts\lv1-reaper`,
verifies each by SHA-256, and clears any stale result file. PowerShell only;
`./deploy.ps1 -Portable "D:\REAPER"` for a portable install.

**A running script keeps the code it was loaded with.** After deploying, close
the importer window and re-run the action - otherwise you are still looking at
the previous version, which is an easy hour to lose.

## Helper CLI

```
node lv1_fetch.js [--host <ip>] [--port <n>] [--scan] [--mock <file>]
                  [--discover-ms 6000] [--listen-ms 4000] [--min-listen-ms 1200]
                  [--out lv1_tracks.json] [--log <file>] [--verbose]
```

Exit codes: `0` ok · `1` connect failed · `2` no LV1 found · `3` host never
announced itself · `4` no handshake · `5` mock file unreadable.

`--scan` lists consoles without connecting. `--verbose` logs every zDNS packet
and OSC message.

## Cutting a release

1. Bump the version in **both** `LV1_Track_Importer.lua` (`@version`, plus a
   `@changelog` entry under the new number) and `package.json`. `npm test`
   fails if the two disagree.
2. Commit, then tag and push:
   ```bash
   git tag -a v2.2.0 -m "v2.2.0" && git push origin main --tags
   ```

That is the whole procedure. `.github/workflows/release.yml` takes over from
the tag and does the rest:

- runs the tests, so a broken tag never becomes a release;
- regenerates `index.xml` - and **fails if the tag and `@version` disagree**,
  before anything is published;
- builds `lv1-to-reaper-v2.2.0.zip` from the tag with `git archive`;
- writes the release notes from the `@changelog` block;
- creates the GitHub release with the archive attached;
- commits the refreshed `index.xml` back to `main`.

That last step is the one worth automating. `index.xml` pins the commit SHA of
the tag, so it has to be regenerated every time; forget it and ReaPack keeps
offering the previous version, with no error shown anywhere.

`git archive` is used rather than `zip` or `Compress-Archive` because it writes
spec-compliant entry names - PowerShell's `Compress-Archive`, the .NET zip API
and `tar -a` each produce something broken or non-portable on Windows - and
because it takes the files from the tag, so the archive cannot drift from what
was tagged.

To run the pieces by hand:

```bash
npm run index    # regenerate index.xml for the latest tag
npm run notes    # print the release notes to stdout
```
