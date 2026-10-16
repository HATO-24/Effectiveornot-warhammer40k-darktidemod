-- armor.lua -- armour types, per-profile armour modifiers, and the verdict.
--
-- Every data shape here was verified against the live game:
--
--   * damage profile:  damage_profile.armor_damage_modifier.attack[armor_type]
--       - the table may instead sit on one of the profile's target sub-tables
--       - ranged attacks use armor_damage_modifier_ranged when present
--       - the value is either a number or a { min, max } lerp pair
--   * breed:           breed.armor_type
--                      breed.hitzone_armor_override[hit_zone_name]  (per body part)
--
-- The six minion armour types below are the complete set the game uses
-- (scripts/settings/damage/armor_settings.lua -> minion_armor_types).

local armor = {}

armor.TYPES = {
	"unarmored",
	"armored",
	"berserker",
	"resistant",
	"disgustingly_resilient",
	"super_armor",
}

-- Reusing the game's own localisation keys means every language works for free.
armor.DISPLAY_NAME = {
	unarmored = "loc_weapon_stats_display_unarmored",
	armored = "loc_weapon_stats_display_armored",
	berserker = "loc_weapon_stats_display_berzerker",
	resistant = "loc_glossary_armour_type_resistant",
	disgustingly_resilient = "loc_weapon_stats_display_disgustingly_resilient",
	super_armor = "loc_weapon_stats_display_super_armor",
}

armor.VERDICT = {
	EFFECTIVE = "effective",
	REDUCED = "reduced",
	WEAK = "weak",
	IMMUNE = "immune",
	UNKNOWN = "unknown",
}

local MELEE_KEYS = { "armor_damage_modifier" }

-- The charged-shot variant sits last on purpose: a profile that has both the
-- normal and the charged ranged table resolves through the normal one, and only
-- the profiles that carry nothing else (4 of them, e.g. lasgun_p2_charge_killshot)
-- fall through to it.
local RANGED_KEYS = {
	"armor_damage_modifier_ranged",
	"armor_damage_modifier",
	"armor_damage_modifier_ranged_charged",
}

-- Ranged armour tables are banded by distance. Verified against all 905 profiles
-- in the game's damage table, and the split is perfectly consistent:
--
--   armor_damage_modifier                -> flat  { attack = {...}, impact = {...} }   1512
--   armor_damage_modifier_ranged         -> banded { near = { attack = ... }, far = ... }  226
--   armor_damage_modifier_ranged_charged -> banded { near = ..., far = ... }              4
--
-- and no profile carries both a melee and a ranged key, so there is no fallback
-- between them: picking the wrong key silently yields no data at all.
local BAND_PREFERENCE = { "near", "far" }

-- Returns the attack map plus the band it was found in (nil when flat).
local function attack_map(candidate, band)
	if type(candidate.attack) == "table" then
		return candidate.attack, nil
	end

	if band and type(candidate[band]) == "table" and type(candidate[band].attack) == "table" then
		return candidate[band].attack, band
	end

	for i = 1, #BAND_PREFERENCE do
		local name = BAND_PREFERENCE[i]
		local entry = candidate[name]

		if type(entry) == "table" and type(entry.attack) == "table" then
			return entry.attack, name
		end
	end

	return nil
end

