-- @description LV1 Track Importer - connect to a Waves LV1 mixer and create Reaper tracks
-- @author Malik MALASSIS - @malik_biendebout
-- @version 2.1.0
-- @provides
--   lv1_fetch.js
-- @links
--   Repository https://github.com/malik-malassis/lv1-to-reaper
--   Report a bug https://github.com/malik-malassis/lv1-to-reaper/issues
-- @about
--   # LV1 Track Importer
--
--   Connects to a Waves LV1 live mixer on the network and creates the matching
--   tracks in the current REAPER project, carrying over name, mono/stereo
--   width and color, and optionally pre-patching the record inputs.
--
--   Requires ReaImGui (cfillion) and Node.js on PATH. LV1_Track_Importer.lua
--   and lv1_fetch.js must sit in the same folder.
--
--   It reads from the console and never writes to it: the only messages sent
--   are the handshake, the keep-alive and two topology queries.
--
--   Licensed under PolyForm Noncommercial 1.0.0 - free for any noncommercial
--   use, not for sale or for inclusion in a commercial product. The bundled
--   OSC codec is used under the MIT License from
--   bitfocus/companion-module-waves-lv1. See LICENSE.
-- @changelog
--   2.1.0
--   - Track creation and update can no longer leave REAPER's UI refresh
--     disabled or an undo block open if they fail partway through.
--   - Shift-click a checkbox to select a range of tracks.
--   - Warns when the selection needs more hardware inputs than the audio
--     device actually provides.
--   - Replayed capture files (--mock) are now flagged in the window.
--   2.0
--   - Rebuilt UI: header status bar, device sidebar, group filters, search,
--     live record-input preview, sticky action footer.
--   - Fetching no longer freezes REAPER (background process + progress).
--   - Multiple LV1s on the LAN are now listed and selectable.
--   - Fixed: saved settings were never reloaded (GetExtState misuse).
--   - Fixed: a failed fetch could display the previous fetch's track list.
--   - New: re-sync existing tracks, folder-per-group, record arming.

local EXT_SECTION = "LV1_Track_Importer"
local SCRIPT_DIR = ({reaper.get_action_context()})[2]:match("(.*[/\\])")
local IS_WIN = reaper.GetOS():match("^Win") ~= nil
local SEP = IS_WIN and "\\" or "/"

-- The result/log files live next to the script when that folder is writable
-- (easiest to find when troubleshooting), otherwise in REAPER's own resource
-- folder — the script directory can be read-only when installed system-wide.
local function isWritable(dir)
	local probe = dir .. ".lv1_write_test"
	local f = io.open(probe, "w")
	if not f then return false end
	f:close()
	os.remove(probe)
	return true
end

local WORK_DIR = isWritable(SCRIPT_DIR) and SCRIPT_DIR or (reaper.GetResourcePath() .. SEP)
local JSON_OUT = WORK_DIR .. "lv1_tracks.json"
local LOG_OUT = WORK_DIR .. "lv1_fetch.log"
local FETCH_JS = SCRIPT_DIR .. "lv1_fetch.js"
local SCHEMA_VERSION = 2

-- ═══════════════════════════════════ ReaImGui binding ═══════════════════
-- ReaImGui exposes two APIs: the original flat `reaper.ImGui_Xxx()` functions
-- (deprecated) and, since v0.9, a proper Lua module obtained with
-- `require 'imgui'`. Prefer the module when available and fall back to a thin
-- proxy over the flat functions otherwise, so the script keeps working on old
-- and new installs alike.
--
-- The one incompatibility between the two is enums: the module exposes them as
-- plain numbers (ImGui.Col_Button) while the flat API exposes them as getter
-- functions (reaper.ImGui_Col_Button()). E() below normalises both, and also
-- tolerates enums that simply don't exist in the installed version.

if not reaper.ImGui_CreateContext and not reaper.ImGui_GetBuiltinPath then
	reaper.MB(
		"This script needs the ReaImGui extension, which isn't installed.\n\n" ..
		"Install it via ReaPack:\n" ..
		"  Extensions > ReaPack > Browse packages...\n" ..
		"  Search for \"ReaImGui\" (author: cfillion), right-click > Install, then restart REAPER.\n\n" ..
		"If you don't have ReaPack either, get it from https://reapack.com first.",
		"LV1 Track Importer - ReaImGui required",
		0
	)
	return
end

local ImGui
do
	local raw
	if reaper.ImGui_GetBuiltinPath then
		local okPath, builtin = pcall(reaper.ImGui_GetBuiltinPath)
		if okPath and builtin then
			package.path = builtin .. "/?.lua;" .. package.path
			local okReq, mod = pcall(function() return require 'imgui' '0.9' end)
			if okReq and type(mod) == "table" then raw = mod end
		end
	end
	if not raw then
		-- Legacy flat API: reaper.ImGui_Xxx(). Missing names are plain nil.
		raw = setmetatable({}, { __index = function(_, k) return reaper["ImGui_" .. k] end })
	end

	-- The table returned by `require 'imgui'` installs a metatable that RAISES
	-- on any unknown field rather than returning nil:
	--   __index = function(_, key) error("attempt to access a nil value ...") end
	-- Every optional-feature probe in this script (`if ImGui.Foo then`, and the
	-- enum lookups in E) would therefore abort the frame on any ReaImGui build
	-- that happens not to expose one name — and pushTheme() runs outside the
	-- per-frame pcall, so a single missing colour enum would kill the whole
	-- script. Wrap it so a missing name reads as nil again, caching the hits.
	ImGui = setmetatable({}, {
		__index = function(t, k)
			local ok, v = pcall(function() return raw[k] end)
			if not ok then v = nil end
			if v ~= nil then rawset(t, k, v) end
			return v
		end,
	})
end

local enumCache = {}
local function E(name, fallback)
	local cached = enumCache[name]
	if cached ~= nil then return cached end
	local v = ImGui[name]
	if type(v) == "function" then
		local ok, res = pcall(v)
		v = ok and res or nil
	end
	if v == nil then v = fallback or 0 end
	enumCache[name] = v
	return v
end

-- ═══════════════════════════════════ palette ════════════════════════════
-- 0xRRGGBBAA. Deliberately low-chroma greys with a single blue accent so the
-- LV1's own track colors (the whole point of the tool) stay the loudest thing
-- on screen.

local COL = {
	bg        = 0x14161CFF,
	panel     = 0x1B1E26FF,
	panelAlt  = 0x212530FF,
	raised    = 0x272B36FF,
	raisedHi  = 0x30354380,
	border    = 0x2E3340FF,
	text      = 0xE6E9EFFF,
	textDim   = 0x9098A8FF,
	textFaint = 0x5D6577FF,
	accent    = 0x3E7BFAFF,
	accentHi  = 0x5A92FFFF,
	accentLo  = 0x2E63D6FF,
	accentDim = 0x3E7BFA26,
	ok        = 0x34D399FF,
	okDim     = 0x34D39926,
	warn      = 0xFBBF24FF,
	err       = 0xF87171FF,
	errDim    = 0xF8717126,
}

-- ═══════════════════════════════════ JSON decode ════════════════════════
-- Sufficient for the flat structure written by lv1_fetch.js (objects, arrays,
-- strings, numbers, booleans, null). Not a general-purpose parser.

