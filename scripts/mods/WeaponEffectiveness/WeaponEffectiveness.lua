-- WeaponEffectiveness -- shows, next to the crosshair, whether the weapon you
-- are holding can actually hurt the enemy you are aiming at, and where to hit it.
--
-- Two layers, and the readout always says which one it used:
--
--   base   : breed.armor_type overridden by breed.hitzone_armor_override[zone]
--            vs damage_profile.armor_damage_modifier.attack[armor_type]
--   live   : the same armour number, then adjusted by the player's own bonuses --
--            rending raises it, and a weakspot part multiplies it -- read from
--            buff_extension:stat_buffs() every frame.
--
-- The live layer is the part that cannot be read off a table, so it is isolated in
-- modules/live_stats.lua, marked as an estimate where the composition is a model
-- rather than a documented rule, and calibrated against the damage the game
-- actually deals (see the hit log).

local mod = get_mod("WeaponEffectiveness")

local armor = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/armor")
local weapon_profiles = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/weapon_profiles")
local target_module = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/target")
local hit_verdict = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/hit_verdict")
local input_state = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/input_state")
local local_player = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/local_player")
local hit_marker = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/hit_marker")
local live_stats = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/live_stats")
local effectiveness_marker_template = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/markers/effectiveness_marker")
local diagnostics = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/modules/diagnostics")

local WeaponTemplate = require("scripts/utilities/weapon/weapon_template")

target_module.set_armor_module(armor)

local HUD_ELEMENT_CLASS = "HudElementWeaponEffectiveness"
local HUD_ELEMENT_SCRIPT = "WeaponEffectiveness/scripts/mods/WeaponEffectiveness/hud/hud_element_weapon_effectiveness"

local ATTACK_KINDS = { "light", "heavy", "special" }

-- Extension names to try, in order, for the local player's weapon component.
local WEAPON_EXTENSION_NAMES = { "weapon_system", "weapon" }

-- Probed on the live action component so the diagnostics dump shows which of
-- these the engine actually populates (charge state especially).
local ACTION_COMPONENT_FIELDS = {
	"current_action_name",
	"previous_action_name",
	"special_active",
	"special_active_at_start",
	"charge_level",
	"is_charging",
	"charging",
	"charge_time",
	"action_charge_time",
	"current_num_activations",
	"num_activations",
	"wielded_slot",
	"template_name",
}

-- ------------------------------------------------------------------ state ---

mod.state = mod.state or {
	visible = false,
	armor_label = nil,
	armor_type = nil,
	has_special = false,
	special_active = false,
	active_kind = nil,
	lines = {},
}

local function setting(id, default)
	local value = mod:get(id)

	if value == nil then
		return default
	end

	return value
end

local function thresholds()
	return {
		effective = setting("effective_min_percent", 100) / 100,
		reduced = setting("reduced_min_percent", 50) / 100,
	}
end

-- Ranged armour tables are banded by distance (near / far), so the verdict has to
-- be explicit about which band it is judging. Defaults to near, which is where
-- most shooting happens; the diagnostics dump records both bands regardless.
local function ranged_band()
	local band = setting("ranged_band", "near")

	if band ~= "near" and band ~= "far" then
		return "near"
	end

	return band
end

local function color_for(key, alpha)
	return {
		alpha or setting("indicator_opacity", 220),
		setting("color_" .. key .. "_R", 255),
		setting("color_" .. key .. "_G", 255),
		setting("color_" .. key .. "_B", 255),
	}
end

function mod.neutral_color()
	return {
		setting("indicator_opacity", 220),
		205,
		195,
		175,
	}
end

-- Exposed for the HUD element.
function mod.verdict_color(verdict)
	if verdict == armor.VERDICT.EFFECTIVE then
		return color_for("effective")
	elseif verdict == armor.VERDICT.REDUCED then
		return color_for("reduced")
	elseif verdict == armor.VERDICT.WEAK then
		return color_for("weak")
	elseif verdict == armor.VERDICT.IMMUNE then
		return color_for("immune")
	end

	return color_for("immune", 160)
end

-- ----------------------------------------------------------------- player ---

-- Goes through local_player so it is safe to call while still at the main menu:
-- PlayerManager:local_player(1) is a native NULL dereference before any player
-- exists, which kills the process rather than raising a Lua error.
local function local_player_unit()
	return local_player.unit()
