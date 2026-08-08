'use strict'

// Unit tests for the pure parts of lv1_fetch.js — the OSC codec, the zDNS
// parser and the track-list builder. These are exactly the pieces that are
// impossible to check by hand against a live console (you can't make an LV1
// send you a malformed packet on demand), and the ones a firmware update is
// most likely to break.
//
//   npm test

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const lv1 = require('../lv1_fetch.js')

// ─── OSC codec ──────────────────────────────────────────────────────────

test('encode/decode round-trips an address with mixed argument types', () => {
	const buf = lv1.encodeMessage('/Notify/Track/Name', [
		{ type: 'i', value: 0 },
		{ type: 'i', value: 11 },
		{ type: 's', value: 'KICK IN' },
	])
	const msg = lv1.decodeMessage(buf)
	assert.equal(msg.address, '/Notify/Track/Name')
	assert.deepEqual(msg.args.map((a) => a.type), ['i', 'i', 's'])
	assert.equal(msg.args[2].value, 'KICK IN')
})

test('encoded messages are 4-byte aligned as OSC 1.0 requires', () => {
	for (const name of ['/a', '/ab', '/abc', '/abcd', '/abcde']) {
		const buf = lv1.encodeMessage(name, [{ type: 's', value: 'x'.repeat(name.length) }])
		assert.equal(buf.length % 4, 0, `${name} produced a ${buf.length}-byte packet`)
	}
})

test('floats survive the round trip', () => {
	const buf = lv1.encodeMessage('/Notify/TrackColor', [
		{ type: 'i', value: 0 }, { type: 'i', value: 3 }, { type: 'i', value: 0 },
		{ type: 'f', value: 0.5 }, { type: 'f', value: 0.25 }, { type: 'f', value: 1 },
	])
	const msg = lv1.decodeMessage(buf)
	assert.equal(msg.args[3].value, 0.5)
	assert.equal(msg.args[5].value, 1)
})

test('a truncated packet decodes to what it can instead of throwing', () => {
	const full = lv1.encodeMessage('/Notify/Meters', [
		{ type: 'i', value: 2 }, { type: 'i', value: 0 }, { type: 'i', value: 1 },
	])
	// Chop the payload but keep the address and type tag intact.
	const truncated = full.subarray(0, full.length - 5)
	const msg = lv1.decodeMessage(truncated)
	assert.equal(msg.address, '/Notify/Meters')
	assert.ok(msg.args.length < 3, 'should stop at the first argument it cannot read')
	assert.equal(msg.truncated, true)
})

test('an unterminated OSC string is reported, not silently accepted', () => {
	assert.throws(() => lv1.readString(Buffer.from('abc'), 0), /not null-terminated/)
})

// ─── zDNS discovery ─────────────────────────────────────────────────────

function zdnsPacket({ service = '_waveslv113._tcp', host = 'LV1-CLASSIC', port = 49699, ips = ['192.168.1.40'] } = {}) {
	return lv1.encodeMessage('/zDNS', [
		{ type: 's', value: service },
		{ type: 'i', value: 1 },
		{ type: 's', value: host },
		{ type: 'i', value: port },
		...ips.map((ip) => ({ type: 's', value: ip })),
	])
}

test('parseZDNS extracts the service, hostname, port and IPv4 addresses', () => {
	const z = lv1.parseZDNS(zdnsPacket())
	assert.equal(z.service, '_waveslv113._tcp')
	assert.equal(z.host, 'LV1-CLASSIC')
	assert.equal(z.port, 49699)
	assert.deepEqual(z.ipv4s, ['192.168.1.40'])
})

test('parseZDNS ignores packets that are not /zDNS', () => {
	assert.equal(lv1.parseZDNS(lv1.encodeMessage('/ping', [])), null)
	assert.equal(lv1.parseZDNS(Buffer.from([1, 2, 3])), null)
})

test('a device announcing several NICs is ranked to the most reachable one', () => {
	const dev = lv1.makeDevice(lv1.parseZDNS(zdnsPacket({ ips: ['169.254.7.7', '192.168.1.40', '172.17.0.1'] })))
	assert.equal(dev.address, '192.168.1.40', 'a link-local or docker address must never win')
	assert.equal(dev.addresses[dev.addresses.length - 1], '169.254.7.7')
})

test('rankIp puts a LAN address above a virtual or link-local one', () => {
	assert.ok(lv1.rankIp('192.168.1.40') > lv1.rankIp('192.168.56.1'))
	assert.ok(lv1.rankIp('10.0.0.5') > lv1.rankIp('172.17.0.1'))
	assert.ok(lv1.rankIp('172.17.0.1') > lv1.rankIp('169.254.1.1'))
	assert.ok(lv1.rankIp('169.254.1.1') > lv1.rankIp('127.0.0.1'))
})

