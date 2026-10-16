local mod = get_mod("WeaponEffectiveness")

local Definitions = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/hud/hud_element_weapon_effectiveness_definitions")
local Settings = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/hud/hud_element_weapon_effectiveness_settings")

local HudElementWeaponEffectiveness = class("HudElementWeaponEffectiveness", "HudElementBase")

local WIDGET = "weapon_effectiveness"
local ROWS = Definitions.rows
local LINE_HEIGHT = Definitions.line_height
local LABEL_WIDTH = Definitions.label_width

local VERDICT_LOC = {
	effective = "verdict_effective",
	reduced = "verdict_reduced",
	weak = "verdict_weak",
	immune = "verdict_immune",
	unknown = "verdict_unknown",
}

local ATTACK_LOC = {
	light = "attack_light",
	heavy = "attack_heavy",
	special = "attack_special",
	stats = "live_stats_label",
}

-- The live panel row is not an attack line: it is filled from state.live_panel.
local STATS_ROW = "stats"

local ARMOR_ROW = "armor"

-- ASCII on purpose: it is guaranteed to exist in every font the game ships.
local ACTIVE_MARKER = "> "

local LABEL_COLOR_BASE = { 205, 195, 175 }

-- Mod text is served by `mod:localize`. The game's global Localize only knows its
-- own strings plus whatever a mod explicitly registered with
-- add_global_localize_strings, so calling it with a mod key renders as
-- "unlocalized" on screen -- which is exactly what happened here. Vanilla `loc_*`
-- keys still go through the game localizer.
local function localize(key)
	if not key then
		return ""
	end

	local ok, text = pcall(mod.localize, mod, key)

	-- mod:localize returns "<key>" for a key it does not have.
	if ok and type(text) == "string" and text ~= "" and text ~= ("<" .. key .. ">") then
		return text
	end

	local ok_game, game_text = pcall(Localize, key)

	if ok_game and type(game_text) == "string" and game_text ~= "" then
		local lowered = string.lower(game_text)

		if not string.find(lowered, "unlocalized", 1, true)
			and not string.find(game_text, "loc_", 1, true)
			and string.sub(game_text, 1, 1) ~= "<"
		then
			return game_text
		end
	end

	-- Nothing resolved: show the raw key rather than a placeholder, so the failure
	-- is at least legible instead of reading "unlocalized".
	return key
end

local function set_row(self, row, label, value, color, visible)
	local widget = self._widgets_by_name[WIDGET]

	if not widget then
		return
	end

	local label_style = widget.style[row .. "_label"]
	local value_style = widget.style[row .. "_value"]

	if not label_style or not value_style then
		return
	end

	local is_visible = visible == true

	label_style.visible = is_visible
	value_style.visible = is_visible

	widget.content[row .. "_label"] = label or ""
	widget.content[row .. "_value"] = value or ""

	if color then
		value_style.text_color = color
	end
end

HudElementWeaponEffectiveness.on_resolution_modified = function(self)
	HudElementWeaponEffectiveness.super.on_resolution_modified(self)
end

HudElementWeaponEffectiveness.init = function(self, parent, draw_layer, start_scale)
	HudElementWeaponEffectiveness.super.init(self, parent, draw_layer, start_scale, Definitions)

	HudElementWeaponEffectiveness.set_offset(self)
end

HudElementWeaponEffectiveness.destroy = function(self, ui_renderer)
	HudElementWeaponEffectiveness.super.destroy(self, ui_renderer)
end

