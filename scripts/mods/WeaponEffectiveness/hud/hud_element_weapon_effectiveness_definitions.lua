local mod = get_mod("WeaponEffectiveness")

local Settings = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/hud/hud_element_weapon_effectiveness_settings")

local UIWorkspaceSettings = mod:original_require("scripts/settings/ui/ui_workspace_settings")
local UIWidget = mod:original_require("scripts/managers/ui/ui_widget")

local settings_vertical_alignment = Settings.vertical_alignment
local settings_horizontal_alignment = Settings.horizontal_alignment

-- Rows are label + value pairs so the attack name can stay neutral while the
-- verdict carries its own colour, without relying on inline text markup.
local ROWS = { "armor", "light", "heavy", "special" }

local font_type = mod:get("font_type") or "proxima_nova_bold"
local font_size = mod:get("font_size") or 20
local opacity = mod:get("indicator_opacity") or 220
local line_height = math.floor(font_size * 1.3 + 0.5)
local label_width = math.floor(font_size * 3.4 + 0.5)

local scenegraph_definition = {
	screen = UIWorkspaceSettings.screen,
	weapon_effectiveness_panel = {
		parent = "screen",
		vertical_alignment = settings_vertical_alignment,
		horizontal_alignment = settings_horizontal_alignment,
		size = Settings.scenegraph_size,
		position = Settings.scenegraph_position,
	},
}

local passes = {}

for index = 1, #ROWS do
	local row = ROWS[index]
	local row_y = (index - 1) * line_height

	local function base_style(x_offset, color)
		return {
			font_type = font_type,
			font_size = font_size,
			size = { Settings.widget_size[1], line_height },
			offset = { x_offset, row_y, 0 },
			vertical_alignment = settings_vertical_alignment,
			horizontal_alignment = settings_horizontal_alignment,
			text_vertical_alignment = "top",
			text_horizontal_alignment = "left",
			text_color = color,
		}
	end

	local neutral_color = { opacity, 205, 195, 175 }

	passes[#passes + 1] = {
		pass_type = "text",
		value_id = row .. "_label",
		style_id = row .. "_label",
		style = base_style(0, neutral_color),
		dirty = true,
	}

	passes[#passes + 1] = {
		pass_type = "text",
		value_id = row .. "_value",
		style_id = row .. "_value",
		style = base_style(label_width, { opacity, 255, 255, 255 }),
		dirty = true,
	}
end

local widget_definitions = {
	weapon_effectiveness = UIWidget.create_definition(passes, "weapon_effectiveness_panel"),
}

return {
	widget_definitions = widget_definitions,
	scenegraph_definition = scenegraph_definition,
	rows = ROWS,
	line_height = line_height,
	label_width = label_width,
}
