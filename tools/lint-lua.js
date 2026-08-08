#!/usr/bin/env node
'use strict'

// Parses the ReaScript so a syntax error can never reach REAPER.
//
// This matters more than it sounds: REAPER only reports a broken script when
// you trigger the action, the message is a bare line number in a modal, and an
// already-open script window keeps running the previous version — so a typo can
// look like "my change had no effect" for a long time before it looks like an
// error.
//
//   npm run lint:lua

const fs = require('fs')
const path = require('path')

let luaparse
try {
	luaparse = require('luaparse')
} catch {
	console.error('luaparse is not installed. Run: npm install')
	process.exitCode = 1
	return
}

const ROOT = path.join(__dirname, '..')
const FILES = process.argv.slice(2).length ? process.argv.slice(2) : ['LV1_Track_Importer.lua']

let failed = 0
for (const rel of FILES) {
	const file = path.resolve(ROOT, rel)
	const source = fs.readFileSync(file, 'utf8')
	try {
		// REAPER embeds Lua 5.3/5.4; the script uses 5.3 bitwise operators.
		luaparse.parse(source, { luaVersion: '5.3' })
		console.log(`ok   ${rel}`)
	} catch (err) {
		failed++
		console.error(`FAIL ${rel}: ${err.message}`)
		const line = err.line || 0
		const lines = source.split('\n')
		for (let i = Math.max(0, line - 3); i < Math.min(lines.length, line + 2); i++) {
			console.error(`  ${String(i + 1).padStart(5)} | ${lines[i]}`)
		}
	}
}

if (failed) process.exitCode = 1
