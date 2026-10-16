-- weapon_profiles.lua -- works out which damage profile the held weapon uses
-- for its light attack, its heavy attack, and each of those while the weapon's
-- special mode is active.
--
-- The light/heavy walk is the same one the game's own stat calculation and the
-- BetterBots AI use: find the action whose `start_input` is "start_attack", then
-- follow `allowed_chain_actions.light_attack` / `.heavy_attack`.
--
-- The special-mode profile needs no hardcoding of weapon names: an action that
-- has a special variant carries it in `damage_profile_special_active`, and the
-- engine toggles it via `inventory_slot_component.special_active`. That covers
-- power swords, relic blades, chain weapons (rev), arc weapons, power mauls and
-- the ogryn crusher alike.

local weapon_profiles = {}

-- The game's own damage-profile resolver.
--
-- This is the authoritative way to ask "what does this action hit with", and it
-- covers every action kind uniformly: melee sweeps, shoot_hit_scan, shoot_pellets,
-- shoot_projectile, flamer gas. Both WeaponStats and weapon_action_details use it.
--
-- Locating the profile by searching the action table instead does not work in
-- general: ranged damage lives at
--
--   fire_configuration.hit_scan_template.damage.impact.damage_profile
--
-- which is five levels deep. A depth-limited search misses it entirely, which is
-- why the plasma gun, the revolver and the Lucius had no rows at all.
local ok_action, Action = pcall(require, "scripts/utilities/action/action")

if not ok_action then
	Action = nil
end

-- Forward declared: defined next to the table-inspection fallback below, but used
-- by special_profile_of() up here.
local profiles_via_game

local SPECIAL_PROFILE_KEYS = {
	"damage_profile_special_active",
	"damage_profile_special",
}

function weapon_profiles.special_profile_of(action)
	if type(action) ~= "table" then
		return nil
	end

	-- Ask the game first: it reports the special-active variant as the second
	-- return of Action.damage_template, which covers actions whose special profile
	-- is nested rather than sitting on a top-level key.
	if profiles_via_game then
		local entry = profiles_via_game(action)[1]

		if entry and entry.special_profile then
			return entry.special_profile, "Action.damage_template"
		end
	end

	for i = 1, #SPECIAL_PROFILE_KEYS do
		local key = SPECIAL_PROFILE_KEYS[i]
		local candidate = action[key]

		if type(candidate) == "table" then
			return candidate, key
		end
	end

	return nil
end

-- Builds an entry for one named action, whether or not it sits on the light/heavy
-- chain. Used for the attacks that are neither: a braced/aimed mode, a special
-- attack, a bash. This is the row the basic build showed as "当前动作".
function weapon_profiles.entry_for_action(weapon_template, action_name)
	if type(weapon_template) ~= "table" then
		return nil
	end

	local actions = weapon_template.actions
	local action = type(actions) == "table" and type(action_name) == "string"
		and actions[action_name]
		or nil

	if type(action) ~= "table" or type(action.damage_profile) ~= "table" then
		return nil
	end

	local special_profile, special_key = weapon_profiles.special_profile_of(action)

	return {
		action_name = action_name,
		kind = action.kind,
		profile = action.damage_profile,
		special_profile = special_profile,
		special_key = special_key,
	}
end

function weapon_profiles.start_action(weapon_template)
	local actions = weapon_template and weapon_template.actions

	if type(actions) ~= "table" then
		return nil
	end

	for _, action in pairs(actions) do
		if type(action) == "table"
			and action.start_input == "start_attack"
			and not action.invalid_start_action_for_stat_calculation
		then
			return action
		end
	end

	return nil
end

local function entry_from_chain(weapon_template, start_action, input_name)
	local chains = start_action.allowed_chain_actions
	local chain = chains and chains[input_name]
	local action_name = chain and chain.action_name
	local action = action_name and weapon_template.actions[action_name]

	if type(action) ~= "table" then
		return nil
	end

	local special_profile, special_key = weapon_profiles.special_profile_of(action)

	return {
		input = input_name,
		action_name = action_name,
		kind = action.kind,
		profile = action.damage_profile,
		special_profile = special_profile,
		special_key = special_key,
		chain_time = chain.chain_time,
	}
end

