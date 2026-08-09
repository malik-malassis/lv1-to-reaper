#!/usr/bin/env node
// lv1_fetch.js
//
// Standalone Node.js helper (no npm dependencies) that connects to a Waves LV1
// mixer over its native OSC-over-TCP protocol and dumps the full track list
// (name, group/channel, stereo/mono width, color) to a JSON file that the
// companion ReaScript (LV1_Track_Importer.lua) can read.
//
// Protocol reverse-engineered by the bitfocus/companion-module-waves-lv1
// project (MIT): https://github.com/bitfocus/companion-module-waves-lv1
//
// Usage:
//   node lv1_fetch.js [--host <ip>] [--port <n>] [--scan] [--mock <file>]
//                     [--discover-ms 6000] [--listen-ms 4000]
//                     [--min-listen-ms 1200] [--out lv1_tracks.json]
//                     [--log <file>] [--verbose]
//
// Modes:
//   (default)  discover (if needed) + connect + dump tracks to --out.
//   --scan     zDNS discovery only: lists every LV1 on the LAN, no connection.
//              Used by the UI's device picker when several LV1s are present.
//   --mock <f> copy a previously captured result file to --out, so the Reaper
//              UI can be developed/demoed with no mixer on the network.
//
// If --host/--port are omitted, the script performs a one-shot zDNS
// multicast discovery (UDP 225.1.1.1:13337) to find the LV1 on the LAN.
// If --host is given without --port, the LV1's OSC port is dynamic and
// cannot be guessed - a filtered zDNS discovery is still run to resolve it.
// If --port is given but turns out to be stale (the LV1 restarted since it
// was saved), the connection is automatically retried once after a fresh
// discovery pass.
//
// This script ALWAYS writes --out, even on failure, with an `ok`/`error`
// field and a `devices` diagnostic list, so a caller (e.g. the Reaper
// ReaScript UI) always has something useful to show the user. The file is
// written atomically (temp file + rename) so a reader can never observe a
// half-written JSON document.

'use strict'

const net = require('net')
const dgram = require('dgram')
const os = require('os')
const fs = require('fs')
const path = require('path')

// Bumped whenever the shape of the output file changes in a way the Lua side
// needs to know about. The UI warns if it reads a file it doesn't understand.
const SCHEMA_VERSION = 2

const ZDNS_GROUP = '225.1.1.1'
const ZDNS_PORT = 13337
const LV1_SERVICE = '_waveslv113._tcp'

// LV1 group ids that are never real, recordable tracks:
//   12 = DCA (control groups - they carry no audio of their own)
//   24 = internal "HidLink:N" pseudo-channels exposed by the LV1 app
const EXCLUDED_GROUPS = new Set([12, 24])
const LR_GROUP = 3

// ─── CLI args ───────────────────────────────────────────────────────────

const DEFAULTS = {
	discoverMs: 6000,
	listenMs: 4000,
	minListenMs: 1200,
	out: 'lv1_tracks.json',
}

// Parses an integer CLI value, falling back to `def` (and reporting the
// problem) rather than silently producing NaN - a NaN timeout would make
// setTimeout fire immediately and turn a typo into a mysterious "no LV1
// found" error.
function intOpt(raw, def, name, warnings) {
	if (raw === undefined) {
		warnings.push(`${name}: missing value, using ${def}`)
		return def
	}
	const v = parseInt(raw, 10)
	if (!Number.isFinite(v) || v < 0) {
		warnings.push(`${name}: invalid value ${JSON.stringify(raw)}, using ${def}`)
		return def
	}
	return v
}

function parseArgs(argv) {
	const warnings = []
	const out = { ...DEFAULTS, verbose: false, scan: false, mock: null, log: null, warnings }
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i]
		const next = () => argv[++i]
		switch (a) {
			case '--host': out.host = next(); break
			case '--port': out.port = intOpt(next(), 0, '--port', warnings); break
			case '--discover-ms': out.discoverMs = intOpt(next(), DEFAULTS.discoverMs, '--discover-ms', warnings); break
			case '--listen-ms': out.listenMs = intOpt(next(), DEFAULTS.listenMs, '--listen-ms', warnings); break
			case '--min-listen-ms': out.minListenMs = intOpt(next(), DEFAULTS.minListenMs, '--min-listen-ms', warnings); break
			case '--out': out.out = next() || DEFAULTS.out; break
			case '--log': out.log = next() || null; break
			case '--mock': out.mock = next() || null; break
			case '--scan': out.scan = true; break
			case '--verbose': out.verbose = true; break
			case '--help':
			case '-h': out.help = true; break
			default:
				if (a.startsWith('--')) warnings.push(`unknown option ${a} (ignored)`)
				break
		}
	}
	if (out.host !== undefined) {
		out.host = String(out.host).trim()
		if (out.host === '') out.host = undefined
	}
	if (out.port !== undefined && (out.port <= 0 || out.port > 65535)) {
		if (out.port !== 0) warnings.push(`--port ${out.port} out of range, ignoring`)
		out.port = undefined
	}
	if (out.minListenMs > out.listenMs) out.minListenMs = out.listenMs
	return out
}

