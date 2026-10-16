// Tests for live_stats.lua -- the live, composed damage stats.
//
// Two things here are not invented:
//   * the rending cases are the worked examples from the game's own talent text
//     ("25% against carapace plus 15% rending becomes 40%", and "already 90%, plus
//     15% rending, becomes 1 + (15%+90%-1)/4 = 101.25%");
//   * the "at base contributes nothing" section is a regression for the first live
//     build, which showed "+200% rending / +400% weakspot" on a character with no
//     such buffs -- because `stat_buffs` starts every multiplier-style entry at its
//     base (1.0), not at zero.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'live_stats.lua');

const STUBS = (metadata) => `
-- ============================ engine stubs ============================
BASE_VALUES = {
	rending_multiplier = 1,
	melee_rending_multiplier = 1,
	ranged_rending_multiplier = 1,
	finesse_modifier_bonus = 1,
	melee_finesse_modifier_bonus = 1,
	ranged_finesse_modifier_bonus = 1,
	critical_strike_damage = 1,
	melee_critical_strike_damage = 1,
	ranged_critical_strike_damage = 1,
	weakspot_damage = 0,
	melee_weakspot_damage = 0,
	ranged_weakspot_damage = 0,
	critical_strike_chance = 0,
	melee_critical_strike_chance = 0,
	ranged_critical_strike_chance = 0,
}

STATS = {}
HANDLING = nil
ARCHETYPE_BASE = 0.075

-- Stands in for scripts/settings/buff/buff_settings.
local REAL_REQUIRE = require
require = function (name)
	if name == "scripts/settings/buff/buff_settings" then
		${metadata
			? 'return { stat_buff_types = {}, stat_buff_type_base_values = BASE_VALUES }'
			: 'return nil'}
	end
	if REAL_REQUIRE then return REAL_REQUIRE(name) end
	return nil
end

ScriptUnit = {
	has_extension = function (unit, name)
		if not unit then return nil end
		if name == "buff_system" then return unit.buff end
		if name == "weapon_system" then return unit.weapon end
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
near("negative rending lowers it", live_stats.apply_rending(0.50, -0.1), 0.40)

print("")
print("== the regression: a stat sitting at its base contributes nothing ==")
-- Exactly the field report: no rending or weakspot buffs at all, yet the panel read
-- "+200% rending / +400% weakspot", because the multiplier-style entries were read
-- as raw bonuses instead of being measured against their base.
STATS = {
	rending_multiplier = 1,
	melee_rending_multiplier = 1,
	ranged_rending_multiplier = 1,
	finesse_modifier_bonus = 1,
	melee_finesse_modifier_bonus = 1,
	ranged_finesse_modifier_bonus = 1,
	critical_strike_damage = 1,
	melee_critical_strike_damage = 1,
	ranged_critical_strike_damage = 1,
	weakspot_damage = 0,
	melee_weakspot_damage = 0,
	ranged_weakspot_damage = 0,
	critical_strike_chance = 0,
	melee_critical_strike_chance = 0,
	ranged_critical_strike_chance = 0,
}
HANDLING = { critical_strike = { chance_modifier = 0 } }

local unit = make_unit(STATS, HANDLING)
local player = make_player(ARCHETYPE_BASE)
local unbuffed = live_stats.snapshot(unit, player, false)

near("unbuffed rending is 0", unbuffed.rending, 0)
near("unbuffed weakspot is 0", unbuffed.weakspot, 0)
near("unbuffed finesse is 0", unbuffed.finesse, 0)
near("unbuffed crit damage is 1", unbuffed.crit_damage, 1)
near("unbuffed crit chance is just the archetype base", unbuffed.crit_chance, ARCHETYPE_BASE)

-- The crit line is informational (the archetype base is always there), but a bonus
-- that is not being granted must not appear.
local unbuffed_lines = live_stats.panel_lines(unbuffed)
local unbuffed_keys = {}
for i = 1, #unbuffed_lines do
	unbuffed_keys[unbuffed_lines[i].key] = true
end
check("no rending line when nothing grants rending", unbuffed_keys.live_rending, nil)
check("no weakspot line when nothing grants it", unbuffed_keys.live_weakspot, nil)
check("crit is still reported", unbuffed_keys.live_crit, true)
near("and the number stays the armour table", live_stats.effective_modifier(0.69, unbuffed, true), 0.69)

print("")
print("== snapshot: deltas, per weapon class ==")
STATS = {
	rending_multiplier = 1.05,
	melee_rending_multiplier = 1.10,
	ranged_rending_multiplier = 1.20,
	weakspot_damage = 0.10,
	melee_weakspot_damage = 0.05,
	ranged_weakspot_damage = 0.15,
	finesse_modifier_bonus = 1.30,
	melee_finesse_modifier_bonus = 1.02,
	ranged_finesse_modifier_bonus = 1.04,
	critical_strike_chance = 0.05,
	melee_critical_strike_chance = 0.025,
	ranged_critical_strike_chance = 0.075,
	critical_strike_damage = 1.5,
	melee_critical_strike_damage = 1.2,
	ranged_critical_strike_damage = 1.3,
}
HANDLING = { critical_strike = { chance_modifier = 0.01 } }

-- Rebuilt because make_unit captured the previous table.
unit = make_unit(STATS, HANDLING)

local melee = live_stats.snapshot(unit, player, false)
check("melee snapshot is available", melee.available, true)
near("melee rending = generic + melee", melee.rending, 0.15)
near("melee weakspot = generic + melee + finesse", melee.weakspot, 0.10 + 0.05 + 0.30 + 0.02)
near("melee crit damage", melee.crit_damage, 1 + 0.5 + 0.2)
near("melee crit chance = base + generic + melee + handling", melee.crit_chance, 0.075 + 0.05 + 0.025 + 0.01)

local ranged = live_stats.snapshot(unit, player, true)
near("ranged rending = generic + ranged", ranged.rending, 0.25)
near("ranged weakspot = generic + ranged + finesse", ranged.weakspot, 0.10 + 0.15 + 0.30 + 0.04)
near("ranged crit chance = base + generic + ranged + handling", ranged.crit_chance, 0.075 + 0.05 + 0.075 + 0.01)

print("")
print("== raw readings are kept, so a surprising number can be explained ==")
local rending_raw = melee.raw and melee.raw.rending_multiplier
check("raw value recorded", rending_raw and rending_raw.value, 1.05)
check("base recorded", rending_raw and rending_raw.base, 1)
near("delta recorded", rending_raw and rending_raw.delta, 0.05)
local weakspot_raw = melee.raw and melee.raw.weakspot_damage
check("an additive stat's base is 0", weakspot_raw and weakspot_raw.base, 0)

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

local raising = live_stats.snapshot({
	buff = { stat_buffs = function () error("engine said no") end },
}, player, false)
check("a raising stat table -> unavailable", raising.available, false)

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
print("== factors: the same number, split into the pieces it was built from ==")
local factor_parts = live_stats.factors(0.69, snapshot, true)
near("table value is untouched", factor_parts.table, 0.69)
near("rended value has rending applied", factor_parts.rended, 0.84)
near("weakspot multiplier", factor_parts.weakspot, 1.25)
near("value is the product", factor_parts.value, 0.84 * 1.25)
near("and matches effective_modifier", factor_parts.value, live_stats.effective_modifier(0.69, snapshot, true))

local body_factors = live_stats.factors(0.69, snapshot, false)
near("a body part gets no weakspot multiplier", body_factors.weakspot, 1)
near("so its value is the rended one", body_factors.value, 0.84)

local no_live_factors = live_stats.factors(0.69, { available = false }, true)
near("no live stats -> the table value", no_live_factors.value, 0.69)
near("and a neutral weakspot multiplier", no_live_factors.weakspot, 1)
check("a non-number base yields nothing", live_stats.factors(nil, snapshot, true), nil)

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

// The fallback path only runs when the game's metadata is missing, which cannot be
// toggled after load, so it gets its own state.
const FALLBACK_TEST = `
local checks, failures = 0, 0
local function near(label, got, want)
	checks = checks + 1
	if type(got) ~= "number" or math.abs(got - want) > 0.0001 then
		failures = failures + 1
		print(string.format("  FAIL %-56s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-56s %s", label, tostring(got)))
	end
