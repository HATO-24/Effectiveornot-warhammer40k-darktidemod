-- diagnostics.lua -- `/wepcheck` writes everything this mod currently believes
-- about the held weapon and the aimed enemy into a JSON file.
--
-- The point is to validate the assumptions the indicator is built on against the
-- running game, because several of them cannot be read out of the game files:
--
--   * which armour-modifier field the held weapon's profile actually populates
--   * whether `special_active` is the right flag, and what it looks like live
--   * what `current_action_name` reads while a heavy attack is being charged
--   * which raycast collision filter returns enemies
--   * the real hit zone names, and the actor names they map to
--
-- Nothing here is needed for the indicator to work; it exists so the indicator
-- can be corrected from evidence instead of guesswork.

local diagnostics = {}

local HitZone = require("scripts/utilities/attack/hit_zone")

local OUT_FILE = "./../mods/WeaponEffectiveness/wepcheck_dump.json"
local LOG_FILE = "./../mods/WeaponEffectiveness/wepcheck.log"

local MAX_DEPTH = 6

local io_handle
do
	local DMF = get_mod("DMF")

	if DMF then
		local persistent = DMF:persistent_table("WeaponEffectiveness_io")

		if not persistent.initialized then
			persistent = DMF.deepcopy(Mods.lua.io)
			persistent.initialized = true
		end

		io_handle = persistent
	end
end

function diagnostics.log(fmt, ...)
	local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt

	print("[WeaponEffectiveness] " .. message)

	if not io_handle then
		return
	end

	local file = io_handle.open(LOG_FILE, "a")

	if file then
		file:write(os.date("%H:%M:%S "), message, "\n")
		file:close()
	end
end

-- ------------------------------------------------------------------ json ----

local function escape_string(value)
	value = string.gsub(value, "\\", "\\\\")
	value = string.gsub(value, '"', '\\"')
	value = string.gsub(value, "\n", "\\n")
	value = string.gsub(value, "\r", "\\r")
	value = string.gsub(value, "\t", "\\t")

	return value
end