// ─── logging ────────────────────────────────────────────────────────────
// Everything goes to stderr (so stdout stays clean) and, when --log is set,
// to a file as well. The Reaper UI reads that file instead of piping stdout,
// because it launches this script detached (non-blocking) and therefore has
// no pipe to read from.

let logFd = null

function openLog(file) {
	if (!file) return
	try {
		logFd = fs.openSync(path.resolve(file), 'w')
	} catch (err) {
		process.stderr.write(`(could not open log file ${file}: ${err.message})\n`)
	}
}

function closeLog() {
	if (logFd == null) return
	try { fs.closeSync(logFd) } catch { /* ignore */ }
	logFd = null
}

// Always-visible line (status, errors).
function say(...args) {
	const line = args.join(' ') + '\n'
	process.stderr.write(line)
	if (logFd != null) {
		try { fs.writeSync(logFd, line) } catch { /* ignore */ }
	}
}

// Verbose-only line (raw packet traces).
function log(verbose, ...args) {
	if (verbose) say(...args)
}

// ─── Minimal OSC 1.0 encoder/decoder ───────────────────────────────────
// Ported from companion-module-waves-lv1 src/osc.ts.

function padTo4(len) { return (4 - (len % 4)) % 4 }

function encodeString(str) {
	const buf = Buffer.from(str + '\0', 'utf8')
	const pad = padTo4(buf.length)
	return pad ? Buffer.concat([buf, Buffer.alloc(pad)]) : buf
}

function encodeMessage(address, args) {
	args = args || []
	const tag = ',' + args.map((a) => a.type).join('')
	const parts = [encodeString(address), encodeString(tag)]
	for (const a of args) {
		switch (a.type) {
			case 'i': {
				const b = Buffer.alloc(4)
				b.writeInt32BE(a.value | 0, 0)
				parts.push(b)
				break
			}
			case 'f': {
				const b = Buffer.alloc(4)
				b.writeFloatBE(a.value, 0)
				parts.push(b)
				break
			}
			case 's':
				parts.push(encodeString(String(a.value)))
				break
			default:
				break
		}
	}
	return Buffer.concat(parts)
}

function readString(buf, offset) {
	let end = offset
	while (end < buf.length && buf[end] !== 0) end++
	if (end >= buf.length) throw new Error('OSC string not null-terminated')
	const str = buf.subarray(offset, end).toString('utf8')
	const total = end - offset + 1
	const padded = total + padTo4(total)
	return [str, padded]
}

function decodeMessage(buf) {
	let off = 0
	const [address, aLen] = readString(buf, off)
	off += aLen
	if (off >= buf.length) return { address, args: [] }
	const [tag, tLen] = readString(buf, off)
	off += tLen
	if (!tag.startsWith(',')) return { address, args: [] }
	const types = tag.slice(1)
	const args = []
	// Every fixed-width read is bounds-checked: a truncated or malformed
	// packet must stop the argument loop, not throw halfway through and
	// discard the address we already decoded successfully.
	const need = (n) => off + n <= buf.length
	for (const t of types) {
		switch (t) {
			case 'i':
				if (!need(4)) return { address, args, truncated: true }
				args.push({ type: 'i', value: buf.readInt32BE(off) })
				off += 4
				break
			case 'f':
				if (!need(4)) return { address, args, truncated: true }
				args.push({ type: 'f', value: buf.readFloatBE(off) })
				off += 4
				break
			case 'h':
				if (!need(8)) return { address, args, truncated: true }
				args.push({ type: 'h', value: buf.readBigInt64BE(off) })
				off += 8
				break
			case 'd':
				if (!need(8)) return { address, args, truncated: true }
				args.push({ type: 'd', value: buf.readDoubleBE(off) })
				off += 8
				break
			case 's': {
				const [s, l] = readString(buf, off)
				args.push({ type: 's', value: s })
				off += l
				break
			}
			case 'b': {
				if (!need(4)) return { address, args, truncated: true }
				const blen = buf.readInt32BE(off)
				off += 4
				if (blen < 0 || !need(blen)) return { address, args, truncated: true }
				args.push({ type: 'b', value: buf.subarray(off, off + blen) })
				off += blen + padTo4(blen)
				break
			}
			case 'T': args.push({ type: 'T', value: true }); break
			case 'F': args.push({ type: 'F', value: false }); break
			case 'N': args.push({ type: 'N', value: null }); break
			case 'I': args.push({ type: 'I', value: Infinity }); break
			default: break
		}
	}
	return { address, args }
}

function intArg(m, idx) {
	const a = m.args[idx]
	if (!a) return undefined
	if (a.type === 'i' || a.type === 'f' || a.type === 'd') return a.value
	return undefined
}
function stringArg(m, idx) {
	const a = m.args[idx]
	return a && a.type === 's' ? a.value : undefined
}
function numArg(m, idx) {
	const a = m.args[idx]
	if (!a) return undefined
	if (a.type === 'f' || a.type === 'd' || a.type === 'i') return a.value
	return undefined
}