-- Returns { light = entry|nil, heavy = entry|nil, has_special = bool,
--           start_action_name = string|nil }
function weapon_profiles.resolve(weapon_template)
	if type(weapon_template) ~= "table" then
		return nil
	end

	local start_action = weapon_profiles.start_action(weapon_template)

	local resolved = {
		light = nil,
		heavy = nil,
		has_special = weapon_template.weapon_special_class ~= nil,
	}

	if start_action then
		resolved.light = entry_from_chain(weapon_template, start_action, "light_attack")
		resolved.heavy = entry_from_chain(weapon_template, start_action, "heavy_attack")
	end

	-- A weapon counts as having a special mode if any action carries a special
	-- variant of its damage profile, regardless of what the fallback chains found.
	if not resolved.has_special then
		for _, action in pairs(weapon_template.actions or {}) do
			if weapon_profiles.special_profile_of(action) then
				resolved.has_special = true

				break
			end
		end
	end

	return resolved
end

-- Picks the profile actually in use right now, given whether the weapon's
-- special mode is on. Falls back to the plain profile.
function weapon_profiles.active_profile(entry, special_active)
	if not entry then
		return nil, nil
	end

	if special_active and entry.special_profile then
		return entry.special_profile, "special"
	end

	return entry.profile, "normal"
end

-- Which attack the current action belongs to.
-- Returns kind, strength, where strength is:
--   "strong" -- the action is exactly one of the resolved light/heavy chain actions
--   "weak"   -- only inferred from the action's kind or its name
-- The caller uses the strength to decide whether to trust this or the live input
-- predicates instead.
function weapon_profiles.current_attack_kind(weapon_template, resolved, current_action_name)
	if type(current_action_name) ~= "string" or current_action_name == "none" then
		return nil
	end

	if resolved then
		if resolved.heavy and resolved.heavy.action_name == current_action_name then
			return "heavy", "strong"
		end

		if resolved.light and resolved.light.action_name == current_action_name then
			return "light", "strong"
		end
	end

	local action = weapon_template
		and weapon_template.actions
		and weapon_template.actions[current_action_name]
	local kind = type(action) == "table" and action.kind or nil

	if type(kind) == "string" then
		if string.find(kind, "heavy", 1, true) or string.find(kind, "charge", 1, true) then
			return "heavy", "weak"
		end

		if string.find(kind, "light", 1, true) then
			return "light", "weak"
		end
	end

	-- Last resort: the action name itself. Actions in this game are named things
	-- like action_left_heavy / action_heavy_1 / action_charge.
	if string.find(current_action_name, "heavy", 1, true)
		or string.find(current_action_name, "charge", 1, true)
	then
		return "heavy", "weak"
	end

	return nil
end

-- Reads the first entry of an action input's sequence. The sequence entry is a
-- predicate on a player input, not just a name:
--
--   light_attack = { input_sequence = { { input = "action_one_hold", time_window = 0.35, value = false } } }
--   heavy_attack = { input_sequence = { { duration = 0.35, input = "action_one_hold", value = true } } }
--
-- Both map to action_one_hold and differ only in `value`, so the input *name*
-- alone cannot distinguish tap from hold -- the value has to be evaluated too.
function weapon_profiles.input_for_action_input(weapon_template, action_input_name)
	local action_inputs = weapon_template and weapon_template.action_inputs
	local input_def = type(action_inputs) == "table" and action_inputs[action_input_name]
	local sequence = type(input_def) == "table" and input_def.input_sequence
	local first = type(sequence) == "table" and sequence[1]

	if type(first) ~= "table" then
		return nil
	end

	return {
		input = first.input,
		value = first.value,
		hold_input = first.hold_input,
		time_window = first.time_window,
		duration = first.duration,
	}
end

-- Flattened view of the whole input mapping, for the diagnostics dump.
function weapon_profiles.input_map(weapon_template)
	local out = {}
	local action_inputs = weapon_template and weapon_template.action_inputs

	if type(action_inputs) ~= "table" then
		return out
	end

	for input_name, input_def in pairs(action_inputs) do
		if type(input_name) == "string" and type(input_def) == "table" then
			local sequence = input_def.input_sequence
			local first = type(sequence) == "table" and sequence[1]
			local entry = {}

			if type(first) == "table" then
				entry.input = first.input
				entry.value = first.value
				entry.hold_input = first.hold_input
				entry.time_window = first.time_window
				entry.sequence_length = #sequence
			end

			for _, action in pairs(weapon_template.actions or {}) do
				if type(action) == "table" and action.start_input == input_name then
					entry.start_of_action_kind = action.kind
					entry.start_of_action_name = action.name
					entry.start_of_action_damage_profile = type(action.damage_profile) == "table"
						and action.damage_profile.name
						or nil

					break
				end
			end

			out[input_name] = entry
		end
	end

	return out
