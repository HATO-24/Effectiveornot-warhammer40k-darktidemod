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

local actionable = armor.zones_with_armor(pivot_breed, true)
check("actionable list drops the shield", #actionable, 2)
check("actionable list keeps head first", actionable[1] and actionable[1].zone, "head")

local bz, ba, bm = armor.best_zone(flat_profile({ armored = 0.5, super_armor = 2.0 }), pivot_breed, false, nil)
check("best zone for a head-hunter profile", bz, "head")
check("its armour", ba, "super_armor")
check("its modifier", bm, 2.0)

local bz2 = armor.best_zone(flat_profile({ armored = 1.5, super_armor = 0.1 }), pivot_breed, false, nil)
check("best zone flips with the profile", bz2, "torso")

local bz3 = armor.best_zone(flat_profile({ armored = 1.0, super_armor = 1.0 }), pivot_breed, false, nil)
check("tie resolves to the earlier zone (head)", bz3, "head")

-- A shield being the best armour on paper must never be suggested: nobody aims at
-- a bulwark's shield on purpose.
local shield_breed = {
	name = "shield_test",
	armor_type = "armored",
	hitzone_armor_override = { shield = "super_armor" },
	hit_zones = {
		{ actors = { "c_head" }, name = "head" },
		{ actors = { "c_shield" }, name = "shield" },
	},
}
local bz_shield = armor.best_zone(flat_profile({ armored = 0.4, super_armor = 3.0 }), shield_breed, false, nil)
check("shield is never the suggested part", bz_shield, "head")

-- A breed whose only parts are non-actionable still gets an answer from its own
-- zone list rather than nothing.
local tail_breed = {
	name = "tail_test",
	armor_type = "armored",
	hit_zones = {
		{ actors = { "c_tail" }, name = "upper_tail" },
	},
}
local bz_tail = armor.best_zone(flat_profile({ armored = 1.0 }), tail_breed, false, nil)
check("non-actionable-only breed falls back to its zones", bz_tail, "upper_tail")

-- Weakspots come from the breed's own hit_zone_weakspot_types. They are marked
-- in the readout, never priced into the number: the extra damage depends on the
-- attacker's finesse bonuses, which are not part of the armour table.
local ws_breed = {
	name = "ws_test",
	armor_type = "armored",
	hitzone_armor_override = { head = "super_armor" },
	hit_zone_weakspot_types = { head = "headshot" },
	hit_zones = {
		{ actors = { "c_head" }, name = "head" },
		{ actors = { "c_hips" }, name = "torso" },
	},
}
local ws_zones = armor.zones_with_armor(ws_breed, true)
check("head carries its weakspot type", ws_zones[1] and ws_zones[1].weakspot, "headshot")
check("torso is not a weakspot", ws_zones[2] and ws_zones[2].weakspot, nil)

local breeds_with_weakspot = 0
for _, breed in pairs(bundle.breeds) do
	local zs = armor.zones_with_armor(breed, true)
	for i = 1, #zs do
		if zs[i].weakspot then
			breeds_with_weakspot = breeds_with_weakspot + 1

			break
		end
	end
end
check("most real breeds expose a weakspot part", breeds_with_weakspot >= 40, true)

-- The hound's weakspot is its tail, which is deliberately not an "actionable"
-- part: it must still be present in the full zone list.
local hound_tail_ws = nil
local hound = bundle.breeds["chaos_armored_hound"]
if hound then
	local all = armor.zones_with_armor(hound, false)
	for i = 1, #all do
		if all[i].zone == "hound_tail" then
			hound_tail_ws = all[i].weakspot
		end
	end
end
check("hound tail is a weakspot in the data", hound_tail_ws, "weakspot")

-- Coverage: every zone name the real breed data mentions must exist in the
-- display order, or it is silently dropped from the readout. hound_tail was
-- missing once, which is how the hound's weakspot stopped being reported.
local known_zones = {}
for i = 1, #armor.ZONE_ORDER do
	known_zones[armor.ZONE_ORDER[i]] = true
end

local dropped = {}
for bname, breed in pairs(bundle.breeds) do
	local mentioned = {}
	local zones = breed.hit_zones
	if type(zones) == "table" then
		for _, zone in pairs(zones) do
			if type(zone) == "table" and type(zone.name) == "string" then
				mentioned[zone.name] = true
			end
		end
	end
	for source in pairs({ breed.hitzone_armor_override, breed.hit_zone_weakspot_types }) do
		if type(source) == "table" then
			for zone_name in pairs(source) do
				if type(zone_name) == "string" then
					mentioned[zone_name] = true
				end
			end
		end
	end
	for zone_name in pairs(mentioned) do
		if not known_zones[zone_name] then
			dropped[#dropped + 1] = tostring(bname) .. ":" .. zone_name
		end
	end
end

table.sort(dropped)
if #dropped > 8 then
	-- Only a few at a time; the count is the assertion.
	local trimmed = {}
	for i = 1, 8 do trimmed[i] = dropped[i] end
	print("   !! zones missing from ZONE_ORDER: " .. table.concat(trimmed, ", "))
end
check("no real zone is missing from ZONE_ORDER", #dropped, 0)

-- scored_parts: the readout lists every part and takes its row colour from the best
-- of them. Scoring goes through the caller because rending favours hard armour and
-- the weakspot multiplier only applies to weakspot parts, so "best" is a different
-- question from the raw table's.
local function scorer(profile_values)
	return function (zone)
		local _, base = armor.modifier(flat_profile(profile_values), zone.armor, false, nil)

		return base and base * (zone.weakspot and 2.0 or 1.0), base
	end
end

local table_parts, table_best = armor.scored_parts(pivot_breed, scorer({ armored = 0.5, super_armor = 2.0 }))
check("one part per aimable zone", #table_parts, 2)
check("listed in display order", table_parts[1] and table_parts[1].zone, "head")
check("the shield is not among them", table_parts[3], nil)
check("best by the raw table", table_best and table_best.zone, "head")
check("base is kept alongside the score", table_best and table_best.base, 2.0)

-- A weakspot multiplier large enough to flip which part wins, on a breed that
-- actually declares the head a weakspot.
local flip_breed = {
	name = "flip_test",
	armor_type = "armored",
	hitzone_armor_override = { head = "super_armor" },
	hit_zone_weakspot_types = { head = "headshot" },
	hit_zones = {
		{ actors = { "c_head" }, name = "head" },
		{ actors = { "c_hips" }, name = "torso" },
	},
}
local flip_parts, flip_best = armor.scored_parts(flip_breed, scorer({ armored = 1.0, super_armor = 0.6 }))
check("live bonuses can flip the best part", flip_best and flip_best.zone, "head")
check("while the base value still shows the table", flip_best and flip_best.base, 0.6)
check("and both parts are still listed", #flip_parts, 2)

-- Without the weakspot flag the raw table decides, which is why the flag travels
-- through the scoring.
local plain_best = select(2, armor.scored_parts(pivot_breed, scorer({ armored = 1.0, super_armor = 0.6 })))
check("no weakspot flag -> the table decides", plain_best and plain_best.zone, "torso")

local no_score_parts, no_score_best = armor.scored_parts(pivot_breed, nil)
check("no score function -> no parts", #no_score_parts, 0)
check("no score function -> no best", no_score_best, nil)

local silent_parts, silent_best = armor.scored_parts(pivot_breed, function () return nil end)
check("a score with no opinion -> no parts", #silent_parts, 0)
check("a score with no opinion -> no best", silent_best, nil)

-- The breed's own per-zone damage multiplier (hitzone_damage_multiplier). It is a
-- big factor, not a rounding detail: a hound takes x3 on every part from melee and
-- x5 on its tail, an armoured infected takes x0.2 on the legs from ranged.
local precedence = {
	name = "mult_test",
	armor_type = "armored",
	hitzone_damage_multiplier = {
		default = { head = 0.5, torso = 0.25 },
		melee = { head = 3 },
	},
}
check("a class table wins over default", armor.hitzone_damage_multiplier(precedence, "head", false), 3)
check("default fills in what the class does not name", armor.hitzone_damage_multiplier(precedence, "torso", false), 0.25)
check("and applies to the other class too", armor.hitzone_damage_multiplier(precedence, "torso", true), 0.25)
check("a class-specific entry only applies to that class", armor.hitzone_damage_multiplier(precedence, "head", true), 0.5)
check("an unlisted zone is neutral", armor.hitzone_damage_multiplier(precedence, "upper_left_arm", false), 1)
check("a breed with no table is neutral", armor.hitzone_damage_multiplier({ name = "x" }, "head", false), 1)
check("a nil breed is neutral", armor.hitzone_damage_multiplier(nil, "head", false), 1)

-- Real data: the hound's tail is its big payoff for melee, and the executor -- the
-- enemy in the reference screenshots -- has no melee table at all, so its melee
-- numbers must not move.
local hound_mult = bundle.breeds["chaos_armored_hound"]
check("hound melee tail is x5", armor.hitzone_damage_multiplier(hound_mult, "hound_tail", false), 5)
check("hound melee centre mass is x1.5", armor.hitzone_damage_multiplier(hound_mult, "center_mass", false), 1.5)
check("hound has no ranged table of its own", armor.hitzone_damage_multiplier(hound_mult, "hound_tail", true), 1)

local executor_mult = bundle.breeds["renegade_executor"]
check("executor melee torso is untouched", armor.hitzone_damage_multiplier(executor_mult, "torso", false), 1)
check("executor ranged legs are halved", armor.hitzone_damage_multiplier(executor_mult, "lower_left_leg", true), 0.5)

-- Coverage: every multiplier in the real data must read back as a finite number,
-- and the melee tables must actually be doing something.
local melee_non_neutral, tables_seen = 0, 0
for _, breed in pairs(bundle.breeds) do
	local by_class = breed.hitzone_damage_multiplier
	if type(by_class) == "table" then
		tables_seen = tables_seen + 1
		for class_name, class_table in pairs(by_class) do
			if type(class_table) == "table" then
				for zone_name, expected in pairs(class_table) do
					local got = armor.hitzone_damage_multiplier(breed, zone_name, class_name == "ranged")
					if type(got) ~= "number" or got ~= got then
						print("   !! non-numeric multiplier for " .. tostring(zone_name))
					end
					if class_name == "melee" and expected ~= 1 then
						melee_non_neutral = melee_non_neutral + 1
					end
				end
			end
		end
	end
end
check("real breeds carry a multiplier table", tables_seen >= 40, true)
check("melee multipliers are mostly non-neutral", melee_non_neutral >= 100, true)

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