// ─── zDNS discovery (UDP 225.1.1.1:13337) ──────────────────────────────

function ipv4Like(s) { return /^\d{1,3}(\.\d{1,3}){3}$/.test(s) }
function ipv6Like(s) { return s.includes(':') }

// Higher = more likely to be the address we can actually reach the LV1 on.
function rankIp(ip) {
	if (/^127\./.test(ip)) return -100
	if (/^169\.254\./.test(ip)) return -50
	if (/^172\.(1[6-9]|2[0-9]|3[01])\./.test(ip)) return 30
	if (/^192\.168\.56\./.test(ip)) return 20   // VirtualBox host-only
	if (/^192\.168\./.test(ip)) return 100
	if (/^10\./.test(ip)) return 90
	return 40
}

function parseZDNS(buf) {
	let msg
	try {
		msg = decodeMessage(buf)
	} catch {
		return null
	}
	if (!msg || msg.address !== '/zDNS' || !Array.isArray(msg.args)) return null
	const args = msg.args
	if (args.length < 2 || args[0].type !== 's') return null
	const service = args[0].value
	const ipv4s = []
	const ipv6s = []
	let host = null
	let port = null
	for (let i = 2; i < args.length; i++) {
		const a = args[i]
		if (a.type === 's') {
			const v = a.value
			if (ipv4Like(v)) ipv4s.push(v)
			else if (ipv6Like(v)) ipv6s.push(v)
			else if (host == null && v.length > 0) host = v
		} else if (a.type === 'i' && port == null) {
			if (a.value > 1024 && a.value < 65536) port = a.value
		}
	}
	return { service, host, port, ipv4s, ipv6s }
}

function makeDevice(z) {
	const addresses = [...z.ipv4s].sort((a, b) => rankIp(b) - rankIp(a))
	return {
		name: z.host || null,
		host: z.host || null,       // kept for backwards compatibility
		address: addresses[0] || null,
		addresses,
		port: z.port || null,
		ipv6: z.ipv6s,
	}
}

function deviceMatches(dev, host) {
	if (!host) return false
	return dev.address === host || dev.addresses.includes(host) || dev.name === host
}

// Listens for LV1 zDNS announcements.
//   timeoutMs  how long to listen at most
//   matchHost  when set, resolve as soon as THIS host announces itself
//              (typical: ~200 ms instead of burning the whole window)
// Resolves to { devices, error } - a bind/multicast failure is reported
// instead of being swallowed into an empty, unexplained result.
function discover({ timeoutMs, verbose, matchHost }) {
	return new Promise((resolve) => {
		const found = new Map()
		let error = null
		let timer = null
		let done = false
		let socket

		const finish = () => {
			if (done) return
			done = true
			if (timer) clearTimeout(timer)
			try { socket && socket.close() } catch { /* ignore */ }
			const devices = [...found.values()]
			// Best guess first: reachable-looking address, then a resolved port.
			devices.sort((a, b) => (b.port ? 1 : 0) - (a.port ? 1 : 0) || rankIp(b.address || '') - rankIp(a.address || ''))
			resolve({ devices, error })
		}

		try {
			socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
		} catch (err) {
			error = `could not create the UDP socket: ${err.message}`
			say(`zDNS: ${error}`)
			finish()
			return
		}

		socket.on('error', (err) => {
			error = err.code === 'EADDRINUSE'
				? `UDP port ${ZDNS_PORT} is already in use by another application - close it (another LV1 tool, a Companion instance...) and retry.`
				: `UDP socket error: ${err.message}`
			say(`zDNS: ${error}`)
			finish()
		})

		socket.on('message', (buf, rinfo) => {
			const z = parseZDNS(buf)
			if (!z) return
			log(verbose, `zDNS: packet from ${rinfo.address} - service=${z.service} host=${z.host} port=${z.port} ipv4=[${z.ipv4s.join(',')}]`)
			if (z.service !== LV1_SERVICE) return
			const key = `${z.host}|${z.port}`
			if (found.has(key)) return
			const dev = makeDevice(z)
			found.set(key, dev)
			say(`zDNS: found ${dev.name || '?'} at ${dev.address || '?'}:${dev.port || '?'}`)
			if (matchHost && dev.port && deviceMatches(dev, matchHost)) finish()
		})

		socket.bind(ZDNS_PORT, () => {
			try { socket.setBroadcast(true) } catch { /* ignore */ }
			const ifaces = os.networkInterfaces()
			let joined = 0
			for (const list of Object.values(ifaces)) {
				if (!list) continue
				for (const iface of list) {
					if (iface.family !== 'IPv4' || iface.internal) continue
					try {
						socket.addMembership(ZDNS_GROUP, iface.address)
						joined++
						log(verbose, `zDNS: joined multicast group on ${iface.address}`)
					} catch (err) {
						log(verbose, `zDNS: failed to join multicast on ${iface.address}: ${err.message}`)
					}
				}
			}
			if (joined === 0) {
				error = 'could not join the multicast group on any network interface - no active IPv4 LAN adapter, or a firewall is blocking it.'
				say(`zDNS: WARNING - ${error}`)
			}
		})

		timer = setTimeout(finish, timeoutMs)
	})
}