end

-- Evaluates one action-input predicate against the live input state, the way the
-- game's action-input system does.
local function predicate_holds(entry, is_held)
	if not entry or not entry.input then
		return false
	end

	local held = is_held(entry.input) == true

	-- A nil `value` means the input only has to be truthy.
	if entry.value == nil then
		return held
	end

	return held == (entry.value == true)
end

-- Returns "light" or "heavy" according to which attack the player is currently
-- committing to. This is the game's own tap-vs-hold split, so it is the most
-- trustworthy signal available while a wind-up is in progress.
function weapon_profiles.attack_kind_from_input(weapon_template, is_held)
	if not is_held then
		return nil
	end

	local light = weapon_profiles.input_for_action_input(weapon_template, "light_attack")
	local heavy = weapon_profiles.input_for_action_input(weapon_template, "heavy_attack")

	local light_now = predicate_holds(light, is_held)
	local heavy_now = predicate_holds(heavy, is_held)

	-- Only answer when exactly one of them applies; if both or neither match, the
	-- mapping is not telling us anything and the name heuristic should decide.
	if heavy_now and not light_now then
		return "heavy"
	end

	if light_now and not heavy_now then
		return "light"
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Attack modes: every way this weapon can deal damage, so ranged weapons get the
-- same treatment melee already had.
--
-- The damage profile is NOT in the same place for every weapon family:
--   melee   -> action.damage_profile
--   ranged  -> action.fire_configuration.shotshell.<...>
--   sweeps  -> inside action.sweeps
-- so the profile is located by its *shape* (a table carrying an armour modifier
-- table) rather than by a hardcoded path. Every explicit path is tried first, and
-- only then a depth-limited, cycle-guarded, sorted-key scan.
-- ---------------------------------------------------------------------------

local MAX_SEARCH_DEPTH = 4
local MAX_MODES = 5
local MAX_PROFILES_PER_MODE = 8

-- Action inputs that never deal damage. Everything else that resolves to a damage
-- profile becomes a mode -- no whitelist of *damage* inputs, because guessing the
-- input names is what silently dropped whole weapon families.
local NON_DAMAGE_INPUTS = {
	reload = true,
	brace_reload = true,
	wield = true,
	inspect_start = true,
	zoom = true,
	zoom_release = true,
	shoot_release = true,
	vent = true,
	vent_release = true,
	block = true,
	block_release = true,
	attack_cancel = true,
	attack_cancel_special = true,
	ability_pressed = true,
	channel = true,
	aim_force_field = true,
	instant_aim_force_field = true,
	aim_drone = true,
	instant_aim_drone = true,
	-- Covered by the light/heavy chain walk, so listing it again would duplicate.
	start_attack = true,
}

-- Inputs whose role is bookkeeping, not a player-chosen attack: button releases,
-- cancels, chain continuations and the non-attack utility actions. Excluded by
-- role word rather than by an exhaustive name list, so an unseen weapon family
-- still gets its real attacks through.
local EXCLUDED_ROLE_WORDS = {
	"release",
	"cancel",
	"follow_up",
	"inspect",
	"wield",
	"reload",
	"vent",
	"block",
	"channel",
	"keep_charging",
	"push",
}

local function is_bookkeeping_input(input_name)
	local lowered = string.lower(input_name)

	for i = 1, #EXCLUDED_ROLE_WORDS do
		if string.find(lowered, EXCLUDED_ROLE_WORDS[i], 1, true) then
			return true
		end
	end

	return false
end

-- Label lookup, most specific patterns first. Anything unmatched keeps its raw
-- input name on screen: ugly, but it tells the player -- and me -- exactly which
-- input it is, instead of showing two identical generic rows.
local LABEL_PATTERNS = {
	{ match = "zoom_shoot", label = "attack_aimed_shoot" },
	{ match = "brace", label = "attack_aimed_shoot" },
	{ match = "aim", label = "attack_aimed_shoot" },
	{ match = "charged", label = "attack_charged_shoot" },
	{ match = "charge", label = "attack_charged_shoot" },
	{ match = "alt", label = "attack_alt_shoot" },
	{ match = "secondary", label = "attack_alt_shoot" },
	{ match = "primary", label = "attack_shoot" },
	{ match = "shoot", label = "attack_shoot" },
	{ match = "bash", label = "attack_bash" },
	{ match = "stab", label = "attack_bash" },
	{ match = "special", label = "attack_special" },
	{ match = "light", label = "attack_light" },
	{ match = "heavy", label = "attack_heavy" },
}

