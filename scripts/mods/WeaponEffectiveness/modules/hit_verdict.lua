-- hit_verdict.lua -- captures, for every hit the local player lands, whether that
-- hit was actually effective against the armour it landed on.
--
-- This exists for two reasons:
--
--   1. It is the shared prerequisite for any damage-number colouring. Whichever
--      renderer ends up being coloured (Healthbars, the vanilla damage
--      indicator, or this mod's own), it needs the same answer keyed by the unit
--      that was hit.
--   2. It captures the engine's own `damage_efficiency` value verbatim.
--
-- On (2): `damage_efficiency` is NOT a number. It is a string enum that the game
-- sends over the network (`NetworkLookup.damage_efficiencies[...]`), which is why
-- an earlier numeric-only log recorded it as null on all 105k rows. It is the
-- engine's own verdict on a hit, so it is worth having as ground truth to check
-- this mod's armour table against.

local hit_verdict = {}

local RECENT_TTL = 5
local SAMPLE_LIMIT = 24

hit_verdict.recent = {}
hit_verdict.efficiency_counts = {}
hit_verdict.samples = {}
hit_verdict.hooked = false
hit_verdict.hook_error = nil

local config = {}

function hit_verdict.install(settings)
	config = settings or {}
end

local function game_time()
	local time_manager = Managers and Managers.time

	if not time_manager then
		return nil
	end

	local ok, value = pcall(function ()
		return time_manager:time("gameplay")
	end)

	if ok and type(value) == "number" then
		return value
	end

	return nil
end

-- Goes through the injected local_player module: PlayerManager:local_player(1) is
-- a native NULL dereference before any player has been registered (i.e. at the
-- main menu), which takes the process down instead of raising a catchable error.
local function local_player_unit()
	local module = config.local_player

	return module and module.unit() or nil
end

-- The engine records the zone of the last hit on the health extension, so the
-- per-body-part armour override can be resolved exactly rather than guessed.
local function last_hit_zone(attacked_unit)
	local health = ScriptUnit.has_extension(attacked_unit, "health_system")

	if not health then
		return nil
	end

	local ok, zone = pcall(function ()
		return health:last_hit_zone_name()
	end)

	if ok and type(zone) == "string" and zone ~= "" then
		return zone
	end

	return nil
end

-- Tries the melee armour key first and falls back to the ranged one, so the
-- result does not depend on knowing whether this profile came from a melee or a
-- ranged attack. No profile carries both keys, so there is no ambiguity.
-- Returns max_modifier, source_key, band.
local function best_modifier(damage_profile, armor_type, band)
	local armor_module = config.armor

	if not armor_module then
		return nil
	end

	local _, max_melee, source_melee, band_melee = armor_module.modifier(damage_profile, armor_type, false)

	if type(max_melee) == "number" then
		return max_melee, source_melee, band_melee
	end

	local _, max_ranged, source_ranged, band_ranged =
		armor_module.modifier(damage_profile, armor_type, true, band)

	if type(max_ranged) == "number" then
		return max_ranged, source_ranged, band_ranged
	end

	return nil
end

local function push_sample(record)
	local samples = hit_verdict.samples

	samples[#samples + 1] = record

	while #samples > SAMPLE_LIMIT do
		table.remove(samples, 1)
	end
end

function hit_verdict.on_attack_result(
	damage_profile,
	attacked_unit,
	attacking_unit,
	_attack_direction,
	hit_world_position,
	hit_weakspot,
	damage,
	_attack_result,
	attack_type,
	damage_efficiency,
	is_critical_strike
)
	if not attacked_unit then
		return
	end

	-- Record the engine's own verdict vocabulary regardless of who dealt the hit:
	-- the point is to enumerate the possible values.
	local efficiency_key = type(damage_efficiency) == "string"
		and damage_efficiency
		or ("<" .. type(damage_efficiency) .. ">")

	hit_verdict.efficiency_counts[efficiency_key] =
		(hit_verdict.efficiency_counts[efficiency_key] or 0) + 1

	local player_unit = local_player_unit()

	if player_unit and attacking_unit ~= player_unit then
		return
	end

	local breed = config.breed_of and config.breed_of(attacked_unit) or nil
	local armor_module = config.armor
	local hit_zone = last_hit_zone(attacked_unit)
	local armor_type = armor_module
		and armor_module.armor_type_for_hitzone(breed, hit_zone)
		or nil

	local max_modifier, source_key, used_band

	if armor_type then
		local band = config.band and config.band() or nil

		max_modifier, source_key, used_band = best_modifier(damage_profile, armor_type, band)
	end

	local thresholds = config.thresholds and config.thresholds()
		or { effective = 1, reduced = 0.5 }

	local record = {
		verdict = armor_module
			and armor_module.classify(max_modifier, thresholds)
			or "unknown",
		max = max_modifier,
		armor_source_key = source_key,
		armor_band = used_band,
		damage = tonumber(damage),
		weakspot = hit_weakspot == true,
		crit = is_critical_strike == true,
		attack_type = type(attack_type) == "string" and attack_type or nil,
		armor_type = armor_type,
		hit_zone = hit_zone,
		breed_name = breed and breed.name or nil,
		profile_name = type(damage_profile) == "table" and damage_profile.name or nil,
		-- Kept so the caller can feed the profile back into weapon_profiles as a
		-- learned mode; introspection cannot know every weapon family's layout, but
		-- a landed hit proves which profile an action used.
		profile = type(damage_profile) == "table" and damage_profile or nil,
		efficiency = efficiency_key,
		t = game_time(),
	}

	hit_verdict.recent[attacked_unit] = record

	push_sample({
		verdict = record.verdict,
		max = record.max,
		armor_source_key = record.armor_source_key,
		armor_band = record.armor_band,
		damage = record.damage,
		weakspot = record.weakspot,
		crit = record.crit,
		attack_type = record.attack_type,
		armor_type = record.armor_type,
		hit_zone = record.hit_zone,
		breed_name = record.breed_name,
		profile_name = record.profile_name,
		efficiency = record.efficiency,
	})

	-- Let the marker layer draw a number for this hit if it deserves one.
	if config.on_hit then
		pcall(config.on_hit, record, attacked_unit, hit_world_position)
	end

	return record
end

-- The most recent verdict for a unit, or nil when it is stale.
function hit_verdict.for_unit(unit)
	local record = hit_verdict.recent[unit]

	if not record then
		return nil
	end

	local now = game_time()

	if record.t and now and (now - record.t) > RECENT_TTL then
		hit_verdict.recent[unit] = nil

		return nil
	end

	return record
end

-- Drops records for units that are gone or stale so the table cannot grow.
function hit_verdict.prune()
	local now = game_time()

	for unit, record in pairs(hit_verdict.recent) do
		local stale = record.t and now and (now - record.t) > RECENT_TTL
		local ok_alive, alive = pcall(Unit.alive, unit)
		local dead = ok_alive and alive == false

		if stale or dead then
			hit_verdict.recent[unit] = nil
		end
	end
end

function hit_verdict.dump()
	return {
		efficiency_values = hit_verdict.efficiency_counts,
		recent_hits = hit_verdict.samples,
	}
end

function hit_verdict.ensure_hook()
	if hit_verdict.hooked then
		return true
	end

	local mod = config.mod
	local attack_report_manager = CLASS and CLASS.AttackReportManager

	if not mod or not attack_report_manager then
		hit_verdict.hook_error = "mod or CLASS.AttackReportManager unavailable"

		return false
	end

	local ok, err = pcall(function ()
		mod:hook_safe(attack_report_manager, "add_attack_result", function (_self, ...)
			hit_verdict.on_attack_result(...)
		end)
	end)

	if ok then
		hit_verdict.hooked = true

		return true
	end

	hit_verdict.hook_error = tostring(err)

	return false
end

return hit_verdict
