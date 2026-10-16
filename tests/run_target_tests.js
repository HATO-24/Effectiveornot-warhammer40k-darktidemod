// Integration test for target.lua's resolution chain, with the engine globals
// stubbed out.
//
// This is where the subtle logic lives: prefer the raycast (it knows the body
// part), fall back to the game's own smart targeting when the ray finds nothing
// or finds something that is not an enemy, and only trust the hit actor when it
// belongs to the unit that was kept.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const MOD = path.join(__dirname, '..');
const ARMOR = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'armor.lua');
const TARGET = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'target.lua');

const STUBS = `
-- ============================ engine stubs ============================
local alive_units = {}
local unit_extensions = {}
local actor_to_unit = {}
local actor_names = {}
local actor_zone = {}
local unit_actor_list = {}
local unit_actor_index = {}
local unit_nodes = {}
local actor_node_of = {}
local unit_breed = {}
local hitzone_get_name_disabled = false
local hitzone_get_name_bogus = false
local raycast_table = nil
local raycast_calls = {}
local error_filter = nil

HEALTH_ALIVE = setmetatable({}, { __index = function (_, u) return alive_units[u] or nil end })

Unit = {
	alive = function (u) return alive_units[u] ~= nil end,
	-- Unit.actor takes an actor INDEX, not a name; a name goes through
	-- Unit.find_actor first. Modelling this faithfully is the whole point: the
	-- shipped code used to call Unit.actor(unit, name) with a string and the old,
	-- wrong stub happily agreed with it.
	actor = function (u, index)
		if type(index) ~= "number" then return nil end
		local list = unit_actor_list[u]
		return list and list[index] or nil
	end,
	find_actor = function (u, name)
		local by_name = unit_actor_index[u]
		return by_name and by_name[name] or nil
	end,
	num_actors = function (u)
		local list = unit_actor_list[u]
		return list and #list or 0
	end,
	-- The other half of the fallback: a breed may list NODE names instead.
	node = function (u, name)
		local by_name = unit_nodes[u]
		return by_name and by_name[name] or nil
	end,
}

ScriptUnit = {
	has_extension = function (unit, name)
		local by_name = unit_extensions[unit]
		return by_name and by_name[name] or nil
	end,
}

Actor = {
	unit = function (a) return actor_to_unit[a] end,
	node = function (a) return actor_node_of[a] end,
	-- Deliberately present but unused: nothing else in this mod collection uses
	-- Actor.name, and it returned nil in practice.
	name = function (a) return actor_names[a] end,
}

PhysicsWorld = {
	raycast = function (_world, _from, _dir, _len, _hit_type, _filter_type, filter_name)
		raycast_calls[#raycast_calls + 1] = filter_name
		if filter_name == error_filter then
			error("raycast exploded")
		end
		local hits = raycast_table and raycast_table[filter_name]
		if not hits then return nil, 0 end
		return hits, #hits
	end,
}

Managers = { player = { local_player = function () return nil end } }

-- target.lua requires the game's hit zone module. hit_zone_names maps a symbolic
-- zone KEY to the value get_actor_names expects; the key is the candidate
-- hitzone_armor_override key.
HIT_ZONE_NAMES = { head = "ZONE_HEAD", torso = "ZONE_TORSO" }
ENGINE_ZONE_ACTORS = {}
local REAL_REQUIRE = require
require = function (p)
	if p == "scripts/utilities/attack/hit_zone" then
		return {
			hit_zone_names = HIT_ZONE_NAMES,
			get_actor_names = function (unit, zone)
				local by_zone = ENGINE_ZONE_ACTORS[unit]
				return by_zone and by_zone[zone] or nil
			end,
			-- The engine's real actor -> zone mapping. Note the shipped code must
			-- REJECT a zone the breed does not know, so the stub returns a bogus
			-- "afro" here exactly as the game did.
			get_name = function (unit, actor)
				if hitzone_get_name_disabled then return nil end
				if hitzone_get_name_bogus then return "afro" end
				return actor_zone[actor]
			end,
		}
	end
	return REAL_REQUIRE(p)
end

-- ============================ fixtures ============================
local HEAD_ZONES = {
	{ actors = { "c_head", "c_neck" }, name = "head" },
	{ actors = { "c_hips", "c_spine" }, name = "torso" },
}

local function make_breed(opts)
	return {
		name = opts.name,
		armor_type = opts.armor,
		hitzone_armor_override = opts.overrides,
		hit_zones = opts.zones or HEAD_ZONES,
		unit_template_name = opts.template or "minion",
		faction_name = opts.faction or "chaos",
	}
end

local function make_unit(id, breed)
	local unit = { id = id }
	alive_units[unit] = true
	unit_breed[unit] = breed
	unit_actor_list[unit] = {}
	unit_actor_index[unit] = {}
	unit_nodes[unit] = {}
	unit_extensions[unit] = {
		unit_data_system = { breed = function () return breed end },
	}
	return unit
end

-- An actor reachable only as a scene-graph NODE name, which is the ambiguity the
-- breed data leaves open.
local function make_node_actor(unit, name, zone_name)
	local actor = {}
	local node = {}
	actor_to_unit[actor] = unit
	actor_node_of[actor] = node
	unit_nodes[unit][name] = node
	actor_zone[actor] = zone_name
	return actor
end

-- An actor registered on the unit (find_actor reaches it) but with NO name:
-- forces the breed-table handle match instead of the actor-name route.
local function make_indexed_actor(unit, name)
	local actor = {}
	actor_to_unit[actor] = unit
	local list = unit_actor_list[unit]
	list[#list + 1] = actor
	unit_actor_index[unit][name] = #list
	return actor
end

-- The worst case: an actor that cannot be named, has no node, and matches nothing
-- in any zone table. Every fallback must survive it.
local function make_ghost_actor(unit)
	local actor = {}
	actor_to_unit[actor] = unit
	return actor
end

-- Which zone a breed lists a given actor name under.
local function zone_for(breed, actor_name)
	for _, zone in ipairs(breed.hit_zones or {}) do
		for _, name in ipairs(zone.actors or {}) do
			if name == actor_name then
				return zone.name
			end
		end
	end
end

local function make_actor(unit, name)
	local actor = {}
	actor_to_unit[actor] = unit
	actor_names[actor] = name

	-- Register it the way the engine does: appended to the unit's actor list, and
	-- reachable by name through Unit.find_actor.
	local list = unit_actor_list[unit]
	list[#list + 1] = actor
	unit_actor_index[unit][name] = #list

	-- The engine's HitZone.get_name mapping, mirrored for the stub.
	actor_zone[actor] = zone_for(unit_breed[unit], name)
	return actor
end

local function make_player(smart_unit)
	local player = {}
	unit_extensions[player] = {
		smart_targeting_system = {
			_physics_world = {},
			_targeting_parameters = function () return { 0, 0, 0 }, { 0, 0, 1 } end,
			targeting_data = function () return { unit = smart_unit } end,
		},
	}
	alive_units[player] = true
	return player
end

local function hit_tuple(actor)
	return { { 0, 0, 0 }, 1.5, { 0, 1, 0 }, actor }
end

local function reset()
	raycast_table = nil
	raycast_calls = {}
	error_filter = nil
	hitzone_get_name_disabled = false
	hitzone_get_name_bogus = false
	ENGINE_ZONE_ACTORS = {}
end

-- A player with no smart targeting extension at all.
local function make_bare_player()
	local player = {}
	alive_units[player] = true
	unit_extensions[player] = {}
	return player
end
`;

