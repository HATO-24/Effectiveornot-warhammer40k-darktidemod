local mod = get_mod("WeaponEffectiveness")

local Settings = mod:io_dofile("WeaponEffectiveness/scripts/mods/WeaponEffectiveness/hud/hud_element_weapon_effectiveness_settings")

local UIWorkspaceSettings = mod:original_require("scripts/settings/ui/ui_workspace_settings")
local UIWidget = mod:original_require("scripts/managers/ui/ui_widget")

local settings_vertical_alignment = Settings.vertical_alignment
local settings_horizontal_alignment = Settings.horizontal_alignment

-- Rows are label + value pairs so the attack name can stay neutral while the
-- verdict carries its own colour, without relying on inline text markup.
-- `stats` is the live panel (rending / weakspot / crit), `blessings` is the wielded
-- weapon's trait list, and `buffs` / `debuffs` are the live buffs on the player and
-- on the aimed enemy -- both fed separately from the attack lines.
local ROWS = { "armor", "light", "heavy", "special", "stats", "blessings", "buffs", "debuffs" }

-- How many buffs each of the two buff rows can draw. Beyond this the extra ones are
-- dropped: a crowded line is worse than a truncated one.
local BUFF_SLOTS = 4

local BUFF_ICON_SIZE = 18
local BUFF_SLOT_WIDTH = 46
local BUFF_BAR_WIDTH = 30
local BUFF_BAR_HEIGHT = 3

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

	-- The two buff rows draw the game's own buff icons, side by side, each with a
	-- progress bar under it. Icons and bars are only built from primitives that are
	-- already proven in this HUD: a texture pass for the icon (the template's
	-- hud_icon, the same asset the native bar shows) and two rects for the bar --
	-- the foreground one is narrowed every frame, the way dopamine's progress bars
	-- work. Slot i's state lives under "<row>_<i>", "<row>_<i>_stacks" and so on.
	if row == "buffs" or row == "debuffs" then
		for slot = 1, BUFF_SLOTS do
			local id = row .. "_" .. slot
			local x = label_width + (slot - 1) * BUFF_SLOT_WIDTH
			local icon_y = row_y
			local bar_y = row_y + BUFF_ICON_SIZE + 1

			passes[#passes + 1] = {
				pass_type = "texture",
				value_id = id,
				style_id = id,
				style = {
					size = { BUFF_ICON_SIZE, BUFF_ICON_SIZE },
					offset = { x, icon_y, 1 },
					vertical_alignment = settings_vertical_alignment,
					horizontal_alignment = settings_horizontal_alignment,
					color = { opacity, 255, 255, 255 },
				},
				visibility_function = function (content)
					return type(content[id]) == "string" and content[id] ~= ""
				end,
			}

			passes[#passes + 1] = {
				pass_type = "rect",
				style_id = id .. "_bar_bg",
				style = {
					size = { BUFF_BAR_WIDTH, BUFF_BAR_HEIGHT },
					offset = { x, bar_y, 1 },
					vertical_alignment = settings_vertical_alignment,
					horizontal_alignment = settings_horizontal_alignment,
					color = { math.floor(opacity * 0.4), 0, 0, 0 },
				},
				visibility_function = function (content)
					return type(content[id]) == "string" and content[id] ~= ""
				end,
			}

			passes[#passes + 1] = {
				pass_type = "rect",
				style_id = id .. "_bar",
				style = {
					-- Width is overwritten from the remaining fraction each frame.
					size = { BUFF_BAR_WIDTH, BUFF_BAR_HEIGHT },
					offset = { x, bar_y, 2 },
					vertical_alignment = settings_vertical_alignment,
					horizontal_alignment = settings_horizontal_alignment,
					color = { opacity, 235, 200, 120 },
				},
				change_function = function (content, style)
					local fraction = tonumber(content[id .. "_progress"]) or 1

					if fraction < 0 then
						fraction = 0
					elseif fraction > 1 then
						fraction = 1
					end

					style.size[1] = math.max(1, math.floor(BUFF_BAR_WIDTH * fraction + 0.5))
				end,
				visibility_function = function (content)
					return type(content[id]) == "string" and content[id] ~= "" and content[id .. "_progress"] ~= nil
				end,
			}

			-- Stack numeral and remaining seconds, next to the icon, like the native
			-- bar's stack count.
			passes[#passes + 1] = {
				pass_type = "text",
				value_id = id .. "_stacks",
				style_id = id .. "_stacks",
				style = {
					font_type = font_type,
					font_size = math.max(10, math.floor(font_size * 0.7)),
					size = { BUFF_SLOT_WIDTH, line_height },
					offset = { x + BUFF_ICON_SIZE + 1, icon_y - 1, 2 },
					vertical_alignment = settings_vertical_alignment,
					horizontal_alignment = settings_horizontal_alignment,
					text_vertical_alignment = "top",
					text_horizontal_alignment = "left",
					text_color = { opacity, 255, 255, 255 },
				},
			}

			passes[#passes + 1] = {
				pass_type = "text",
				value_id = id .. "_time",
				style_id = id .. "_time",
				style = {
					font_type = font_type,
					font_size = math.max(10, math.floor(font_size * 0.7)),
					size = { BUFF_SLOT_WIDTH, line_height },
					offset = { x + BUFF_ICON_SIZE + 1, icon_y + math.floor(line_height * 0.5), 2 },
					vertical_alignment = settings_vertical_alignment,
					horizontal_alignment = settings_horizontal_alignment,
					text_vertical_alignment = "top",
					text_horizontal_alignment = "left",
					text_color = { opacity, 205, 195, 175 },
				},
			}
		end
	end
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
	buff_slots = BUFF_SLOTS,
}
