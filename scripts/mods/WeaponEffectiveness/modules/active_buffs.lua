-- active_buffs.lua -- the buffs currently running on a unit, ready to draw.
--
-- Why this is possible at all: the game's own HUD does not special-case anything,
-- it walks `buff_extension:buffs()` and draws the ones whose template carries an
-- icon. So the same walk gives the same list, and no UI has to be scraped.
--
-- There is deliberately no name: buff templates have `name` (an internal id) but no
-- display_name, and the native bar shows only the icon plus a stack numeral. Making
-- up a label here would be inventing text the game never shows.
--
-- Ordering is by urgency: expiring soonest first, permanent buffs last. The native
-- bar uses hud_priority, which is about icon placement, not about what a player
-- wants to read first.

local active_buffs = {}

-- The same filter the game's buff bar applies.
local function shows_in_hud(template)
	if type(template) ~= "table" then
		return false
	end

	if template.hide_icon_in_hud == true then
		return false
	end

	return type(template.hud_icon) == "string" and template.hud_icon ~= ""
end

local function call_number(buff, method_name)
	if type(buff[method_name]) ~= "function" then
		return nil
	end

	local ok, value = pcall(buff[method_name], buff)

	if ok and type(value) == "number" then
		return value
	end

	return nil
end

local function template_of(buff)
	if type(buff) ~= "table" then
		return nil
	end

	if type(buff.template) ~= "function" then
		return nil
	end

	local ok, template = pcall(buff.template, buff)

	return ok and template or nil
end

-- Every buff running on `unit` that the game would show, with the numbers needed to
-- draw it. Never raises: an unreadable buff extension yields an empty list.
function active_buffs.list(unit)
	local out = {}

	if not unit then
		return out
	end

	local extension = ScriptUnit.has_extension(unit, "buff_system")

	if not extension or type(extension.buffs) ~= "function" then
		return out
	end

	local ok, buffs = pcall(extension.buffs, extension)

	if not ok or type(buffs) ~= "table" then
		return out
	end

	for _, buff in pairs(buffs) do
		local template = template_of(buff)

		if shows_in_hud(template) then
			local duration = call_number(buff, "duration")
			local progress = call_number(buff, "duration_progress")

			-- duration_progress is the fraction REMAINING (1 at the moment the buff
			-- starts, 0 as it expires), which is what the icon's sweep wants.
			local remaining = nil

			if duration and progress then
				remaining = duration * progress
			end

			out[#out + 1] = {
				template_name = type(template.name) == "string" and template.name or nil,
				icon = template.hud_icon,
				-- visual_stack_count is what the native bar prints, so it is preferred
				-- over the raw count.
				stacks = call_number(buff, "visual_stack_count") or call_number(buff, "stack_count") or 1,
				duration = duration,
				progress = progress,
				remaining = remaining,
			}
		end
	end

	table.sort(out, function (left, right)
		local left_remaining = left.remaining
		local right_remaining = right.remaining

		if left_remaining and right_remaining then
			if left_remaining == right_remaining then
				return (left.template_name or "") < (right.template_name or "")
			end

			return left_remaining < right_remaining
		end

		if left_remaining then
			return true
		end

		if right_remaining then
			return false
		end

		return (left.template_name or "") < (right.template_name or "")
	end)

	return out
end

-- The localised name for a buff, or nil when nothing could resolve one.
function active_buffs.resolved_name(entry, names)
	local template_name = entry and entry.template_name

	if type(template_name) ~= "string" then
		return nil
	end

	local named = type(names) == "table" and names[template_name] or nil

	if type(named) == "string" and named ~= "" then
		return named
	end

	return nil
end

-- Kept for callers that want *something* to print rather than nothing.
function active_buffs.display_name(entry, names)
	local resolved = active_buffs.resolved_name(entry, names)

	if resolved then
		return resolved
	end

	local template_name = entry and entry.template_name

	if type(template_name) ~= "string" then
		return "?"
	end

	return (string.gsub(template_name, "_", " "))
end

-- The one-line summary a text row can carry, e.g. "Energy Cycle x3 4s".
--
-- Only buffs that could be NAMED are listed. Buff templates carry no display_name
-- of their own (checked across all 2656 of them), so a buff granted by a talent we
-- have no name for would otherwise print its internal id -- "veteran toughness on
-- elite kill effect" -- which is worse than useless on a HUD. The unnamed ones are
-- counted instead, as "+2", so nothing disappears silently.
function active_buffs.summary(entries, limit, names)
	local pieces = {}
	local unnamed = 0

	for i = 1, math.min(#(entries or {}), limit or 4) do
		local entry = entries[i]
		local text = active_buffs.resolved_name(entry, names)

		if not text then
			unnamed = unnamed + 1
		else
			if (entry.stacks or 1) > 1 then
				text = text .. " x" .. tostring(entry.stacks)
			end

			if entry.remaining then
				text = text .. string.format(" %.0fs", entry.remaining)
			end

			pieces[#pieces + 1] = text
		end
	end

	local line = table.concat(pieces, "  ·  ")

	if unnamed > 0 then
		line = (line ~= "" and (line .. "  ") or "") .. "+" .. tostring(unnamed)
	end

	return line
end

return active_buffs
