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