end

local function scripting_extension(unit, name)
	if not unit then
		return nil
	end

	local ok, extension = pcall(ScriptUnit.has_extension, unit, name)

	if ok and extension then
		return extension
	end

	return nil
end

local function weapon_extension(player_unit)
	for i = 1, #WEAPON_EXTENSION_NAMES do
		local name = WEAPON_EXTENSION_NAMES[i]
		local extension = scripting_extension(player_unit, name)

		if extension then
			return extension, name
		end
	end

	return nil
end

local function weapon_template_of(extension)
	if not extension then
		return nil
	end

	local ok, template = pcall(function ()
		return extension:weapon_template()
	end)

	if ok and type(template) == "table" then
		return template
	end

	local action_component = extension._weapon_action_component

	if action_component then
		local ok_fallback, fallback = pcall(WeaponTemplate.current_weapon_template, action_component)

		if ok_fallback and type(fallback) == "table" then
			return fallback
		end
	end

	return nil
end

-- The gameplay input service. input_state.module falls back to its own hook on
-- InputService:_get if this one returns nothing, which is what makes the
-- tap-vs-hold verdict robust.
local function gameplay_input_service()
	local input_manager = Managers.input

	if not input_manager then
		return nil
	end

	local ok, service = pcall(function ()
		return input_manager:get_input_service("Ingame")
	end)

	if ok then
		return service
	end

	return nil
end

-- A weapon's special mode only ever lives in a weapon slot. Restricting to these
-- two is not cosmetic: reading any other wielded slot (grenade, combat ability,
-- device, luggable) can hand `read_component` a slot it has no component for,
-- which errors inside the engine's own player_unit_data_extension:
--
--   player_unit_data_extension.lua:482: attempt to index local 'field' (a nil value)
--
-- That was observed for real, once, and the frame's whole refresh was lost.
local WEAPON_SLOTS = {
	slot_primary = true,
	slot_secondary = true,
}

-- `inventory_slot_component.special_active` is the flag the engine itself reads to
-- decide whether an attack uses damage_profile_special_active.
local function special_active_from_slot(player_unit)
	local unit_data = scripting_extension(player_unit, "unit_data_system")

	if not unit_data then
		return nil
	end

	local ok, inventory = pcall(function ()
		return unit_data:read_component("inventory")
	end)

	if not ok or type(inventory) ~= "table" then
		return nil
	end

	local slot = inventory.wielded_slot

	if not WEAPON_SLOTS[slot] then
		return nil
	end

	local ok_slot, slot_component = pcall(function ()
		return unit_data:read_component(slot)
	end)

	if not ok_slot or type(slot_component) ~= "table" then
		return nil
	end

	return slot_component.special_active == true, slot, slot_component
end

-- Returns special_active, wielded_slot, slot_component.
local function special_active_of(player_unit, action_component)
	local from_slot, slot, slot_component = special_active_from_slot(player_unit)

	if from_slot ~= nil then
		return from_slot, slot, slot_component
	end

	-- Falling back to the weapon action component keeps the verdict working when
	-- the slot component cannot be read.
	local ok, value = pcall(function ()
		return action_component and action_component.special_active
	end)

	if ok and type(value) == "boolean" then
		return value, slot, slot_component
	end

	return nil, slot, slot_component
end

-- What the header line shows: who is under the crosshair, and how its parts are
-- armoured.
--
-- Two shapes, because one of them is noise on most enemies:
--   * parts differ  -> list each part with its armour (`头部 硬壳(弱点) · 躯干 防弹`)
--   * parts equal   -> name the armour once and only call out the weakspot parts
--                      (`喷火兵 · 狂怒甲 · 头部(弱点)`)
--
-- The header names the enemy and how its aimable parts are armoured: one entry per
-- part when they differ (`头部 硬壳装甲 · 躯干 防弹装甲`), otherwise the armour
-- named once. Weakspot status is part of the number each row shows now, so it is
-- not spelled out here.
local function header_info(breed, name)
	if type(breed) ~= "table" then
		return { name = name }
	end

	local zones = armor.zones_with_armor(breed, true)
	local parts = {}
	local seen_armor = {}
	local first_armor = nil
	local uniform = true

	for i = 1, #zones do
		local zone = zones[i]

		if first_armor == nil then
			first_armor = zone.armor
		elseif zone.armor ~= first_armor then
			uniform = false
		end

		if zone.armor and not seen_armor[zone.armor] then
			seen_armor[zone.armor] = true

			parts[#parts + 1] = {
				zone_key = "zone_" .. zone.zone,
				armor = armor.display_name(zone.armor),
			}
		end
	end

	if uniform then
		-- One armour everywhere: name it once.
		return {
			name = name,
			armor = armor.display_name(breed.armor_type),
		}
	end

	return {
		name = name,
		parts = parts,
	}
