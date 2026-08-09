#!/usr/bin/env node
'use strict'

// Prints the release notes for a version to stdout: the @changelog entries
// from the ReaScript header, plus the standing install instructions, so the
// GitHub release page is useful on its own to someone who has never seen the
// repository.
//
//   node tools/changelog.js            # version from the script header
//   node tools/changelog.js 2.2.0

const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const REPO = 'malik-malassis/lv1-to-reaper'
const lua = fs.readFileSync(path.join(ROOT, 'LV1_Track_Importer.lua'), 'utf8').replace(/\r\n/g, '\n')

const version = (process.argv[2] || (lua.match(/^-- @version (\S+)$/m) || [])[1] || '').replace(/^v/, '')
if (!version) {
	console.error('changelog: could not determine the version')
	process.exit(1)
}

const block = lua.match(/^-- @changelog\n((?:--.*\n)+)/m)
let entries = ''
if (block) {
	const lines = block[1].split('\n').map((l) => l.replace(/^--\s{0,3}/, ''))
	const start = lines.findIndex((l) => l.trim() === version)
	if (start !== -1) {
		const out = []
		for (let i = start + 1; i < lines.length; i++) {
			if (/^\s*\d+\.\d+/.test(lines[i])) break
			out.push(lines[i].replace(/^\s{0,2}/, ''))
		}
		entries = out.join('\n').trim()
	}
}

process.stdout.write(`${entries ? `## What's new\n\n${entries}\n\n` : ''}## Install

**With ReaPack** — in REAPER: Extensions → ReaPack → Import repositories, paste

\`\`\`
https://raw.githubusercontent.com/${REPO}/main/index.xml
\`\`\`

then Browse packages → search \`LV1\` → Install. Updates arrive automatically
from then on.

**By hand** — download the zip below. In REAPER: Options → Show REAPER resource
path, open the \`Scripts\` folder, unzip there. Then Actions → Show action list
→ New action → Load ReaScript → \`LV1_Track_Importer.lua\`.

Keep \`LV1_Track_Importer.lua\` and \`lv1_fetch.js\` in the same folder.

You also need [ReaImGui](https://github.com/cfillion/reaimgui) (via ReaPack)
and [Node.js](https://nodejs.org/) 16+. Full instructions in the
[README](https://github.com/${REPO}#readme).

---

The importer only reads your console — it cannot change a level, a name or a
routing on the desk.

Free for any non-commercial use; not for sale. See
[LICENSE](https://github.com/${REPO}/blob/main/LICENSE).
`)
