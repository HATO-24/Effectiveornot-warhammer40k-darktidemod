-- hit_marker.lua -- registers this mod's damage-number marker template and
-- spawns the numbers themselves.
--
-- Spawns are deliberately narrow: only hits that came out reduced, weak or
-- immune get one. An effective hit keeps whatever the game already draws, so a
-- healthy number is never duplicated on screen.

local hit_marker = {}

local POOL_SIZE = 48
local POOL_PREFIX = "weapon_effectiveness_hit#"
local WORLD_MARKERS_ELEMENT = "HudElementWorldMarkers"

local config = {}
local template = nil
local counter = 0
local hook_installed = false

function hit_marker.install(settings)
	config = settings or {}
	template = config.template
end

local function world_markers_element()
	local ui_manager = Managers and Managers.ui
	local hud = ui_manager and ui_manager:get_hud()

	if not hud or not hud.element then
		return nil
	end

	local ok, element = pcall(function ()
		return hud:element(WORLD_MARKERS_ELEMENT)
	end)

	if ok then
		return element
	end

	return nil
end

local function register_into(element)
	if not template or not element then
		return false
	end

	if type(element._marker_templates) ~= "table" then
		return false
	end

	element._marker_templates[template.name] = template

	-- Pooled type names so several numbers can be alive at once.
	for index = 1, POOL_SIZE do
		element._marker_templates[string.format("%s%d", POOL_PREFIX, index)] = template
	end

	return true
end

local function install_hook()
	if hook_installed or not template then
		return false
	end

	local mod = config.mod
	local element_class = CLASS and CLASS.HudElementWorldMarkers

	if not mod or not element_class then
		return false
	end

	local ok = pcall(function ()
		mod:hook_safe(element_class, "init", function (self)
			register_into(self)
		end)
	end)

	if ok then
		hook_installed = true
	end

	return ok
end

-- Called every frame: the HUD may not exist yet when the mod loads, and it may
-- be rebuilt (the mod's own recreate_hud does exactly that), so registration has
-- to survive both.
function hit_marker.ensure_registered()
	if not template then
		return false
	end

	if not hook_installed then
		install_hook()
	end

	local element = world_markers_element()

	if not element then
		return false
	end

	if type(element._marker_templates) == "table" and element._marker_templates[template.name] then
		return true
	end

	return register_into(element)
end

-- Reported in the diagnostics dump: if the marker never registers, no number can
-- ever appear, and this says which step failed.
function hit_marker.status()
	local element = world_markers_element()
	local templates = element and element._marker_templates
	local template_name = template and template.name or nil
	local registered = type(templates) == "table"
		and template_name ~= nil
		and templates[template_name] ~= nil

	return {
		hook_installed = hook_installed,
		template_name = template_name,
		world_markers_element = element ~= nil,
		registered = registered and true or false,
		spawned = counter,
	}
end

local function pooled_name()
	counter = (counter % POOL_SIZE) + 1

	return string.format("%s%d", POOL_PREFIX, counter)
end

-- Returns true when a number was actually spawned.
function hit_marker.spawn(record, unit, hit_position)
	if not template or not record or not hit_position or not unit then
		return false
	end

	if config.enabled and not config.enabled() then
		return false
	end

	local ok_alive, alive = pcall(Unit.alive, unit)

	if ok_alive and alive == false then
		return false
	end

	-- Only the hits worth flagging.
	local verdict = record.verdict

	if verdict ~= "reduced" and verdict ~= "weak" and verdict ~= "immune" then
		return false
	end

	local element = world_markers_element()

	if not element or not element.event_add_world_marker_unit then
		return false
	end

	if type(element._marker_templates) ~= "table" or not element._marker_templates[template.name] then
		if not register_into(element) then
			return false
		end
	end

	local color = config.color_for and config.color_for(verdict)

	if not color then
		return false
	end

	local damage_value = math.floor((tonumber(record.damage) or 0) + 0.5)
	local text = tostring(damage_value)

	if config.show_multiplier and config.show_multiplier() and type(record.max) == "number" then
		text = string.format("%s x%.2f", text, record.max)
	end

	local data = {
		dmg = damage_value,
		text = text,
		color = color,
		font_size = config.font_size and config.font_size() or nil,
		hit_pos = hit_position,
		lift = 0.25,
		life = config.lifetime and config.lifetime() or 1.2,
		rise_px = 40,
		screen_offset_y_px = 26,
		use_world_position = true,
	}

	local ok = pcall(function ()
		element:event_add_world_marker_unit(pooled_name(), unit, nil, data)
	end)

	return ok
end

return hit_marker