// ─── /Channels bulk message ────────────────────────────────────────────

// The LV1's /Channels broadcast packs N tracks back to back with a fixed
// number of OSC args per track. Upstream documents 19 (i s iidd iiiiiiiiiiii
// hd), but that stride is the one part of the schema most likely to drift
// between LV1 versions - and a wrong stride decodes to *nothing* rather than
// to something obviously broken. So: try the documented stride first, then
// any other stride whose every track slot starts with (string, int, int).
function detectChannelStride(args, count) {
	const fits = (stride) => {
		if (stride < 3) return false
		if (1 + (count - 1) * stride + 2 >= args.length) return false
		for (let i = 0; i < count; i++) {
			const base = 1 + i * stride
			const a = args[base], b = args[base + 1], c = args[base + 2]
			if (!a || a.type !== 's') return false
			if (!b || b.type !== 'i') return false
			if (!c || c.type !== 'i') return false
		}
		return true
	}
	const nominal = Math.floor((args.length - 1) / count)
	const candidates = [19, nominal]
	for (let s = 3; s <= 48; s++) candidates.push(s)
	for (const s of candidates) {
		if (fits(s)) return s
	}
	return null
}

// Decodes /Channels into [{ name, group, ch, pan, width }, ...].
// Signature per track: [0]=name(s) [1]=group(i) [2]=ch(i) [3]=pan(d) [4]=width(d)
// Fields beyond index 4 are not reliably decoded upstream and are ignored.
function parseChannelsMessage(args) {
	const count = args[0] && args[0].type === 'i' ? args[0].value : 0
	if (count <= 0 || count > 512) return { count, stride: null, tracks: [] }
	const stride = detectChannelStride(args, count)
	if (stride == null) return { count, stride: null, tracks: [] }
	const tracks = []
	for (let i = 0; i < count; i++) {
		const base = 1 + i * stride
		const pan = args[base + 3]
		const width = args[base + 4]
		tracks.push({
			name: args[base].value,
			group: args[base + 1].value,
			ch: args[base + 2].value,
			pan: pan && (pan.type === 'd' || pan.type === 'f') ? pan.value : null,
			width: width && (width.type === 'd' || width.type === 'f') ? width.value : null,
		})
	}
	return { count, stride, tracks }
}

// ─── TCP client with LV1 8-byte framing ────────────────────────────────

