-- live_stats.lua -- the player's live, already-composed damage stats.
--
-- How to read them: the engine aggregates every active buff into one flat table,
-- which is what
--
--     ScriptUnit.has_extension(player_unit, "buff_system"):stat_buffs()
--
-- returns. That is the same accessor dozens of mods in this collection use
-- (blitz_augur, crosshair_hud, DivisionHUD, debuff_indicator, ...), and
-- `BuffSettings.stat_buff_types` / `stat_buff_type_base_values` document how each
-- entry is meant to combine and what its neutral value is -- so nothing here has
-- to guess whether a given stat is additive or multiplicative.
--
-- What no table provides is how the pieces compose into final damage. The rules
-- below are therefore explicit and sourced:
--
--   * rending: additive to the armour modifier, with the excess above 1 counted at
--     a quarter. Both worked examples from the game's own talent descriptions come
--     out right (see apply_rending).
--   * weakspot: the sum of the weakspot / finesse stat bonuses. This is a MODEL,
--     not a documented formula -- which is why the hit log records the predicted
--     value next to the damage the game actually dealt, so it can be calibrated
--     against real hits instead of being trusted.

local live_stats = {}

-- The game's own metadata about each stat:
--
--   stat_buff_types[name]            "value" | "additive_multiplier" | "multiplicative_multiplier"
--   stat_buff_type_base_values[name] the value a stat sits at with no buffs at all
--
-- The second one is not optional. `stat_buffs` starts every entry at its BASE, not
-- at zero (NumericUI relies on exactly that: "Every stat starts at its base value,
-- as BuffExtensionBase._reset_stat_buffs leaves them"), so a multiplier-style stat
-- reads 1.0 when the player has no bonus at all. Treating that as "+100%" inflated
-- every row: the first live build showed "+200% rending / +400% weakspot" on a
-- character with no such buffs, purely from un-subtracted bases.
--
-- There is no pcall around the require: when the module is missing the whole file
-- degrades to "no live stats", which is the same path as an unreadable buff table.
local ok_settings, BuffSettings = pcall(require, "scripts/settings/buff/buff_settings")

if not ok_settings then
	BuffSettings = nil
end

-- Neutral values, used only when the game's own table does not cover a stat.
--
-- The key list comes first because the naming is not a reliable guide:
-- `critical_strike_damage` is a multiplier that happens to end in `_damage`
-- (InventoryStats' formula defaults it to 1 and subtracts one per entry, which only
-- makes sense if 1 is neutral), so the suffix rule would get it wrong.
local BASE_BY_KEY = {
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

local BASE_BY_SUFFIX = {
	-- Multiplier-style stats are neutral at 1.
	["_multiplier"] = 1,
	["_modifier_bonus"] = 1,
	-- Bonuses and chances are neutral at 0.
	["_damage"] = 0,
	["_chance"] = 0,
}

-- The value a stat is neutral at. The game's table wins when it has an entry.
function live_stats.base_value(key, fallback)
	local bases = BuffSettings and BuffSettings.stat_buff_type_base_values

	if type(bases) == "table" and type(bases[key]) == "number" then
		return bases[key]
	end

	return fallback or 0
end

function live_stats.stat_type(key)
	local types = BuffSettings and BuffSettings.stat_buff_types

	if type(types) == "table" and type(types[key]) == "string" then
		return types[key]
	end

	return nil
end

-- The fallback base, used only when the metadata is unavailable.
local function fallback_base(key)
	if BASE_BY_KEY[key] ~= nil then
		return BASE_BY_KEY[key]
	end

	for suffix, base in pairs(BASE_BY_SUFFIX) do
		if string.sub(key, -#suffix) == suffix then
			return base
		end
	end

	return 0
end

-- How much this stat is above neutral right now, plus the raw reading and the base
-- it was measured against (both kept for the diagnostics dump).
local function delta(stats, key)
	local raw = type(stats) == "table" and stats[key] or nil

	if type(raw) ~= "number" then
		return 0, nil, nil
	end

	local implicit = fallback_base(key)

	-- Multiplicative stats combine by product, so their contribution to a sum is
	-- still measured against the neutral 1.
	local base = live_stats.base_value(key, implicit)

	return raw - base, raw, base
end

local RENDING_GENERIC = "rending_multiplier"
local RENDING_MELEE = "melee_rending_multiplier"
local RENDING_RANGED = "ranged_rending_multiplier"

local WEAKSPOT_GENERIC = "weakspot_damage"
local WEAKSPOT_MELEE = "melee_weakspot_damage"
local WEAKSPOT_RANGED = "ranged_weakspot_damage"

-- Finesse raises both crit damage and weakspot damage (see CharacterStats, which
-- groups finesse_modifier_bonus under exactly those two headings).
local FINESSE_GENERIC = "finesse_modifier_bonus"
local FINESSE_MELEE = "melee_finesse_modifier_bonus"
local FINESSE_RANGED = "ranged_finesse_modifier_bonus"

local CRIT_DAMAGE_GENERIC = "critical_strike_damage"
local CRIT_DAMAGE_MELEE = "melee_critical_strike_damage"
local CRIT_DAMAGE_RANGED = "ranged_critical_strike_damage"

local CRIT_CHANCE_GENERIC = "critical_strike_chance"
local CRIT_CHANCE_MELEE = "melee_critical_strike_chance"
local CRIT_CHANCE_RANGED = "ranged_critical_strike_chance"

-- Rending is added straight onto the armour modifier, and only the part that
-- pushes the result past 1.0 is quartered.
--
-- The game's own talent text gives both cases, and this reproduces them:
--   "25% against carapace, +15% rending, becomes 25+15=40%"   -> 0.25 + 0.15 = 0.40
--   "already 90%, +15% rending -> 1 + (15%+90%-1)/4 = 101.25%" -> 1 + 0.05/4
function live_stats.apply_rending(base_modifier, rending)
	if type(base_modifier) ~= "number" then
		return nil
	end

	if type(rending) ~= "number" or rending == 0 then
		return base_modifier
	end

	local raw = base_modifier + rending

	if raw > 1 then
		return 1 + (raw - 1) / 4
	end

	return raw
end

-- The armour modifier a hit would actually get, including the player's live
-- bonuses. Returns the base modifier unchanged when the live stats are missing,
-- so the caller never has to care whether the snapshot worked.
function live_stats.effective_modifier(base_modifier, snapshot, is_weakspot)
	local modifier = base_modifier

	if type(modifier) ~= "number" then
		return nil
	end

	if type(snapshot) ~= "table" or not snapshot.available then
		return modifier
	end

	modifier = live_stats.apply_rending(modifier, snapshot.rending)

	if is_weakspot and type(modifier) == "number" then
		modifier = modifier * (1 + (snapshot.weakspot or 0))
	end

	return modifier
end

local function weapon_handling_crit_modifier(player_unit)
	local weapon_system = player_unit and ScriptUnit.has_extension(player_unit, "weapon_system")

	if not weapon_system or type(weapon_system.weapon_handling_template) ~= "function" then
		return 0
	end

	local ok, handling = pcall(weapon_system.weapon_handling_template, weapon_system)

	if not ok or type(handling) ~= "table" then
		return 0
	end

	local critical_strike = handling.critical_strike

	if type(critical_strike) == "table" and type(critical_strike.chance_modifier) == "number" then
		return critical_strike.chance_modifier
	end

	return 0
end

local function archetype_base_crit(player)
	if not player or type(player.profile) ~= "function" then
		return nil
	end

	local ok, profile = pcall(player.profile, player)

	if not ok or type(profile) ~= "table" then
		return nil
	end

	local archetype = profile.archetype
	local base = type(archetype) == "table" and archetype.base_critical_strike_chance or nil

	return type(base) == "number" and base or nil
end

-- Everything the readout needs about the player's damage bonuses right now.
-- `available` is false when the buff extension could not be read, and callers
-- then fall back to the plain armour table.
function live_stats.snapshot(player_unit, player, is_ranged)
	local out = {
		available = false,
		rending = 0,
		weakspot = 0,
		finesse = 0,
		crit_chance = nil,
		crit_damage = 1,
	}

	local buff_extension = player_unit and ScriptUnit.has_extension(player_unit, "buff_system")

	if not buff_extension or type(buff_extension.stat_buffs) ~= "function" then
		return out
	end

	local ok, stats = pcall(buff_extension.stat_buffs, buff_extension)

	if not ok or type(stats) ~= "table" then
		return out
	end

	out.available = true
	out.stats = stats
	out.raw = {}

	local function take(key)
		local value, raw, base = delta(stats, key)

		if raw ~= nil then
			out.raw[key] = { value = raw, base = base, delta = value }
		end

		return value
	end

	local class_rending = is_ranged and RENDING_RANGED or RENDING_MELEE
	local class_weakspot = is_ranged and WEAKSPOT_RANGED or WEAKSPOT_MELEE
	local class_finesse = is_ranged and FINESSE_RANGED or FINESSE_MELEE
	local class_crit_damage = is_ranged and CRIT_DAMAGE_RANGED or CRIT_DAMAGE_MELEE
	local class_crit_chance = is_ranged and CRIT_CHANCE_RANGED or CRIT_CHANCE_MELEE

	out.rending = take(RENDING_GENERIC) + take(class_rending)
	out.finesse = take(FINESSE_GENERIC) + take(class_finesse)
	out.weakspot = take(WEAKSPOT_GENERIC) + take(class_weakspot) + out.finesse

	-- Crit damage: neutral at 1, plus whatever the generic and class bonuses add.
	out.crit_damage = 1 + take(CRIT_DAMAGE_GENERIC) + take(class_crit_damage)

	-- Crit chance, following scripts/utilities/attack/critical_strike as re-stated
	-- by InventoryStats: archetype base + generic + weapon class + the weapon's own
	-- handling modifier, clamped to a probability.
	local base = archetype_base_crit(player)

	if base then
		local chance = base
			+ take(CRIT_CHANCE_GENERIC)
			+ take(class_crit_chance)
			+ weapon_handling_crit_modifier(player_unit)

		if chance < 0 then
			chance = 0
		elseif chance > 1 then
			chance = 1
		end

		out.crit_chance = chance
	end

	return out
end

-- The lines the HUD panel shows, as { key, value } pairs with the value already
-- formatted. Only entries that are actually doing something are included: a
-- neutral stat on the panel is noise.
function live_stats.panel_lines(snapshot)
	if type(snapshot) ~= "table" or not snapshot.available then
		return {}
	end

	local lines = {}

	if snapshot.rending and snapshot.rending ~= 0 then
		lines[#lines + 1] = { key = "live_rending", value = string.format("+%.0f%%", snapshot.rending * 100) }
	end

	if snapshot.weakspot and snapshot.weakspot ~= 0 then
		lines[#lines + 1] = { key = "live_weakspot", value = string.format("+%.0f%%", snapshot.weakspot * 100) }
	end

	if snapshot.crit_chance and snapshot.crit_chance > 0 then
		lines[#lines + 1] = {
			key = "live_crit",
			value = string.format("%.1f%%  x%.2f", snapshot.crit_chance * 100, snapshot.crit_damage or 1),
		}
	end

	return lines
end

return live_stats