local function encode(value, depth, seen)
	local value_type = type(value)

	if value == nil then
		return "null"
	elseif value_type == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end

		return string.format("%.6g", value)
	elseif value_type == "boolean" then
		return value and "true" or "false"
	elseif value_type == "string" then
		return '"' .. escape_string(value) .. '"'
	elseif value_type == "function" then
		return '"<function>"'
	elseif value_type ~= "table" then
		return '"<' .. value_type .. '>"'
	end

	if depth > MAX_DEPTH then
		return '"<max depth>"'
	end

	if seen[value] then
		return '"<cycle>"'
	end

	seen[value] = true

	local keys = {}
	local key_count = 0
	local is_array = true

	for key in pairs(value) do
		key_count = key_count + 1

		if type(key) ~= "number" then
			is_array = false
		end

		keys[#keys + 1] = key
	end

	local encoded

	if key_count == 0 then
		encoded = "{}"
	elseif is_array then
		local parts = {}

		for index = 1, key_count do
			parts[index] = encode(value[index], depth + 1, seen)
		end

		encoded = "[" .. table.concat(parts, ",") .. "]"
	else
		table.sort(keys, function (a, b)
			local type_a, type_b = type(a), type(b)

			if type_a == type_b then
				if type_a == "number" then
					return a < b
				end

				return tostring(a) < tostring(b)
			end

			return type_a == "string"
		end)

		local parts = {}

		for index = 1, #keys do
			local key = keys[index]

			parts[index] = '"'
				.. escape_string(tostring(key))
				.. '":'
				.. encode(value[key], depth + 1, seen)
		end

		encoded = "{" .. table.concat(parts, ",") .. "}"
	end

	seen[value] = nil

	return encoded
end

function diagnostics.encode_json(value)
	return encode(value, 0, {})
end

-- ----------------------------------------------------------------- probes ---

-- Reads the named fields straight off an object, recording which exist so a
-- wrong field guess is visible in the dump rather than silently nil.
function diagnostics.probe_fields(object, field_names)
	local out = {}

	if type(object) ~= "table" then
		return out
	end

	for i = 1, #field_names do
		local name = field_names[i]
		local ok, value = pcall(function ()
			return object[name]
		end)

		if ok then
			local value_type = type(value)

			if value_type == "number" or value_type == "string" or value_type == "boolean" then
				out[name] = value
			elseif value ~= nil then
				out[name] = "<" .. value_type .. ">"
			else
				out[name] = "<nil>"
			end
		else
			out[name] = "<error>"
		end
	end

	return out
end

-- Method names on an extension's metatable, filtered by keyword.
function diagnostics.probe_methods(object, keyword)
	local names = {}

	if not object then
		return names
	end

	pcall(function ()
		local metatable = getmetatable(object)
		local index = metatable and metatable.__index

		if type(index) ~= "table" then
			return
		end

		for key, value in pairs(index) do
			if type(key) == "string" and type(value) == "function" then
				if not keyword or string.find(key, keyword, 1, true) then
					names[#names + 1] = key
				end
			end
		end
	end)

	table.sort(names)

	return names
end

-- ---------------------------------------------------------------- payload ---

local config = {}

function diagnostics.init(settings)
	config = settings or {}
end

local ARMOR_TYPES = {
	"unarmored",
	"armored",
	"berserker",
	"resistant",
	"disgustingly_resilient",
	"super_armor",
}

-- Armour modifiers for one damage profile: which key resolved, in which shape,
-- and both distance bands when the profile is ranged.
local function modifier_matrix(damage_profile, is_ranged)
	local out = {
		per_armor = {},
	}

	if type(damage_profile) ~= "table" then
		return out
	end

	out.profile_name = damage_profile.name
	out.power_distribution = damage_profile.power_distribution
	out.power_distribution_ranged = damage_profile.power_distribution_ranged

	-- Which cleave indices the profile carries, and whether they disagree about
	-- the armour modifier. They do for a third of the profiles that use this
	-- shape, which is why the target pick has to be explicit rather than `pairs`.
	if type(damage_profile.targets) == "table" then
		local names = {}
		local signatures = {}
		local differing = false

		for name in pairs(damage_profile.targets) do
			names[#names + 1] = tostring(name)
		end

		table.sort(names)

		for i = 1, #names do
			local target = damage_profile.targets[names[i]]

			if type(target) ~= "table" then
				target = damage_profile.targets[tonumber(names[i])]
			end

			if type(target) == "table" then
				for _, key in ipairs({ "armor_damage_modifier", "armor_damage_modifier_ranged" }) do
					local candidate = target[key]

					if type(candidate) == "table" then
						local signature = diagnostics.encode_json(candidate)

						if signatures[signature] then
							differing = true
						end

						signatures[signature] = true
					end
				end
			end
		end

		out.target_keys = names
		out.targets_disagree = differing
	end

	local armor = config.armor

	if not armor then
		return out
	end

	out.melee_bands = armor.bands(damage_profile, false)
	out.ranged_bands = armor.bands(damage_profile, true)

	for i = 1, #ARMOR_TYPES do
		local armor_type = ARMOR_TYPES[i]
		local min_melee, max_melee, key_melee, band_melee = armor.modifier(damage_profile, armor_type, false)
		local min_near, max_near, key_near = armor.modifier(damage_profile, armor_type, true, "near")
		local min_far, max_far, key_far = armor.modifier(damage_profile, armor_type, true, "far")

		out.per_armor[armor_type] = {
			melee = {
				min = min_melee,
				max = max_melee,
				source = key_melee,
				band = band_melee,
			},
			ranged_near = {
				min = min_near,
				max = max_near,
				source = key_near,
			},
			ranged_far = {
				min = min_far,
				max = max_far,
				source = key_far,
			},
		}
	end

	out.used_ranged_key = is_ranged

	return out
end

local function entry_dump(entry, is_ranged)
	if not entry then
		return nil
	end

	return {
		input = entry.input,
		action_name = entry.action_name,
		kind = entry.kind,
		chain_time = entry.chain_time,
		special_profile_key = entry.special_key,
		normal = modifier_matrix(entry.profile, is_ranged),
		special = entry.special_profile and modifier_matrix(entry.special_profile, is_ranged) or nil,
	}
end

-- Breed fields that decide the armour shown for the aimed body part.
local function breed_dump(breed)
	if type(breed) ~= "table" then
		return nil
	end

	return {
		name = breed.name,
		armor_type = breed.armor_type,
		toughness_armor_type = breed.toughness_armor_type,
		unit_template_name = breed.unit_template_name,
		faction_name = breed.faction_name,
		fallback_hit_zone = breed.fallback_hit_zone,
		hitzone_armor_override = breed.hitzone_armor_override,
		hitzone_damage_multiplier = breed.hitzone_damage_multiplier,
		hit_zone_weakspot_types = breed.hit_zone_weakspot_types,
		hit_zones = breed.hit_zones,
		tags = breed.tags,
	}
end

function diagnostics.collect()
	local snapshot = config.snapshot and config.snapshot() or {}
	local payload = {
		generated_at = os.date("%Y-%m-%d %H:%M:%S"),
		mod_version = "0.1.0",
		hit_zone_names = HitZone and HitZone.hit_zone_names or nil,
		weapon = snapshot.weapon,
		resolved = {
			light = entry_dump(snapshot.resolved and snapshot.resolved.light, snapshot.is_ranged),
			heavy = entry_dump(snapshot.resolved and snapshot.resolved.heavy, snapshot.is_ranged),
			has_special = snapshot.resolved and snapshot.resolved.has_special,
		},
		live = snapshot.live,
		target = {
			found = snapshot.target and snapshot.target.unit ~= nil,
			breed_name = snapshot.target and snapshot.target.breed_name,
			hit_zone_name = snapshot.target and snapshot.target.hit_zone_name,
			actor_name = snapshot.target and snapshot.target.actor_name,
			armor_type = snapshot.target and snapshot.target.armor_type,
			armor_source = snapshot.target and snapshot.target.armor_source,
			raycast_filter = snapshot.target and snapshot.target.raycast_filter,
			steps = snapshot.target and snapshot.target.steps,
			breed = breed_dump(snapshot.target and snapshot.target.breed),
		},
		verdicts = snapshot.verdicts,
		hidden_reason = snapshot.hidden_reason,
		probe = snapshot.probe,
		marker = snapshot.marker,
		input = snapshot.input,
		hit_results = snapshot.hit_results,
	}

	return payload
end

function diagnostics.write()
	local payload = diagnostics.collect()
	local json = diagnostics.encode_json(payload)

	if not io_handle then
		diagnostics.log("no io handle; cannot write %s", OUT_FILE)

		return nil, json
	end

	local file = io_handle.open(OUT_FILE, "w")

	if not file then
		diagnostics.log("could not open %s for write", OUT_FILE)

		return nil, json
	end

	file:write(json)
	file:close()

	diagnostics.log("wrote %s (%d bytes)", OUT_FILE, #json)

	return OUT_FILE, json
end

function diagnostics.out_file()
	return OUT_FILE
end

-- Writes any value to a named file next to the dump, for the module dump below.
-- Returns the path and the byte count, or nil when the write did not happen.
function diagnostics.write_json(file_name, value)
	if not io_handle or type(file_name) ~= "string" then
		return nil
	end

	local ok, json = pcall(encode, value, 0, {})

	if not ok or type(json) ~= "string" or #json < 3 then
		return nil
	end

	local path = "./../mods/WeaponEffectiveness/out/" .. file_name
	local file = io_handle.open(path, "w")

	if not file then
		return nil
	end

	file:write(json)
	file:close()

	diagnostics.log("wrote %s (%d bytes)", path, #json)

	return path, #json
end

return diagnostics