const HEADER_LEN = 8
const DEFAULT_HEADER = Buffer.from([0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
const CONNECT_TIMEOUT_MS = 5000

function randomUuid() {
	const hex = '0123456789ABCDEF'
	let s = ''
	for (let i = 0; i < 36; i++) {
		if (i === 8 || i === 13 || i === 18 || i === 23) s += '-'
		else s += hex[Math.floor(Math.random() * 16)]
	}
	return s
}

function connectAndFetch(host, port, { listenMs, minListenMs, verbose }) {
	return new Promise((resolve, reject) => {
		if (!host) {
			reject(new Error('connectAndFetch: no host given'))
			return
		}
		if (!Number.isInteger(port) || port <= 0 || port > 65535) {
			reject(new Error(`connectAndFetch: invalid port (${port}). The LV1's OSC port is dynamic - it must come from zDNS discovery, it cannot be guessed.`))
			return
		}

		const sock = new net.Socket()
		let rxBuf = Buffer.alloc(0)
		let registered = false
		let finished = false
		let listenTimer = null
		let pollTimer = null
		let startedAt = 0

		const state = {
			channels: new Map(), // `${group}.${ch}` -> { name, group, ch, pan, width, color, hasRightMeter }
			auxNames: [],
			registered: false,
			packetsSeen: 0,
			channelsSeen: 0,
			meterFrames: 0,
			channelsStride: null,
			elapsedMs: 0,
		}

		function ensure(group, ch) {
			const key = `${group}.${ch}`
			let s = state.channels.get(key)
			if (!s) {
				// hasRightMeter tracks whether a /Notify/Meters frame with sub=1 (the
				// right-channel VU) was ever seen for this channel - this is a far more
				// reliable mono/stereo signal than the "width" field (which is really a
				// stereo-image-width knob that can read >0 even on mono channels, and was
				// observed to make every channel look "stereo"). null = not yet observed.
				s = { group, ch, name: null, pan: 0, width: 0, color: null, hasRightMeter: null }
				state.channels.set(key, s)
			}
			return s
		}

		function frame(address, args) {
			const packet = encodeMessage(address, args || [])
			const len = Buffer.alloc(4)
			len.writeUInt32BE(packet.length, 0)
			return Buffer.concat([len, DEFAULT_HEADER, packet])
		}

		function send(address, args) { sock.write(frame(address, args)) }
		function sendBatch(messages) {
			sock.write(Buffer.concat(messages.map((m) => frame(m.address, m.args))))
		}

		function finish(err) {
			if (finished) return
			finished = true
			if (listenTimer) clearTimeout(listenTimer)
			if (pollTimer) clearInterval(pollTimer)
			state.elapsedMs = startedAt ? Date.now() - startedAt : 0
			try { sock.destroy() } catch { /* ignore */ }
			if (err) reject(err)
			else resolve(state)
		}

		// Everything we need usually lands within ~1s: the bulk /Channels dump
		// plus a couple of /Notify/Meters frames (needed for the mono/stereo
		// detection). Stop as soon as both are in rather than always burning the
		// full listen window - that alone cuts a typical fetch from ~10s to ~2s.
		function maybeEarlyExit() {
			if (finished || !registered) return
			if (Date.now() - startedAt < minListenMs) return
			if (state.channelsSeen > 0 && state.meterFrames >= 2) {
				log(verbose, `Early exit: /Channels received and ${state.meterFrames} meter frames seen after ${Date.now() - startedAt} ms`)
				finish()
			}
		}

		function handlePacket(m) {
			state.packetsSeen++
			log(verbose, `<- ${m.address} ${m.args.map((a) => `${a.type}:${a.type === 'b' ? '<blob>' : a.value}`).join(' ')}`)
			switch (m.address) {
				case '/handshake':
					if (!registered && intArg(m, 0) === 1) {
						registered = true
						state.registered = true
						say('Handshake acknowledged - registered with the LV1.')
						// Ask for topology once registered.
						send('/Get/Aux/Tracks', [])
						send('/Get/Layers', [{ type: 'i', value: 0 }, { type: 'i', value: 0 }])
					}
					break
				case '/ping':
					send('/pong', m.args)
					break
				case '/Aux/Tracks': {
					const count = intArg(m, 0)
					if (count == null) break
					const names = []
					for (let i = 1; i + 2 < m.args.length; i += 3) {
						const nameArg = m.args[i + 2]
						if (nameArg && nameArg.type === 's') names.push(nameArg.value)
					}
					state.auxNames = names
					break
				}
				case '/Notify/TrackColor': {
					const g = intArg(m, 0), ch = intArg(m, 1)
					const r = numArg(m, 3), gC = numArg(m, 4), b = numArg(m, 5)
					if (g == null || ch == null || r == null || gC == null || b == null) break
					ensure(g, ch).color = { r, g: gC, b }
					break
				}
				case '/Notify/Track/Pan/Width':
				case '/Notify/PanArcWidth': {
					const g = intArg(m, 0), ch = intArg(m, 1)
					const v = numArg(m, 2)
					if (g == null || ch == null || v == null) break
					ensure(g, ch).width = v
					break
				}
				case '/Notify/Meters': {
					// args[0] = count, then (group, ch, sub, dB-float) per meter, repeated.
					// sub=0 is the mono/left VU, sub=1 is the right-channel VU - a channel
					// only ever gets a sub=1 entry if it's actually a stereo pair, so this
					// is the authoritative mono/stereo signal (unlike "width", which is a
					// stereo-image knob that reads nonzero even on mono channels).
					const args = m.args
					let touched = false
					for (let i = 1; i + 3 < args.length; i += 4) {
						const g = args[i] && args[i].type === 'i' ? args[i].value : null
						const ch = args[i + 1] && args[i + 1].type === 'i' ? args[i + 1].value : null
						const sub = args[i + 2] && args[i + 2].type === 'i' ? args[i + 2].value : null
						if (g == null || ch == null || sub == null) continue
						const s = ensure(g, ch)
						touched = true
						if (sub === 1) s.hasRightMeter = true
						else if (sub === 0 && s.hasRightMeter == null) s.hasRightMeter = false
					}
					if (touched) {
						state.meterFrames++
						maybeEarlyExit()
					}
					break
				}
				case '/Notify/Track/Name':
				case '/Notify/TrackName': {
					const g = intArg(m, 0), ch = intArg(m, 1)
					const name = stringArg(m, 2)
					if (g == null || ch == null || name == null) break
					ensure(g, ch).name = name
					break
				}
				case '/Channels': {
					// Bulk topology broadcast, sent a few times right after handshake.
					const parsed = parseChannelsMessage(m.args)
					if (parsed.stride == null) {
						if (parsed.count > 0) {
							say(`WARNING: /Channels announced ${parsed.count} track(s) but none could be decoded - the LV1's message layout may have changed in this firmware version. Please report this with a --verbose log.`)
						}
						break
					}
					state.channelsStride = parsed.stride
					if (parsed.stride !== 19) log(verbose, `/Channels: using auto-detected stride ${parsed.stride} (documented is 19)`)
					for (const t of parsed.tracks) {
						const s = ensure(t.group, t.ch)
						s.name = t.name
						if (t.pan != null) s.pan = t.pan
						if (t.width != null) s.width = t.width
					}
					state.channelsSeen++
					maybeEarlyExit()
					break
				}
				default:
					break
			}
		}

		function drain() {
			while (rxBuf.length >= 4 + HEADER_LEN) {
				const size = rxBuf.readUInt32BE(0)
				if (size === 0 || size > 16 * 1024 * 1024) {
					// Not a plausible frame length - resync one byte at a time.
					rxBuf = rxBuf.subarray(1)
					continue
				}
				const total = 4 + HEADER_LEN + size
				if (rxBuf.length < total) return
				const packet = rxBuf.subarray(4 + HEADER_LEN, total)
				rxBuf = rxBuf.subarray(total)
				let decoded
				try {
					decoded = decodeMessage(packet)
				} catch {
					continue
				}
				handlePacket(decoded)
			}
		}

		sock.setTimeout(CONNECT_TIMEOUT_MS)
		sock.on('timeout', () => {
			if (!registered) {
				finish(new Error(`TCP connect timed out after ${CONNECT_TIMEOUT_MS / 1000}s (${host}:${port}). The host is likely unreachable (wrong IP, different subnet/VLAN, or a firewall dropping the connection).`))
			}
		})
		sock.on('error', (err) => {
			const code = err.code ? ` [${err.code}]` : ''
			finish(new Error(`TCP error connecting to ${host}:${port}${code}: ${err.message}`))
		})
		sock.on('close', () => {
			if (!finished) finish(new Error(`Connection to ${host}:${port} closed unexpectedly before the handshake completed.`))
		})
		sock.on('data', (chunk) => {
			rxBuf = Buffer.concat([rxBuf, chunk])
			drain()
		})
		sock.on('connect', () => {
			say(`TCP connected to ${host}:${port}, sending handshake...`)
			sock.setTimeout(0)
			startedAt = Date.now()
			const uuid = randomUuid()
			sendBatch([
				{ address: '/handshake', args: [{ type: 'i', value: 1 }, { type: 'i', value: -1 }, { type: 'i', value: 1 }] },
				{ address: '/device_name', args: [{ type: 's', value: 'ReaperLV1Importer' }, { type: 's', value: uuid }] },
			])
			// Hard stop: give the LV1 at most `listenMs` to flood /Channels +
			// aux/layer replies. maybeEarlyExit() usually beats this by a lot.
			listenTimer = setTimeout(() => finish(), listenMs)
			// The early-exit condition can also become true purely through the
			// passage of time (minListenMs), so re-check periodically too.
			pollTimer = setInterval(maybeEarlyExit, 200)
		})
		sock.connect(port, host)
	})
}

// ─── result building ───────────────────────────────────────────────────

function rgbToHex(c) {
	const clamp = (v) => Math.max(0, Math.min(255, Math.round(v * 255)))
	const r = clamp(c.r), g = clamp(c.g), b = clamp(c.b)
	return '#' + [r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')
}

// Turns the raw per-channel state into the flat track list the Reaper UI
// consumes. Pure function - covered by test/lv1_fetch.test.js.
function buildTracks(channels) {
	return [...channels]
		.filter((t) => t.name != null && t.name !== '' && !EXCLUDED_GROUPS.has(t.group))
		.map((t) => {
			// hasRightMeter (from /Notify/Meters sub=1) is the authoritative
			// signal: a channel only ever gets a right-channel VU frame if it's
			// really a stereo pair. Fall back to the "width" heuristic only if we
			// never saw ANY meter frame for this channel within the listen window.
			// The LR master bus is ALWAYS stereo by definition, so force it rather
			// than relying on detection there.
			let stereo, detect
			if (t.group === LR_GROUP) {
				stereo = true
				detect = 'bus'
			} else if (t.hasRightMeter != null) {
				stereo = t.hasRightMeter
				detect = 'meter'
			} else {
				stereo = (t.width || 0) > 0.05
				detect = 'width'
			}
			return {
				group: t.group,
				ch: t.ch,
				name: t.name,
				stereo,
				// How `stereo` was determined, so the UI can flag the tracks whose
				// width is a guess ('width') rather than confirmed ('meter'/'bus').
				detect,
				color: t.color ? rgbToHex(t.color) : null,
			}
		})
		.sort((a, b) => (a.group - b.group) || (a.ch - b.ch))
}

// Writes atomically: a reader polling this path can never observe a
// half-written document, and a crash mid-write leaves the previous file
// intact instead of a truncated one.
function writeResult(outPath, result) {
	const abs = path.resolve(outPath)
	const tmp = `${abs}.tmp`
	fs.writeFileSync(tmp, JSON.stringify(result, null, 2), 'utf8')
	fs.renameSync(tmp, abs)
	return abs
}

const USAGE = `lv1_fetch.js - fetch the track list from a Waves LV1 mixer

  node lv1_fetch.js [options]

  --host <ip>          LV1 address (omit to auto-discover on the LAN)
  --port <n>           OSC port (dynamic; omit to resolve it via zDNS)
  --scan               only list the LV1s on the LAN, don't connect
  --mock <file>        copy a captured result file to --out (offline UI dev)
  --discover-ms <n>    discovery window, default ${DEFAULTS.discoverMs}
  --listen-ms <n>      max listen window after handshake, default ${DEFAULTS.listenMs}
  --min-listen-ms <n>  min listen window before early exit, default ${DEFAULTS.minListenMs}
  --out <file>         result JSON, default ${DEFAULTS.out}
  --log <file>         also write the diagnostic log to this file
  --verbose            log every OSC/zDNS packet
`

// ─── main ───────────────────────────────────────────────────────────────

async function main() {
	const opts = parseArgs(process.argv.slice(2))
	if (opts.help) {
		process.stdout.write(USAGE)
		return 0
	}
	openLog(opts.log)
	for (const w of opts.warnings) say(`Argument warning: ${w}`)

	let host = opts.host
	let port = opts.port
	let devices = []
	let discoveryError = null

	const base = () => ({
		schemaVersion: SCHEMA_VERSION,
		ok: false,
		mode: opts.scan ? 'scan' : 'fetch',
		error: null,
		errorCode: null,
		host: host || null,
		port: port || null,
		deviceName: null,
		registered: false,
		devices,
		ambiguous: devices.length > 1,
		discoveryError,
		fetchedAt: new Date().toISOString(),
		elapsedMs: 0,
		trackCount: 0,
		tracks: [],
	})

	const fail = (code, errorCode, message, extra) => {
		say(`Error: ${message}`)
		writeResult(opts.out, { ...base(), ...(extra || {}), error: message, errorCode })
		return code
	}

	// ── mock mode: replay a captured file, no network at all ──
	if (opts.mock) {
		const src = path.resolve(opts.mock)
		say(`Mock mode: replaying ${src}`)
		let parsed
		try {
			parsed = JSON.parse(fs.readFileSync(src, 'utf8'))
		} catch (err) {
			return fail(5, 'MOCK_READ_FAILED', `Could not read the mock file ${src}: ${err.message}`)
		}
		const outFile = writeResult(opts.out, {
			...base(),
			...parsed,
			schemaVersion: SCHEMA_VERSION,
			mock: true,
			fetchedAt: new Date().toISOString(),
		})
		say(`Wrote ${(parsed.tracks || []).length} mocked track(s) to ${outFile}`)
		return 0
	}

	// ── scan mode: enumerate every LV1 on the LAN ──
	if (opts.scan) {
		say(`Scanning the LAN for LV1s (${opts.discoverMs} ms)...`)
		const res = await discover({ timeoutMs: opts.discoverMs, verbose: opts.verbose })
		devices = res.devices
		discoveryError = res.error
		const outFile = writeResult(opts.out, {
			...base(),
			ok: devices.length > 0,
			error: devices.length > 0 ? null : (discoveryError
				? `No LV1 found. Discovery problem: ${discoveryError}`
				: 'No LV1 announced itself on the LAN during the scan. Check that the mixer is powered on, on the same subnet/VLAN, and that UDP multicast 225.1.1.1:13337 is not blocked by a firewall.'),
			errorCode: devices.length > 0 ? null : 'NO_DEVICE',
		})
		say(`Scan finished: ${devices.length} LV1(s) found - written to ${outFile}`)
		return devices.length > 0 ? 0 : 2
	}

	// ── fetch mode ──
	const startedAt = Date.now()

	// Resolve the port when we don't have one: it's dynamic (it changes every
	// time the LV1 app restarts or the mixer mode changes), so it can never be
	// guessed or hardcoded.
	if (!port) {
		if (host) {
			say(`Host given without port - running a filtered zDNS discovery for ${host} (up to ${opts.discoverMs} ms)...`)
		} else {
			say(`Discovering the LV1 on the LAN (up to ${opts.discoverMs} ms)...`)
		}
		const res = await discover({ timeoutMs: opts.discoverMs, verbose: opts.verbose, matchHost: host })
		devices = res.devices
		discoveryError = res.error

		if (host) {
			const match = devices.find((d) => deviceMatches(d, host))
			if (!match || !match.port) {
				const seen = devices.length
					? devices.map((d) => `${d.name || '?'} @ ${d.address || '?'}:${d.port}`).join(', ')
					: '(none)'
				return fail(3, 'HOST_NOT_ANNOUNCED',
					`No zDNS announcement found for host ${host}. The LV1's OSC port is dynamic and cannot be guessed - it must be discovered. ` +
					`LV1s seen on the LAN during this scan: ${seen}. ` +
					(discoveryError ? `Discovery problem: ${discoveryError} ` : '') +
					`Checklist: (1) this machine and the LV1 must be on the same subnet/VLAN, (2) UDP multicast 225.1.1.1:13337 must not be blocked ` +
					`by a firewall/router, (3) allow Node.js through the Windows Firewall (Private network) if prompted.`)
			}
			port = match.port
			say(`Resolved port ${port} for ${host} via zDNS (${match.name || 'unnamed'})`)
		} else {
			if (!devices.length) {
				return fail(2, 'NO_DEVICE',
					'No LV1 found via zDNS discovery. ' +
					(discoveryError ? `Discovery problem: ${discoveryError} ` : '') +
					'Checklist: (1) the LV1 app must be running and on the same subnet/VLAN as this machine, (2) UDP multicast 225.1.1.1:13337 must not ' +
					'be blocked by a firewall/router, (3) allow Node.js through the Windows Firewall (Private network) if prompted, (4) if discovery still ' +
					"fails, enter the LV1's IP manually (the port can stay blank - it is still resolved by a filtered scan).")
			}
			const chosen = devices[0]
			host = chosen.address || chosen.name
			port = chosen.port
			if (devices.length > 1) {
				say(`WARNING: ${devices.length} LV1s are announcing themselves on this network. Auto-selected ${chosen.name || host} @ ${host}:${port} - pick a specific one in the device list if that is the wrong console.`)
			}
			say(`Discovered LV1 at ${host}:${port}`)
		}
	}

	const deviceName = (devices.find((d) => deviceMatches(d, host)) || {}).name || null

	say(`Connecting to ${host}:${port}...`)
	let state = null
	let connectError = null
	try {
		state = await connectAndFetch(host, port, opts)
	} catch (err) {
		connectError = err
	}

	// A saved/user-supplied port goes stale every time the LV1 app restarts.
	// Rather than making that the user's problem, transparently re-resolve it
	// once and retry - this is by far the most common failure in the field.
	const staleLikely = !state || !state.registered
	if (staleLikely && opts.port) {
		say('The supplied port did not work - re-resolving it via zDNS and retrying once...')
		const res = await discover({ timeoutMs: opts.discoverMs, verbose: opts.verbose, matchHost: host })
		if (res.devices.length) devices = res.devices
		if (res.error) discoveryError = res.error
		const match = devices.find((d) => deviceMatches(d, host)) || (host ? null : devices[0])
		if (match && match.port && match.port !== port) {
			say(`Retrying with freshly discovered port ${match.port} (was ${port})`)
			port = match.port
			connectError = null
			try {
				state = await connectAndFetch(host, port, opts)
			} catch (err) {
				connectError = err
				state = null
			}
		}
	}

	if (connectError) {
		return fail(1, 'CONNECT_FAILED', connectError.message, { host, port, deviceName })
	}

	if (!state.registered) {
		return fail(4, 'NO_HANDSHAKE',
			`Connected to ${host}:${port} but the LV1 never acknowledged the handshake (no /handshake ACK within the listen window). ` +
			`Packets seen: ${state.packetsSeen}. This usually means the port is stale (the LV1 restarted or changed mixer mode since it was ` +
			'discovered) or another application is already holding the LV1\'s remote-control slot.',
			{ host, port, deviceName, registered: false })
	}

	const tracks = buildTracks(state.channels.values())
	const guessed = tracks.filter((t) => t.detect === 'width').length

	const result = {
		...base(),
		ok: true,
		error: tracks.length === 0
			? 'Connected and registered, but the LV1 sent no named tracks (/Channels) within the listen window. Try increasing the listen timeout.'
			: null,
		errorCode: tracks.length === 0 ? 'NO_TRACKS' : null,
		host,
		port,
		deviceName,
		registered: true,
		elapsedMs: Date.now() - startedAt,
		channelsStride: state.channelsStride,
		meterFrames: state.meterFrames,
		widthGuessedCount: guessed,
		trackCount: tracks.length,
		tracks,
	}

	const outFile = writeResult(opts.out, result)
	say(`Wrote ${tracks.length} track(s) to ${outFile} in ${result.elapsedMs} ms` + (guessed ? ` (${guessed} track(s) had their mono/stereo width guessed - check them in the UI)` : ''))
	return 0
}

if (require.main === module) {
	main()
		.then((code) => {
			process.exitCode = code || 0
			closeLog()
		})
		.catch((err) => {
			say(`Fatal: ${err.stack || err.message}`)
			try {
				writeResult(parseArgs(process.argv.slice(2)).out, {
					schemaVersion: SCHEMA_VERSION,
					ok: false,
					mode: 'fetch',
					error: `Fatal script error: ${err.message}`,
					errorCode: 'FATAL',
					host: null,
					port: null,
					deviceName: null,
					registered: false,
					devices: [],
					ambiguous: false,
					discoveryError: null,
					fetchedAt: new Date().toISOString(),
					elapsedMs: 0,
					trackCount: 0,
					tracks: [],
				})
			} catch { /* ignore */ }
			process.exitCode = 1
			closeLog()
		})
}

module.exports = {
	SCHEMA_VERSION,
	EXCLUDED_GROUPS,
	parseArgs,
	encodeString,
	encodeMessage,
	decodeMessage,
	readString,
	parseZDNS,
	rankIp,
	makeDevice,
	deviceMatches,
	detectChannelStride,
	parseChannelsMessage,
	buildTracks,
	rgbToHex,
	writeResult,
}
