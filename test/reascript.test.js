'use strict'

// Checks on the ReaScript half of the project. There is no way to unit-test
// ReaImGui drawing code outside REAPER, but the two things that silently break
// a release - a syntax error, and the two halves disagreeing about the file
// format they exchange - are both checkable from here.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const ROOT = path.join(__dirname, '..')
const LUA_PATH = path.join(ROOT, 'LV1_Track_Importer.lua')
// Normalise line endings: on Windows with core.autocrlf the working copy is
// checked out as CRLF, and a pattern matching an explicit \n would then fail
// for reasons that have nothing to do with what is being tested.
const LUA = fs.readFileSync(LUA_PATH, 'utf8').replace(/\r\n/g, '\n')
const lv1 = require('../lv1_fetch.js')

let luaparse
try {
	luaparse = require('luaparse')
} catch {
	luaparse = null
}

test('the ReaScript parses as Lua 5.3', { skip: luaparse ? false : 'luaparse not installed (run npm install)' }, () => {
	assert.doesNotThrow(() => luaparse.parse(LUA, { luaVersion: '5.3' }))
})

test('both halves agree on the result-file schema version', () => {
	const declared = LUA.match(/^local SCHEMA_VERSION = (\d+)$/m)
	assert.ok(declared, 'SCHEMA_VERSION not found in the ReaScript')
	assert.equal(
		Number(declared[1]),
		lv1.SCHEMA_VERSION,
		'lv1_fetch.js and LV1_Track_Importer.lua disagree about the JSON schema version - ' +
		'bump both, or the UI will refuse the file it is handed'
	)
})

test('the ReaScript carries the ReaPack metadata needed to distribute it', () => {
	for (const field of ['@description', '@author', '@version', '@provides']) {
		assert.ok(LUA.includes(field), `missing ${field} header`)
	}
	// @provides must ship the Node helper: the ReaScript looks for it next to
	// itself, so a package containing only the .lua installs broken.
	const provides = LUA.match(/^-- @provides\n((?:--\s+\S.*\n)+)/m)
	assert.ok(provides, '@provides block not found')
	assert.match(provides[1], /lv1_fetch\.js/, '@provides must include lv1_fetch.js')
})

test('the version in the ReaScript header matches package.json', () => {
	const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'))
	const header = LUA.match(/^-- @version (\S+)$/m)
	assert.ok(header, '@version header not found')
	assert.equal(pkg.version, header[1], 'package.json and the ReaScript header disagree on the version')
})