end

-- ----------------------------------------------------------------- refresh --

-- The aimed enemy's name. Every breed carries `display_name` as a vanilla loc key
-- (`loc_breed_display_name_*`), so this goes through the game's own localizer --
-- the same mechanism the armour names use -- with the same guard against the
-- "unlocalized" placeholder the game returns for a key it does not have.
local function enemy_display_name(breed)
	if type(breed) ~= "table" then
		return nil
	end

	local key = breed.display_name

	if type(key) == "string" and key ~= "" then
		local ok, text = pcall(Localize, key)

		if ok and type(text) == "string" and text ~= "" then
			local lowered = string.lower(text)

			if not string.find(lowered, "unlocalized", 1, true)
				and not string.find(text, "loc_", 1, true)
				and string.sub(text, 1, 1) ~= "<"
			then
				return text
			end
		end
	end

	-- Unknown breed: its internal name is still better than showing nothing.
	return breed.name
end

local function refresh()
	local state = mod.state
	local player_unit = local_player_unit()

	state.visible = false
	state.lines = {}
	state.active_kind = nil
	state.hidden_reason = nil

	if not player_unit then
		state.hidden_reason = "no local player unit"

		return
	end

	local extension, extension_name = weapon_extension(player_unit)
	local weapon_template = weapon_template_of(extension)
	local is_ranged = false
	local is_melee = false

	if weapon_template then
		local ok_ranged, ranged = pcall(WeaponTemplate.is_ranged, weapon_template)
		local ok_melee, melee = pcall(WeaponTemplate.is_melee, weapon_template)

		is_ranged = ok_ranged and ranged == true
		is_melee = ok_melee and melee == true
	end

	local action_component = extension and extension._weapon_action_component
	local current_action_name = action_component and action_component.current_action_name

	local special_active, wielded_slot, slot_component = special_active_of(player_unit, action_component)
	local resolved = weapon_profiles.resolve(weapon_template)

	-- The player's own damage bonuses, read live. Downstream code treats this as
	-- optional: when it is unavailable the readout is exactly the armour-table one.
	local player = local_player.player()
	local snapshot = live_stats.snapshot(player_unit, player, is_ranged)

	if setting("use_live_stats", true) == false then
		snapshot = { available = false }
	end

	state.live_stats = snapshot
	state.live_panel = setting("show_live_stats_panel", true) ~= false and live_stats.panel_lines(snapshot) or {}

	mod._weapon_dump = {
		template_name = weapon_template and weapon_template.name,
		display_name = weapon_template and weapon_template.display_name,
		weapon_special_class = weapon_template and weapon_template.weapon_special_class,
		keywords = weapon_template and weapon_template.keywords,
		is_ranged = is_ranged,
		is_melee = is_melee,
		extension_name = extension_name,
		-- The weapon's own tap-vs-hold input mapping, so the dump proves whether
		-- reading the template was enough to identify the heavy attack input.
		input_map = weapon_profiles.input_map(weapon_template),
	}

	mod._live_dump = {
		current_action_name = current_action_name,
		special_active = special_active,
		wielded_slot = wielded_slot,
		action_component_fields = diagnostics.probe_fields(action_component, ACTION_COMPONENT_FIELDS),
		slot_component_fields = diagnostics.probe_fields(slot_component, ACTION_COMPONENT_FIELDS),
		weapon_extension_methods = diagnostics.probe_methods(extension, "weapon"),
		input_probe = {
			action_one_hold = input_state.is_held("action_one_hold"),
			action_one_pressed = input_state.is_held("action_one_pressed"),
			action_two_hold = input_state.is_held("action_two_hold"),
			debug = input_state.debug(),
		},
	}

	mod._weapon_template = weapon_template
	mod._resolved = resolved
	mod._is_ranged = is_ranged

	-- Which attack the player is committing to drives which line is emphasised.
	--
	-- Precedence: an exact match against the resolved light/heavy chain action is
	-- the strongest signal there is. Failing that, the weapon's own action-input
	-- predicates decide, because they *are* the game's tap-vs-hold rule (for a
	-- power sword light and heavy share the input `action_one_hold` and differ
	-- only in the required value). Only if neither has an opinion does the weaker
	-- name/kind inference stand.
	local name_kind, name_strength =
		weapon_profiles.current_attack_kind(weapon_template, resolved, current_action_name)

	local active_kind = name_kind

	if name_strength ~= "strong" then
		local input_kind = weapon_profiles.attack_kind_from_input(weapon_template, input_state.is_held)

		if input_kind then
			active_kind = input_kind
		end
	end

	state.active_kind = active_kind
	state.has_special = resolved ~= nil and resolved.has_special == true
	state.special_active = special_active == true
	state.weapon_name = weapon_template and weapon_template.display_name

	local target_info = target_module.resolve(player_unit)

	mod._target = target_info
	state.armor_type = target_info.armor_type
	state.armor_label = target_info.armor_type and armor.display_name(target_info.armor_type) or nil
	state.target_name = enemy_display_name(target_info.breed)
	state.hit_zone_name = target_info.hit_zone_name
	state.header = header_info(target_info.breed, state.target_name)

	-- A compact snapshot of everything that had to go right for the indicator to
	-- show something. /wepcheckstate prints this, so a single in-game test can
	-- report *why* nothing appeared instead of just "nothing appeared".
	state.probe = {
		weapon_extension = extension_name,
		weapon = weapon_template and weapon_template.name,
		is_ranged = is_ranged,
		current_action = current_action_name,
		light_action = resolved and resolved.light and resolved.light.action_name,
		heavy_action = resolved and resolved.heavy and resolved.heavy.action_name,
		has_special = state.has_special,
		special_active = state.special_active,
		active_kind = active_kind,
		target_unit_found = target_info.unit ~= nil,
		target_breed = target_info.breed_name,
		zone_source = target_info.zone_source,
		zone_probe = target_info.zone_probe,
		hit_zone = target_info.hit_zone_name,
		armor_type = target_info.armor_type,
		armor_source = target_info.armor_source,
		raycast_filter = target_info.raycast_filter,
		target_steps = target_info.steps,
		live_stats = {
			available = snapshot.available,
			rending = snapshot.rending,
			weakspot = snapshot.weakspot,
			finesse = snapshot.finesse,
			crit_chance = snapshot.crit_chance,
			crit_damage = snapshot.crit_damage,
			-- Every stat that fed those sums, with the base it was measured against:
			-- a surprising total explains itself from this alone.
			raw = snapshot.raw,
		},
		input_action_one_hold = input_state.is_held("action_one_hold"),
		player = local_player.debug(),
	}

	-- Record the body-part resolution whenever it changes. Console output is easy to
	-- lose and tedious to copy; a short log of "while aiming, the zone resolved like
	-- this" is what makes a single run diagnosable from the file alone.
	local zone_signature = string.format(
		"%s|%s|%s|%s",
		tostring(target_info.breed_name),
		tostring(target_info.hit_zone_name),
		tostring(target_info.zone_source),
		tostring(target_info.armor_type)
	)

	if zone_signature ~= mod._zone_signature then
		mod._zone_signature = zone_signature
		mod._zone_log_count = (mod._zone_log_count or 0) + 1

		-- Capped: sweeping the crosshair across a crowd would otherwise bury the log.
		if target_info.unit ~= nil and mod._zone_log_count <= 300 then
			local zone_probe = target_info.zone_probe or {}

			diagnostics.log(
				"zone breed=%s zone=%s src=%s raw=%s armour=%s(%s) overrides=[%s]",
				tostring(target_info.breed_name),
				tostring(target_info.hit_zone_name),
				tostring(target_info.zone_source),
				tostring(zone_probe.raw_get_name),
				tostring(target_info.armor_type),
				tostring(target_info.armor_source),
				zone_probe.override_keys and table.concat(zone_probe.override_keys, ",") or "-"
			)

			-- Only when it failed: dump which handle each breed name resolves to.
			if not target_info.hit_zone_name then
				local candidates = zone_probe.candidates or {}

				for i = 1, math.min(#candidates, 12) do
					diagnostics.log("  cand %s", candidates[i])
				end
			end
		end
	end

	-- Nothing under the crosshair means there is no armour to judge against, so
	-- stay hidden rather than printing a row of question marks.
	if target_info.unit == nil then
		state.hidden_reason = "no enemy under the crosshair"

		return
	end

	local bands = thresholds()
	local armor_type = target_info.armor_type

	if not armor_type then
		state.hidden_reason = "aimed enemy has no armour type for this body part"

		return
	end

	local lines = {}

	-- The special row previews what activating the special mode would do, so it
	-- only appears while the mode is OFF. Once it is on, the light and heavy rows
	-- already carry the special profiles and a third row would merely repeat one
	-- of them.
	local show_special_preview = state.has_special and not state.special_active

	-- Each row lists every body part the player can aim at, with that part's
	-- effective multiplier, instead of collapsing to a single "best" one: which
	-- part you actually hit is your call, so both numbers are the honest answer.
	-- The row's colour still comes from the best part, which is the actionable
	-- question ("is there anywhere this works?").
	local function attack_line(entry, force_special, is_active)
		if not entry then
			return nil
		end

		local profile = weapon_profiles.active_profile(entry, force_special and true or state.special_active)

		if type(profile) ~= "table" then
			return nil
		end

		local band = is_ranged and ranged_band() or nil
		local live = state.live_stats

		-- Scored parts: every aimable part with its effective multiplier, plus the
		-- best of them for the row colour. Three factors go in, and only the first is
		-- the armour table: the breed's own per-zone damage multiplier (a hound takes
		-- x3 on every part from melee, an armoured infected x0.2 on the legs from
		-- ranged), then the player's live bonuses.
		local scored, best = armor.scored_parts(target_info.breed, function (zone)
			local _, base_max = armor.modifier(profile, zone.armor, is_ranged, band)
			local zone_factor = armor.hitzone_damage_multiplier(target_info.breed, zone.zone, is_ranged)
			local value = live_stats.effective_modifier(base_max, live, zone.weakspot ~= nil)

			if type(value) == "number" then
				value = value * zone_factor
			end

			return value, base_max
		end)

		-- A breed with no zone data at all is judged on its breed-wide armour.
		if not best then
			local _, base_max = armor.modifier(profile, target_info.breed and target_info.breed.armor_type, is_ranged, band)
			local effective = live_stats.effective_modifier(base_max, live, false)

			if type(effective) == "number" then
				scored = { {
					zone = nil,
					armor = target_info.breed and target_info.breed.armor_type,
					weakspot = false,
					value = effective,
					base = base_max,
				} }
				best = scored[1]
			end
		end

		if not best then
			return nil
		end

		-- Build the display list: named parts in the header's order, collapsed to a
		-- single "全身" when every part behaves identically (same armour, same
		-- weakspot status), because listing them separately would be noise.
		local parts = {}
		local uniform = #scored > 1

		for i = 2, #scored do
			if scored[i].armor ~= scored[1].armor or scored[i].weakspot ~= scored[1].weakspot then
				uniform = false

				break
			end
		end

		if uniform then
			parts[1] = {
				zone_key = "zone_whole_body",
				base = best.base,
				value = best.value,
				weakspot = best.weakspot,
			}
		else
			for i = 1, #scored do
				local part = scored[i]

				parts[#parts + 1] = {
					zone_key = part.zone and ("zone_" .. part.zone) or "zone_whole_body",
					base = part.base,
					value = part.value,
					weakspot = part.weakspot,
				}
			end
		end

		return {
			verdict = armor.classify(best.value, bands),
			max = best.value,
			base_max = best.base,
			parts = parts,
			profile_name = profile.name,
			variant = nil,
			action_name = entry.action_name,
			zone = best.zone,
			active = is_active and true or false,
		}
	end

	for i = 1, #ATTACK_KINDS do
		local kind = ATTACK_KINDS[i]

		if kind ~= "special" or show_special_preview then
			local entry = resolved and resolved[kind]

			if kind == "special" and resolved then
				-- Mirror whichever attack the player is winding up, so the preview
				-- answers the question they are about to ask.
				entry = (active_kind == "light" and resolved.light)
					or resolved.heavy
					or resolved.light
			end

			local force_special = kind == "special"

			local line = attack_line(
				entry,
				force_special,
				(active_kind == kind) or (force_special and state.special_active and active_kind == nil)
			)

			if line then
				line.kind = kind
				lines[#lines + 1] = line
			end
		end
	end

	if #lines == 0 then
		state.hidden_reason = "no light/heavy damage profile resolved for the wielded weapon"
	end

	state.lines = lines
	state.visible = #lines > 0
end

function mod.snapshot()
	return {
		weapon = mod._weapon_dump,
		resolved = mod._resolved,
		is_ranged = mod._is_ranged,
		live = mod._live_dump,
		target = mod._target,
		verdicts = mod.state.lines,
		hit_results = hit_verdict.dump(),
		hidden_reason = mod.state.hidden_reason,
		probe = mod.state.probe,
		marker = mod._marker_status,
		input = input_state.debug(),
	}
end

diagnostics.init({
	armor = armor,
	snapshot = mod.snapshot,
})

-- Wired here rather than beside the requires: these closures reference the
-- `setting` local, which is only in scope from this point on.
target_module.install({
	raycast_filter = function ()
		return setting("raycast_filter", "auto")
	end,
})

hit_marker.install({
	mod = mod,
	template = effectiveness_marker_template,
	color_for = mod.verdict_color,
	enabled = function ()
		return setting("show_hit_numbers", true)
	end,
	show_multiplier = function ()
		return setting("number_show_multiplier", false)
	end,
	font_size = function ()
		return setting("number_font_size", 24)
	end,
})

input_state.install({
	mod = mod,
	service = gameplay_input_service,
})

hit_verdict.install({
	mod = mod,
	armor = armor,
	local_player = local_player,
	breed_of = target_module.breed_of,
	thresholds = thresholds,
	band = ranged_band,
	is_ranged = function ()
		return mod._is_ranged == true
	end,
	-- The same armour modifier the readout shows, so every hit logs a predicted
	-- number next to the damage the game actually dealt.
	live_modifier = function (damage_profile, armor_type_value, is_ranged_now, is_weakspot)
		local _, base_max = armor.modifier(damage_profile, armor_type_value, is_ranged_now, is_ranged_now and ranged_band() or nil)
		local effective = live_stats.effective_modifier(base_max, mod.state and mod.state.live_stats, is_weakspot)

		return base_max, effective
	end,
	on_hit = function (record, unit, hit_position)
		-- Calibration line: the live model's prediction beside the game's own
		-- result. Comparing head and body hits of one profile is what pins the
		-- weakspot multiplier down empirically.
		mod._hit_log_count = (mod._hit_log_count or 0) + 1

		if mod._hit_log_count <= 400 then
			diagnostics.log(
				"hit profile=%s breed=%s zone=%s armor=%s weak=%s crit=%s dmg=%s base=%s pred=%s eff=%s",
				tostring(record.profile_name),
				tostring(record.breed_name),
				tostring(record.hit_zone),
				tostring(record.armor_type),
				tostring(record.weakspot),
				tostring(record.crit),
				tostring(record.damage),
				tostring(record.live_base),
				tostring(record.live_effective),
				tostring(record.efficiency)
			)
		end

		hit_marker.spawn(record, unit, hit_position)
	end,
})

-- ------------------------------------------------------------------- loop ---

-- A bare pcall only reports the deepest frame, which for an engine-side error says
-- nothing about which of our calls caused it. `debug` may have been scrubbed by the
-- game's own patches, so the traceback is best-effort.
local function refresh_error_handler(message)
	local text = tostring(message)

	if debug and type(debug.traceback) == "function" then
		local ok_trace, trace = pcall(debug.traceback, "", 2)

		if ok_trace and type(trace) == "string" then
			return text .. "\n" .. trace
		end
	end

	return text
end

function mod.update(dt)
	input_state.update(dt)
	input_state.ensure_hook()

	hit_verdict.ensure_hook()

	-- Re-registered every frame on purpose: recreate_hud destroys and rebuilds the
	-- player HUD, which throws the world-marker template table away with it.
	hit_marker.ensure_registered()
	mod._marker_status = hit_marker.status()

	local ok, err = xpcall(refresh, refresh_error_handler)

	if not ok then
		mod.state.visible = false
		mod._refresh_errors = (mod._refresh_errors or 0) + 1

		-- A handful of failures is enough to diagnose; one line per frame would
		-- bury it.
		if mod._refresh_errors <= 5 then
			diagnostics.log("refresh failed (#%d): %s", mod._refresh_errors, tostring(err))
		end
	end

	-- Pruning walks every recently hit unit, so it does not need to run per frame.
	mod._prune_accumulator = (mod._prune_accumulator or 0) + (tonumber(dt) or 0)

	if mod._prune_accumulator > 2 then
		mod._prune_accumulator = 0

		pcall(hit_verdict.prune)
	end
end

-- ------------------------------------------------------------------- hud ----

local hud_element = {
	use_hud_scale = true,
	filename = HUD_ELEMENT_SCRIPT,
	class_name = HUD_ELEMENT_CLASS,
	visibility_groups = {
		"alive",
		"communication_wheel",
	},
}

function mod.recreate_hud()
	local ui_manager = Managers.ui

	if not ui_manager then
		return
	end

	local hud = ui_manager._hud

	if not hud then
		return
	end

	local player = local_player.player()

	if not player then
		return
	end

	local peer_id = player:peer_id()
	local local_player_id = player:local_player_id()
	local elements = hud._element_definitions
	local visibility_groups = hud._visibility_groups

	hud:destroy()
	ui_manager:create_player_hud(peer_id, local_player_id, elements, visibility_groups)
end

function mod.get_hud_element()
	local ui_manager = Managers.ui
	local hud = ui_manager and ui_manager:get_hud()

	return hud and hud:element(HUD_ELEMENT_CLASS)
end

mod:add_require_path(HUD_ELEMENT_SCRIPT)

mod:hook(CLASS.UIHud, "init", function (func, self, elements, visibility_groups, params, ...)
	if not table.find_by_key(elements, "class_name", HUD_ELEMENT_CLASS) then
		table.insert(elements, hud_element)
	end

	return func(self, elements, visibility_groups, params, ...)
end)

function mod.on_all_mods_loaded()
	mod:recreate_hud()
end

function mod.player_unit_loaded()
	mod:recreate_hud()
end

function mod.on_setting_changed(id)
	local hud = mod.get_hud_element()

	if not hud then
		return
	end

	if id == "font_type" or id == "font_size" then
		hud:set_font(setting("font_type", "proxima_nova_bold"), setting("font_size", 20))
	elseif id == "indicator_horizontal_offset" or id == "indicator_vertical_offset" then
		hud:set_offset(setting("indicator_vertical_offset", 38), setting("indicator_horizontal_offset", 96))
	elseif string.find(id, "indicator_opacity", 1, true) or string.find(id, "color_", 1, true) then
		hud:apply_colors()
	end
end

-- ---------------------------------------------------------------- command ---

mod:command("wepcheck", "Dump the weapon/armour state this mod sees to a JSON file", function ()
	local path, json = diagnostics.write()

	if mod.echo then
		if path then
			mod:echo("WeaponEffectiveness: wrote " .. tostring(path))
		else
			mod:echo("WeaponEffectiveness: could not write the dump (see wepcheck.log)")
		end
	end

	if not path and json then
		-- Last resort so the data is at least reachable from the console log.
		print("[WeaponEffectiveness] dump: " .. json)
	end
end)

mod:command("wepcheckstate", "Report what the indicator currently sees, and why it is hidden", function ()
	local state = mod.state

	if not mod.echo then
		return
	end

	if state.visible then
		mod:echo(string.format(
			"WeaponEffectiveness: VISIBLE  armour=%s  rows=%d  active=%s",
			tostring(state.armor_type),
			#state.lines,
			tostring(state.active_kind)
		))
	else
		mod:echo("WeaponEffectiveness: HIDDEN - " .. tostring(state.hidden_reason or "unknown reason"))
	end

	local probe = state.probe

	if not probe then
		return
	end

	mod:echo(string.format(
		"  weapon=%s (%s) ext=%s ranged=%s",
		tostring(probe.weapon),
		tostring(probe.weapon_extension),
		tostring(probe.weapon_extension),
		tostring(probe.is_ranged)
	))
	mod:echo(string.format(
		"  action=%s light=%s heavy=%s special=%s/%s active=%s",
		tostring(probe.current_action),
		tostring(probe.light_action),
		tostring(probe.heavy_action),
		tostring(probe.has_special),
		tostring(probe.special_active),
		tostring(probe.active_kind)
	))
	mod:echo(string.format(
		"  target=%s zone=%s zone_src=%s armour=%s(%s) filter=%s",
		tostring(probe.target_breed),
		tostring(probe.hit_zone),
		tostring(probe.zone_source),
		tostring(probe.armor_type),
		tostring(probe.armor_source),
		tostring(probe.raycast_filter)
	))

	-- The live layer, with its inputs. A surprising total ("+200% rending"?) is
	-- answered by the per-key lines below it: each shows the raw aggregated value,
	-- the base it is neutral at, and the delta actually applied.
	local live = probe.live_stats

	if live then
		mod:echo(string.format(
			"  live: available=%s rending=%+.3f weakspot=%+.3f finesse=%+.3f crit=%s x%.2f",
			tostring(live.available),
			tonumber(live.rending) or 0,
			tonumber(live.weakspot) or 0,
			tonumber(live.finesse) or 0,
			live.crit_chance and string.format("%.3f", live.crit_chance) or "-",
			tonumber(live.crit_damage) or 1
		))

		local keys = {}

		for key in pairs(live.raw or {}) do
			keys[#keys + 1] = key
		end

		table.sort(keys)

		for index = 1, #keys do
			local key = keys[index]
			local entry = live.raw[key]

			mod:echo(string.format(
				"    %s raw=%s base=%s delta=%+.3f",
				key,
				tostring(entry.value),
				tostring(entry.base),
				tonumber(entry.delta) or 0
			))
		end
	end

	-- The body-part resolution is the part most likely to fail silently, so it gets
	-- its own line: which of the three routes won, what the engine's zone
	-- vocabulary looks like, whether the hit actor can be named, and which override
	-- keys the aimed breed actually has.
	local zone_probe = probe.zone_probe

	if zone_probe then
		mod:echo(string.format(
			"  zone: has_get_name=%s has_get_actor_names=%s has_find_actor=%s has_actor_node=%s raw_get_name=%s",
			tostring(zone_probe.has_get_name),
			tostring(zone_probe.has_get_actor_names),
			tostring(zone_probe.has_find_actor),
			tostring(zone_probe.has_actor_node),
			tostring(zone_probe.raw_get_name)
		))
		mod:echo(string.format(
			"  zone: engine_zones=%s override_keys=%s",
			type(zone_probe.hit_zone_names) == "table"
				and table.concat(zone_probe.hit_zone_names, ",")
				or tostring(zone_probe.hit_zone_names),
			zone_probe.override_keys and table.concat(zone_probe.override_keys, ",") or "-"
		))

		for i = 1, math.min(#(zone_probe.candidates or {}), 4) do
			mod:echo("  zone: " .. zone_probe.candidates[i])
		end
	end
	local steps = probe.target_steps

	if steps then
		local hits = {}

		for _, filter_name in ipairs(steps.filters_tried or {}) do
			hits[#hits + 1] = string.format("%s=%s", filter_name, tostring((steps.hits_per_filter or {})[filter_name]))
		end

		mod:echo(string.format(
			"  steps ext=%s physics=%s params=%s data=%s live_from=%s",
			tostring(steps.targeting_extension),
			tostring(steps.physics_world),
			tostring(steps.targeting_parameters),
			tostring(steps.targeting_data),
			tostring(steps.live_minion_from)
		))
		mod:echo("  filter hits: " .. (#hits > 0 and table.concat(hits, "  ") or "(none tried)"))
	end

	local input = input_state.debug()
	local player = probe.player

	if player then
		mod:echo(string.format(
			"  player found=%s manager=%s safe_accessor=%s num_players=%s",
			tostring(player.found),
			tostring(player.manager),
			tostring(player.has_safe_accessor),
			tostring(player.num_players)
		))
	end

	mod:echo(string.format(
		"  input action_one_hold=%s  service=%s  hook=%s  err=%s",
		tostring(probe.input_action_one_hold),
		tostring(input.service_available),
		tostring(input.hooked),
		tostring(input.hook_error)
	))

	local marker = mod._marker_status

	if marker then
		mod:echo(string.format(
			"  marker registered=%s hook=%s element=%s spawned=%s",
			tostring(marker.registered),
			tostring(marker.hook_installed),
			tostring(marker.world_markers_element),
			tostring(marker.spawned)
		))
	end
end)

return mod