-- Substring match that refuses to match the tail of a longer word, so a short
-- token like "alt" cannot fire on an unrelated name that merely contains it.
local function contains_token(source, token)
	local position = 1

	while true do
		local found = string.find(source, token, position, true)

		if not found then
			return false
		end

		if found == 1 or not string.match(string.sub(source, found - 1, found - 1), "%a") then
			return true
		end

		position = found + 1
	end
end

-- Works out what to call an attack mode.
--
-- Two sources, because neither is complete on its own:
--   1. the action input's name (shoot / zoom_shoot / charge / bash ...)
--   2. the damage profile's name, which routinely encodes the mode even when the
--      input name does not -- e.g. `plasma_p1_m2_charged` says "charged" outright.
--
-- The second source is what labels a weapon family whose input names are unknown,
-- without me having to see its template. The raw input name is deliberately NOT
-- shown: it belongs in /wepcheckstate and the dump, not on screen.
local function label_for_input(input_name, profile)
	local sources = {
		type(input_name) == "string" and string.lower(input_name) or nil,
		type(profile) == "table" and type(profile.name) == "string" and string.lower(profile.name) or nil,
	}

	for s = 1, #sources do
		local source = sources[s]

		if source then
			for i = 1, #LABEL_PATTERNS do
				if contains_token(source, LABEL_PATTERNS[i].match) then
					return LABEL_PATTERNS[i].label
				end
			end
		end
	end

	return "attack_other"
end

-- Display order: primary fire, aimed, charged, melee secondary, special, rest.
local INPUT_PRIORITY = {
	shoot = 1,
	shoot_pressed = 1,
	zoom_shoot = 2,
	charge = 3,
	charge_release = 3,
	keep_charging = 3,
	bash = 4,
	stab = 4,
	special_action = 5,
	special_action_hold = 5,
	special_action_light = 5,
	special_action_heavy = 5,
}

local function input_priority(input_name)
	return INPUT_PRIORITY[input_name] or 6
end

-- Forward declared: learn_profile (below) invalidates it.
local MODE_CACHE

-- Profiles observed in play, keyed by weapon template. Template introspection
-- cannot know every weapon family's layout, but a landed hit *proves* which
-- profile an action used, so once you have fired the weapon the indicator can
-- still answer.
local LEARNED = setmetatable({}, { __mode = "k" })

function weapon_profiles.learn_profile(weapon_template, profile)
	if type(weapon_template) ~= "table" or type(profile) ~= "table" then
		return false
	end

	local learned = LEARNED[weapon_template]

	if not learned then
		learned = {}
		LEARNED[weapon_template] = learned
	end

	if learned[profile] then
		return false
	end

	learned[profile] = true
	MODE_CACHE[weapon_template] = nil

	return true
end

local function looks_like_damage_profile(value)
	if type(value) ~= "table" then
		return false
	end

	if type(value.armor_damage_modifier) == "table" then
		return true
	end

	if type(value.armor_damage_modifier_ranged) == "table" then
		return true
	end

	-- A profile with neither is not usable here anyway, so it does not count.
	return false
end

-- Explicit paths, tried in order, so the common cases never depend on scan order.
local EXPLICIT_PATHS = {
	{ "damage_profile" },
	{ "fire_configuration", "damage_profile" },
	{ "fire_configuration", "shotshell", "damage_profile" },
	{ "fire_configuration", "shotshell" },
	{ "fire_configuration", "shotshell", "projectile" },
	{ "fire_configuration", "shotshell", "projectile_template" },
}

local function path_value(root, path)
	local value = root

	for i = 1, #path do
		if type(value) ~= "table" then
			return nil
		end

		value = value[path[i]]
	end

	return value
end

local function path_string(path)
	return table.concat(path, ".")
end

