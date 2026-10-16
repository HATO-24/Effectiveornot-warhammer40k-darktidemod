-- DshProbe  --  one-shot data harvester for the Darktide TTK simulator
--
-- Dumps the runtime tables the simulator still needs. Two lessons from the
-- first run are baked in:
--   * io.open cannot create directories, so if out/ is missing every write
--     fails and the whole dump is lost -> try a fallback dir and report which
--     one was used
--   * guessing require paths loses modules -> either require the path, or SCAN
--     package.loaded for modules matching a pattern
--
-- Output: mods/DshProbe/out/*.json   (falls back to mods/DshProbe/)
-- Log:    mods/DshProbe/dsh_probe.log

local mod = get_mod("DshProbe")
if not mod then
	return
end

local DMF = get_mod("DMF")

local _io = DMF:persistent_table("DshProbe_io")
if not _io.initialized then
	_io = DMF.deepcopy(Mods.lua.io)
	_io.initialized = true
end

local OUT_DIR = "./../mods/DshProbe/out/"
local FALLBACK_DIR = "./../mods/DshProbe/"
local LOG_FILE = "./../mods/DshProbe/dsh_probe.log"
local DL = "./../mods/DshDamageLog/damage_log.jsonl"
local MAX_DEPTH = 7
local MAX_NODES = 120000

-- ------------------------------------------------------------------- log ----
local function logline(fmt, ...)
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	print("[DshProbe] " .. msg)
	local f = _io.open(LOG_FILE, "a")
	if f then
		f:write(os.date("%H:%M:%S "), msg, "\n")
		f:close()
	end
end

-- ------------------------------------------------------------------ json ----
local function esc(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "")
	s = s:gsub("\t", "\\t")
	return (s:gsub("[%z\1-\31]", " "))
end

local function numstr(v)
	if v ~= v or v == math.huge or v == -math.huge then
		return "null"
	end
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	return string.format("%.6g", v)
end

local function enc(v, depth, seen, budget, out)
	local t = type(v)
	if t == "nil" then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		out[#out + 1] = numstr(v)
	elseif t == "string" then
		out[#out + 1] = '"' .. esc(v) .. '"'
	elseif t == "table" then
		if depth <= 0 then
			out[#out + 1] = '"[maxdepth]"'
			return
		end
		if seen[v] then
			out[#out + 1] = '"[cycle]"'
			return
		end
		seen[v] = true
		budget.n = budget.n + 1
		if budget.n > budget.max then
			out[#out + 1] = '"[budget]"'
			seen[v] = nil
			return
		end

		local count, isarr = 0, true
		for k in pairs(v) do
			count = count + 1
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
				isarr = false
				break
			end
		end
		if isarr and count > 0 then
			for i = 1, count do
				if v[i] == nil then
					isarr = false
					break
				end
			end
		end

		-- Lua arrays must be written as JSON arrays. Emitting `{a,b}` is not
		-- valid JSON and made every dump fail to parse on the first run.
		out[#out + 1] = isarr and "[" or "{"
		local first = true
		if isarr then
			for i = 1, count do
				if not first then out[#out + 1] = "," end
				first = false
				enc(v[i], depth - 1, seen, budget, out)
			end
		else
			local keys = {}
			for k in pairs(v) do
				if type(k) == "string" or type(k) == "number" then
					keys[#keys + 1] = k
				end
			end
			table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				if not first then out[#out + 1] = "," end
				first = false
				out[#out + 1] = '"' .. esc(tostring(k)) .. '":'
				enc(v[k], depth - 1, seen, budget, out)
			end
		end
		out[#out + 1] = isarr and "]" or "}"
		seen[v] = nil
	else
		out[#out + 1] = '"<' .. t .. '>"'
	end
end

local function to_json(v, max_nodes)
	local out = {}
	enc(v, MAX_DEPTH, {}, { n = 0, max = max_nodes or MAX_NODES }, out)
	return table.concat(out)
end

-- --------------------------------------------------------------- modules ----
-- `path` = require it directly;  `scan` = merge every loaded module whose path
-- contains this substring (for tables whose path is not knowable up front);
-- `collect` = run a purpose-built reducer (see collect_weapon_modes below).
local collect_weapon_modes

local MODULES = {
	{ name = "breeds", tier = 1,
	  path = "scripts/settings/breed/breeds",
	  why = "per-hit-zone damage multipliers and armour per body part" },
	{ name = "damage_profile_templates", tier = 1,
	  path = "scripts/settings/damage/damage_profile_templates",
	  why = "authoritative power_distribution for every attack" },
	{ name = "weapon_traits_all", tier = 1,
	  scan = "weapon_traits",
	  why = "blessing definitions, incl. the loc key for the name" },
	{ name = "archetype_talents", tier = 1,
	  path = "scripts/settings/ability/archetype_talents/archetype_talents",
	  why = "official talent names (display_name) per archetype" },
	{ name = "weapon_archetypes", tier = 1,
	  scan = "archetype",
	  why = "which archetype may equip which weapon" },
	{ name = "weapon_modes", tier = 1,
	  collect = collect_weapon_modes,
	  why = "per-weapon action inputs and resolved damage profiles, for every weapon at once" },
	{ name = "hit_zone_api", tier = 1,
	  path = "scripts/utilities/attack/hit_zone",
	  why = "every function the hit zone module exposes plus its zone-name table, so the actor->body-part mapping can be used correctly" },

	{ name = "armor_settings", tier = 2,
	  path = "scripts/settings/damage/armor_settings",
	  why = "armour types, rending and overdamage multipliers" },
	{ name = "power_level_settings", tier = 2,
	  path = "scripts/settings/damage/power_level_settings",
	  why = "finesse boost tables, boost curves, min damage" },
	{ name = "damage_settings", tier = 2,
	  path = "scripts/settings/damage/damage_settings",
	  why = "damage types and their multipliers" },
	{ name = "buff_templates", tier = 2,
	  path = "scripts/settings/buff/buff_templates",
	  why = "max_stacks / num_stacks_on_hit for stacking effects" },
	{ name = "talent_settings", tier = 2,
	  path = "scripts/settings/talent/talent_settings",
	  why = "talent tree layout" },
	{ name = "minion_damage_profiles", tier = 2,
	  path = "scripts/settings/damage/damage_profiles/minion_damage_profile_templates",
	  why = "enemy-side damage profiles" },
}

-- ------------------------------------------------------------------ queue ----
mod.queue = mod.queue or {}
mod.running = mod.running or false
mod.results = mod.results or {}
mod.used_dir = mod.used_dir or nil

local function safe_require(path)
	local ok, res = pcall(require, path)
	if ok and type(res) == "table" then
		return res, nil
	end
	local pkg = rawget(_G, "package")
	local loaded = pkg and rawget(pkg, "loaded")
	local cached = loaded and loaded[path]
	if type(cached) == "table" then
		return cached, nil
	end
	return nil, tostring(res)
end

local function scan_loaded(pattern, exclude)
	local pkg = rawget(_G, "package")
	local loaded = pkg and rawget(pkg, "loaded")
	if type(loaded) ~= "table" then
		return nil, "package.loaded unavailable"
	end
	local merged, hits = {}, 0
	for path, tbl in pairs(loaded) do
		if type(path) == "string" and path:find(pattern, 1, true)
			and (not exclude or not path:find(exclude, 1, true))
			and type(tbl) == "table" then
			hits = hits + 1
			for k, v in pairs(tbl) do
				local key = tostring(k)
				if merged[key] ~= nil then
					key = path .. "::" .. key
				end
				merged[key] = v
			end
		end
	end
	if hits == 0 then
		return nil, "no loaded module matched '" .. pattern .. "'"
	end
	return merged, nil, hits
end

local function write_file(name, text)
	for _, dir in ipairs({ OUT_DIR, FALLBACK_DIR }) do
		local f = _io.open(dir .. name .. ".json", "w")
		if f then
			f:write(text)
			f:close()
			if not mod.used_dir then
				mod.used_dir = dir
				logline("writing into %s", dir)
			end
			return true
		end
	end
	logline("CANNOT WRITE %s.json -- tried %s and %s", name, OUT_DIR, FALLBACK_DIR)
	return false
end

local function start_job(tier_limit)
	mod.queue = {}
	for _, m in ipairs(MODULES) do
		if m.tier <= tier_limit then
			mod.queue[#mod.queue + 1] = m
		end
	end
	mod.results = {}
	mod.running = #mod.queue > 0
	logline("queued %d modules (tier <= %d)", #mod.queue, tier_limit)
end

-- Purpose-built reducer for the weapon templates.
--
-- Dumping the raw templates would blow the node budget long before the last
-- weapon, and `scan` would flatten every template's *fields* into one table. This
-- keeps only what attack-mode detection needs, so all weapons fit in one dump:
-- each weapon's action inputs and the damage profiles the game resolves for them.
--
-- That is what makes it possible to verify the detection against weapons nobody
-- testing this actually owns -- the Lucius, for one.
collect_weapon_modes = function ()
	local Action = safe_require("scripts/utilities/action/action")

	if type(Action) ~= "table" then
		return nil, "action module unavailable"
	end

	local pkg = rawget(_G, "package")
	local loaded = pkg and rawget(pkg, "loaded")

	if type(loaded) ~= "table" then
		return nil, "package.loaded unavailable"
	end

	local out = {}

	for path, template in pairs(loaded) do
		if type(path) == "string"
			and path:find("weapon_templates/", 1, true)
			and not path:find("settings_templates", 1, true)
			and type(template) == "table"
			and type(template.actions) == "table"
			and type(template.name) == "string"
		then
			local entry = {
				actions = {},
				inputs = {},
			}

			for _, action in pairs(template.actions) do
				if type(action) == "table" and type(action.start_input) == "string" then
					entry.inputs[#entry.inputs + 1] = string.format(
						"%s -> %s [%s]",
						action.start_input,
						tostring(action.name),
						tostring(action.kind)
					)

					local count = 1
					local ok_count, templates = pcall(Action.num_damage_templates, action)

					if ok_count and type(templates) == "number" and templates > 0 then
						count = templates
					end

					for index = 1, count do
						local ok_profile, profile, special = pcall(Action.damage_template, action, index)

						if ok_profile and type(profile) == "table" then
							entry.actions[#entry.actions + 1] = string.format(
								"%s#%d=%s%s",
								action.start_input,
								index,
								tostring(profile.name),
								type(special) == "table" and ("  special=" .. tostring(special.name)) or ""
							)
						end
					end
				end
			end

			table.sort(entry.actions)
			table.sort(entry.inputs)

			out[template.name] = entry
		end
	end

	local count = 0

	for _ in pairs(out) do
		count = count + 1
	end

	if count == 0 then
		return nil, "no weapon templates found in package.loaded"
	end

	return out
end

local function run_one(m)
	local tbl, err, hits

	if m.collect then
		local ok_collect, value, collect_err = pcall(m.collect)

		if ok_collect then
			tbl, err = value, collect_err
		else
			tbl, err = nil, tostring(value)
		end
	elseif m.scan then
		tbl, err, hits = scan_loaded(m.scan, m.exclude)
	else
		tbl, err = safe_require(m.path)
	end

	if not tbl then
		mod.results[#mod.results + 1] = { name = m.name, ok = false, err = err }
		logline("  FAILED %-28s %s", m.name, tostring(err))
		return
	end

	local ok, text = pcall(to_json, tbl, MAX_NODES)
	if not ok then
		mod.results[#mod.results + 1] = { name = m.name, ok = false, err = tostring(text) }
		logline("  ENCODE FAILED %-22s %s", m.name, tostring(text))
		return
	end

	local wrote = write_file(m.name, text)
	mod.results[#mod.results + 1] = { name = m.name, ok = wrote, bytes = #text }
	if m.scan then
		logline("  %-28s %8d bytes  (scan '%s' -> %d modules)", m.name, #text, m.scan, hits or 0)
	else
		logline("  %-28s %8d bytes", m.name, #text)
	end
end

-- ---------------------------------------------------------------- update ----
mod.update = function (dt)
	if not mod.running then
		return
	end
	local m = table.remove(mod.queue, 1)
	if not m then
		mod.running = false
		local okn = 0
		for _, r in ipairs(mod.results) do
			if r.ok then okn = okn + 1 end
		end
		logline("DONE: %d/%d written (%s)", okn, #mod.results,
			tostring(mod.used_dir or "NOTHING WRITTEN"))
		if mod.echo then
			pcall(function ()
				mod:echo(string.format("DshProbe: %d/%d 完成", okn, #mod.results))
			end)
		end
		return
	end
	pcall(run_one, m)
end

mod.on_all_mods_loaded = function ()
	logline("DshProbe loaded")
end

if mod.command then
	pcall(function ()
		mod:command("dshprobe", "Dump the game tables the simulator needs", function (arg)
			arg = (arg or ""):lower()
			if arg == "list" then
				for _, m in ipairs(MODULES) do
					logline("  t%d %-28s %s", m.tier, m.name, m.why)
				end
				logline("output -> %s", OUT_DIR)
				return
			end
			if arg == "status" then
				logline("running=%s remaining=%d done=%d",
					tostring(mod.running), #(mod.queue or {}), #(mod.results or {}))
				return
			end
			start_job(arg == "core" and 1 or 2)
		end)
	end)
end

-- ============================================================ damage log ====
mod.seq = mod.seq or 0
mod.buf = mod.buf or {}
mod.enabled = mod.enabled ~= false
mod.mark = mod.mark or ""
mod.clock = mod.clock or 0
mod.ticks = 0
mod.dl_hooked = false

local function flush_dl()
	if #mod.buf == 0 then return end
	local f = _io.open(DL, "a")
	if f then
		f:write(table.concat(mod.buf, "\n"), "\n")
		f:close()
		mod.buf = {}
	end
end

local function dl_write(list)
	local parts = {}
	for _, kv in ipairs(list) do
		parts[#parts + 1] = '"' .. kv[1] .. '":' .. kv[2]
	end
	mod.buf[#mod.buf + 1] = "{" .. table.concat(parts, ",") .. "}"
end

local function jnum(v)
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return string.format("%.4f", v)
	end
	return "null"
end

local function jstr(v)
	if type(v) == "string" then return '"' .. esc(v) .. '"' end
	return "null"
end

local STACK_KEYS = { "bleed", "bleed_long", "burn", "warpfire", "brittleness",
                     "rending", "toxin", "soulblaze" }

local function stack_info(unit)
	local out = {}
	if not unit then return out end
	local ext
	pcall(function () ext = ScriptUnit.has_extension(unit, "buff_system") end)
	if not ext then return out end
	local methods = { "stacks", "get_stacks", "buff_stacks", "num_stacks",
	                  "stacks_of", "get_stack_count", "current_stacks" }
	for _, key in ipairs(STACK_KEYS) do
		for _, m in ipairs(methods) do
			local ok, v = pcall(function () return ext[m](ext, key) end)
			if ok and type(v) == "number" then
				out[key] = v
				break
			end
		end
	end
	return out
end

local breed_util = nil
pcall(function () breed_util = require("scripts/utilities/breed") end)

local function target_info(unit)
	local info = {}
	if not unit then return info end
	pcall(function ()
		local ud = ScriptUnit.has_extension(unit, "unit_data_system")
		local b = ud and ud:breed()
		if not b and breed_util then b = breed_util.unit_breed_or_nil(unit) end
		if b then
			info.breed = b.name
			info.armor = b.armor_type
			if type(b.tags) == "table" then
				local t = {}
				for k in pairs(b.tags) do t[#t + 1] = tostring(k) end
				table.sort(t)
				info.tags = table.concat(t, "|")
			end
		end
	end)
	return info
end

local function health_info(unit)
	local out = {}
	if not unit then return out end
	pcall(function ()
		local h = ScriptUnit.has_extension(unit, "health_system")
		if not h then return end
		for _, m in ipairs({ "current_health", "health", "get_current_health" }) do
			local ok, v = pcall(function () return h[m](h) end)
			if ok and type(v) == "number" then out.health = v break end
		end
	end)
	return out
end

local function ensure_hook()
	if mod.dl_hooked then return end
	local ok, err = pcall(function ()
		mod:hook_safe("AttackReportManager", "add_attack_result", function (_, ...)
			if not mod.enabled then return end
			local damage_profile, attacked_unit, attacking_unit, _d, _p,
			      hit_weakspot, damage, attack_result, attack_type,
			      damage_efficiency, is_critical_strike = ...

			local dmg = tonumber(damage) or 0
			if dmg <= 0 or not attacked_unit then return end
			local lp = Managers.player and Managers.player:local_player(1)
			if not lp or lp.player_unit ~= attacking_unit then return end

			local ti = target_info(attacked_unit)

			local pname, pd_atk
			if type(damage_profile) == "table" then
				pname = damage_profile.name
				local pd = damage_profile.power_distribution
				if type(pd) == "table" then
					local a = pd.attack
					if type(a) == "table" then
						pd_atk = string.format("%s~%s", tostring(a[1]), tostring(a[2]))
					else
						pd_atk = tostring(a)
					end
				end
			end

			mod.seq = mod.seq + 1
			local row = {
				{ "seq", tostring(mod.seq) },
				{ "t", string.format("%.3f", mod.clock) },
				{ "mark", jstr(mod.mark) },
				{ "profile", jstr(pname) },
				{ "pd_attack", jstr(pd_atk) },
				{ "enemy", jstr(ti.breed) },
				{ "armor", jstr(ti.armor) },
				{ "tags", jstr(ti.tags) },
				{ "weakspot", hit_weakspot and "true" or "false" },
				{ "crit", is_critical_strike and "true" or "false" },
				{ "attack_type", jstr(attack_type) },
				{ "damage", jnum(dmg) },
				{ "efficiency", jnum(tonumber(damage_efficiency)) },
			}
			-- the hit-zone name is not a direct hook argument, but it often
			-- rides along inside attack_result; take it when present
			if type(attack_result) == "table" then
				for _, k in ipairs({ "hit_zone", "hit_zone_name", "armor_type",
				                     "damage_type" }) do
					if type(attack_result[k]) == "string" then
						row[#row + 1] = { "ar_" .. k, jstr(attack_result[k]) }
					end
				end
			end
			for k, v in pairs(stack_info(attacked_unit)) do
				row[#row + 1] = { "st_" .. k, jnum(v) }
			end
			local hi = health_info(attacked_unit)
			if hi.health then
				row[#row + 1] = { "target_hp", jnum(hi.health) }
			end
			dl_write(row)
		end)
	end)
	if ok then
		mod.dl_hooked = true
		logline("hooked AttackReportManager:add_attack_result")
	else
		logline("damage hook failed: %s", tostring(err))
	end
end

local probe_update = mod.update
mod.update = function (dt)
	pcall(probe_update, dt)
	mod.clock = mod.clock + (tonumber(dt) or 0)
	pcall(ensure_hook)
	mod.ticks = mod.ticks + 1
	if #mod.buf >= 64 or (mod.ticks % 60 == 0 and #mod.buf > 0) then
		pcall(flush_dl)
	end
end

if mod.command then
	pcall(function ()
		mod:command("dshlog", "Toggle damage recording", function ()
			mod.enabled = not mod.enabled
			dl_write({ { "seq", tostring(mod.seq) },
			           { "marker", jstr(mod.enabled and "== logging ON ==" or "== logging OFF ==") },
			           { "profile", "null" }, { "damage", "null" } })
			flush_dl()
			if mod.echo then
				pcall(function () mod:echo("DshProbe 记录: " .. (mod.enabled and "开" or "关")) end)
			end
		end)
		mod:command("dshmark", "Label the next section of the damage log", function (text)
			mod.mark = text or ""
			dl_write({ { "seq", tostring(mod.seq) },
			           { "marker", jstr("== MARK: " .. (text or "") .. " ==") },
			           { "profile", "null" }, { "damage", "null" } })
			flush_dl()
			if mod.echo then
				pcall(function () mod:echo("DshProbe 标记: " .. (text or "")) end)
			end
		end)
		mod:command("dshnew", "Start a fresh damage log file", function ()
			mod.buf = {}
			local f = _io.open(DL, "w")
			if f then f:close() end
			mod.seq = 0
			dl_write({ { "seq", "0" }, { "marker", jstr("== NEW FILE ==") },
			           { "profile", "null" }, { "damage", "null" } })
			flush_dl()
		end)
	end)
end

return mod