end

print("== no metadata: names decide the base, and 'no buffs' still means zero ==")
check_metadata = live_stats.stat_type("rending_multiplier")
print("  (stat_type with no metadata: " .. tostring(check_metadata) .. ")")

-- Without the game's table the module falls back to the naming convention:
-- *_multiplier and *_modifier_bonus are neutral at 1, everything else at 0.
local stats = {
	rending_multiplier = 1,
	melee_rending_multiplier = 1,
	finesse_modifier_bonus = 1,
	melee_finesse_modifier_bonus = 1,
	weakspot_damage = 0,
	melee_weakspot_damage = 0,
	critical_strike_damage = 1,
	melee_critical_strike_damage = 1,
}
local unit = { buff = { stat_buffs = function () return stats end } }
local snapshot = live_stats.snapshot(unit, nil, false)
near("unbuffed rending still reads 0", snapshot.rending, 0)
near("unbuffed weakspot still reads 0", snapshot.weakspot, 0)
near("unbuffed crit damage still reads 1", snapshot.crit_damage, 1)

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
`;

function run(prelude, body, label) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  const chunk = [
    prelude,
    'local live_stats = (function()',
    fs.readFileSync(SRC, 'utf8'),
    'end)()',
    body,
  ].join('\n');

  if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
    console.error('LUA ERROR (' + label + '): ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
  }
}

run(STUBS(true), TEST, 'with metadata');
run(STUBS(false), FALLBACK_TEST, 'without metadata');