-- Walks a subtree looking for damage-profile-shaped tables, and records the key
-- path each one was found at -- a precise path is what makes a missed profile
-- diagnosable from a single dump.
local function scan_for_profiles(node, out, depth, seen, prefix)
	if depth > MAX_SEARCH_DEPTH or type(node) ~= "table" or seen[node] then
		return
	end

	seen[node] = true

	if looks_like_damage_profile(node) then
		out[#out + 1] = { profile = node, path = prefix }

		return
	end

	-- Sorted keys, because `pairs` order is undefined and the first profile found
	-- has to be the same one every frame.
	local keys = {}

	for key in pairs(node) do
		keys[#keys + 1] = key
	end

	table.sort(keys, function (a, b)
		return tostring(a) < tostring(b)
	end)

	for i = 1, #keys do
		if #out >= MAX_PROFILES_PER_MODE then
			return
		end

		scan_for_profiles(node[keys[i]], out, depth + 1, seen, prefix .. "." .. tostring(keys[i]))
	end
end

-- Asks the game what an action hits with. Returns an empty table when the game
-- module is unavailable, so the caller can fall back to table inspection.
local function profiles_via_game_impl(action)
	local found = {}

	if not Action or type(Action.damage_template) ~= "function" then
		return found
	end

	local count = 1

	if type(Action.num_damage_templates) == "function" then
		local ok_count, templates = pcall(Action.num_damage_templates, action)

		if ok_count and type(templates) == "number" and templates > 0 then
			count = templates
		end
	end

	local seen = {}

	for index = 1, count do
		local ok, profile, special_profile = pcall(Action.damage_template, action, index)

		if ok and type(profile) == "table" and not seen[profile] then
			seen[profile] = true

			found[#found + 1] = {
				profile = profile,
				special_profile = type(special_profile) == "table" and special_profile or nil,
				path = "Action.damage_template(" .. index .. ")",
			}
		end
	end

	return found
end

profiles_via_game = profiles_via_game_impl

-- Returns the profiles reachable from one action, each with the route that found
-- it: the game's resolver by preference, table inspection as a fallback.
function weapon_profiles.profiles_in_action(action)
	local found = {}

	if type(action) ~= "table" then
		return found
	end

	-- The game's resolver first: it knows every action kind.
	found = profiles_via_game(action)

	if #found > 0 then
		return found
	end

	local seen_profiles = {}

	local function collect(found_here)
		for j = 1, #found_here do
			local entry = found_here[j]

			if not seen_profiles[entry.profile] then
				seen_profiles[entry.profile] = true

				found[#found + 1] = entry
			end
		end
	end

	for i = 1, #EXPLICIT_PATHS do
		local path = EXPLICIT_PATHS[i]
		local value = path_value(action, path)

		if type(value) == "table" and not seen_profiles[value] then
			-- The path may land on the profile itself or on a container of them.
			local collected = {}

			scan_for_profiles(value, collected, 1, {}, path_string(path))
			collect(collected)
		end
	end

	if #found > 0 then
		return found
	end

	-- Nothing on a known path: search the whole action, deterministically.
	local collected = {}

	scan_for_profiles(action, collected, 1, {}, "action")
	collect(collected)

	return found
end

MODE_CACHE = setmetatable({}, { __mode = "k" })

-- The weapon's damage-dealing modes, in display order.
-- A content signature for a damage profile: its armour modifier for every armour
-- type, in both the flat and the distance-banded shape. Two profiles with the same
-- signature behave identically, so showing both is noise. Read straight off the
-- tables so this module needs no dependency on armor.lua.
local SIGNATURE_ARMOR_TYPES = {
	"unarmored",
	"armored",
	"berserker",
	"resistant",
	"disgustingly_resilient",
	"super_armor",
}

local function raw_armor_value(profile, armor_type)
	local tables = {
		profile.armor_damage_modifier,
		profile.armor_damage_modifier_ranged,
	}

	for i = 1, #tables do
		local candidate = tables[i]

		if type(candidate) == "table" then
			-- Flat shape, or banded by distance.
			local attack = candidate.attack
				or (type(candidate.near) == "table" and candidate.near.attack)
				or (type(candidate.far) == "table" and candidate.far.attack)

			if type(attack) == "table" then
				local value = attack[armor_type]

				if type(value) == "number" then
					return tostring(value)
				elseif type(value) == "table" then
					return tostring(value[1]) .. "-" .. tostring(value[2])
				end
			end
		end
	end

	return "-"
end

local function profile_signature(profile)
	if type(profile) ~= "table" then
		return "nil"
	end

	local parts = {}

	for i = 1, #SIGNATURE_ARMOR_TYPES do
		local armor_type = SIGNATURE_ARMOR_TYPES[i]

		parts[i] = raw_armor_value(profile, armor_type)
	end

	return table.concat(parts, ",")
end

-- Each entry: { input, label, action_name, profile, path }
function weapon_profiles.attack_modes(weapon_template)
	if type(weapon_template) ~= "table" then
		return {}
	end

	local cached = MODE_CACHE[weapon_template]

	if cached then
		return cached
	end

	local modes = {}
	local actions = weapon_template.actions
	local used_profiles = {}

	-- Enumerate the weapon's own actions. Any input-triggered action that resolves
	-- to a damage profile is a mode -- there is deliberately no list of "known
	-- damage inputs" to fall outside of, because that is exactly what made whole
	-- weapon families (revolver, plasma) show nothing at all. Bookkeeping inputs are
	-- excluded by role so the rows stay meaningful.
	local candidates = {}

	if type(actions) == "table" then
		for _, action in pairs(actions) do
			if type(action) == "table" then
				local input = action.start_input

				if type(input) == "string"
					and not NON_DAMAGE_INPUTS[input]
					and not is_bookkeeping_input(input)
				then
					local profiles = weapon_profiles.profiles_in_action(action)

					if #profiles > 0 then
						candidates[#candidates + 1] = {
							input = input,
							action_name = action.name,
							profile = profiles[1].profile,
							path = profiles[1].path,
						}
					end
				end
			end
		end
	end

	-- Deterministic display order, so the rows do not shuffle between frames.
	table.sort(candidates, function (a, b)
		local pa, pb = input_priority(a.input), input_priority(b.input)

		if pa ~= pb then
			return pa < pb
		end

		if a.input ~= b.input then
			return a.input < b.input
		end

		return tostring(a.action_name) < tostring(b.action_name)
	end)

	local used_signatures = {}

	for i = 1, #candidates do
		if #modes >= MAX_MODES then
			break
		end

		local candidate = candidates[i]
		local signature = profile_signature(candidate.profile)

		-- Skip a mode whose profile is already shown, or whose armour behaviour is
		-- identical to one already shown -- two rows with the same numbers are noise,
		-- not information.
		if not used_profiles[candidate.profile] and not used_signatures[signature] then
			used_profiles[candidate.profile] = true
			used_signatures[signature] = true

			modes[#modes + 1] = {
				input = candidate.input,
				label = label_for_input(candidate.input, candidate.profile),
				action_name = candidate.action_name,
				profile = candidate.profile,
				path = candidate.path,
				source = "template",
			}
		end
	end

	-- Then anything actually observed in play that introspection did not account
	-- for. These carry a neutral label because what triggers them is unknown.
	local learned = LEARNED[weapon_template]

	if learned then
		for profile in pairs(learned) do
			if #modes >= MAX_MODES then
				break
			end

			if not used_profiles[profile] then
				used_profiles[profile] = true

				modes[#modes + 1] = {
					input = "learned",
					label = "attack_other",
					action_name = nil,
					profile = profile,
					path = "observed",
					source = "learned",
				}
			end
		end
	end

	MODE_CACHE[weapon_template] = modes

	return modes
end

-- Reconnaissance for the diagnostics dump: every action input of the weapon, the
-- action it starts, and which profiles (and by which path) were found. This is
-- what makes a single in-game run enough to fix a missed profile location.
function weapon_profiles.mode_probe(weapon_template)
	local out = {}

	if type(weapon_template) ~= "table" then
		return out
	end

	local actions = weapon_template.actions

	if type(actions) ~= "table" then
		return out
	end

	-- Driven by the actions themselves rather than by action_inputs, so an action
	-- whose input is not declared in action_inputs still shows up here.
	for _, action in pairs(actions) do
		if type(action) == "table" and type(action.start_input) == "string" then
			local input_name = action.start_input
			local entry = out[input_name]

			if not entry then
				local profiles = weapon_profiles.profiles_in_action(action)

				entry = {
					kind = action.kind,
					actions = {},
					profiles = {},
					skipped_as_non_damage = NON_DAMAGE_INPUTS[input_name] == true,
					bookkeeping = is_bookkeeping_input(input_name),
					label = label_for_input(input_name, profiles[1] and profiles[1].profile),
				}

				out[input_name] = entry
			end

			entry.actions[#entry.actions + 1] = action.name

			local profiles = weapon_profiles.profiles_in_action(action)

			for i = 1, #profiles do
				entry.profiles[#entry.profiles + 1] = {
					name = profiles[i].profile.name,
					path = profiles[i].path,
				}
			end
		end
	end

	return out
end

return weapon_profiles