-- Encodes a Unicode code point as UTF-8. The previous implementation used
-- string.char(code), which produces a raw Latin-1 byte — that turns any
-- escaped accented character into mojibake in REAPER's track names.
local function utf8Encode(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
	elseif code < 0x10000 then
		return string.char(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
	end
	return string.char(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
end

local JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

local function jsonDecode(str)
	local i = 1
	local n = #str

	local function skipWs()
		while i <= n do
			local c = str:sub(i, i)
			if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
		end
	end

	local parseValue

	local function parseString()
		i = i + 1 -- skip opening quote
		local buf = {}
		while i <= n do
			local c = str:sub(i, i)
			if c == '"' then
				i = i + 1
				return table.concat(buf)
			elseif c == "\\" then
				local nx = str:sub(i + 1, i + 1)
				if nx == "n" then buf[#buf+1] = "\n"
				elseif nx == "t" then buf[#buf+1] = "\t"
				elseif nx == "r" then buf[#buf+1] = "\r"
				elseif nx == "b" then buf[#buf+1] = "\b"
				elseif nx == "f" then buf[#buf+1] = "\f"
				elseif nx == "u" then
					local code = tonumber(str:sub(i + 2, i + 5), 16) or 0xFFFD
					i = i + 4
					-- Surrogate pair: 😀 style. Combine both halves into
					-- the real code point instead of emitting two broken chars.
					if code >= 0xD800 and code <= 0xDBFF and str:sub(i + 2, i + 3) == "\\u" then
						local low = tonumber(str:sub(i + 4, i + 7), 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
							i = i + 6
						end
					end
					buf[#buf+1] = utf8Encode(code)
				else buf[#buf+1] = nx end
				i = i + 2
			else
				buf[#buf+1] = c
				i = i + 1
			end
		end
		return table.concat(buf)
	end

	local function parseNumber()
		local start = i
		while i <= n and str:sub(i, i):match("[%d%.%-%+eE]") do i = i + 1 end
		return tonumber(str:sub(start, i - 1))
	end

	local function parseArray()
		i = i + 1
		local out = {}
		skipWs()
		if str:sub(i, i) == "]" then i = i + 1; return out end
		while true do
			skipWs()
			local v = parseValue()
			-- A literal null inside an array must not collapse the array: storing
			-- nil would silently shift every following element down one slot.
			out[#out+1] = (v == nil) and JSON_NULL or v
			skipWs()
			local c = str:sub(i, i)
			if c == "," then i = i + 1
			elseif c == "]" then i = i + 1; break
			else break end
		end
		return out
	end

	local function parseObject()
		i = i + 1
		local out = {}
		skipWs()
		if str:sub(i, i) == "}" then i = i + 1; return out end
		while true do
			skipWs()
			local key = parseString()
			skipWs()
			i = i + 1 -- skip ':'
			skipWs()
			out[key] = parseValue()
			skipWs()
			local c = str:sub(i, i)
			if c == "," then i = i + 1
			elseif c == "}" then i = i + 1; break
			else break end
		end
		return out
	end

	parseValue = function()
		skipWs()
		local c = str:sub(i, i)
		if c == '"' then return parseString()
		elseif c == "{" then return parseObject()
		elseif c == "[" then return parseArray()
		elseif str:sub(i, i + 3) == "true" then i = i + 4; return true
		elseif str:sub(i, i + 4) == "false" then i = i + 5; return false
		elseif str:sub(i, i + 3) == "null" then i = i + 4; return nil
		else return parseNumber() end
	end

	skipWs()
	local ok, result = pcall(parseValue)
	if ok and type(result) == "table" then return result end
	return nil
end

-- ═══════════════════════════════════ config ═════════════════════════════
-- reaper.GetExtState() returns a SINGLE value. The previous `local ok, v =`
-- form put the value in `ok` and left `v` nil, so every saved setting silently
-- fell back to its default on every launch.

local function getCfg(key, default)
	local v = reaper.GetExtState(EXT_SECTION, key)
	if v == nil or v == "" then return default end
	return v
end
local function setCfg(key, value)
	reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
end
local function getNumCfg(key, default, min, max)
	local v = tonumber(getCfg(key, tostring(default))) or default
	if min and v < min then v = min end
	if max and v > max then v = max end
	return v
end

local cfg = {
	host = getCfg("host", ""),
	port = getCfg("port", ""),
	deviceName = getCfg("deviceName", ""),
	nodePath = getCfg("nodePath", "node"),
	discoverMs = getNumCfg("discoverMs", 6000, 500, 60000),
	listenMs = getNumCfg("listenMs", 4000, 500, 60000),
	verbose = getCfg("verbose", "1") == "1",
	blockingMode = getCfg("blockingMode", "0") == "1",
	prePatchInputs = getCfg("prePatchInputs", "1") == "1",
	prefixTrackNumber = getCfg("prefixTrackNumber", "1") == "1",
	createFolders = getCfg("createFolders", "0") == "1",
	armRecord = getCfg("armRecord", "0") == "1",
	skipExisting = getCfg("skipExisting", "1") == "1",
	hideUnused = getCfg("hideUnused", "0") == "1",
	-- "console": hardware input assigned to each "In" track matches its real
	-- LV1 console input position, so unselected/skipped channels leave gaps.
	-- "linear": hardware inputs are assigned sequentially (0,1,2,...) across
	-- only the SELECTED "In" tracks, with no gaps, regardless of their real
	-- console channel numbers.
	prePatchMode = getCfg("prePatchMode", "console"),
	-- 1-based hardware input channel the LR (main stereo bus) return is wired
	-- to on the recording interface. Blank = leave the input unassigned. This
	-- is specific to each user's physical wiring, so it can't be auto-detected.
	lrInputChannel = getCfg("lrInputChannel", ""),
}

-- ═══════════════════════════════════ groups ═════════════════════════════

local GROUP_IN, GROUP_GRP, GROUP_AUX, GROUP_LR, GROUP_C, GROUP_M, GROUP_MTX, GROUP_CUE, GROUP_TB =
	0, 1, 2, 3, 4, 5, 6, 7, 8

local GROUP_TAG = {
	[GROUP_IN] = "In", [GROUP_GRP] = "Grp", [GROUP_AUX] = "Aux", [GROUP_LR] = "LR",
	[GROUP_C] = "C", [GROUP_M] = "M", [GROUP_MTX] = "Mtx", [GROUP_CUE] = "Cue", [GROUP_TB] = "TB",
}

-- Sidebar filter sections. `groups = nil` is the catch-all bucket for LV1
-- group ids this script doesn't know about yet (firmware additions), so new
-- channel types show up instead of silently vanishing.
local SECTIONS = {
	{ id = "in",  label = "Inputs",   color = 0x3E7BFAFF, groups = { [GROUP_IN] = true } },
	{ id = "grp", label = "Groups",   color = 0xA78BFAFF, groups = { [GROUP_GRP] = true } },
	{ id = "aux", label = "Aux / FX", color = 0x34D399FF, groups = { [GROUP_AUX] = true } },
	{ id = "mtx", label = "Matrix",   color = 0xF472B6FF, groups = { [GROUP_MTX] = true } },
	{ id = "mas", label = "Masters",  color = 0xFBBF24FF, groups = { [GROUP_LR] = true, [GROUP_C] = true, [GROUP_M] = true } },
	{ id = "cue", label = "Cue / TB", color = 0x94A3B8FF, groups = { [GROUP_CUE] = true, [GROUP_TB] = true } },
	{ id = "oth", label = "Other",    color = 0x64748BFF, groups = nil },
}

local KNOWN_GROUPS = {}
for _, s in ipairs(SECTIONS) do
	if s.groups then for g in pairs(s.groups) do KNOWN_GROUPS[g] = true end end
end

local function sectionOf(group)
	for _, s in ipairs(SECTIONS) do
		if s.groups and s.groups[group] then return s end
	end
	return SECTIONS[#SECTIONS] -- "Other"
end

-- ═══════════════════════════════════ state ═════════════════════════════

local tracks = {}          -- { {group, ch, name, editedName, stereo, detect, color, selected}, ... }
local devices = {}         -- LV1s seen on the LAN during the last scan/fetch

-- Builds a device entry out of the saved settings. The console picked in an
-- earlier session has to stay visible in the Devices list even before any scan
-- has run, otherwise the header names a target the list doesn't contain - and
-- there is nothing to click to clear the selection.
local function savedDevice()
	if cfg.host == "" then return nil end
	return {
		name = cfg.deviceName ~= "" and cfg.deviceName or cfg.host,
		host = cfg.deviceName ~= "" and cfg.deviceName or nil,
		address = cfg.host,
		addresses = { cfg.host },
		port = tonumber(cfg.port),
		seen = false,      -- restored from settings, not observed on the LAN yet
	}
end

-- Upholds the invariant "the selected console is always one of the rows".
local function mergeSavedDevice()
	if cfg.host == "" then return end
	for _, d in ipairs(devices) do
		if d.address == cfg.host or d.name == cfg.host or d.host == cfg.host then return end
	end
	devices[#devices+1] = savedDevice()
end

do
	local d = savedDevice()
	if d then devices = { d } end
end
-- Opening line matches whichever button is lit, so the window explains its own
-- next step whether or not a console was already saved from a previous session.
local statusMsg = cfg.host ~= ""
	and string.format("Ready. Console: %s. Click \"Fetch tracks\".", cfg.deviceName ~= "" and cfg.deviceName or cfg.host)
	or "Start with \"Scan network\" to find your LV1, then pick it in the Devices list."
local statusKind = "idle"  -- idle | busy | ok | error
local lastLog = ""
local forceOpenDiag = false
local searchText = ""
local activeSection = nil  -- nil = no filter, otherwise a SECTIONS entry id
local showSettings = false
local lastResult = nil     -- the raw decoded JSON of the last successful read
local isMockData = false   -- the list came from --mock, not from a live console
local lastClickedKey = nil -- anchor row for shift-click range selection

-- Background job (fetch or scan). REAPER's UI stays responsive: the Node
-- helper is launched detached and we poll its output files from the defer loop.
local job = nil            -- { kind, startedAt, budgetSec, lastLogSize }

local function setStatus(kind, msg)
	statusKind = kind
	statusMsg = msg
end

-- ═══════════════════════════════════ helpers ═══════════════════════════

local function readFile(p)
	local f = io.open(p, "rb")
	if not f then return nil end
	local content = f:read("*a")
	f:close()
	return content
end

local function fileExists(p)
	local f = io.open(p, "rb")
	if not f then return false end
	f:close()
	return true
end

local function hexToRgb(hex)
	if not hex or type(hex) ~= "string" then return nil end
	hex = hex:gsub("#", "")
	if #hex ~= 6 then return nil end
	return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

-- Packed 0xRRGGBB int used by ImGui_ColorEdit3.
local function hexToImU32(hex)
	local r, g, b = hexToRgb(hex)
	if not r then return 0x808080 end
	return (r << 16) | (g << 8) | b
end
local function imU32ToHex(v)
	return string.format("#%02x%02x%02x", (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
end

-- LV1 factory/default channel names follow a plain "<Word> <N>" pattern
-- (e.g. "Channel 12", "Aux 3", "Fx 2"). A channel that still carries one is
-- almost certainly unused; a renamed one is a strong signal it's in use.
local DEFAULT_NAME_PATTERNS = {
	"^%s*[Cc]hannel%s+%d+%s*$",
	"^%s*[Aa]ux%s+%d+%s*$",
	"^%s*[Ff]x%s+%d+%s*$",
	"^%s*[Gg]roup%s+%d+%s*$",
	"^%s*[Mm]atrix%s+%d+%s*$",
	"^%s*[Mm]ono%s*%d*%s*$",
	"^%s*[Cc]ue%s*%d*%s*$",
	"^%s*[Tt]alk%s*[Bb]ack%s*%d*%s*$",
	"^%s*LR%s*$",
	"^%s*[Cc]enter%s*$",
}

local function isDefaultChannelName(name)
	if not name or name == "" then return true end
	for _, pat in ipairs(DEFAULT_NAME_PATTERNS) do
		if name:match(pat) then return true end
	end
	return false
end

local function trackKey(t) return tostring(t.group) .. "." .. tostring(t.ch) end

local function matchesFilters(t)
	if activeSection and sectionOf(t.group).id ~= activeSection then return false end
	if cfg.hideUnused and isDefaultChannelName(t.name) then return false end
	if searchText ~= "" then
		local needle = searchText:lower()
		local hay = (t.editedName or ""):lower() .. " " .. (t.name or ""):lower() .. " " ..
			(GROUP_TAG[t.group] or ""):lower() .. tostring(t.ch + 1)
		if not hay:find(needle, 1, true) then return false end
	end
	return true
end

-- ═══════════════════════════════════ record input mapping ══════════════
-- Builds a map from LV1 "In" channel index to the 0-based hardware input slot.
--   "console": mirrors the real console input layout — iterates ALL fetched
--     "In" channels (selected or not), so a stereo channel shifts everything
--     after it by one extra slot and skipped channels leave gaps.
--   "linear": iterates only the SELECTED "In" channels and assigns sequential
--     slots with no gaps.
local function buildInputHwMap(mode)
	local inTracks = {}
	for _, t in ipairs(tracks) do
		if t.group == GROUP_IN and (mode == "console" or t.selected) then
			inTracks[#inTracks+1] = t
		end
	end
	table.sort(inTracks, function(a, b) return a.ch < b.ch end)
	local map, hw = {}, 0
	for _, t in ipairs(inTracks) do
		map[t.ch] = hw
		hw = hw + (t.stereo and 2 or 1)
	end
	return map
end

-- Human-readable preview of what a track's record input will be, shown live in
-- the table so the patching is verifiable before anything is created.
local function inputPreview(t, hwMap)
	if not cfg.prePatchInputs then return "-", COL.textFaint end
	if t.group == GROUP_IN then
		local hw = hwMap[t.ch] or t.ch
		if t.stereo then return string.format("%d/%d", hw + 1, hw + 2), COL.textDim end
		return tostring(hw + 1), COL.textDim
	end
	if t.group == GROUP_LR then
		local lr = tonumber((cfg.lrInputChannel or ""):match("^%s*(.-)%s*$"))
		if lr and lr >= 1 then return string.format("%d/%d", lr, lr + 1), COL.ok end
		return "none", COL.textFaint
	end
	return "-", COL.textFaint
end

-- ═══════════════════════════════════ fetch / scan ══════════════════════

local function quoteArg(s)
	s = tostring(s)
	if IS_WIN then return '"' .. s:gsub('"', '') .. '"' end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Only ever pass a syntactically valid host to the shell. Anything else is a
-- typo, and letting it through would splice arbitrary text into a command line.
local function sanitizedHost()
	local h = (cfg.host or ""):match("^%s*(.-)%s*$")
	if h == "" then return "" end
	if h:match("^%d+%.%d+%.%d+%.%d+$") or h:match("^[%w%-%.]+$") then return h end
	return nil
end

local function buildCommand(kind)
	local host = sanitizedHost()
	if host == nil then return nil, "Invalid host: use an IPv4 address (e.g. 192.168.1.40) or a plain hostname." end

	local parts = { quoteArg(cfg.nodePath), quoteArg(FETCH_JS) }
	local function add(...) for _, v in ipairs({...}) do parts[#parts+1] = v end end

	if kind == "scan" then
		add("--scan")
	else
		if host ~= "" then add("--host", host) end
		if (cfg.port or "") ~= "" and tonumber(cfg.port) then add("--port", tostring(math.floor(tonumber(cfg.port)))) end
		add("--listen-ms", tostring(math.floor(cfg.listenMs)))
	end
	add("--discover-ms", tostring(math.floor(cfg.discoverMs)))
	add("--out", quoteArg(JSON_OUT))
	add("--log", quoteArg(LOG_OUT))
	if cfg.verbose then add("--verbose") end
	return table.concat(parts, " ")
end

local applyResult  -- forward declaration (defined below, used by both paths)

-- Blocking fallback: kept because io.popen has different failure modes from
-- ExecProcess, and when the Node helper can't even be launched it is the path
-- that actually surfaces the OS error message.
local function runBlocking(cmd, kind)
	local inner = cmd .. " 2>&1"
	-- On Windows io.popen runs the string through "cmd.exe /c <cmd>". With more
	-- than two quote characters, cmd.exe stops preserving inner quotes and
	-- strips only the first and last one of the whole line, corrupting every
	-- quoted path in between. Wrapping the whole command in one more pair of
	-- quotes makes cmd.exe strip only that outer wrapper. Harmless on POSIX.
	local full = IS_WIN and ('"' .. inner .. '"') or inner
	local handle = io.popen(full, "r")
	local output = ""
	if handle then
		output = handle:read("*a") or ""
		handle:close()
	end
	if output ~= "" then lastLog = output end
	applyResult(kind, true)
end

local function startJob(kind)
	if job then return end

	local cmd, err = buildCommand(kind)
	if not cmd then
		setStatus("error", err)
		showSettings = true
		return
	end

	-- Delete the previous run's artefacts FIRST. Without this, a fetch that
	-- fails before Node even starts would fall through to the stale JSON from
	-- the last successful run and cheerfully report its track list as fresh.
	os.remove(JSON_OUT)
	os.remove(LOG_OUT)
	lastLog = ""

	if cfg.blockingMode then
		setStatus("busy", "Running lv1_fetch.js (blocking mode)...")
		runBlocking(cmd, kind)
		return
	end

	-- -2 = run detached, no console window. REAPER keeps rendering while the
	-- helper works; we poll JSON_OUT/LOG_OUT from the defer loop.
	local launched = reaper.ExecProcess(cmd, -2)
	if launched == nil then
		setStatus("error", "Could not launch Node.js. Check the Node path in Settings (currently: " .. cfg.nodePath .. ").")
		showSettings = true
		return
	end

	local budget = (cfg.discoverMs + (kind == "scan" and 0 or cfg.listenMs)) / 1000 + 12
	job = { kind = kind, startedAt = reaper.time_precise(), budgetSec = budget }
	setStatus("busy", kind == "scan" and "Scanning the network for LV1s..." or "Connecting to the LV1...")
end

-- Reads back whatever lv1_fetch.js wrote and folds it into the UI state.
applyResult = function(kind, blocking)
	local content = readFile(JSON_OUT)
	local fileLog = readFile(LOG_OUT)
	if fileLog and fileLog ~= "" then lastLog = fileLog end
	if lastLog == "" then
		lastLog = "(no output captured — check that Node.js is installed and on PATH, or set its full path in Settings)"
	end

	if not content then
		setStatus("error", blocking
			and "lv1_tracks.json was not written. See the diagnostic log below."
			or "The helper produced no result file. Check the Node.js path in Settings, then try again (Settings > Advanced > blocking mode gives more detail).")
		forceOpenDiag = true
		return
	end

	local data = jsonDecode(content)
	if not data then
		setStatus("error", "Could not parse lv1_tracks.json. See the diagnostic log below.")
		forceOpenDiag = true
		return
	end

	lastResult = data
	-- Building a whole live session out of a replayed capture without noticing
	-- is the kind of mistake you only discover at soundcheck, so this is
	-- surfaced as a banner rather than buried in the diagnostics.
	isMockData = (data.mock == true)
	if type(data.devices) == "table" then devices = data.devices end
	mergeSavedDevice()

	if data.schemaVersion and data.schemaVersion > SCHEMA_VERSION then
		setStatus("error", string.format(
			"lv1_fetch.js is newer than this script (schema %d vs %d) — update LV1_Track_Importer.lua.",
			data.schemaVersion, SCHEMA_VERSION))
		return
	end

	if kind == "scan" then
		if data.ok == true then
			setStatus("ok", string.format("Found %d LV1%s on the network.", #devices, #devices == 1 and "" or "s"))
		else
			setStatus("error", data.error or "No LV1 found on the network.")
			forceOpenDiag = true
		end
		return
	end

	if data.ok ~= true then
		setStatus("error", data.error or "Fetch failed for an unknown reason. See the diagnostic log below.")
		forceOpenDiag = true
		return
	end

	-- Carry the user's per-track edits across a re-fetch: re-ticking 30 boxes
	-- because the mixer was re-scanned would be needless work.
	local previous = {}
	for _, t in ipairs(tracks) do
		previous[trackKey(t)] = { selected = t.selected, editedName = t.editedName, name = t.name, color = t.color, stereo = t.stereo }
	end
	local hadTracks = #tracks > 0

	tracks = {}
	for _, t in ipairs(data.tracks or {}) do
		if type(t) == "table" and type(t.group) == "number" and type(t.ch) == "number" then
			local name = type(t.name) == "string" and t.name or ""
			local key = tostring(t.group) .. "." .. tostring(t.ch)
			local prev = previous[key]
			-- Default selection: always pre-select the LR master bus; for "In"
			-- channels, pre-select only those renamed away from the LV1's factory
			-- default (a strong signal the channel is actually in use). Every other
			-- group is left unticked.
			local preselect = (t.group == GROUP_LR) or (t.group == GROUP_IN and not isDefaultChannelName(name))
			local entry = {
				group = t.group,
				ch = t.ch,
				name = name,
				editedName = name,
				stereo = t.stereo == true,
				detect = type(t.detect) == "string" and t.detect or "meter",
				color = type(t.color) == "string" and t.color or nil,
				selected = preselect,
			}
			if prev and hadTracks then
				entry.selected = prev.selected
				-- Only keep a manual rename, not a stale copy of an old LV1 name.
				if prev.editedName ~= prev.name then entry.editedName = prev.editedName end
				if prev.color and not entry.color then entry.color = prev.color end
			end
			tracks[#tracks+1] = entry
		end
	end

	if #tracks == 0 then
		setStatus("error", data.error or "The LV1 answered but sent no named tracks. Try raising the listen timeout in Settings.")
		forceOpenDiag = true
		return
	end

	local where = data.deviceName and data.deviceName ~= "" and data.deviceName or tostring(data.host)
	local msg = string.format("Fetched %d tracks from %s", #tracks, where)
	if data.elapsedMs then msg = msg .. string.format(" in %.1fs", data.elapsedMs / 1000) end
	if (data.widthGuessedCount or 0) > 0 then
		msg = msg .. string.format(" — %d track(s) had their mono/stereo guessed, marked with ~", data.widthGuessedCount)
	end
	setStatus(data.error and "error" or "ok", data.error and (msg .. ". " .. data.error) or (msg .. "."))
	if data.ambiguous then
		setStatus("ok", msg .. string.format(". Note: %d LV1s are on this network — check the device list.", #devices))
	end
end

local function pollJob()
	if not job then return end

	local now = reaper.time_precise()
	if fileExists(JSON_OUT) then
		local kind = job.kind
		job = nil
		applyResult(kind, false)
		return
	end

	-- Stream the helper's log while it works so the progress area shows what is
	-- actually happening rather than an opaque spinner. Throttled: re-reading
	-- the file at frame rate would be pure waste.
	if now - (job.lastLogRead or 0) > 0.15 then
		job.lastLogRead = now
		local partial = readFile(LOG_OUT)
		if partial and partial ~= "" then lastLog = partial end
	end

	if now - job.startedAt > job.budgetSec then
		local kind = job.kind
		job = nil
		if lastLog == "" then
			setStatus("error", "Timed out and the helper never wrote anything — Node.js probably didn't start. Check the Node path in Settings, or enable blocking mode there to see the OS error.")
			showSettings = true
		else
			setStatus("error", "Timed out waiting for " .. kind .. " to finish. See the diagnostic log below.")
			forceOpenDiag = true
		end
		forceOpenDiag = true
	end
end

-- ═══════════════════════════════════ create / update tracks ════════════

-- Tracks created by this script are stamped with their LV1 identity, so a
-- later run can recognise them (and update instead of duplicating) even after
-- they've been renamed or reordered in REAPER.
local TAG_KEY = "P_EXT:lv1_track"

local function existingLv1Tracks()
	local map = {}
	for i = 0, reaper.CountTracks(0) - 1 do
		local tr = reaper.GetTrack(0, i)
		local ok, tag = reaper.GetSetMediaTrackInfo_String(tr, TAG_KEY, "", false)
		if ok and tag ~= "" then map[tag] = tr end
	end
	return map
end

local function selectedTracksInOrder()
	local out = {}
	for _, t in ipairs(tracks) do
		if t.selected then out[#out+1] = t end
	end
	return out
end

local function applyTrackSettings(tr, t, label, hwMap)
	reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", label, true)
	reaper.GetSetMediaTrackInfo_String(tr, TAG_KEY, trackKey(t), true)
	-- REAPER track channel count: 1 = mono, 2 = stereo.
	reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", t.stereo and 2 or 1)

	if t.color then
		local r, g, b = hexToRgb(t.color)
		if r then
			-- The 0x1000000 bit is REAPER's "this track has a custom color" flag.
			reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", reaper.ColorToNative(r, g, b) | 0x1000000)
		end
	end

	if cfg.armRecord then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1) end

	if not cfg.prePatchInputs then return nil end

	-- I_RECINPUT encoding: 0 <= x < 1024 selects mono hardware input x
	-- (0-based); 1024 + x selects the stereo pair starting at input x.
	-- A negative value means "no input" and is enough on its own to display
	-- "None" in the record input selector. Do NOT also set I_RECMODE=2 to
	-- clear an input: that value is REAPER's "Disable (input monitoring only)"
	-- mode, which blocks recording even once an input is assigned later.
	if t.group == GROUP_IN then
		local hw = hwMap[t.ch] or t.ch
		reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", t.stereo and (1024 + hw) or hw)
	elseif t.group == GROUP_LR then
		-- LR is a mix bus, not a hardware input — except that many live
		-- multitrack rigs also record the main mix through a dedicated analog
		-- return. That wiring is specific to each setup and can't be detected,
		-- hence the configurable 1-based channel number.
		local lrCh = tonumber((cfg.lrInputChannel or ""):match("^%s*(.-)%s*$"))
		if lrCh and lrCh >= 1 then
			reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 1024 + (lrCh - 1))
			return string.format("LR patched to hardware input %d/%d", lrCh, lrCh + 1)
		end
		reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)
		return "LR left with no input (set \"LR record input\" to patch it)"
	else
		-- Buses (Grp, Aux, Mtx...) have nothing meaningful to patch to. REAPER
		-- defaults a new track to input 1, which looks patched when it isn't.
		reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)
	end
	return nil
end

local function labelFor(t, index, padWidth)
	local base = (t.editedName ~= "" and t.editedName) or t.name
	if not cfg.prefixTrackNumber then return base end
	return string.format("%0" .. padWidth .. "d %s", index, base)
end

-- PreventUIRefresh is a counter and Undo_BeginBlock opens a project-wide block:
-- if the body between them throws, REAPER stops refreshing its track list and
-- arrange view for the rest of the session and the undo block never closes —
-- with nothing on screen to explain it, since the caller runs inside the
-- per-frame pcall that swallows the error. So the body is always guarded and
-- the closers always run.
local function inUndoBlock(label, body)
	reaper.PreventUIRefresh(1)
	reaper.Undo_BeginBlock()
	local ok, err = pcall(body)
	reaper.Undo_EndBlock(label, -1)
	reaper.PreventUIRefresh(-1)
	reaper.TrackList_AdjustWindows(false)
	reaper.UpdateArrange()
	if not ok then
		reaper.ShowConsoleMsg("LV1 Track Importer: \"" .. label .. "\" failed: " .. tostring(err) .. "\n")
	end
	return ok, err
end

local function createSelectedTracks()
	local selected = selectedTracksInOrder()
	if #selected == 0 then
		setStatus("error", "Nothing selected.")
		return
	end

	local existing = cfg.skipExisting and existingLv1Tracks() or {}
	local hwMap = buildInputHwMap(cfg.prePatchMode)
	-- Zero-pad to the width of the largest index so names keep sorting
	-- correctly ("01".."12" rather than "1", "10", "11", "12", "2", ...).
	local padWidth = math.max(2, #tostring(#selected))

	local created, skipped, note = 0, 0, nil
	local n = 0
	local folderOpen, lastTrack, currentSection = false, nil, nil

	local function closeFolder()
		if folderOpen and lastTrack then
			reaper.SetMediaTrackInfo_Value(lastTrack, "I_FOLDERDEPTH", -1)
		end
		folderOpen = false
	end

	local ok = inUndoBlock("Create tracks from LV1", function()
		for _, t in ipairs(selected) do
			n = n + 1
			if existing[trackKey(t)] then
				skipped = skipped + 1
			else
				if cfg.createFolders then
					local sec = sectionOf(t.group)
					if sec.id ~= currentSection then
						closeFolder()
						currentSection = sec.id
						local fidx = reaper.CountTracks(0)
						reaper.InsertTrackAtIndex(fidx, true)
						local folder = reaper.GetTrack(0, fidx)
						if folder then
							reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "LV1 " .. sec.label:upper(), true)
							reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
							reaper.SetMediaTrackInfo_Value(folder, "I_RECINPUT", -1)
							local r, g, b = hexToRgb(imU32ToHex(sec.color >> 8))
							if r then reaper.SetMediaTrackInfo_Value(folder, "I_CUSTOMCOLOR", reaper.ColorToNative(r, g, b) | 0x1000000) end
							folderOpen = true
						end
					end
				end

				local idx = reaper.CountTracks(0)
				reaper.InsertTrackAtIndex(idx, true)
				local tr = reaper.GetTrack(0, idx)
				if tr then
					local msg = applyTrackSettings(tr, t, labelFor(t, n, padWidth), hwMap)
					if msg then note = msg end
					lastTrack = tr
					created = created + 1
				end
			end
		end
		closeFolder()
	end)

	if not ok then
		setStatus("error", string.format(
			"Track creation failed after %d track(s) — see the REAPER console. Undo to roll back.", created))
		return
	end

	local msg = string.format("Created %d track%s.", created, created == 1 and "" or "s")
	if skipped > 0 then msg = msg .. string.format(" %d already existed and were skipped.", skipped) end
	if note then msg = msg .. " " .. note .. "." end
	setStatus("ok", msg)
end

local function updateExistingTracks()
	local existing = existingLv1Tracks()
	local selected = selectedTracksInOrder()
	local hwMap = buildInputHwMap(cfg.prePatchMode)
	local padWidth = math.max(2, #tostring(math.max(#selected, 1)))
	local updated, missing = 0, 0

	local n = 0
	local ok = inUndoBlock("Update tracks from LV1", function()
		for _, t in ipairs(selected) do
			n = n + 1
			local tr = existing[trackKey(t)]
			if tr then
				applyTrackSettings(tr, t, labelFor(t, n, padWidth), hwMap)
				updated = updated + 1
			else
				missing = missing + 1
			end
		end
	end)

	if not ok then
		setStatus("error", string.format(
			"Update failed after %d track(s) — see the REAPER console. Undo to roll back.", updated))
	elseif updated == 0 then
		setStatus("error", "No previously imported LV1 track found in this project — use \"Create tracks\" first.")
	else
		local msg = string.format("Updated %d existing track%s.", updated, updated == 1 and "" or "s")
		if missing > 0 then msg = msg .. string.format(" %d selected track%s not in the project yet.", missing, missing == 1 and " is" or "s are") end
		setStatus("ok", msg)
	end
end

-- ═══════════════════════════════════ GUI ═══════════════════════════════

local ctx = ImGui.CreateContext('LV1 Track Importer')

local FONT_TITLE, FONT_SMALL
do
	-- Fonts are optional: ReaImGui changed PushFont's signature across versions
	-- and a missing font must degrade to the default one, never break the UI.
	local okT, f = pcall(ImGui.CreateFont, 'sans-serif', 20)
	if okT and f then
		if pcall(ImGui.Attach, ctx, f) then FONT_TITLE = f end
	end
	local okS, g = pcall(ImGui.CreateFont, 'sans-serif', 11)
	if okS and g then
		if pcall(ImGui.Attach, ctx, g) then FONT_SMALL = g end
	end
end

local function pushFont(f)
	if not f then return false end
	if pcall(ImGui.PushFont, ctx, f) then return true end
	if pcall(ImGui.PushFont, ctx, f, 0) then return true end
	return false
end
local function popFont(pushed)
	if pushed then pcall(ImGui.PopFont, ctx) end
end

-- All style pushes are balanced with a single PopStyleVar/PopStyleColor call
-- per frame (both take a count), and each push only happens when the enum
-- actually exists, so version differences can't desync the counts.
local function pushTheme()
	-- Each counter is only incremented when the push actually succeeded, so a
	-- style name this ReaImGui build rejects can never desync the matching
	-- Pop*(count) call. pushTheme runs outside the per-frame pcall, so it has
	-- to be the sturdiest code in the script.
	local nVars, nCols = 0, 0
	local function var(name, ...)
		local v = E(name, -1)
		if v ~= -1 and pcall(ImGui.PushStyleVar, ctx, v, ...) then nVars = nVars + 1 end
	end
	local function col(name, value)
		local v = E(name, -1)
		if v ~= -1 and pcall(ImGui.PushStyleColor, ctx, v, value) then nCols = nCols + 1 end
	end

	var('StyleVar_WindowRounding', 8.0)
	var('StyleVar_ChildRounding', 8.0)
	var('StyleVar_FrameRounding', 5.0)
	var('StyleVar_GrabRounding', 5.0)
	var('StyleVar_PopupRounding', 8.0)
	var('StyleVar_ScrollbarRounding', 8.0)
	var('StyleVar_TabRounding', 5.0)
	var('StyleVar_WindowPadding', 14.0, 12.0)
	var('StyleVar_FramePadding', 9.0, 5.0)
	var('StyleVar_ItemSpacing', 8.0, 7.0)
	var('StyleVar_ItemInnerSpacing', 6.0, 4.0)
	var('StyleVar_CellPadding', 7.0, 5.0)
	var('StyleVar_ScrollbarSize', 11.0)
	var('StyleVar_ChildBorderSize', 1.0)
	var('StyleVar_FrameBorderSize', 0.0)

	col('Col_WindowBg', COL.bg)
	col('Col_ChildBg', COL.panel)
	col('Col_PopupBg', COL.panelAlt)
	col('Col_Border', COL.border)
	col('Col_Text', COL.text)
	col('Col_TextDisabled', COL.textFaint)
	col('Col_FrameBg', COL.raised)
	col('Col_FrameBgHovered', 0x30354AFF)
	col('Col_FrameBgActive', 0x363C50FF)
	col('Col_TitleBg', 0x101218FF)
	col('Col_TitleBgActive', 0x171A21FF)
	col('Col_Button', COL.raised)
	col('Col_ButtonHovered', 0x333A4AFF)
	col('Col_ButtonActive', COL.accentLo)
	col('Col_Header', COL.accentDim)
	col('Col_HeaderHovered', 0x3E7BFA44)
	col('Col_HeaderActive', COL.accentLo)
	col('Col_CheckMark', COL.accentHi)
	col('Col_SliderGrab', COL.accent)
	col('Col_SliderGrabActive', COL.accentHi)
	col('Col_Tab', COL.panelAlt)
	col('Col_TabHovered', COL.accentLo)
	col('Col_TabActive', COL.accent)
	col('Col_TabSelected', COL.accent)
	col('Col_Separator', COL.border)
	col('Col_SeparatorHovered', COL.accent)
	col('Col_ScrollbarBg', 0x00000000)
	col('Col_ScrollbarGrab', 0x3A4052FF)
	col('Col_ScrollbarGrabHovered', 0x4A5268FF)
	col('Col_TableHeaderBg', COL.panelAlt)
	col('Col_TableRowBg', 0x00000000)
	col('Col_TableRowBgAlt', 0xFFFFFF06)
	col('Col_TableBorderStrong', COL.border)
	col('Col_TableBorderLight', 0x252932FF)

	return nVars, nCols
end

local function popTheme(nVars, nCols)
	if nVars > 0 then ImGui.PopStyleVar(ctx, nVars) end
	if nCols > 0 then ImGui.PopStyleColor(ctx, nCols) end
end

-- ─── small drawing helpers ───

-- allowDisabled is needed to explain a greyed-out control: ImGui suppresses
-- hover on disabled items unless explicitly asked otherwise, and a disabled
-- button with no explanation is the most frustrating thing in a UI.
local function tooltip(text, allowDisabled)
	local flags = allowDisabled and E('HoveredFlags_AllowWhenDisabled') or 0
	if ImGui.IsItemHovered(ctx, flags) then ImGui.SetTooltip(ctx, text) end
end

-- Paints a button as the primary action. Only one button is ever primary at a
-- time: the blue fill is what tells you the next step, so spending it on two
-- controls at once would make it mean nothing.
local function pushPrimaryColors(isPrimary)
	if not isPrimary then return 0 end
	local nc = 0
	local function col(name, v) local e = E(name, -1); if e ~= -1 and pcall(ImGui.PushStyleColor, ctx, e, v) then nc = nc + 1 end end
	col('Col_Button', COL.accent)
	col('Col_ButtonHovered', COL.accentHi)
	col('Col_ButtonActive', COL.accentLo)
	col('Col_Text', 0xFFFFFFFF)
	return nc
end

-- A filled dot drawn straight into the draw list: ReaImGui's default font
-- can't be relied on for symbol glyphs, and this always looks right.
local function statusDot(color, radius)
	radius = radius or 4
	local x, y = ImGui.GetCursorScreenPos(ctx)
	local h = ImGui.GetTextLineHeight(ctx)
	ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + radius, y + h * 0.5, radius, color, 16)
	ImGui.Dummy(ctx, radius * 2 + 4, h)
end

local function labelledValue(label, value, valueColor)
	ImGui.TextColored(ctx, COL.textFaint, label)
	ImGui.SameLine(ctx)
	ImGui.TextColored(ctx, valueColor or COL.text, value)
end

-- Toggle button pair used for Mono/Stereo. Far more compact and far easier to
-- hit than two radio buttons, and it reads as one control instead of two.
local function segmented(isStereo)
	local changed, value = false, isStereo

	local function part(text, active, width)
		local nc = 0
		local function col(name, v) local e = E(name, -1); if e ~= -1 and pcall(ImGui.PushStyleColor, ctx, e, v) then nc = nc + 1 end end
		col('Col_Button', active and COL.accent or 0x00000000)
		col('Col_ButtonHovered', active and COL.accentHi or COL.raisedHi)
		col('Col_ButtonActive', COL.accentLo)
		col('Col_Text', active and 0xFFFFFFFF or COL.textDim)
		local clicked = ImGui.Button(ctx, text, width, 0)
		if nc > 0 then ImGui.PopStyleColor(ctx, nc) end
		return clicked
	end

	if part('Mono', not isStereo, 52) then changed, value = true, false end
	ImGui.SameLine(ctx, 0, 3)
	if part('Stereo', isStereo, 56) then changed, value = true, true end
	return changed, value
end

-- ─── header ───

local function drawHeader()
	local h = 54
	if ImGui.BeginChild(ctx, 'header', 0, h, E('ChildFlags_Borders', E('ChildFlags_Border', 1))) then
		local pushed = pushFont(FONT_TITLE)
		ImGui.TextColored(ctx, COL.text, 'LV1')
		popFont(pushed)
		ImGui.SameLine(ctx, 0, 6)
		local p2 = pushFont(FONT_TITLE)
		ImGui.TextColored(ctx, COL.accent, '->')
		ImGui.SameLine(ctx, 0, 6)
		ImGui.TextColored(ctx, COL.text, 'REAPER')
		popFont(p2)

		ImGui.SameLine(ctx, 0, 20)
		ImGui.BeginGroup(ctx)
		local dotColor = (statusKind == 'ok' and COL.ok)
			or (statusKind == 'error' and COL.err)
			or (statusKind == 'busy' and COL.warn)
			or COL.textFaint
		statusDot(dotColor, 4)
		ImGui.SameLine(ctx, 0, 2)
		local target = cfg.deviceName ~= "" and cfg.deviceName
			or (cfg.host ~= "" and cfg.host or "auto-discover")
		local where = cfg.host ~= "" and (cfg.host .. (cfg.port ~= "" and (":" .. cfg.port) or "")) or "no address saved"
		ImGui.TextColored(ctx, COL.text, target)
		ImGui.SameLine(ctx, 0, 8)
		ImGui.TextColored(ctx, COL.textFaint, where)
		ImGui.EndGroup(ctx)

		-- Right-aligned action cluster. Positioning from the child's own width is
		-- deterministic, unlike chaining SameLine spacings off the previous item.
		local cluster = 128 + 116 + 92 + 8 * 2
		ImGui.SameLine(ctx)
		ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx) + 12, ImGui.GetWindowWidth(ctx) - cluster - 14))

		-- The blue fill always marks the next sensible step: scan until a console
		-- has been picked, then fetch. Note the condition is "a console is
		-- selected", NOT "a scan ran in this session" - a host restored from the
		-- saved settings is just as valid a target, and forcing a rescan at every
		-- REAPER launch would be busywork.
		local hasTarget = cfg.host ~= ""

		ImGui.BeginDisabled(ctx, job ~= nil or not hasTarget)
		local nc = pushPrimaryColors(hasTarget)
		if ImGui.Button(ctx, (job and job.kind == 'fetch') and 'Fetching...' or 'Fetch tracks', 128, 26) then
			startJob('fetch')
		end
		if nc > 0 then ImGui.PopStyleColor(ctx, nc) end
		ImGui.EndDisabled(ctx)
		tooltip(hasTarget
			and 'Connect to the LV1 and read its track list.'
			or 'No console selected yet. Run "Scan network", then click your LV1 in the Devices list.', true)

		ImGui.SameLine(ctx)
		ImGui.BeginDisabled(ctx, job ~= nil)
		local nc2 = pushPrimaryColors(not hasTarget)
		if ImGui.Button(ctx, (job and job.kind == 'scan') and 'Scanning...' or 'Scan network', 116, 26) then
			startJob('scan')
		end
		if nc2 > 0 then ImGui.PopStyleColor(ctx, nc2) end
		ImGui.EndDisabled(ctx)
		tooltip('List every LV1 announcing itself on the LAN, without connecting.')

		ImGui.SameLine(ctx)
		if ImGui.Button(ctx, 'Settings', 92, 26) then showSettings = true end

		ImGui.EndChild(ctx)
	end
end

-- ─── status / progress strip ───

local function drawStatusStrip()
	if job then
		local elapsed = reaper.time_precise() - job.startedAt
		local frac = math.min(0.97, elapsed / job.budgetSec)
		ImGui.TextColored(ctx, COL.warn, statusMsg)
		ImGui.SameLine(ctx)
		ImGui.TextColored(ctx, COL.textFaint, string.format('%.1fs', elapsed))
		ImGui.SameLine(ctx)
		if ImGui.SmallButton(ctx, 'Cancel') then
			job = nil
			setStatus('idle', 'Cancelled. (The helper process finishes on its own in the background.)')
		end
		local nc = 0
		local e = E('Col_PlotHistogram', -1)
		if e ~= -1 then ImGui.PushStyleColor(ctx, e, COL.accent); nc = 1 end
		ImGui.ProgressBar(ctx, frac, -1, 6, '')
		if nc > 0 then ImGui.PopStyleColor(ctx, nc) end
		-- Last log line: turns the wait into something readable.
		local tail = lastLog:match('([^\r\n]+)%s*$')
		if tail then ImGui.TextColored(ctx, COL.textFaint, tail:sub(1, 160)) end
	else
		local c = (statusKind == 'error' and COL.err) or (statusKind == 'ok' and COL.ok) or COL.textDim
		ImGui.TextColored(ctx, c, statusMsg)
	end
end

-- ─── sidebar ───

local function useDevice(dev)
	cfg.host = dev and (dev.address or dev.host or "") or ""
	cfg.port = ""  -- always re-resolved: the LV1's OSC port changes on restart
	cfg.deviceName = dev and (dev.name or dev.host or "") or ""
	setCfg('host', cfg.host)
	setCfg('port', cfg.port)
	setCfg('deviceName', cfg.deviceName)
end

local function drawSidebar(height)
	if not ImGui.BeginChild(ctx, 'sidebar', 218, height, E('ChildFlags_Borders', E('ChildFlags_Border', 1))) then return end

	-- Devices ------------------------------------------------------------
	ImGui.TextColored(ctx, COL.textFaint, 'DEVICES')
	ImGui.SameLine(ctx)
	ImGui.TextColored(ctx, COL.textFaint, string.format('(%d)', #devices))
	ImGui.Separator(ctx)

	for i, dev in ipairs(devices) do
		ImGui.PushID(ctx, 'dev' .. i)
		local addr = dev.address or dev.host or '?'
		local isCurrent = (cfg.host ~= "" and (cfg.host == addr or cfg.host == dev.name))
		-- Clicking the selected console again clears the choice, which is how
		-- you get back to "use whatever answers first" without a pseudo-entry
		-- sitting in a list of real hardware.
		if ImGui.Selectable(ctx, (dev.name or dev.host or 'LV1'), isCurrent, 0, 118, 0) then
			useDevice(isCurrent and nil or dev)
		end
		tooltip(string.format('%s\nport %s (re-resolved at every fetch)%s\n\nClick again to clear the selection.',
			addr, tostring(dev.port or '?'),
			dev.seen == false and '\n\nRestored from your settings - this console has not announced itself since the window opened.' or ''))
		ImGui.SameLine(ctx, 0, 6)
		ImGui.TextColored(ctx, (isCurrent and dev.seen ~= false) and COL.accentHi or COL.textFaint, addr)
		ImGui.PopID(ctx)
	end

	if #devices == 0 then
		ImGui.TextColored(ctx, COL.textFaint, 'No scan yet.')
		ImGui.TextColored(ctx, COL.textFaint, 'Use "Scan network".')
	elseif #devices > 1 and cfg.host == "" then
		ImGui.Spacing(ctx)
		ImGui.TextColored(ctx, COL.warn, string.format('%d consoles found -', #devices))
		ImGui.TextColored(ctx, COL.warn, 'pick the right one.')
	end

	ImGui.Spacing(ctx)
	ImGui.Spacing(ctx)

	-- Group filters ------------------------------------------------------
	ImGui.TextColored(ctx, COL.textFaint, 'GROUPS')
	ImGui.Separator(ctx)

	local counts = {}
	local totalSel = 0
	for _, t in ipairs(tracks) do
		local sec = sectionOf(t.group)
		local c = counts[sec.id] or { total = 0, sel = 0 }
		c.total = c.total + 1
		if t.selected then c.sel = c.sel + 1; totalSel = totalSel + 1 end
		counts[sec.id] = c
	end

	if ImGui.Selectable(ctx, string.format('All (%d)', #tracks), activeSection == nil) then activeSection = nil end

	for _, sec in ipairs(SECTIONS) do
		local c = counts[sec.id]
		if c and c.total > 0 then
			ImGui.PushID(ctx, sec.id)
			-- Tri-state-ish checkbox: ticks the whole group in one click.
			local allSel = c.sel == c.total
			local changed, val = ImGui.Checkbox(ctx, '##all', allSel)
			if changed then
				for _, t in ipairs(tracks) do
					if sectionOf(t.group).id == sec.id then t.selected = val end
				end
			end
			tooltip('Select / deselect every track in this group')
			ImGui.SameLine(ctx, 0, 4)
			if ImGui.Selectable(ctx, sec.label, activeSection == sec.id, 0, 108, 0) then
				activeSection = (activeSection == sec.id) and nil or sec.id
			end
			ImGui.SameLine(ctx)
			ImGui.TextColored(ctx, c.sel > 0 and sec.color or COL.textFaint, string.format('%d/%d', c.sel, c.total))
			ImGui.PopID(ctx)
		end
	end

	if #tracks == 0 then
		ImGui.TextColored(ctx, COL.textFaint, 'No tracks fetched yet.')
	end

	ImGui.EndChild(ctx)
end

-- ─── track table ───

local function drawTrackTable(height)
	if not ImGui.BeginChild(ctx, 'main', 0, height, E('ChildFlags_Borders', E('ChildFlags_Border', 1))) then return end

	-- Toolbar
	ImGui.SetNextItemWidth(ctx, 240)
	local changed, val
	if ImGui.InputTextWithHint then
		changed, val = ImGui.InputTextWithHint(ctx, '##search', 'Search a track...', searchText)
	else
		changed, val = ImGui.InputText(ctx, '##search', searchText)
	end
	if changed then searchText = val end

	ImGui.SameLine(ctx)
	local huChanged, huVal = ImGui.Checkbox(ctx, 'Hide unused', cfg.hideUnused)
	if huChanged then cfg.hideUnused = huVal; setCfg('hideUnused', huVal and '1' or '0') end
	tooltip('Hide channels still carrying an LV1 factory name (Channel 12, Aux 3, Fx 2...).')

	-- Visible set drives "select all/none" so those buttons act on what the
	-- user can actually see rather than silently on hidden rows too.
	local visible, visSel = {}, 0
	for _, t in ipairs(tracks) do
		if matchesFilters(t) then
			visible[#visible+1] = t
			if t.selected then visSel = visSel + 1 end
		end
	end

	ImGui.SameLine(ctx)
	ImGui.BeginDisabled(ctx, #visible == 0)
	if ImGui.Button(ctx, 'All', 44, 0) then for _, t in ipairs(visible) do t.selected = true end end
	tooltip('Select every visible track.\nTip: shift-click a checkbox to tick a whole range.')
	ImGui.SameLine(ctx, 0, 4)
	if ImGui.Button(ctx, 'None', 52, 0) then for _, t in ipairs(visible) do t.selected = false end end
	tooltip('Deselect every visible track')
	ImGui.SameLine(ctx, 0, 4)
	if ImGui.Button(ctx, 'Invert', 60, 0) then for _, t in ipairs(visible) do t.selected = not t.selected end end
	ImGui.EndDisabled(ctx)

	local counterText = string.format('%d / %d shown', visSel, #visible)
	local tw = ImGui.CalcTextSize(ctx, counterText)
	ImGui.SameLine(ctx)
	ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx) + 8, ImGui.GetWindowWidth(ctx) - tw - 20))
	ImGui.TextColored(ctx, visSel > 0 and COL.accentHi or COL.textFaint, counterText)

	ImGui.Spacing(ctx)

	local hwMap = buildInputHwMap(cfg.prePatchMode)
	local _, tableH = ImGui.GetContentRegionAvail(ctx)

	local flags = E('TableFlags_RowBg') | E('TableFlags_ScrollY') | E('TableFlags_BordersInnerV')
		| E('TableFlags_Resizable')

	if ImGui.BeginTable(ctx, 'tracks', 6, flags, 0, tableH) then
		ImGui.TableSetupColumn(ctx, '##sel', E('TableColumnFlags_WidthFixed'), 26)
		ImGui.TableSetupColumn(ctx, '##col', E('TableColumnFlags_WidthFixed'), 26)
		ImGui.TableSetupColumn(ctx, 'Ch', E('TableColumnFlags_WidthFixed'), 62)
		ImGui.TableSetupColumn(ctx, 'Name', E('TableColumnFlags_WidthStretch'))
		ImGui.TableSetupColumn(ctx, 'Width', E('TableColumnFlags_WidthFixed'), 118)
		ImGui.TableSetupColumn(ctx, 'Input', E('TableColumnFlags_WidthFixed'), 62)
		ImGui.TableSetupScrollFreeze(ctx, 0, 1)
		ImGui.TableHeadersRow(ctx)

		for i, t in ipairs(visible) do
			ImGui.TableNextRow(ctx)
			ImGui.PushID(ctx, i)
			if t.selected then
				ImGui.TableSetBgColor(ctx, E('TableBgTarget_RowBg0'), COL.accentDim)
			end

			ImGui.TableNextColumn(ctx)
			local sc
			sc, t.selected = ImGui.Checkbox(ctx, '##sel', t.selected)
			if sc then
				-- Shift-click ticks everything between the previous click and this
				-- one. The anchor is stored as a track key rather than a row index
				-- so it survives a change of filter or search term between clicks.
				local mods = ImGui.GetKeyMods and ImGui.GetKeyMods(ctx) or 0
				if (mods & E('Mod_Shift')) ~= 0 and lastClickedKey then
					local anchor
					for k, v in ipairs(visible) do
						if trackKey(v) == lastClickedKey then anchor = k break end
					end
					if anchor and anchor ~= i then
						for k = math.min(anchor, i), math.max(anchor, i) do
							visible[k].selected = t.selected
						end
					end
				end
				lastClickedKey = trackKey(t)
			end

			ImGui.TableNextColumn(ctx)
			ImGui.SetNextItemWidth(ctx, 22)
			local cc, colv = ImGui.ColorEdit3(ctx, '##color', hexToImU32(t.color),
				E('ColorEditFlags_NoInputs') | E('ColorEditFlags_NoLabel'))
			if cc then t.color = imU32ToHex(colv) end
			tooltip(t.color and ('Track color ' .. t.color) or 'No color received from the LV1 - click to pick one')

			ImGui.TableNextColumn(ctx)
			local sec = sectionOf(t.group)
			ImGui.TextColored(ctx, sec.color, string.format('%s %d', GROUP_TAG[t.group] or ('g' .. t.group), t.ch + 1))

			ImGui.TableNextColumn(ctx)
			ImGui.SetNextItemWidth(ctx, -1)
			local nc2
			nc2, t.editedName = ImGui.InputText(ctx, '##name', t.editedName)
			if t.editedName ~= t.name then
				tooltip('LV1 name: ' .. t.name)
			end

			ImGui.TableNextColumn(ctx)
			local wc, wv = segmented(t.stereo)
			if wc then t.stereo = wv end
			if t.detect == 'width' then
				ImGui.SameLine(ctx, 0, 4)
				ImGui.TextColored(ctx, COL.warn, '~')
				tooltip('Mono/stereo could not be confirmed from the LV1 meters and was inferred from the stereo-width value - double-check this one.')
			end

			ImGui.TableNextColumn(ctx)
			local prev, prevCol = inputPreview(t, hwMap)
			ImGui.TextColored(ctx, prevCol, prev)

			ImGui.PopID(ctx)
		end
		ImGui.EndTable(ctx)
	end

	if #tracks > 0 and #visible == 0 then
		ImGui.TextColored(ctx, COL.textFaint, 'No track matches the current filters.')
	end

	ImGui.EndChild(ctx)
end

-- ─── footer ───

local function drawFooter()
	local sel, mono, stereo, minHw, maxHw = 0, 0, 0, nil, nil
	local hwMap = buildInputHwMap(cfg.prePatchMode)
	for _, t in ipairs(tracks) do
		if t.selected then
			sel = sel + 1
			if t.stereo then stereo = stereo + 1 else mono = mono + 1 end
			if t.group == GROUP_IN and cfg.prePatchInputs then
				local hw = hwMap[t.ch] or t.ch
				local last = hw + (t.stereo and 1 or 0)
				minHw = (minHw == nil or hw < minHw) and hw or minHw
				maxHw = (maxHw == nil or last > maxHw) and last or maxHw
			end
		end
	end

	-- The LR return is patched by absolute channel number, independently of the
	-- input map, so it has to be folded into the "does my interface actually
	-- have this many inputs" check too.
	local highestNeeded = maxHw and (maxHw + 1) or nil
	if cfg.prePatchInputs then
		local lr = tonumber((cfg.lrInputChannel or ""):match("^%s*(.-)%s*$"))
		local lrSelected = false
		for _, t in ipairs(tracks) do
			if t.selected and t.group == GROUP_LR then lrSelected = true break end
		end
		if lrSelected and lr and lr >= 1 then
			highestNeeded = math.max(highestNeeded or 0, lr + 1)
		end
	end
	-- REAPER happily accepts a record input past the end of the device and just
	-- shows an unusable entry; you find out when you arm the track. Say it now.
	local availableInputs = reaper.GetNumAudioInputs and reaper.GetNumAudioInputs() or 0
	local shortBy = (highestNeeded and availableInputs > 0 and highestNeeded > availableInputs)
		and (highestNeeded - availableInputs) or nil

	ImGui.BeginGroup(ctx)
	if sel == 0 then
		ImGui.TextColored(ctx, COL.textFaint, 'Nothing selected.')
	else
		ImGui.TextColored(ctx, COL.text, string.format('%d track%s', sel, sel == 1 and '' or 's'))
		ImGui.SameLine(ctx, 0, 8)
		ImGui.TextColored(ctx, COL.textFaint, string.format('| %d mono, %d stereo', mono, stereo))
		if minHw then
			ImGui.SameLine(ctx, 0, 8)
			ImGui.TextColored(ctx, shortBy and COL.err or COL.textFaint,
				string.format('| inputs %d-%d', minHw + 1, maxHw + 1))
		end
		if shortBy then
			ImGui.SameLine(ctx, 0, 8)
			ImGui.TextColored(ctx, COL.err, string.format('| needs %d, device has %d', highestNeeded, availableInputs))
			tooltip(string.format(
				'This selection patches up to hardware input %d, but REAPER currently sees only %d input(s).\n' ..
				'%d track(s) would end up on an input that does not exist.\n\n' ..
				'Either connect/enable the right device in REAPER\'s audio preferences, switch the patching to ' ..
				'"Linear (no gaps)" in Settings > Import, or turn record-input pre-patching off.',
				highestNeeded, availableInputs, shortBy))
		end
		if cfg.createFolders then
			ImGui.SameLine(ctx, 0, 8)
			ImGui.TextColored(ctx, COL.textFaint, '| grouped in folders')
		end
	end
	ImGui.EndGroup(ctx)

	ImGui.SameLine(ctx)
	ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx) + 12, ImGui.GetWindowWidth(ctx) - (150 + 190 + 8) - 16))

	ImGui.BeginDisabled(ctx, sel == 0 or job ~= nil)
	if ImGui.Button(ctx, 'Update existing', 150, 30) then updateExistingTracks() end
	tooltip('Refresh name, color, width and record input of tracks previously created by this script, instead of creating duplicates.')
	ImGui.SameLine(ctx)
	local nc = 0
	local function col(name, v) local e = E(name, -1); if e ~= -1 and pcall(ImGui.PushStyleColor, ctx, e, v) then nc = nc + 1 end end
	col('Col_Button', COL.accent)
	col('Col_ButtonHovered', COL.accentHi)
	col('Col_ButtonActive', COL.accentLo)
	col('Col_Text', 0xFFFFFFFF)
	if ImGui.Button(ctx, string.format('Create %d track%s', sel, sel == 1 and '' or 's'), 190, 30) then
		createSelectedTracks()
	end
	if nc > 0 then ImGui.PopStyleColor(ctx, nc) end
	ImGui.EndDisabled(ctx)
end

-- ─── settings modal ───

local function settingsBody()
	local changed, val

	if ImGui.BeginTabBar(ctx, 'settings_tabs') then
		if ImGui.BeginTabItem(ctx, 'Connection') then
			ImGui.Spacing(ctx)
			ImGui.TextWrapped(ctx, 'Leave the host blank to auto-discover. The LV1\'s OSC port changes every time it restarts, so it is always re-resolved automatically - only fill the port in to force a specific one.')
			ImGui.Spacing(ctx)

			ImGui.SetNextItemWidth(ctx, 220)
			changed, val = ImGui.InputText(ctx, 'Host (IP)', cfg.host)
			if changed then cfg.host = val; setCfg('host', val) end
			if sanitizedHost() == nil then
				ImGui.SameLine(ctx); ImGui.TextColored(ctx, COL.err, 'invalid')
			end

			ImGui.SetNextItemWidth(ctx, 220)
			changed, val = ImGui.InputText(ctx, 'Port (blank = auto)', cfg.port)
			if changed then cfg.port = val; setCfg('port', val) end

			ImGui.SetNextItemWidth(ctx, 220)
			changed, val = ImGui.InputText(ctx, 'Node.js executable', cfg.nodePath)
			if changed then cfg.nodePath = val; setCfg('nodePath', val) end
			tooltip('"node" works if Node.js is on PATH; otherwise give the full path to node.exe.')

			ImGui.Spacing(ctx)
			ImGui.SetNextItemWidth(ctx, 220)
			changed, val = ImGui.InputInt(ctx, 'Discovery timeout (ms)', math.floor(cfg.discoverMs), 500, 1000)
			if changed then cfg.discoverMs = math.max(500, math.min(60000, val)); setCfg('discoverMs', cfg.discoverMs) end

			ImGui.SetNextItemWidth(ctx, 220)
			changed, val = ImGui.InputInt(ctx, 'Listen timeout (ms)', math.floor(cfg.listenMs), 500, 1000)
			if changed then cfg.listenMs = math.max(500, math.min(60000, val)); setCfg('listenMs', cfg.listenMs) end
			tooltip('Upper bound only - the fetch stops as soon as the track list and meter frames have arrived.')

			ImGui.EndTabItem(ctx)
		end

		if ImGui.BeginTabItem(ctx, 'Import') then
			ImGui.Spacing(ctx)
			changed, val = ImGui.Checkbox(ctx, 'Pre-patch record inputs (In channels, mono/stereo aware)', cfg.prePatchInputs)
			if changed then cfg.prePatchInputs = val; setCfg('prePatchInputs', val and '1' or '0') end

			ImGui.Indent(ctx)
			ImGui.BeginDisabled(ctx, not cfg.prePatchInputs)
			if ImGui.RadioButton(ctx, 'Console-accurate (keep gaps)', cfg.prePatchMode == 'console') then
				cfg.prePatchMode = 'console'; setCfg('prePatchMode', 'console')
			end
			tooltip('Hardware inputs follow the real console layout: skipped channels leave gaps.')
			ImGui.SameLine(ctx)
			if ImGui.RadioButton(ctx, 'Linear (no gaps)', cfg.prePatchMode == 'linear') then
				cfg.prePatchMode = 'linear'; setCfg('prePatchMode', 'linear')
			end
			tooltip('Selected channels are patched to a contiguous block of inputs starting at 1.')

			ImGui.Spacing(ctx)
			ImGui.SetNextItemWidth(ctx, 120)
			changed, val = ImGui.InputText(ctx, 'LR record input (1-based, blank = none)', cfg.lrInputChannel)
			if changed then cfg.lrInputChannel = val; setCfg('lrInputChannel', val) end
			local lr = tonumber(cfg.lrInputChannel)
			if lr and lr >= 1 then
				ImGui.TextColored(ctx, COL.ok, string.format('LR will be patched to hardware input %d/%d.', lr, lr + 1))
			else
				ImGui.TextColored(ctx, COL.textFaint, 'LR will be created with no input assigned.')
			end
			ImGui.EndDisabled(ctx)
			ImGui.Unindent(ctx)

			ImGui.Spacing(ctx)
			ImGui.Separator(ctx)
			ImGui.Spacing(ctx)

			changed, val = ImGui.Checkbox(ctx, 'Prefix track names with their order number', cfg.prefixTrackNumber)
			if changed then cfg.prefixTrackNumber = val; setCfg('prefixTrackNumber', val and '1' or '0') end

			changed, val = ImGui.Checkbox(ctx, 'Group created tracks into folders (Inputs, Groups, Aux...)', cfg.createFolders)
			if changed then cfg.createFolders = val; setCfg('createFolders', val and '1' or '0') end

			changed, val = ImGui.Checkbox(ctx, 'Arm created tracks for recording', cfg.armRecord)
			if changed then cfg.armRecord = val; setCfg('armRecord', val and '1' or '0') end

			changed, val = ImGui.Checkbox(ctx, 'Skip tracks already imported into this project', cfg.skipExisting)
			if changed then cfg.skipExisting = val; setCfg('skipExisting', val and '1' or '0') end
			tooltip('Tracks created by this script are tagged, so re-running it will not duplicate them.')

			ImGui.EndTabItem(ctx)
		end

		if ImGui.BeginTabItem(ctx, 'Advanced') then
			ImGui.Spacing(ctx)
			changed, val = ImGui.Checkbox(ctx, 'Verbose diagnostic log', cfg.verbose)
			if changed then cfg.verbose = val; setCfg('verbose', val and '1' or '0') end
			tooltip('Logs every zDNS and OSC packet. Leave on: it costs nothing and makes connection problems diagnosable.')

			changed, val = ImGui.Checkbox(ctx, 'Blocking mode (freezes REAPER during a fetch)', cfg.blockingMode)
			if changed then cfg.blockingMode = val; setCfg('blockingMode', val and '1' or '0') end
			ImGui.TextWrapped(ctx, 'Fallback for the rare setup where the background launch fails silently: it runs the helper synchronously and captures the OS error message directly.')

			ImGui.Spacing(ctx)
			ImGui.Separator(ctx)
			ImGui.Spacing(ctx)
			labelledValue('Helper:', FETCH_JS)
			labelledValue('Result:', JSON_OUT)
			labelledValue('Log:', LOG_OUT)
			if lastResult then
				labelledValue('Last fetch:', tostring(lastResult.fetchedAt or '?'))
				if lastResult.channelsStride and lastResult.channelsStride ~= 19 then
					ImGui.TextColored(ctx, COL.warn, string.format('/Channels stride auto-detected as %d (documented: 19)', lastResult.channelsStride))
				end
			end
			ImGui.EndTabItem(ctx)
		end
		ImGui.EndTabBar(ctx)
	end
end

local function drawSettingsModal()
	if showSettings then
		ImGui.OpenPopup(ctx, 'Settings')
		showSettings = false
	end
	-- Centring is cosmetic: skip it rather than risk erroring on a ReaImGui
	-- build that doesn't expose the viewport helpers.
	if ImGui.Viewport_GetCenter and ImGui.GetMainViewport then
		local okC, cx, cy = pcall(function() return ImGui.Viewport_GetCenter(ImGui.GetMainViewport(ctx)) end)
		if okC and cx then ImGui.SetNextWindowPos(ctx, cx, cy, E('Cond_Appearing'), 0.5, 0.5) end
	end
	ImGui.SetNextWindowSize(ctx, 560, 430, E('Cond_Appearing'))
	-- Passing a p_open of `true` gives the modal a close button and makes the
	-- Escape key dismiss it, which it would not do with a nil p_open.
	local visible, keepOpen = ImGui.BeginPopupModal(ctx, 'Settings', true, E('WindowFlags_NoCollapse'))
	if visible then
		local ok, err = pcall(settingsBody)
		if not ok then ImGui.TextColored(ctx, COL.err, tostring(err)) end
		ImGui.Separator(ctx)
		if ImGui.Button(ctx, 'Close', 120, 26) or keepOpen == false then ImGui.CloseCurrentPopup(ctx) end
		ImGui.SameLine(ctx)
		ImGui.TextColored(ctx, COL.textFaint, 'Settings are saved as you type.')
		ImGui.EndPopup(ctx)
	end
end

-- ─── diagnostics ───

local function drawDiagnostics()
	-- SetNextItemOpen (not the DefaultOpen flag) is what actually re-opens the
	-- section after the user has collapsed it once: DefaultOpen only applies
	-- while ImGui has no stored state for this header.
	if forceOpenDiag then
		ImGui.SetNextItemOpen(ctx, true)
		forceOpenDiag = false
	end
	if ImGui.CollapsingHeader(ctx, 'Diagnostic log') then
		if #devices > 0 then
			ImGui.TextColored(ctx, COL.textDim, string.format('LV1(s) seen on the LAN (%d):', #devices))
			for _, d in ipairs(devices) do
				ImGui.BulletText(ctx, string.format('%s @ %s:%s', tostring(d.name or d.host), tostring(d.address or '?'), tostring(d.port or '?')))
			end
		else
			ImGui.TextColored(ctx, COL.textFaint, 'No LV1 announcement seen on the LAN during the last scan.')
		end
		if lastResult and lastResult.discoveryError then
			ImGui.TextColored(ctx, COL.warn, 'Discovery: ' .. tostring(lastResult.discoveryError))
		end
		ImGui.Spacing(ctx)
		-- ImGui_BeginChild already calls EndChild internally when it returns
		-- false (collapsed/clipped child), so EndChild must only be called when
		-- it returned true - otherwise the child is double-closed and ImGui
		-- throws "Calling End() too many times!".
		if ImGui.BeginChild(ctx, 'log_child', 0, 150, E('ChildFlags_Borders', E('ChildFlags_Border', 1))) then
			local f = pushFont(FONT_SMALL)
			ImGui.TextWrapped(ctx, lastLog ~= '' and lastLog or '(nothing yet - run a fetch first)')
			popFont(f)
			ImGui.EndChild(ctx)
		end
	end
end

-- ─── window body ───

local function drawWindowBody()
	drawHeader()
	drawStatusStrip()
	if isMockData then
		ImGui.TextColored(ctx, COL.err,
			'REPLAYED CAPTURE - this list came from a mock file, not from a live LV1. Do not build a real session from it.')
	end
	ImGui.Spacing(ctx)

	local _, availH = ImGui.GetContentRegionAvail(ctx)
	local diagH = 30
	local footerH = 44
	local bodyH = math.max(160, availH - footerH - diagH - 18)

	drawSidebar(bodyH)
	ImGui.SameLine(ctx)
	drawTrackTable(bodyH)

	ImGui.Spacing(ctx)
	drawFooter()
	ImGui.Spacing(ctx)
	drawDiagnostics()
	drawSettingsModal()
end

local function loop()
	pollJob()

	local nVars, nCols = pushTheme()
	ImGui.SetNextWindowSize(ctx, 1040, 700, E('Cond_FirstUseEver'))
	if ImGui.SetNextWindowSizeConstraints then
		ImGui.SetNextWindowSizeConstraints(ctx, 860, 540, 4000, 4000)
	end
	local visible, open = ImGui.Begin(ctx, 'LV1 Track Importer', true)
	if visible then
		-- Wrap the body in pcall so a Lua error partway through a frame can
		-- never skip ImGui.End below. An unhandled error would otherwise abort
		-- the script mid-frame and permanently desync ReaImGui's Begin/End
		-- stack, throwing "Calling End() too many times!" on every later frame.
		local ok, err = pcall(drawWindowBody)
		if not ok then
			setStatus('error', 'UI error (see REAPER console): ' .. tostring(err))
			reaper.ShowConsoleMsg('LV1 Track Importer UI error: ' .. tostring(err) .. '\n')
		end
		-- ImGui.Begin already calls End internally when it returns false
		-- (collapsed/clipped window), exactly like BeginChild - confirmed
		-- against reaimgui's own demo.lua.
		ImGui.End(ctx)
	end
	popTheme(nVars, nCols)

	if open then
		reaper.defer(loop)
	elseif ImGui.DestroyContext then
		-- Removed in newer ReaImGui versions (contexts are garbage-collected).
		pcall(ImGui.DestroyContext, ctx)
	end
end

reaper.defer(loop)
