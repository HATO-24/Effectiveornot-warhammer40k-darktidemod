-- target.lua -- "what is under the crosshair, and which body part is it".
--
-- Two sources, used together:
--
--   1. `smart_targeting_system:targeting_data().unit` -- the game's own answer to
--      "which enemy am I aiming at". This is what the vanilla smart-tag and the
--      DivisionHUD enemy widget use.
--   2. a physics raycast along the same targeting parameters the game uses. This
--      is what tells us *which body part* the reticle is on, which matters
--      because armour is per hit zone (a renegade_executor's head is armored,
--      its body is unarmored).
--
-- The raycast returns the hit actor; `HitZone.get_actor_names` maps a unit's
-- hit zones to actor names, so the reverse lookup gives us the zone name that
-- `breed.hitzone_armor_override` is keyed by.

local target = {}

local HitZone = require("scripts/utilities/attack/hit_zone")

-- AutoMark documents the hit tuple layout: position, distance, normal, actor.
local INDEX_ACTOR = 4
local MAX_RANGE = 50

-- Tried in order; the first filter that yields a live minion wins.
--
-- The first entry is the game's own player-shooting raycast filter, which is what
-- the flamer/cleave code uses via `HitScan.raycast(..., "filter_player_character_shooting_raycast", ...)`
-- and is therefore the one that matches "what my shots can hit".
-- `filter_player_ping_target_selection` is the fallback because the working
-- smart-tag targeting in AutoMark uses it. The last is a plain line-of-sight
-- filter that only exists as a last resort.
local RAYCAST_FILTERS = {
	"filter_player_character_shooting_raycast",
	"filter_player_ping_target_selection",
	"filter_ray_aim_assist_line_of_sight",
}

local config = {}

function target.install(settings)
	config = settings or {}
end

local function scripting_extension(unit, name)
	if not unit then
		return nil
	end

	local ok, extension = pcall(ScriptUnit.has_extension, unit, name)

	if ok and extension then
		return extension
	end

	return nil
end

function target.targeting_extension(player_unit)
	return scripting_extension(player_unit, "smart_targeting_system")
end

function target.breed_of(unit)
	local unit_data = scripting_extension(unit, "unit_data_system")

	if not unit_data then
		return nil
	end

	local ok, breed = pcall(function ()
		return unit_data:breed()
	end)

	if ok and type(breed) == "table" then
		return breed
	end

	return nil
end

local function is_live_minion(unit)
	if not unit then
		return false
	end

	-- `Unit.alive` is not guaranteed to exist in every build, so never let a
	-- missing helper decide the answer.
	local ok_alive, alive = pcall(Unit.alive, unit)

	if ok_alive and alive == false then
		return false
	end

	-- Same table the vanilla smart-tag system uses to reject dead targets.
	if HEALTH_ALIVE and not HEALTH_ALIVE[unit] then
		return false
	end

	local breed = target.breed_of(unit)

	if not breed then
		return false
	end

	-- Keep players, props and Imperium allies out of the crosshair readout.
	if breed.unit_template_name and breed.unit_template_name ~= "minion" then
		return false
	end

	if breed.faction_name == "imperium" then
		return false
	end

	return true, breed
end

-- Name (or index) -> actor handle.
--
-- Unit.actor() takes an INDEX, not a name. The working pattern is
-- Unit.find_actor(unit, name) followed by Unit.actor(unit, index) -- exactly what
-- enginseers_workbench/explosion_limit_modification does:
--
--   local index = Unit.find_actor(hit_unit, "c_destructible") or 1
--   hit_actor = Unit.actor(hit_unit, index)
--
-- Passing a *string* to Unit.actor returned an unrelated actor, which is why every
-- handle comparison failed and the aimed body part never resolved.
local function actor_for_name(unit, name)
	if type(name) == "number" then
		local ok_actor, actor = pcall(Unit.actor, unit, name)

		return ok_actor and actor or nil
	end

	if type(name) ~= "string" then
		return nil
	end

	local ok_find, index = pcall(Unit.find_actor, unit, name)

	if not ok_find or index == nil then
		return nil
	end

	local ok_actor, actor = pcall(Unit.actor, unit, index)

	if ok_actor then
		return actor
	end

	return nil
end

-- Does this name refer to the actor we hit?
--
-- There is no way to tell from the data whether a breed's body-part names are
-- physics ACTOR names or scene-graph NODE names -- the field is called `actors`,
-- but the values look like the game's `c_*` character nodes. So both lookups are
-- tried. `Actor.name` does not exist at all (confirmed against the game's own Actor
-- API stub), which is why matching has to be done on handles.
local function name_matches(unit, name, actor, actor_node)
	local unit_actor = actor_for_name(unit, name)

	if unit_actor ~= nil and unit_actor == actor then
		return true
	end

	if type(name) == "string" and actor_node then
		local ok_node, unit_node = pcall(Unit.node, unit, name)

		if ok_node and unit_node ~= nil and unit_node == actor_node then
			return true
		end
	end

	return false