-- The table is either directly on the profile or nested under one of its target
-- entries. In the latter case the choice matters: `targets` is keyed by cleave
-- index, and 126 of the 334 profiles that use this shape give the indices
-- *different* armour modifiers. `pairs` order is undefined in Lua, so the pick
-- has to be explicit or the verdict can flicker between cleave steps.
local function table_from_profile(damage_profile, key)
	local direct = damage_profile[key]

	if type(direct) == "table" then
		return direct, "profile"
	end

	local targets = damage_profile.targets

	if type(targets) ~= "table" then
		return nil
	end

	-- The enemy actually hit: numeric 1 first (this is how the game's own code
	-- reads it), then the string form the JSON dump produces, then the default.
	local preferred = { targets[1], targets["1"], targets.default_target }

	for i = 1, #preferred do
		local candidate = preferred[i]

		if type(candidate) == "table" and type(candidate[key]) == "table" then
			return candidate[key], "targets"
		end
	end

	-- Last resort, ordered so the result is at least stable frame to frame.
	local names = {}

	for name in pairs(targets) do
		names[#names + 1] = name
	end

	table.sort(names, function (a, b)
		return tostring(a) < tostring(b)
	end)

	for i = 1, #names do
		local candidate = targets[names[i]]

		if type(candidate) == "table" and type(candidate[key]) == "table" then
			return candidate[key], "targets"
		end
	end

	return nil
end

-- Which bands this profile's table offers, for diagnostics.
function armor.bands(damage_profile, is_ranged)
	local out = {}

	if type(damage_profile) ~= "table" then
		return out
	end

	local keys = is_ranged and RANGED_KEYS or MELEE_KEYS

	for i = 1, #keys do
		local candidate = table_from_profile(damage_profile, keys[i])

		if type(candidate) == "table" then
			if type(candidate.attack) == "table" then
				out[#out + 1] = "flat"
			end

			for j = 1, #BAND_PREFERENCE do
				local name = BAND_PREFERENCE[j]
				local entry = candidate[name]

				if type(entry) == "table" and type(entry.attack) == "table" then
					out[#out + 1] = name
				end
			end

			if #out > 0 then
				return out
			end
		end
	end

	return out
end

-- Returns the resolved attack map plus the key and band it came from, so
-- diagnostics can report what the game actually populated on this profile.
-- `band` is optional; "near" is preferred when it is not given.
function armor.attack_table(damage_profile, is_ranged, band)
	if type(damage_profile) ~= "table" then
		return nil
	end

	local keys = is_ranged and RANGED_KEYS or MELEE_KEYS

	for i = 1, #keys do
		local key = keys[i]
		local candidate, source = table_from_profile(damage_profile, key)

		if type(candidate) == "table" then
			local attack, used_band = attack_map(candidate, band)

			if attack then
				return attack, key, used_band, source
			end
		end
	end

	return nil
end

-- Returns min_modifier, max_modifier, source_key, band.
-- Two values because a modifier can be a { min, max } lerp rather than a number.
function armor.modifier(damage_profile, armor_type, is_ranged, band)
	if not armor_type then
		return nil
	end

	local attack, source_key, used_band = armor.attack_table(damage_profile, is_ranged, band)

	if not attack then
		return nil
	end

	local value = attack[armor_type]

	if type(value) == "number" then
		return value, value, source_key, used_band
	elseif type(value) == "table" then
		local min_value = tonumber(value[1]) or 0
		local max_value = tonumber(value[2]) or min_value

		return min_value, max_value, source_key, used_band
	end

	return nil
end

-- Classify on the optimistic end of the range: if any part of the attack can
-- reach the threshold, telling the player "this works" is the useful answer.
function armor.classify(max_modifier, thresholds)
	if type(max_modifier) ~= "number" then
		return armor.VERDICT.UNKNOWN
	elseif max_modifier <= 0 then
		return armor.VERDICT.IMMUNE
	elseif max_modifier >= thresholds.effective then
		return armor.VERDICT.EFFECTIVE
	elseif max_modifier >= thresholds.reduced then
		return armor.VERDICT.REDUCED
	end

	return armor.VERDICT.WEAK
end

function armor.display_name(armor_type)
	if not armor_type then
		return ""
	end

	local key = armor.DISPLAY_NAME[armor_type]

	if not key then
		return armor_type
	end

	local ok, text = pcall(Localize, key)

	if ok and type(text) == "string" and text ~= "" then
		local lowered = string.lower(text)

		-- The localizer hands back a placeholder for a key it cannot resolve; the
		-- raw armour type is more useful than "unlocalized" on screen.
		if not string.find(lowered, "unlocalized", 1, true)
			and not string.find(text, "loc_", 1, true)
			and string.sub(text, 1, 1) ~= "<"
		then
			return text
		end
	end

	return armor_type
end

-- Resolves a hit actor to its body part using `breed.hit_zones`, which is the
-- game's own actor -> zone table. Verified against all 59 breeds in the game:
-- every one of them carries it, and it looks like this:
--
--   hit_zones = {
--     { actors = { "c_head", "c_neck" },            name = "head" },
--     { actors = { "c_hips", "c_spine", "c_spine1" }, name = "torso" },
--     { actors = { "c_hips", "c_spine" },           name = "center_mass" },
--     ...
--   }
--
-- `hitzone_armor_override` is keyed by those `name` values (head, upper_left_leg,
-- torso, center_mass, afro, ...), which is why resolving through this table is
-- safer than relying on a utility module's symbolic names: real zone names
-- include things like `afro` and `captain_void_shield`.
--
-- An actor can belong to more than one zone (c_hips is under both torso and
-- center_mass), so a zone that actually carries an armour override wins, and the
-- first zone in the game's own order is used as the label otherwise.
-- Returns zone_name, override_armor_type.
function armor.zone_for_actor(breed, actor_name)
	if type(breed) ~= "table" or type(actor_name) ~= "string" then
		return nil
	end

	local hit_zones = breed.hit_zones

	if type(hit_zones) ~= "table" then
		return nil
	end

	local override = breed.hitzone_armor_override
	local first_zone = nil

	for i = 1, #hit_zones do
		local zone = hit_zones[i]

		if type(zone) == "table" and type(zone.actors) == "table" then
			local actors = zone.actors
			local matched = false

			-- `actors` is a set, which may be keyed or array-shaped.
			if actors[actor_name] ~= nil then
				matched = true
			else
				for j = 1, #actors do
					if actors[j] == actor_name then
						matched = true

						break
					end
				end
			end

			if matched then
				local zone_name = zone.name or actor_name

				if not first_zone then
					first_zone = zone_name
				end

				if type(override) == "table" and override[zone_name] ~= nil then
					return zone_name, override[zone_name]
				end
			end
		end
	end

	return first_zone
end

-- Convenience wrapper: the armour for a specific hit actor.
-- Returns armor_type, zone_name, source.
function armor.armor_type_for_actor(breed, actor_name)
	local zone_name, override_armor = armor.zone_for_actor(breed, actor_name)

	if override_armor then
		return override_armor, zone_name, "hitzone"
	end

	if type(breed) == "table" then
		return breed.armor_type, zone_name, "breed"
	end

	return nil, zone_name
end

-- Armour is per body part: e.g. a renegade_executor's head is armored while its
-- body is unarmored. Returns armor_type, was_overridden.
function armor.armor_type_for_hitzone(breed, hit_zone_name)
	if type(breed) ~= "table" then
		return nil, false
	end

	local override = breed.hitzone_armor_override

	if hit_zone_name and type(override) == "table" then
		local specific = override[hit_zone_name]

		if type(specific) == "string" then
			return specific, true
		end
	end

	return breed.armor_type, false
end

return armor