const TESTS = `
-- ============================ assertions ============================
local checks, failures = 0, 0
local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("  FAIL %-56s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-56s %s", label, tostring(got)))
	end
end

local F1 = "filter_player_character_shooting_raycast"
local F2 = "filter_player_ping_target_selection"

local enemy_breed = make_breed({ name = "renegade_executor", armor = "armored", overrides = { head = "super_armor" } })
local companion_breed = make_breed({ name = "companion_dog", armor = nil, template = "minion_companion_dog", faction = "imperium" })
local bare_breed = make_breed({ name = "chaos_poxwalker", armor = "unarmored", zones = { { actors = { "c_spine" }, name = "torso" } } })

print("== S1: ray hits a live enemy, armour override applies ==")
reset()
local enemy = make_unit("e1", enemy_breed)
local head_actor = make_actor(enemy, "c_head")
raycast_table = { [F1] = { hit_tuple(head_actor) } }
local player = make_player(nil)
local r = target.resolve(player)
check("unit is the ray target", r.unit, enemy)
check("hit zone via the actor-name route", r.hit_zone_name, "head")
check("zone source", r.zone_source, "actor_name")
check("authoritative zone overrides breed armour", r.armor_type, "super_armor")
check("armour source", r.armor_source, "hitzone")
check("filter that worked", r.raycast_filter, F1)
check("steps: extension found", r.steps.targeting_extension, true)
check("steps: physics world found", r.steps.physics_world, true)
check("steps: targeting params ok", r.steps.targeting_parameters, true)
check("steps: targeting data ok", r.steps.targeting_data, true)
check("steps: filter tried", r.steps.filters_tried[1], F1)
check("steps: hit count for that filter", r.steps.hits_per_filter[F1], 1)
check("steps: live minion from", r.steps.live_minion_from, F1)
check("steps: targeting data keys present", type(r.steps.targeting_data_keys), "table")

print("")
print("== S2: first filter finds nothing, second one does ==")
reset()
local enemy2 = make_unit("e2", enemy_breed)
local torso_actor = make_actor(enemy2, "c_spine")
raycast_table = { [F2] = { hit_tuple(torso_actor) } }
local r2 = target.resolve(make_player(nil))
check("unit found via fallback filter", r2.unit, enemy2)
check("zone is torso", r2.hit_zone_name, "torso")
check("armour falls back to breed", r2.armor_type, "armored")
check("armour source is breed", r2.armor_source, "breed")
check("reported filter", r2.raycast_filter, F2)
check("both filters were tried", #raycast_calls, 2)
check("order of attempts", raycast_calls[1], F1)

print("")
print("== S3: no filter works, fall back to smart targeting (no body part) ==")
reset()
local enemy3 = make_unit("e3", enemy_breed)
local r3 = target.resolve(make_player(enemy3))
check("unit from smart targeting", r3.unit, enemy3)
check("no hit zone", r3.hit_zone_name, nil)
check("armour is breed-wide", r3.armor_type, "armored")
check("armour source", r3.armor_source, "breed")
check("no filter reported", r3.raycast_filter, nil)

print("")
print("== S4: ray hits a companion (not an enemy), smart target is an enemy ==")
reset()
local companion = make_unit("c1", companion_breed)
local comp_actor = make_actor(companion, "c_skull")
raycast_table = { [F1] = { hit_tuple(comp_actor) } }
local enemy4 = make_unit("e4", enemy_breed)
local r4 = target.resolve(make_player(enemy4))
check("falls back to the enemy", r4.unit, enemy4)
check("no hit zone from the companion", r4.hit_zone_name, nil)
check("armour from the enemy breed", r4.armor_type, "armored")

print("")
print("== S5: ray unit wins over smart target when it is a live enemy ==")
reset()
local enemy5 = make_unit("e5", enemy_breed)
local a5 = make_actor(enemy5, "c_neck")
raycast_table = { [F1] = { hit_tuple(a5) } }
local other_enemy = make_unit("e6", bare_breed)
local r5 = target.resolve(make_player(other_enemy))
check("ray target wins", r5.unit, enemy5)
check("zone from ray target", r5.hit_zone_name, "head")

print("")
print("== S6: nothing at all ==")
reset()
local r6 = target.resolve(make_player(nil))
check("no unit", r6.unit, nil)

print("")
print("== S7: actor the breed does not list ==")
reset()
local enemy7 = make_unit("e7", bare_breed)
local odd_actor = make_actor(enemy7, "c_unknown_thing")
raycast_table = { [F1] = { hit_tuple(odd_actor) } }
local r7 = target.resolve(make_player(nil))
check("unit still resolved", r7.unit, enemy7)
check("zone unknown", r7.hit_zone_name, nil)
check("armour falls back to breed", r7.armor_type, "unarmored")

print("")
print("== S8: pinned filter from settings is the only one tried ==")
reset()
local enemy8 = make_unit("e8", enemy_breed)
local a8 = make_actor(enemy8, "c_head")
raycast_table = { [F2] = { hit_tuple(a8) } }
target.install({ raycast_filter = function () return F2 end })
local r8 = target.resolve(make_player(nil))
check("pinned filter found the unit", r8.unit, enemy8)
check("only one filter attempted", #raycast_calls, 1)
check("the pinned one", raycast_calls[1], F2)
target.install({ raycast_filter = function () return "auto" end })

print("")
print("== S9: every filter returns zero hits (wrong filter vs no physics) ==")
reset()
local r9 = target.resolve(make_player(nil))
check("extension still found", r9.steps.targeting_extension, true)
check("physics world still found", r9.steps.physics_world, true)
check("all three filters tried", #r9.steps.filters_tried, 3)
check("first filter reported 0 hits", r9.steps.hits_per_filter[F1], 0)
check("no live minion from any filter", r9.steps.live_minion_from, nil)

print("")
print("== S10: a raycast call raising is recorded as -1, not as 0 hits ==")
reset()
error_filter = F1
local r10 = target.resolve(make_player(nil))
check("erroring filter recorded as -1", r10.steps.hits_per_filter[F1], -1)
check("later filters still tried", r10.steps.hits_per_filter[F2], 0)

print("")
print("== S11: player with no smart targeting extension ==")
reset()
local r11 = target.resolve(make_bare_player())
check("extension not found", r11.steps.targeting_extension, false)
check("physics world not found", r11.steps.physics_world, false)
check("no filters tried", #r11.steps.filters_tried, 0)
check("no unit", r11.unit, nil)

print("")
print("== S12: no actor name -> breed hit_zones handle match ==")
reset()
hitzone_get_name_disabled = true
local enemy12 = make_unit("e12", enemy_breed)
local a12 = make_indexed_actor(enemy12, "c_head")
raycast_table = { [F1] = { hit_tuple(a12) } }
local r12 = target.resolve(make_player(nil))
check("zone recovered from breed.hit_zones", r12.hit_zone_name, "head")
check("zone source says which path", r12.zone_source, "breed_hit_zones")
check("armour still from the override", r12.armor_type, "super_armor")

print("")
print("== S13: neither mapping knows the actor -> breed-wide armour ==")
reset()
hitzone_get_name_disabled = true
local enemy13 = make_unit("e13", enemy_breed)
local a13 = make_actor(enemy13, "c_unknown_thing")
raycast_table = { [F1] = { hit_tuple(a13) } }
local r13 = target.resolve(make_player(nil))
check("no zone", r13.hit_zone_name, nil)
check("no zone source", r13.zone_source, nil)
check("armour falls back to the breed", r13.armor_type, "armored")
check("armour source is breed", r13.armor_source, "breed")

print("")
print("== S14: neither get_name nor the breed table knows it -> engine zones ==")
reset()
hitzone_get_name_disabled = true
-- A breed whose zone table does not list the actor we hit...
local sparse_zones = {
	{ actors = { "c_hips" }, name = "torso" },
}
local enemy14 = make_unit("e14", make_breed({
	name = "b14", armor = "armored", overrides = { head = "super_armor" }, zones = sparse_zones,
}))
local a14 = make_actor(enemy14, "c_weirdhead")
-- ...but the engine reports that actor under its own "head" zone.
ENGINE_ZONE_ACTORS[enemy14] = { ZONE_HEAD = { "c_weirdhead" } }
raycast_table = { [F1] = { hit_tuple(a14) } }
local r14 = target.resolve(make_player(nil))
check("zone from the engine zone table", r14.hit_zone_name, "head")
check("source says engine_zones", r14.zone_source, "engine_zones")
check("armour from the override", r14.armor_type, "super_armor")
check("probe names the zone", r14.zone_probe and r14.zone_probe.resolved_zone, "head")
check("probe lists override keys", r14.zone_probe and r14.zone_probe.override_keys[1], "head")

print("")
print("== S15: the breed lists NODE names, not actor names ==")
reset()
hitzone_get_name_disabled = true
local node_zones = {
	{ actors = { "c_head" }, name = "head" },
}
local enemy15 = make_unit("e15", make_breed({
	name = "b15", armor = "armored", overrides = { head = "super_armor" }, zones = node_zones,
}))
-- Unit.actor(unit, "c_head") resolves to nothing; Unit.node(unit, "c_head") works.
local a15 = make_node_actor(enemy15, "c_head", nil)
raycast_table = { [F1] = { hit_tuple(a15) } }
local r15 = target.resolve(make_player(nil))
check("zone found via the node handle", r15.hit_zone_name, "head")
check("source is the breed table", r15.zone_source, "breed_hit_zones")
check("armour from the override", r15.armor_type, "super_armor")
check("probe reports the actor API", r15.zone_probe and r15.zone_probe.has_actor_node, true)
check("probe lists candidates", r15.zone_probe and #r15.zone_probe.candidates, 1)

print("")
print("== S16: the engine answers a bogus zone (afro) -- rejected, recorded ==")
reset()
-- This is the exact production failure seen in the field log: get_name answered
-- "afro" for nearly every actor. "afro" has no armour override on any breed, so
-- trusting it pinned every body part to the breed-wide armour. The fix: a zone
-- without an override is rejected and the value is recorded for the diagnosis.
hitzone_get_name_bogus = true
local enemy16 = make_unit("e16", make_breed({
	name = "b16", armor = "armored",
	overrides = { head = "super_armor" },
	zones = {
		{ actors = { "c_head" }, name = "head" },
	},
}))
-- A ghost actor: cannot be named, matches nothing. Every route fails, so only the
-- bogus engine answer remains -- and it must be refused.
local a16 = make_ghost_actor(enemy16)
raycast_table = { [F1] = { hit_tuple(a16) } }
local r16 = target.resolve(make_player(nil))
check("bogus zone rejected", r16.hit_zone_name, nil)
check("no zone source", r16.zone_source, nil)
check("armour falls back to the breed", r16.armor_type, "armored")
check("the bogus value is still recorded", r16.zone_probe and r16.zone_probe.raw_get_name, "afro")

print("")
print(string.format("%d checks, %d failures", checks, failures))
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	'local armor = (function()',
	'local Localize = function(key) return key end',
	fs.readFileSync(ARMOR, 'utf8'),
	'end)()',
	STUBS,
	'local target = (function()',
	fs.readFileSync(TARGET, 'utf8'),
	'end)()',
	'target.set_armor_module(armor)',
	TESTS,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
