#!/usr/bin/env node
'use strict'

// Regenerates index.xml, the file ReaPack reads to know which versions exist
// and where to download them.
//
// The <source> URLs pin the commit SHA of the tag rather than a branch, so an
// install always gets the exact files that version was tested with — which
// also means this file MUST be regenerated for every release. Forgetting it
// leaves ReaPack users silently on the old version, with no error anywhere.
//
//   node tools/make-index.js            # uses the most recent tag
//   node tools/make-index.js v2.2.0     # uses a specific tag

const fs = require('fs')
const path = require('path')
const { execSync } = require('child_process')

const ROOT = path.join(__dirname, '..')
const REPO = 'malik-malassis/lv1-to-reaper'
const AUTHOR = 'malik-malassis'
const CATEGORY = 'LV1'
const MAIN = 'LV1_Track_Importer.lua'
const EXTRA = ['lv1_fetch.js']

const git = (cmd) => execSync(cmd, { cwd: ROOT, encoding: 'utf8' }).trim()

function fail(msg) {
	console.error(`make-index: ${msg}`)
	process.exit(1)
}

const tag = process.argv[2] || (() => {
	try {
		return git('git describe --tags --abbrev=0')
	} catch {
		fail('no tag given and no tag found in this repository')
	}
})()

let sha
try {
	sha = git(`git rev-list -n 1 ${tag}`)
} catch {
	fail(`tag ${tag} does not exist`)
}

const lua = fs.readFileSync(path.join(ROOT, MAIN), 'utf8').replace(/\r\n/g, '\n')
const version = (lua.match(/^-- @version (\S+)$/m) || [])[1]
const desc = (lua.match(/^-- @description (.+)$/m) || [])[1]
if (!version || !desc) fail(`could not read @version / @description from ${MAIN}`)

// The tag and the script header must agree, or ReaPack would advertise a
// version number that does not match the file it hands out.
if (tag.replace(/^v/, '') !== version) {
	fail(`tag ${tag} does not match @version ${version} in ${MAIN} — bump one of them`)
}

// Pull out the changelog entries for this version only, stopping at the next
// version heading.
function changelogFor(v) {
	const block = lua.match(/^-- @changelog\n((?:--.*\n)+)/m)
	if (!block) return ''
	const lines = block[1].split('\n').map((l) => l.replace(/^--\s{0,3}/, ''))
	const start = lines.findIndex((l) => l.trim() === v)
	if (start === -1) return ''
	const out = []
	for (let i = start + 1; i < lines.length; i++) {
		if (/^\s*\d+\.\d+/.test(lines[i])) break
		out.push(lines[i].replace(/^\s{0,2}/, ''))
	}
	return out.join('\n').trim()
}

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const time = new Date(git(`git log -1 --format=%cI ${sha}`)).toISOString().replace(/\.\d{3}Z$/, 'Z')
const base = `https://github.com/${REPO}/raw/${sha}/`

const sources = [`        <source main="main">${base}${MAIN}</source>`]
	.concat(EXTRA.map((f) => `        <source file="${f}">${base}${f}</source>`))
	.join('\n')

const xml = `<?xml version="1.0" encoding="utf-8"?>
<index version="1" name="LV1 to REAPER">
  <category name="${CATEGORY}">
    <reapack name="${MAIN}" type="script" desc="${esc(desc)}">
      <metadata>
        <link rel="website">https://github.com/${REPO}</link>
      </metadata>
      <version name="${version}" author="${AUTHOR}" time="${time}">
        <changelog><![CDATA[${changelogFor(version)}]]></changelog>
${sources}
      </version>
    </reapack>
  </category>
</index>
`

fs.writeFileSync(path.join(ROOT, 'index.xml'), xml)
console.log(`make-index: ${tag} -> ${sha.slice(0, 10)} (version ${version})`)
