// Tests for live_stats.lua -- the live, composed damage stats.
//
// The two rending cases are not invented: they are the worked examples in the
// game's own talent descriptions ("25% against carapace plus 15% rending becomes
// 40%", and "already 90%, plus 15% rending, becomes 1 + (15%+90%-1)/4 = 101.25%").
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'live_stats.lua');

const STUBS = `
-- ============================ engine stubs ============================
STATS = {}
HANDLING = nil
ARCHETYPE_BASE = 0.075
HAS_BUFF_EXTENSION = true

ScriptUnit = {
	has_extension = function (unit, name)
		if not unit then return nil end
		if name == "buff_system" then
			if not HAS_BUFF_EXTENSION then return nil end
			return unit.buff
		end
		if name == "weapon_system" then
			return unit.weapon
		end
		return nil
	end,
}
`;

const TEST = `
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

local function near(label, got, want, tolerance)
	checks = checks + 1
	if type(got) ~= "number" or math.abs(got - want) > (tolerance or 0.0001) then
		failures = failures + 1
		print(string.format("  FAIL %-56s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-56s %s", label, tostring(got)))
	end
end

local function make_unit(stats, handling)
	return {
		buff = stats and { stat_buffs = function () return stats end } or nil,
		weapon = handling and { weapon_handling_template = function () return handling end } or nil,
	}
end

local function make_player(base)
	return {
		profile = function ()
			return { archetype = { base_critical_strike_chance = base } }
		end,
	}
end

print("== apply_rending: the two documented worked examples ==")
near("25% + 15% rending = 40%", live_stats.apply_rending(0.25, 0.15), 0.40)
near("90% + 15% -> 1 + 0.05/4 = 1.0125", live_stats.apply_rending(0.90, 0.15), 1.0125)
near("no rending leaves the base alone", live_stats.apply_rending(0.75, 0), 0.75)
check("nil base stays nil", live_stats.apply_rending(nil, 0.15), nil)
near("exactly 1.0 is not quartered", live_stats.apply_rending(0.85, 0.15), 1.0)

print("")
print("== snapshot: which keys apply to which weapon class ==")
STATS = {
	rending_multiplier = 0.05,
	melee_rending_multiplier = 0.10,
	ranged_rending_multiplier = 0.20,
	weakspot_damage = 0.10,
	melee_weakspot_damage = 0.05,
	ranged_weakspot_damage = 0.15,
	finesse_modifier_bonus = 0.30,
	melee_finesse_modifier_bonus = 0.02,
	ranged_finesse_modifier_bonus = 0.04,
	critical_strike_chance = 0.05,
	melee_critical_strike_chance = 0.025,
	ranged_critical_strike_chance = 0.075,
	critical_strike_damage = 1.5,
	melee_critical_strike_damage = 1.2,
	ranged_critical_strike_damage = 1.3,
}
HANDLING = { critical_strike = { chance_modifier = 0.01 } }

local unit = make_unit(STATS, HANDLING)
local player = make_player(ARCHETYPE_BASE)

local melee = live_stats.snapshot(unit, player, false)
check("melee snapshot is available", melee.available, true)
near("melee rending = generic + melee", melee.rending, 0.15)
near("melee weakspot = generic + melee + finesse", melee.weakspot, 0.10 + 0.05 + 0.30 + 0.02)
near("melee crit damage", melee.crit_damage, 1.5 + 1.2 - 1)
near("melee crit chance = base + generic + melee + handling", melee.crit_chance, 0.075 + 0.05 + 0.025 + 0.01)

local ranged = live_stats.snapshot(unit, player, true)
near("ranged rending = generic + ranged", ranged.rending, 0.25)
near("ranged weakspot = generic + ranged + finesse", ranged.weakspot, 0.10 + 0.15 + 0.30 + 0.04)
near("ranged crit chance = base + generic + ranged + handling", ranged.crit_chance, 0.075 + 0.05 + 0.075 + 0.01)

print("")
print("== snapshot: missing pieces degrade to neutral, never to an error ==")
local no_extension = live_stats.snapshot(make_unit(nil, nil), player, false)
check("no buff extension -> unavailable", no_extension.available, false)
near("unavailable snapshot has no rending", no_extension.rending, 0)

local no_handling = live_stats.snapshot(make_unit(STATS, nil), player, false)
near("missing weapon handling -> no handling bonus", no_handling.crit_chance, 0.075 + 0.05 + 0.025)

local no_archetype = live_stats.snapshot(unit, { profile = function () return {} end }, false)
check("no archetype base -> crit chance unknown", no_archetype.crit_chance, nil)
check("but the rest still resolves", no_archetype.available, true)

local clamped = live_stats.snapshot(make_unit({ critical_strike_chance = 5 }, HANDLING), player, false)
near("crit chance clamps to 1", clamped.crit_chance, 1)

print("")
print("== effective_modifier ==")
local snapshot = { available = true, rending = 0.15, weakspot = 0.25 }
near("no snapshot -> plain armour table", live_stats.effective_modifier(0.69, nil, false), 0.69)
near("unavailable snapshot -> plain armour table", live_stats.effective_modifier(0.69, { available = false }, true), 0.69)
near("rending lifts a body hit", live_stats.effective_modifier(0.69, snapshot, false), 0.84)
near("weakspot multiplies on top", live_stats.effective_modifier(0.69, snapshot, true), 0.84 * 1.25)
check("nil base stays nil", live_stats.effective_modifier(nil, snapshot, true), nil)
near("rending is quartered past 1.0", live_stats.effective_modifier(0.90, snapshot, false), 1 + (1.05 - 1) / 4)

print("")
print("== panel_lines: neutral values are left out ==")
local empty = live_stats.panel_lines({ available = true, rending = 0, weakspot = 0, crit_chance = 0, crit_damage = 1 })
check("nothing doing -> no lines", #empty, 0)

local full = live_stats.panel_lines({ available = true, rending = 0.15, weakspot = 0.25, crit_chance = 0.125, crit_damage = 1.5 })
check("three lines", #full, 3)
check("rending line key", full[1] and full[1].key, "live_rending")
check("rending line value", full[1] and full[1].value, "+15%")
check("weakspot line value", full[2] and full[2].value, "+25%")
check("crit line value", full[3] and full[3].value, "12.5%  x1.50")
check("unavailable snapshot -> no lines", #live_stats.panel_lines({ available = false }), 0)

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	STUBS,
	'local live_stats = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