end

local function node_of(actor)
	local ok, node = pcall(Actor.node, actor)

	if ok then
		return node
	end

	return nil
end

-- The hit actor's name. This is the lookup the first shipped version used and the
-- one the user validated: name the actor, then reverse-map through the breed's
-- hit_zones table by string comparison. Kept as the first route.
local function actor_name_of(actor)
	if not actor then
		return nil
	end

	local ok, name = pcall(Actor.name, actor)

	if ok and type(name) == "string" and name ~= "" then
		return name
	end

	return nil
end

-- A zone from HitZone.get_name is only trusted when it changes the armour: it must
-- carry an override for the aimed breed. A zone without an override displays the
-- breed-wide armour anyway, so accepting it would only stop the other routes from
-- trying -- and "afro" (present on every breed, overridden by none) was exactly the
-- value that froze the readout.
local function zone_has_override(breed, zone_name)
	if type(zone_name) ~= "string" or type(breed) ~= "table" then
		return false
	end

	local override = breed.hitzone_armor_override

	return type(override) == "table" and override[zone_name] ~= nil
end

-- Engine's own actor -> zone mapping, accepted only when it carries an override.
-- Returns (accepted, raw).
local function zone_from_actor(unit, actor, breed)
	if not unit or not actor or not HitZone or not HitZone.get_name then
		return nil, nil
	end

	local ok, zone_name = pcall(HitZone.get_name, unit, actor)

	if not ok or type(zone_name) ~= "string" or zone_name == "" then
		return nil, nil
	end

	if not zone_has_override(breed, zone_name) then
		return nil, zone_name
	end

	return zone_name, zone_name
end

-- Second path: ask the engine for the names belonging to every hit zone it knows,
-- and compare handles. This is the pattern a working mod uses
-- (enginseers_workbench/explosion_limit_modification: get_actor_names -> Unit.actor),
-- and it yields the engine's own zone key, which is what hitzone_armor_override is
-- keyed by.
local function zone_from_engine_zones(unit, actor, actor_node)
	if not unit or not actor or not HitZone then
		return nil
	end

	local zone_names = HitZone.hit_zone_names

	if type(zone_names) ~= "table" or type(HitZone.get_actor_names) ~= "function" then
		return nil
	end

	for key, zone in pairs(zone_names) do
		local ok, names = pcall(HitZone.get_actor_names, unit, zone)

		if ok and type(names) == "table" then
			for i = 1, #names do
				if name_matches(unit, names[i], actor, actor_node) then
					return key
				end
			end
		end
	end

	return nil
end

-- Fallback: walk the breed's own `hit_zones` table.
local function zone_from_breed(unit, actor, actor_node, breed)
	if not unit or not actor or type(breed) ~= "table" then
		return nil
	end

	local hit_zones = breed.hit_zones

	if type(hit_zones) ~= "table" then
		return nil
	end

	for i = 1, #hit_zones do
		local zone = hit_zones[i]

		if type(zone) == "table" and type(zone.actors) == "table" then
			for _, actor_name in pairs(zone.actors) do
				if name_matches(unit, actor_name, actor, actor_node) then
					return zone.name or actor_name
				end
			end
		end
	end

	return nil
end

-- Forward declared: the raycast below records the hit tuple's shape, but the
-- helper itself sits with the other diagnostics further down.
local describe_tuple

