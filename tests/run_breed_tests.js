// Runs the shipped armor.zone_for_actor / armor.armor_type_for_actor against all
// 59 real breeds, over every actor slot the game lists (1195 of them), in both
// actor-set representations the game may use (array-shaped and keyed).
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const MOD = path.join(__dirname, '..');
const ARMOR_LUA = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'armor.lua');
const BUNDLE = path.join(__dirname, 'bundles', 'breeds_bundle.lua');

const TEST = `
local checked, bad_zone, bad_armor = 0, 0, 0
local samples = {}

-- Added for the best-zone section (the older parts use print + counters).
local pivot_checks, pivot_failures = 0, 0

local function check(label, got, want)
	pivot_checks = pivot_checks + 1
	if got ~= want then
		pivot_failures = pivot_failures + 1
		print(string.format("  FAIL %-52s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-52s %s", label, tostring(got)))
	end
end

local function run(breeds, expected, label)
	for bname, exp in pairs(expected) do
		local breed = breeds[bname]
		if breed then
			for actor, e in pairs(exp) do
				checked = checked + 1
				local zone, override = armor.zone_for_actor(breed, actor)
				local atype, zname, source = armor.armor_type_for_actor(breed, actor)

				if zone ~= e.zone then
					bad_zone = bad_zone + 1
					if #samples < 10 then samples[#samples + 1] = string.format("%s ZONE %s.%s got=%s want=%s", label, bname, actor, tostring(zone), tostring(e.zone)) end
				end
				if atype ~= e.armor then
					bad_armor = bad_armor + 1
					if #samples < 10 then samples[#samples + 1] = string.format("%s ARMOR %s.%s got=%s want=%s", label, bname, actor, tostring(atype), tostring(e.armor)) end
				end
			end
		end
	end
	print(string.format("[%s] actor slots checked=%d  zone mismatches=%d  armour mismatches=%d", label, checked, bad_zone, bad_armor))
end

run(bundle.breeds, bundle.expected, "actors as array set  ")
run(bundle.breeds_keyed, bundle.expected, "actors as keyed set  ")
for i = 1, #samples do print("   !! " .. samples[i]) end

print("")
print("== worked example: renegade_executor (armor_type=armored, head override=super_armor) ==")
local exec = bundle.breeds["renegade_executor"]
for _, actor in ipairs({ "c_head", "c_neck", "c_spine1", "c_hips", "c_leftleg", "r_afro", "c_rightfoot", "does_not_exist" }) do
	local zone = armor.zone_for_actor(exec, actor)
	local atype, zname, source = armor.armor_type_for_actor(exec, actor)
	print(string.format("   %-16s zone=%-12s armor=%-14s source=%s", actor, tostring(zone), tostring(atype), tostring(source)))
end

print("")
print("== armor_type_for_hitzone, the path target.lua now uses ==")
local zone_checks, zone_bad = 0, 0
for bname, breed in pairs(bundle.breeds) do
	local zones = breed.hit_zones
	local override = breed.hitzone_armor_override or {}
	if type(zones) == "table" then
		for _, zone in pairs(zones) do
			if type(zone) == "table" and type(zone.name) == "string" then
				zone_checks = zone_checks + 1
				local want = override[zone.name] or breed.armor_type
				local got = armor.armor_type_for_hitzone(breed, zone.name)
				if got ~= want then
					zone_bad = zone_bad + 1
					if zone_bad <= 5 then
						print(string.format("   !! %s zone=%s got=%s want=%s", bname, zone.name, tostring(got), tostring(want)))
					end
				end
			end
		end
	end
end
print(string.format("   zone lookups checked=%d  mismatches=%d", zone_checks, zone_bad))

print("")
print("== zones_with_armor / best_zone (the best-part pivot) ==")

-- A synthetic breed with a clear answer: head carapace, torso flak, plus an
-- override-only zone (shield) the hit_zones table never lists.
local pivot_breed = {
	name = "pivot_test",
	armor_type = "armored",
	hitzone_armor_override = { head = "super_armor", shield = "super_armor" },
	hit_zones = {
		{ actors = { "c_head" }, name = "head" },
		{ actors = { "c_hips" }, name = "torso" },
	},
}

local function flat_profile(values)
	return { armor_damage_modifier = { attack = values } }
end

local zones = armor.zones_with_armor(pivot_breed)
check("zones listed in display order", zones[1] and zones[1].zone, "head")
check("second zone", zones[2] and zones[2].zone, "torso")
check("override-only zone included", zones[3] and zones[3].zone, "shield")
check("armour read from override", zones[1].armor, "super_armor")
check("armour falls back to breed", zones[2].armor, "armored")

local bz, ba, bm = armor.best_zone(flat_profile({ armored = 0.5, super_armor = 2.0 }), pivot_breed, false, nil)
check("best zone for a head-hunter profile", bz, "head")
check("its armour", ba, "super_armor")
check("its modifier", bm, 2.0)

local bz2 = armor.best_zone(flat_profile({ armored = 1.5, super_armor = 0.1 }), pivot_breed, false, nil)
check("best zone flips with the profile", bz2, "torso")

local bz3 = armor.best_zone(flat_profile({ armored = 1.0, super_armor = 1.0 }), pivot_breed, false, nil)
check("tie resolves to the earlier zone (head)", bz3, "head")

local nozones = { name = "nozones", armor_type = "berserker" }
local bz4, ba4, bm4 = armor.best_zone(flat_profile({ berserker = 0.75 }), nozones, false, nil)
check("no zones -> nil zone", bz4, nil)
check("no zones -> breed armour", ba4, "berserker")
check("no zones -> breed modifier", bm4, 0.75)

-- Real data: every breed must yield at least one zone, and every zone it names
-- must resolve to an armour value. Companion-type breeds carry no armour at all
-- (and are rejected as aim targets anyway), so they are exempt from the second.
local no_zone_breeds, nil_armor_zones = 0, 0
for bname, breed in pairs(bundle.breeds) do
	local zs = armor.zones_with_armor(breed)
	if #zs == 0 then
		no_zone_breeds = no_zone_breeds + 1
		if no_zone_breeds <= 5 then print("   !! breed without zones: " .. tostring(bname)) end
	end
	if type(breed.armor_type) == "string" then
		for i = 1, #zs do
			if type(zs[i].armor) ~= "string" then
				nil_armor_zones = nil_armor_zones + 1
			end
		end
	end
end
check("every real breed has at least one zone", no_zone_breeds, 0)
check("every zone resolves to an armour value", nil_armor_zones, 0)

print(string.format("   pivot checks=%d failures=%d", pivot_checks, pivot_failures))

print("")
print("== a breed with several overrides ==")
for bname, breed in pairs(bundle.breeds) do
	local ov = breed.hitzone_armor_override
	if ov then
		local n = 0
		for _ in pairs(ov) do n = n + 1 end
		if n >= 3 then
			print("   " .. bname .. " overrides:")
			for z, a in pairs(ov) do print(string.format("      %-22s -> %s", z, tostring(a))) end
			break
		end
	end
end

if bad_zone > 0 or bad_armor > 0 or pivot_failures > 0 then os.exit(1) end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	'local Localize = function(key) return key end',
	'local armor = (function()',
	fs.readFileSync(ARMOR_LUA, 'utf8'),
	'end)()',
	'local bundle = (function()',
	fs.readFileSync(BUNDLE, 'utf8'),
	'end)()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
