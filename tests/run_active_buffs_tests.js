// Tests for active_buffs.lua -- the buffs running on a unit, as the game's own bar
// would list them.
//
// The filter and the accessors are not invented: the game's buff bar shows a buff
// when its template carries a hud_icon and is not marked hidden, reads
// visual_stack_count for the numeral, and duration_progress for the sweep (1 at the
// start, 0 as it expires).
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'active_buffs.lua');

const STUBS = `
ScriptUnit = {
	has_extension = function (unit, name)
		if not unit or name ~= "buff_system" then return nil end
		return unit.buff_extension
	end,
}

-- A stand-in for a buff instance: the game's instances are objects with methods.
local function make_buff(template, options)
	options = options or {}
	return {
		template = function () return template end,
		duration = function () return options.duration end,
		duration_progress = function () return options.progress end,
		visual_stack_count = function () return options.visual_stacks end,
		stack_count = function () return options.stacks end,
	}
end

local function make_unit(buffs, raising)
	return {
		buff_extension = {
			buffs = function ()
				if raising then error("engine said no") end
				return buffs
			end,
		},
	}
end
`;

const TEST = `
local checks, failures = 0, 0
local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("  FAIL %-58s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-58s %s", label, tostring(got)))
	end
end

local function near(label, got, want)
	checks = checks + 1
	if type(got) ~= "number" or math.abs(got - want) > 0.01 then
		failures = failures + 1
		print(string.format("  FAIL %-58s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-58s %s", label, tostring(got)))
	end
end

local ICON = "content/ui/textures/icons/buffs/hud/test"

print("== the filter is the native bar's ==")
local mixed = {
	make_buff({ name = "shown", hud_icon = ICON }, { duration = 10, progress = 0.42, visual_stacks = 3 }),
	make_buff({ name = "hidden", hud_icon = ICON, hide_icon_in_hud = true }, { duration = 10, progress = 1 }),
	make_buff({ name = "no_icon" }, { duration = 10, progress = 1 }),
	make_buff({ name = "empty_icon", hud_icon = "" }, { duration = 10, progress = 1 }),
}

local listed = active_buffs.list(make_unit(mixed))
check("only the icon-bearing, non-hidden buff is listed", #listed, 1)
check("and it is the right one", listed[1] and listed[1].template_name, "shown")
check("its icon comes from the template", listed[1] and listed[1].icon, ICON)

print("")
print("== stacks and time ==")
check("visual_stack_count is preferred", listed[1] and listed[1].stacks, 3)
near("remaining = duration * progress", listed[1] and listed[1].remaining, 4.2)
near("progress is passed through for the bar", listed[1] and listed[1].progress, 0.42)

local fallback = active_buffs.list(make_unit({
	make_buff({ name = "raw_stacks", hud_icon = ICON }, { stacks = 7 }),
}))
check("raw stack_count is the fallback", fallback[1] and fallback[1].stacks, 7)

local bare = active_buffs.list(make_unit({
	make_buff({ name = "bare", hud_icon = ICON }, {}),
}))
check("no stack accessor -> 1", bare[1] and bare[1].stacks, 1)
check("no duration -> no remaining time", bare[1] and bare[1].remaining, nil)
check("no duration -> no progress", bare[1] and bare[1].progress, nil)

print("")
print("== ordering: expiring soonest first, permanent last ==")
local ordered = active_buffs.list(make_unit({
	make_buff({ name = "permanent", hud_icon = ICON }, { stacks = 1 }),
	make_buff({ name = "slow", hud_icon = ICON }, { duration = 20, progress = 1 }),
	make_buff({ name = "urgent", hud_icon = ICON }, { duration = 5, progress = 0.2 }),
}))
check("three entries", #ordered, 3)
check("the one about to expire is first", ordered[1] and ordered[1].template_name, "urgent")
check("then the longer one", ordered[2] and ordered[2].template_name, "slow")
check("and the permanent one is last", ordered[3] and ordered[3].template_name, "permanent")

print("")
print("== it never raises ==")
check("no unit", #active_buffs.list(nil), 0)
check("a unit with no buff extension", #active_buffs.list({}), 0)
check("a buff extension that errors", #active_buffs.list(make_unit({}, true)), 0)

local bad_template = active_buffs.list(make_unit({
	{
		template = function () error("no template") end,
	},
	make_buff({ name = "fine", hud_icon = ICON }, { duration = 1, progress = 1 }),
}))
check("a buff whose template raises is skipped", #bad_template, 1)
check("and the rest still resolve", bad_template[1] and bad_template[1].template_name, "fine")

print("")
print("== summary line: only what can be named ==")
local names = { adamant_crit_chance_on_kill_effect = "Energy Cycle" }
check("resolved name, stacks and seconds", active_buffs.summary(
	{ { template_name = "adamant_crit_chance_on_kill_effect", stacks = 3, remaining = 4.2 } }, 4, names
), "Energy Cycle x3 4s")
check("a stack of 1 is not printed", active_buffs.summary(
	{ { template_name = "adamant_crit_chance_on_kill_effect", stacks = 1, remaining = 2 } }, 4, names
), "Energy Cycle 2s")
check("a permanent buff shows no seconds", active_buffs.summary(
	{ { template_name = "adamant_crit_chance_on_kill_effect", stacks = 2 } }, 4, names
), "Energy Cycle x2")

-- An unnamed buff must never print its internal id. This is the regression that put
-- "veteran toughness on elite kill effect" across the HUD.
check("an unnamed buff is counted, not printed", active_buffs.summary(
	{ { template_name = "veteran_toughness_on_elite_kill_effect" }, { template_name = "adamant_crit_chance_on_kill_effect" } },
	4, names
), "Energy Cycle  +1")
check("nothing nameable -> an empty line, not a count", active_buffs.summary(
	{ { template_name = "some_internal_id" } }, 4, {}
), "")
check("limit is respected", active_buffs.summary(
	{ { template_name = "a" }, { template_name = "b" }, { template_name = "c" } }, 2, { a = "A" }
), "A  +1")
check("nothing -> empty", active_buffs.summary({}, 4, {}), "")

print("")
print("== resolved_name / display_name ==")
check("a known buff resolves", active_buffs.resolved_name({ template_name = "x" }, { x = "Name" }), "Name")
check("an unknown one does not", active_buffs.resolved_name({ template_name = "x" }, {}), nil)
check("an empty mapping counts as unknown", active_buffs.resolved_name({ template_name = "x" }, { x = "" }), nil)
check("display_name still falls back to the id", active_buffs.display_name({ template_name = "x_y" }, {}), "x y")
check("display_name prefers the resolved one", active_buffs.display_name({ template_name = "x" }, { x = "Name" }), "Name")
check("a missing template name is safe", active_buffs.display_name({}, {}), "?")
check("nil entries are safe", active_buffs.display_name(nil, nil), "?")

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	STUBS,
	'local active_buffs = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
