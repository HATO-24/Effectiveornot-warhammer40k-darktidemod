-- effectiveness_marker.lua -- the world marker that draws this mod's own damage
-- number for hits that were reduced or ineffective.
--
-- Why it exists: the game only has three damage-number colours (default / crit /
-- weakspot), decided by two booleans on the enemy's health extension, so there is
-- no slot for "this hit barely did anything". Rather than patch Healthbars or
-- CustomDamageNumbers -- neither exposes a seam -- this draws its own number at
-- the hit position, and only for the hits that need flagging.
--
-- The registration/spawn pattern is the one Healthbars and DamageNumbers use:
-- put a template into HudElementWorldMarkers._marker_templates, then spawn with
-- event_add_world_marker_unit.
--
-- Colour and text arrive in `data` rather than being read from settings here, so
-- all colour decisions live in the main script.

local UIFontSettings = require("scripts/managers/ui/ui_font_settings")
local UIWidget = require("scripts/managers/ui/ui_widget")

local template = {}

local BASE_FONT_SIZE = 24

template.name = "weapon_effectiveness_hit"
template.size = { 400, 200 }

-- `j_head` rather than a made-up node name: Healthbars uses exactly this node for
-- its markers on every enemy breed, so it is known to resolve. The marker only
-- needs a valid node for the instant it is created -- update_function immediately
-- detaches it and pins it to the recorded hit position instead.
template.unit_node = "j_head"
template.position_offset = { 0, 0, 0.4 }

-- A damage number must not be hidden because the enemy stepped behind cover, so
-- line of sight is deliberately not required.
template.check_line_of_sight = false
template.screen_clamp = false
template.remove_on_death_duration = 0.5

template.max_distance = 60
template.min_distance = 0

local function base_text_style()
	local style = table.clone(UIFontSettings.hud_body)

	style.font_size = BASE_FONT_SIZE
	style.text_color = { 255, 240, 130, 60 }
	style.default_text_color = style.text_color
	style.drop_shadow = true
	style.offset = { 0, -26, 20 }
	style.default_offset = { 0, -26, 20 }
	style.size = { template.size[1], template.size[2] }
	style.horizontal_alignment = "center"
	style.vertical_alignment = "center"
	style.text_horizontal_alignment = "center"
	style.text_vertical_alignment = "center"

	return style
end

-- Note the game's own spelling: "defintion", not "definition".
template.create_widget_defintion = function (_, scenegraph_id)
	return UIWidget.create_definition({
		{
			pass_type = "text",
			value_id = "text",
			style_id = "text",
			style = base_text_style(),
			visibility_function = function (content, _style)
				return content.text and content.text ~= ""
			end,
		},
	}, scenegraph_id)
end

template.on_enter = function (widget)
	widget.content.text = widget.content.text or ""
end

-- The hit position arrives as a Vector3Box (what the attack report carries), a
-- plain Vector3, or a table.
--
-- The type must never be probed by *indexing* the value. Vector3Box's metatable
-- __index is Vector3's C __index, so an expression like `vec.unbox` raises
-- "bad argument #1 to '__index' (Vector3 or Vector4 expected, got userdata)" --
-- which is exactly what killed the game from inside the marker update when the
-- force sword's beam landed. Every attempt below is wrapped, and the box is
-- unwrapped through the static `Vector3Box.unbox`, which touches no metatable.
local function vec_xyz(vec)
	if vec == nil then
		return nil
	end

	-- Vector3Box first: unwrapping goes through the static helper, which touches no
	-- metatable on the value at all.
	if Vector3Box and Vector3Box.unbox then
		local ok_box, unboxed = pcall(Vector3Box.unbox, vec)

		if ok_box and unboxed ~= nil then
			local ok_xyz, x, y, z = pcall(function ()
				return Vector3.x(unboxed), Vector3.y(unboxed), Vector3.z(unboxed)
			end)

			if ok_xyz and type(x) == "number" then
				return x, y, z
			end
		end
	end

	if type(vec) == "table" then
		-- Even these are guarded: a table with a hostile __index would otherwise raise.
		local ok_array, x, y, z = pcall(function ()
			return vec[1], vec[2], vec[3]
		end)

		if ok_array and type(x) == "number" then
			return x, y, z
		end

		local ok_fields, fx, fy, fz = pcall(function ()
			return vec.x, vec.y, vec.z
		end)

		if ok_fields and type(fx) == "number" then
			return fx, fy, fz
		end
	end

	-- Deliberately reached even for tables: an unrecognised table should still get
	-- the engine accessors tried rather than giving up here.
	local ok_vec, x, y, z = pcall(function ()
		return Vector3.x(vec), Vector3.y(vec), Vector3.z(vec)
	end)

	if ok_vec and type(x) == "number" then
		return x, y, z
	end

	return nil
end

template.update_function = function (_parent, _ui_renderer, widget, marker, _template, dt, _t)
	if not marker or not widget then
		return false
	end

	local data = marker.data or {}

	-- Detach from any unit the marker was created against and pin it to the world
	-- position the hit landed on instead.
	--
	-- If the position cannot be read, the marker simply stays attached to the unit:
	-- a number anchored above the enemy is a far better outcome than an error
	-- raised every frame from inside the HUD update. `_we_worldpos_failed` stops it
	-- retrying.
	if not marker._we_worldpos_applied and not marker._we_worldpos_failed then
		local x, y, z = vec_xyz(data.hit_pos)

		if x and y and z then
			local lift = data.lift or 0.25

			marker._we_worldpos_box = Vector3Box and Vector3Box(x, y, z + lift)
				or Vector3(x, y, z + lift)
			marker._we_worldpos_applied = true
		else
			marker._we_worldpos_failed = true
		end
	end

	if marker._we_worldpos_box then
		marker.world_position = marker._we_worldpos_box
		marker.use_world_position = true
		marker.unit = nil
		marker.unit_node = nil
		marker.node_index = -1
	end

	local content = widget.content
	local style = widget.style.text

	content.text = data.text or tostring(data.dmg or "")
	style.font_size = data.font_size or BASE_FONT_SIZE

	local color = data.color

	if color and style.text_color then
		style.text_color[2] = color[2] or 255
		style.text_color[3] = color[3] or 255
		style.text_color[4] = color[4] or 255
	end

	marker._we_elapsed = (marker._we_elapsed or 0) + (dt or 0)

	local life = data.life or 1.2
	local age = marker._we_elapsed
	local progress = math.clamp(life > 0 and age / life or 0, 0, 1)
	local rise_px = data.rise_px or 40

	style.offset[1] = 0
	style.offset[2] = -(data.screen_offset_y_px or 26) - age * rise_px

	-- Hold full opacity, then fade over the last quarter of the lifetime.
	local base_alpha = (color and color[1]) or 255
	local alpha = base_alpha

	if progress > 0.75 then
		alpha = math.floor(base_alpha * (1 - (progress - 0.75) / 0.25))
	end

	if style.text_color then
		style.text_color[1] = alpha
	end

	widget.visible = progress < 1

	if not marker._we_life_applied then
		marker.life_time = life
		marker._we_life_applied = true
	end

	if age >= life then
		widget.visible = false

		return true
	end

	return false
end

return template