test('deviceMatches accepts the address, any alias and the hostname', () => {
	const dev = lv1.makeDevice(lv1.parseZDNS(zdnsPacket({ ips: ['192.168.1.40', '10.0.0.9'] })))
	assert.ok(lv1.deviceMatches(dev, '192.168.1.40'))
	assert.ok(lv1.deviceMatches(dev, '10.0.0.9'))
	assert.ok(lv1.deviceMatches(dev, 'LV1-CLASSIC'))
	assert.ok(!lv1.deviceMatches(dev, '192.168.1.41'))
	assert.ok(!lv1.deviceMatches(dev, ''))
})

// ─── /Channels bulk message ─────────────────────────────────────────────

// Builds the decoded-args array of a /Channels message with `count` tracks at
// an arbitrary stride, so the auto-detection can be exercised against layouts
// other than the documented one.
function channelsArgs(tracks, stride) {
	const args = [{ type: 'i', value: tracks.length }]
	for (const t of tracks) {
		const slot = [
			{ type: 's', value: t.name },
			{ type: 'i', value: t.group },
			{ type: 'i', value: t.ch },
			{ type: 'd', value: t.pan ?? 0 },
			{ type: 'd', value: t.width ?? 0 },
		]
		while (slot.length < stride) slot.push({ type: 'i', value: 0 })
		args.push(...slot)
	}
	return args
}

const SAMPLE = [
	{ name: 'KICK IN', group: 0, ch: 0, pan: 0, width: 0 },
	{ name: 'OH', group: 0, ch: 8, pan: 0, width: 1 },
	{ name: 'LR', group: 3, ch: 0, pan: 0, width: 1 },
]

test('the documented 19-arg stride is decoded', () => {
	const parsed = lv1.parseChannelsMessage(channelsArgs(SAMPLE, 19))
	assert.equal(parsed.stride, 19)
	assert.equal(parsed.tracks.length, 3)
	assert.deepEqual(parsed.tracks.map((t) => t.name), ['KICK IN', 'OH', 'LR'])
	assert.equal(parsed.tracks[1].width, 1)
})

test('a firmware that changes the stride is auto-detected instead of decoding to nothing', () => {
	for (const stride of [17, 21, 24]) {
		const parsed = lv1.parseChannelsMessage(channelsArgs(SAMPLE, stride))
		assert.equal(parsed.stride, stride, `stride ${stride} was not detected`)
		assert.deepEqual(parsed.tracks.map((t) => t.ch), [0, 8, 0])
	}
})

test('a /Channels message whose layout makes no sense yields no tracks and no crash', () => {
	const junk = [{ type: 'i', value: 4 }, { type: 'i', value: 1 }, { type: 'i', value: 2 }]
	const parsed = lv1.parseChannelsMessage(junk)
	assert.equal(parsed.stride, null)
	assert.deepEqual(parsed.tracks, [])
})

test('an absurd track count is rejected rather than trusted', () => {
	assert.deepEqual(lv1.parseChannelsMessage([{ type: 'i', value: 99999 }]).tracks, [])
	assert.deepEqual(lv1.parseChannelsMessage([{ type: 'i', value: -1 }]).tracks, [])
})

test('detectChannelStride prefers the documented stride when several fit', () => {
	assert.equal(lv1.detectChannelStride(channelsArgs(SAMPLE, 19), 3), 19)
})

// ─── track list building ────────────────────────────────────────────────

const ch = (o) => ({ group: 0, ch: 0, name: 'x', pan: 0, width: 0, color: null, hasRightMeter: null, ...o })

test('DCA and internal HidLink channels never become REAPER tracks', () => {
	const tracks = lv1.buildTracks([
		ch({ group: 0, ch: 0, name: 'KICK' }),
		ch({ group: 12, ch: 0, name: 'DCA 1' }),
		ch({ group: 24, ch: 0, name: 'HidLink:0' }),
	])
	assert.deepEqual(tracks.map((t) => t.name), ['KICK'])
})

test('channels with no name are dropped', () => {
	const tracks = lv1.buildTracks([ch({ name: null }), ch({ ch: 1, name: '' }), ch({ ch: 2, name: 'VOX' })])
	assert.deepEqual(tracks.map((t) => t.name), ['VOX'])
})

test('a right-channel meter frame is what decides stereo, not the width knob', () => {
	// width says "stereo", the meters say mono — the meters win.
	const [t] = lv1.buildTracks([ch({ name: 'SNARE', width: 0.8, hasRightMeter: false })])
	assert.equal(t.stereo, false)
	assert.equal(t.detect, 'meter')
})