local function raycast(extension, steps)
	local physics_world = extension and extension._physics_world

	if not physics_world then
		return nil
	end

	if steps then
		steps.physics_world = true
	end

	local ok_params, ray_origin, forward = pcall(extension._targeting_parameters, extension)

	if not ok_params or not ray_origin or not forward then
		return nil
	end

	if steps then
		steps.targeting_parameters = true
	end

	-- A pinned filter from the settings is tried on its own; otherwise every
	-- candidate is tried in order and the first that yields a live minion wins.
	local pinned = config.raycast_filter and config.raycast_filter()
	local filters = RAYCAST_FILTERS

	if pinned and pinned ~= "auto" then
		filters = { pinned }
	end

	for i = 1, #filters do
		local filter_name = filters[i]
		local ok, hits, num_hits = pcall(
			PhysicsWorld.raycast,
			physics_world,
			ray_origin,
			forward,
			MAX_RANGE,
			"all",
			"collision_filter",
			filter_name
		)

		-- Recorded even when nothing usable came back: knowing which filters see
		-- *anything* at all is what separates "wrong filter" from "no physics
		-- solution" when the indicator refuses to appear. -1 marks a raised error.
		if steps then
			steps.filters_tried[#steps.filters_tried + 1] = filter_name
			steps.hits_per_filter[filter_name] = (ok and num_hits) or -1
		end

		if ok and hits and num_hits and num_hits > 0 then
			-- Walk the hits front to back and take the first live minion, so a
			-- railing or a barrel in front of the enemy does not win.
			for hit_index = 1, num_hits do
				local hit = hits[hit_index]
				local actor = hit and hit[INDEX_ACTOR]
				local hit_unit = actor and Actor.unit(actor)

				if is_live_minion(hit_unit) then
					if steps then
						steps.live_minion_from = filter_name
						steps.hit_index = hit_index
						steps.hit_count = num_hits
						-- The hit tuple's shape, so the actor slot can be confirmed
						-- from one dump instead of inferred from other mods.
						steps.hit_tuple = describe_tuple(hit)
					end

					return hit_unit, actor, filter_name
				end
			end
		end
	end

	return nil
end

-- Reports the numeric slots of a hit tuple and their types, e.g. "1:boolean 2:number
-- 3:userdata". Cheap, and it settles empirically which slot holds the actor.
describe_tuple = function (value)
	if type(value) ~= "table" then
		return "not-a-table"
	end
	local parts = {}

	for i = 1, 6 do
		local slot = value[i]

		if slot == nil then
			break
		end

		parts[#parts + 1] = i .. ":" .. type(slot)
	end

	return table.concat(parts, " ")
end

-- Everything needed to explain a body-part resolution from a single dump.
--
-- The decisive part is `candidates`: for the first dozen names the breed lists, it
-- records whether Unit.actor and Unit.node resolve them and whether either matches
-- the hit actor -- which settles whether those names are actor names or node names,
-- the ambiguity that made the earlier attempts fail silently.
local function zone_diagnostics(unit, actor, actor_node, breed, resolved_zone, raw_zone)
	local probe = {
		resolved_zone = resolved_zone,
		raw_get_name = raw_zone,
		has_actor_name = type(Actor.name) == "function",
		has_actor_node = type(Actor.node) == "function",
		has_find_actor = type(Unit.find_actor) == "function",
		actor_node_present = actor_node ~= nil,
	}

	if HitZone and type(HitZone.hit_zone_names) == "table" then
		local keys = {}

		for key in pairs(HitZone.hit_zone_names) do
			keys[#keys + 1] = tostring(key)
		end

		table.sort(keys)

		probe.hit_zone_names = keys
		probe.has_get_name = type(HitZone.get_name) == "function"
		probe.has_get_actor_names = type(HitZone.get_actor_names) == "function"
	else
		probe.hit_zone_names = "absent"
		probe.has_get_name = type(HitZone) == "table" and type(HitZone.get_name) == "function"
	end

	local ok_unit, actor_unit = pcall(Actor.unit, actor)

	probe.actor_belongs_to_unit = ok_unit and actor_unit == unit

	local candidates = {}

	if type(breed) == "table" and type(breed.hit_zones) == "table" then
		for i = 1, #breed.hit_zones do
			local zone = breed.hit_zones[i]

			if type(zone) == "table" and type(zone.actors) == "table" then
				for _, name in pairs(zone.actors) do
					if type(name) == "string" and #candidates < 12 then
						-- The real lookup: find_actor gives an index, actor takes it.
						local ok_find, index = pcall(Unit.find_actor, unit, name)
						local ok_actor, unit_actor = false, nil

						if ok_find and index ~= nil then
							ok_actor, unit_actor = pcall(Unit.actor, unit, index)
						end

						local ok_node, unit_node = pcall(Unit.node, unit, name)

						candidates[#candidates + 1] = string.format(
							"%s zone=%s  index=%s actor_match=%s  node_resolves=%s node_match=%s",
							name,
							tostring(zone.name),
							tostring(ok_find and index),
							tostring(ok_actor and unit_actor ~= nil and unit_actor == actor),
							tostring(ok_node and unit_node ~= nil),
							tostring(ok_node and actor_node ~= nil and unit_node == actor_node)
						)
					end
				end
			end
		end
	end

	table.sort(candidates)

	probe.candidates = candidates

	if type(breed) == "table" then
		local override_keys = {}

		if type(breed.hitzone_armor_override) == "table" then
			for key in pairs(breed.hitzone_armor_override) do
				override_keys[#override_keys + 1] = tostring(key)
			end

			table.sort(override_keys)
		end

		probe.override_keys = override_keys
		probe.breed_armor = breed.armor_type

		local zone_table = {}
		local hit_zones = breed.hit_zones

		if type(hit_zones) == "table" then
			for i = 1, #hit_zones do
				local zone = hit_zones[i]

				if type(zone) == "table" then
					local names = {}

					if type(zone.actors) == "table" then
						for _, name in pairs(zone.actors) do
							if type(name) == "string" and #names < 4 then
								names[#names + 1] = name
							end
						end
					end

					table.sort(names)

					zone_table[#zone_table + 1] = tostring(zone.name) .. "=[" .. table.concat(names, ",") .. "]"
				end
			end
		end

		probe.hit_zones = zone_table
	end

	return probe
end

-- Returns:
--   {
--     unit            = Unit|nil,
--     breed           = table|nil,
--     breed_name      = string|nil,
--     hit_zone_name   = string|nil,
--     actor_name      = string|nil,
--     armor_type      = string|nil,
--     armor_source    = "hitzone"|"breed"|nil,
--     raycast_filter  = string|nil,   -- which filter produced the hit
--     smart_unit      = Unit|nil,     -- what smart targeting alone reported
--     steps           = table,        -- which link of the chain held up
--   }
function target.resolve(player_unit)
	local result = {
		steps = {
			targeting_extension = false,
			physics_world = false,
			targeting_parameters = false,
			targeting_data = false,
			targeting_data_keys = nil,
			filters_tried = {},
			hits_per_filter = {},
			live_minion_from = nil,
		},
	}

	local extension = target.targeting_extension(player_unit)
	local smart_unit = nil

	if extension then
		result.steps.targeting_extension = true

		local ok, data = pcall(function ()
			return extension:targeting_data()
		end)

		if ok and type(data) == "table" then
			result.steps.targeting_data = true

			-- Only the key names are recorded: the table itself holds live Units and
			-- vectors and is not worth (or safe to) serialise.
			local keys = {}

			for key in pairs(data) do
				keys[#keys + 1] = tostring(key)
			end

			table.sort(keys)

			result.steps.targeting_data_keys = keys
			smart_unit = data.unit
		end
	end

	result.smart_unit = smart_unit

	local ray_unit, actor, filter_name = raycast(extension, result.steps)

	result.raycast_filter = filter_name

	local unit = ray_unit or smart_unit

	if not unit then
		return result
	end

	local live, breed = is_live_minion(unit)

	-- The ray is authoritative for *where* we are pointing, but if it landed on
	-- something that is not a live minion fall back to the smart target.
	if not live and smart_unit then
		unit = smart_unit
		live, breed = is_live_minion(unit)
	end

	if not live then
		return result
	end

	result.unit = unit
	result.breed = breed
	result.breed_name = breed.name

	-- Only trust the actor's hit zone when the actor belongs to the unit we kept.
	local armor_module = target._armor

	if actor and ray_unit == unit then
		-- Routes to the body part, in the order the working basic build used them.
		-- The actor NAME route is first: it is the one the first shipped version
		-- validated, and every route below only runs when it produced nothing.
		local actor_node = node_of(actor)
		local actor_name = actor_name_of(actor)
		result.actor_name = actor_name

		local zone_name, raw_zone = nil, nil
		local zone_source = nil

		if actor_name then
			zone_name = armor_module and armor_module.zone_for_actor(breed, actor_name) or nil

			if zone_name then
				zone_source = "actor_name"
			end
		end

		if not zone_name then
			zone_name = zone_from_breed(unit, actor, actor_node, breed)
			zone_source = zone_name and "breed_hit_zones" or nil
		end

		if not zone_name then
			zone_name = zone_from_engine_zones(unit, actor, actor_node)
			zone_source = zone_name and "engine_zones" or nil
		end

		if not zone_name then
			zone_name, raw_zone = zone_from_actor(unit, actor, breed)
			zone_source = zone_name and "hit_zone_module" or nil
		end

		result.hit_zone_name = zone_name
		result.zone_source = zone_source
		result.zone_probe = zone_diagnostics(unit, actor, actor_node, breed, zone_name, raw_zone)
	end

	if armor_module then
		local armor_type, overridden = armor_module.armor_type_for_hitzone(breed, result.hit_zone_name)

		result.armor_type = armor_type
		result.armor_source = overridden and "hitzone" or "breed"
	end

	return result
end

-- Injected by the main script to avoid a circular require.
function target.set_armor_module(armor_module)
	target._armor = armor_module
end

return target
