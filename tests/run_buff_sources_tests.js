// Tests for buff_sources.lua -- sorting the running buffs into the weapon element
// and the talent element, with the game's own names.
//
// The lookup chains are the ones verified against the game's data: a blessing's
// master item lists the buff templates it applies, and a buff template declares
// related_talents, each of which has a loc_talent_<id> key.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'buff_sources.lua');

const STUBS = `
-- Stand-in for the game's localiser: known keys resolve, unknown ones come back as
-- the key itself, which is exactly what the real one does.
LOC = {
	loc_talent_zealot_fanatic_rage = "Fanatical Rage",
	loc_talent_cryptic_precision_stance = "Precision Stance",
}
function Localize(key)
	return LOC[key] or key
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

local WEAPON_NAMES = { adamant_crit_chance_on_kill_effect = "Energy Cycle" }

print("== origin: weapon first, then talent ==")
local weapon_origin = buff_sources.origin({ template_name = "adamant_crit_chance_on_kill_effect" }, WEAPON_NAMES)
check("a blessing buff is weapon-sourced", weapon_origin and weapon_origin.source, "weapon")
check("and named after the blessing", weapon_origin and weapon_origin.name, "Energy Cycle")

local talent_origin = buff_sources.origin(
	{ template_name = "some_talent_buff", related_talents = { "zealot_fanatic_rage" } },
	WEAPON_NAMES
)
check("a talent buff is talent-sourced", talent_origin and talent_origin.source, "talent")
check("named through loc_talent_<id>", talent_origin and talent_origin.name, "Fanatical Rage")

local both = buff_sources.origin(
	{ template_name = "adamant_crit_chance_on_kill_effect", related_talents = { "zealot_fanatic_rage" } },
	WEAPON_NAMES
)
check("the weapon wins when both could name it", both and both.source, "weapon")

print("")
print("== the curated table is the third source ==")
local CURATED = { ogryn_block_increases_power_active_buff = "loc_talent_ogryn_block_increases_power_name" }
LOC.loc_talent_ogryn_block_increases_power_name = "Block Increases Power"

local curated_origin = buff_sources.origin({ template_name = "ogryn_block_increases_power_active_buff" }, {}, CURATED)
check("named through the curated table", curated_origin and curated_origin.name, "Block Increases Power")
check("and it counts as a talent buff", curated_origin and curated_origin.source, "talent")

-- The curated entry must not shadow a weapon blessing of the same template name.
local both_sources = buff_sources.origin(
	{ template_name = "ogryn_block_increases_power_active_buff" },
	{ ogryn_block_increases_power_active_buff = "Energy Cycle" },
	CURATED
)
check("a weapon name still wins", both_sources and both_sources.source, "weapon")

-- A curated entry whose key the localiser cannot resolve must fall through to the
-- id rule rather than producing a name out of nothing.
local broken_curated = buff_sources.origin(
	{ template_name = "some_talent_buff", related_talents = { "zealot_fanatic_rage" } },
	{},
	{ some_talent_buff = "loc_talent_does_not_exist" }
)
check("an unresolvable curated key falls through", broken_curated and broken_curated.name, "Fanatical Rage")

print("")
print("== nothing resolvable is not shown ==")
check("no name anywhere -> nil", buff_sources.origin({ template_name = "veteran_toughness_on_elite_kill_effect" }, {}), nil)
check("an unknown talent id -> nil", buff_sources.origin({ template_name = "x", related_talents = { "nope" } }, {}), nil)
check("no template name at all -> nil", buff_sources.origin({}, {}), nil)
check("nil entry -> nil", buff_sources.origin(nil, nil), nil)

print("")
print("== the localiser's own failure modes are rejected ==")
check("a key with no string is not a name", buff_sources.localize_key("loc_talent_missing"), nil)
check("an empty key is not a name", buff_sources.localize_key(""), nil)
check("nil is not a name", buff_sources.localize_key(nil), nil)
check("a real key resolves", buff_sources.localize_key("loc_talent_zealot_fanatic_rage"), "Fanatical Rage")
LOC.loc_talent_broken = "unlocalized"
check("the unlocalized placeholder is rejected", buff_sources.localize_key("loc_talent_broken"), nil)

print("")
print("== split ==")
local entries = {
	{ template_name = "adamant_crit_chance_on_kill_effect", stacks = 3, remaining = 4.2 },
	{ template_name = "some_talent_buff", related_talents = { "cryptic_precision_stance" }, stacks = 1 },
	{ template_name = "veteran_toughness_on_elite_kill_effect", stacks = 2 },
	{ template_name = "another_talent_buff", related_talents = { "nope", "zealot_fanatic_rage" } },
}
local weapon, talent, unnamed = buff_sources.split(entries, WEAPON_NAMES)

check("one weapon buff", #weapon, 1)
check("it keeps its stacks", weapon[1] and weapon[1].stacks, 3)
check("it carries the resolved name for display", weapon[1] and weapon[1].display, "Energy Cycle")

check("two talent buffs", #talent, 2)
check("the first is named", talent[1] and talent[1].display, "Precision Stance")
check("a later talent id is tried when the first fails", talent[2] and talent[2].display, "Fanatical Rage")

check("the unnammable one is counted, not listed", unnamed, 1)
check("and it is in neither list", #weapon + #talent + unnamed, #entries)
local empty_weapon, empty_talent, empty_unnamed = buff_sources.split(nil, nil)
check("split of nothing is safe", #empty_weapon + #empty_talent + empty_unnamed, 0)

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	STUBS,
	'local buff_sources = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