test('width is only used as a fallback when no meter frame was seen', () => {
	const [wide, narrow] = lv1.buildTracks([
		ch({ ch: 0, name: 'OH', width: 0.9, hasRightMeter: null }),
		ch({ ch: 1, name: 'SNARE', width: 0, hasRightMeter: null }),
	])
	assert.equal(wide.stereo, true)
	assert.equal(wide.detect, 'width', 'the UI relies on this flag to mark the value as a guess')
	assert.equal(narrow.stereo, false)
})

test('the LR master bus is always stereo regardless of what detection says', () => {
	const [t] = lv1.buildTracks([ch({ group: 3, name: 'LR', width: 0, hasRightMeter: false })])
	assert.equal(t.stereo, true)
	assert.equal(t.detect, 'bus')
})

test('tracks come out sorted by group then channel', () => {
	const tracks = lv1.buildTracks([
		ch({ group: 3, ch: 0, name: 'LR' }),
		ch({ group: 0, ch: 5, name: 'TOM' }),
		ch({ group: 0, ch: 1, name: 'KICK' }),
		ch({ group: 2, ch: 0, name: 'VERB' }),
	])
	assert.deepEqual(tracks.map((t) => t.name), ['KICK', 'TOM', 'VERB', 'LR'])
})

test('colors are converted to hex and clamped to the valid range', () => {
	assert.equal(lv1.rgbToHex({ r: 0, g: 0, b: 0 }), '#000000')
	assert.equal(lv1.rgbToHex({ r: 1, g: 1, b: 1 }), '#ffffff')
	assert.equal(lv1.rgbToHex({ r: 0.5, g: 0.25, b: 0 }), '#804000')
	assert.equal(lv1.rgbToHex({ r: 2, g: -1, b: 0.5 }), '#ff0080', 'out-of-range floats must not produce invalid hex')
})

test('a channel with no color reported stays null so the UI can flag it', () => {
	const [t] = lv1.buildTracks([ch({ name: 'VOX', color: null })])
	assert.equal(t.color, null)
})

// ─── CLI parsing ────────────────────────────────────────────────────────

test('numeric options fall back to their default instead of becoming NaN', () => {
	const opts = lv1.parseArgs(['--discover-ms', 'abc', '--listen-ms'])
	assert.equal(opts.discoverMs, 6000)
	assert.equal(opts.listenMs, 4000)
	assert.ok(opts.warnings.length >= 2, 'the user must be told their argument was ignored')
})

test('an out-of-range port is discarded so discovery can resolve the real one', () => {
	assert.equal(lv1.parseArgs(['--port', '99999']).port, undefined)
	assert.equal(lv1.parseArgs(['--port', '49699']).port, 49699)
})

test('a blank host is treated as "auto-discover"', () => {
	assert.equal(lv1.parseArgs(['--host', '   ']).host, undefined)
	assert.equal(lv1.parseArgs(['--host', ' 192.168.1.40 ']).host, '192.168.1.40')
})

test('the minimum listen window can never exceed the maximum', () => {
	const opts = lv1.parseArgs(['--listen-ms', '800', '--min-listen-ms', '5000'])
	assert.equal(opts.minListenMs, 800)
})

// ─── result file ────────────────────────────────────────────────────────

test('the result file is written atomically and leaves no temp file behind', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lv1-'))
	const out = path.join(dir, 'lv1_tracks.json')
	lv1.writeResult(out, { ok: true, tracks: [] })
	assert.deepEqual(JSON.parse(fs.readFileSync(out, 'utf8')), { ok: true, tracks: [] })
	assert.ok(!fs.existsSync(`${out}.tmp`))
	// Overwriting an existing result must succeed (Windows rename semantics).
	lv1.writeResult(out, { ok: false, tracks: [{ name: 'a' }] })
	assert.equal(JSON.parse(fs.readFileSync(out, 'utf8')).tracks.length, 1)
	fs.rmSync(dir, { recursive: true, force: true })
})

test('the bundled fixture matches the schema the Lua side expects', () => {
	const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'lv1_tracks.sample.json'), 'utf8'))
	assert.equal(fixture.schemaVersion, lv1.SCHEMA_VERSION)
	assert.equal(fixture.ok, true)
	assert.equal(fixture.trackCount, fixture.tracks.length)
	for (const t of fixture.tracks) {
		assert.equal(typeof t.group, 'number')
		assert.equal(typeof t.ch, 'number')
		assert.equal(typeof t.name, 'string')
		assert.equal(typeof t.stereo, 'boolean')
		assert.ok(!lv1.EXCLUDED_GROUPS.has(t.group), `group ${t.group} should have been filtered out`)
		assert.ok(t.color === null || /^#[0-9a-f]{6}$/.test(t.color))
	}
})
