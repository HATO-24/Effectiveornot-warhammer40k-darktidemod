// Runs the shipped armor.lua against all 905 real damage profiles extracted from
// the game, comparing what it resolves against an expectation derived
// independently from the raw data shape.
//
// This exists because two parsing bugs already slipped through static review:
// ranged tables being banded by distance, and `targets` being keyed by cleave
// index with disagreeing values. Both were only findable by running the code
// against real data.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const MOD = path.join(__dirname, '..');
const ARMOR_LUA = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'armor.lua');
const BUNDLE = path.join(__dirname, 'bundles', 'profiles_bundle.lua');

const TEST = `
local ARMOR_TYPES = { "unarmored", "armored", "berserker", "resistant", "disgustingly_resilient", "super_armor" }

local function run(profiles, expected, label)
	local mismatch_melee, mismatch_ranged = 0, 0
	local resolved_melee, resolved_ranged = 0, 0
	local inconsistent, far_fail, count = 0, 0, 0
	local bad, bands = {}, {}

	for name, exp in pairs(expected) do
		local prof = profiles[name]
		if prof then
			count = count + 1

			local _, m = armor.modifier(prof, "unarmored", false)
			local _, r, source_key, band = armor.modifier(prof, "unarmored", true)
			local got_melee = type(m) == "number"
			local got_ranged = type(r) == "number"

			if got_melee ~= exp.melee then
				mismatch_melee = mismatch_melee + 1
				if #bad < 8 then bad[#bad + 1] = label .. " MELEE " .. name .. " expected=" .. tostring(exp.melee) .. " got=" .. tostring(got_melee) end
			end
			if got_ranged ~= exp.ranged then
				mismatch_ranged = mismatch_ranged + 1
				if #bad < 8 then bad[#bad + 1] = label .. " RANGED " .. name .. " expected=" .. tostring(exp.ranged) .. " got=" .. tostring(got_ranged) end
			end

			if got_melee then resolved_melee = resolved_melee + 1 end
			if got_ranged then
				resolved_ranged = resolved_ranged + 1
				local key = tostring(band) .. "/" .. tostring(source_key)
				bands[key] = (bands[key] or 0) + 1

				-- Both distance bands must resolve when the table is banded.
				local _, far = armor.modifier(prof, "unarmored", true, "far")
				if type(far) ~= "number" then far_fail = far_fail + 1 end
			end

			-- Every armour type must agree about whether this profile resolves.
			local use_ranged = exp.ranged and not exp.melee
			local present, absent = 0, 0
			for i = 1, #ARMOR_TYPES do
				local _, v = armor.modifier(prof, ARMOR_TYPES[i], use_ranged)
				if type(v) == "number" then present = present + 1 else absent = absent + 1 end
			end
			if present > 0 and absent > 0 then inconsistent = inconsistent + 1 end
		end
	end

	print(string.format("[%s] profiles=%d", label, count))
	print(string.format("   melee  resolved=%d mismatches=%d", resolved_melee, mismatch_melee))
	print(string.format("   ranged resolved=%d mismatches=%d  (far-band failures=%d)", resolved_ranged, mismatch_ranged, far_fail))
	print(string.format("   profiles where armour types disagree=%d", inconsistent))
	for i = 1, #bad do print("   !! " .. bad[i]) end
	local parts = {}
	for k, v in pairs(bands) do parts[#parts + 1] = k .. "=" .. v end
	table.sort(parts)
	print("   band/source histogram: " .. table.concat(parts, "  "))
	print("")
end

run(bundle.profiles, bundle.expected, "targets as string keys")
run(bundle.profiles_numeric, bundle.expected, "targets as numeric keys")

-- Spot-check a real ranged profile end to end.
local probe = bundle.profiles["adamant_grenade_impact"]
if probe then
	print("adamant_grenade_impact (ranged, banded):")
	for i = 1, #ARMOR_TYPES do
		local at = ARMOR_TYPES[i]
		local _, near = armor.modifier(probe, at, true, "near")
		local _, far = armor.modifier(probe, at, true, "far")
		print(string.format("   %-24s near=%s far=%s", at, tostring(near), tostring(far)))
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