HudElementWeaponEffectiveness.update = function(self, dt, t, ui_renderer, render_settings, input_service)
	HudElementWeaponEffectiveness.super.update(self, dt, t, ui_renderer, render_settings, input_service)

	local widget = self._widgets_by_name[WIDGET]

	if not widget then
		return
	end

	local state = mod.state

	if not state or not state.visible then
		for index = 1, #ROWS do
			set_row(self, ROWS[index], "", "", nil, false)
		end

		return
	end

	-- Clear first, then fill in whatever applies this frame, so a row cannot get
	-- stuck showing last frame's verdict.
	for index = 1, #ROWS do
		set_row(self, ROWS[index], "", "", nil, false)
	end

	if mod:get("show_indicator") == false then
		return
	end

	local only_training = mod:get("only_in_training_grounds")

	if only_training then
		local game_mode = Managers.state and Managers.state.game_mode
		local mode_name = game_mode and game_mode:game_mode_name()

		if mode_name ~= "shooting_range" then
			return
		end
	end

	-- Header: who is under the crosshair, and how its parts are armoured. The
	-- aimed part is not printed -- that could not be resolved reliably -- so the
	-- header describes the enemy and each attack row says where to hit it.
	local header = state.header or {}
	local header_parts = {}

	if header.name and header.name ~= "" then
		header_parts[#header_parts + 1] = header.name
	end

	if mod:get("show_armor_name") ~= false then
		if header.parts and #header.parts > 0 then
			-- Parts differ in armour: name each one.
			for index = 1, #header.parts do
				local part = header.parts[index]
				local text = localize(part.zone_key)

				if part.armor and part.armor ~= "" then
					text = text .. " " .. part.armor
				end

				header_parts[#header_parts + 1] = text
			end
		elseif header.armor and header.armor ~= "" then
			-- One armour everywhere: name it once.
			header_parts[#header_parts + 1] = header.armor
		end
	end

	if state.has_special and state.special_active then
		header_parts[#header_parts + 1] = localize("special_active_marker")
	end

	if #header_parts > 0 then
		set_row(self, ARMOR_ROW, "", table.concat(header_parts, " · "), mod.neutral_color(), true)
	end

	local show_multiplier = mod:get("show_multiplier") ~= false

	local lines_by_kind = {}

	for index = 1, #state.lines do
		local line = state.lines[index]

		lines_by_kind[line.kind] = line
	end

	for index = 1, #ROWS do
		local row = ROWS[index]
		local line = lines_by_kind[row]

		-- The live panel is its own row: read straight from the composed stats.
		if row == STATS_ROW then
			local panel = state.live_panel or {}
			local pieces = {}

			for panel_index = 1, #panel do
				local entry = panel[panel_index]
				local name = localize(entry.key)

				if name ~= "" then
					pieces[#pieces + 1] = name .. " " .. tostring(entry.value)
				end
			end

			if #pieces > 0 then
				set_row(self, row, localize(ATTACK_LOC[row]), table.concat(pieces, "  ·  "), mod.neutral_color(), true)
			end
		elseif line then
			local label = localize(ATTACK_LOC[row])

			if line.active then
				label = ACTIVE_MARKER .. label
			end

			-- The value lists every body part with its own multiplier, in the same
			-- order the header names them, so the columns line up between rows. The
			-- verdict is carried by the colour, taken from the best part.
			local pieces = {}

			for part_index = 1, #(line.parts or {}) do
				local part = line.parts[part_index]
				local text = localize(part.zone_key)

				if show_multiplier and type(part.value) == "number" then
					text = text .. "  " .. string.format("x%.2f", part.value)
				end

				pieces[#pieces + 1] = text
			end

			local value = table.concat(pieces, "  ·  ")

			if value == "" and type(line.max) == "number" and show_multiplier then
				value = string.format("x%.2f", line.max)
			end

			if value == "" then
				value = localize(VERDICT_LOC[line.verdict] or "verdict_unknown")
			end

			set_row(self, row, label, value, mod.verdict_color(line.verdict), true)
		end
	end
end

-- Reads the configured offsets and re-stacks the rows under them.
HudElementWeaponEffectiveness.set_offset = function(self)
	local widget = self._widgets_by_name and self._widgets_by_name[WIDGET]

	if not widget then
		return
	end

	local horizontal = mod:get("indicator_horizontal_offset")

	if horizontal == nil then
		horizontal = Settings.widget_horizontal_offset
	end

	local vertical = mod:get("indicator_vertical_offset")

	if vertical == nil then
		vertical = Settings.widget_vertical_offset
	end

	for index = 1, #ROWS do
		local row = ROWS[index]
		local y = vertical + (index - 1) * LINE_HEIGHT
		local label_style = widget.style[row .. "_label"]
		local value_style = widget.style[row .. "_value"]

		if label_style then
			label_style.offset = { horizontal, y, 0 }
		end

		if value_style then
			value_style.offset = { horizontal + LABEL_WIDTH, y, 0 }
		end
	end
end

HudElementWeaponEffectiveness.set_font = function(self, font_type, font_size)
	local widget = self._widgets_by_name and self._widgets_by_name[WIDGET]

	if not widget then
		return
	end

	for index = 1, #ROWS do
		local row = ROWS[index]

		for _, suffix in ipairs({ "_label", "_value" }) do
			local style = widget.style[row .. suffix]

			if style then
				style.font_type = font_type
				style.font_size = font_size
			end
		end
	end
end

-- Verdict colours are re-read from the settings every frame, so only the neutral
-- label colour has to be pushed here.
HudElementWeaponEffectiveness.apply_colors = function(self)
	local widget = self._widgets_by_name and self._widgets_by_name[WIDGET]

	if not widget then
		return
	end

	local opacity = mod:get("indicator_opacity") or 220

	for index = 1, #ROWS do
		local style = widget.style[ROWS[index] .. "_label"]

		if style then
			style.text_color = { opacity, LABEL_COLOR_BASE[1], LABEL_COLOR_BASE[2], LABEL_COLOR_BASE[3] }
		end
	end
end

return HudElementWeaponEffectiveness
