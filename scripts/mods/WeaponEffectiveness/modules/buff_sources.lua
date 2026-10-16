-- buff_sources.lua -- which of the running buffs belong to the weapon and which to
-- the character's talents, each with the game's own localised name.
--
-- Buff templates have no display_name of their own (checked across all 2656 of
-- them), so a name has to be reverse-looked-up from whatever GRANTS the buff:
--
--   weapon blessing : the blessing's master item lists the buff templates it
--                     applies, under `buffs`; the key is the template name
--   talent          : the template declares `related_talents`, and each id has a
--                     `loc_talent_<id>` localisation key
--
-- Measured against the game's own data: 337 templates declare related_talents,
-- across 278 distinct talent ids, and 154 of those resolve through loc_talent_<id>
-- in the exported localisation. That 55% is a LOWER BOUND -- the localisation export
-- is partial (the same export carries only 497 loc_trait_* keys for the whole
-- blessing set) -- but it is the honest number to quote.
--
-- Nothing that fails to resolve is shown: an internal id on the HUD ("veteran
-- toughness on elite kill effect") is worse than a missing line, and that exact
-- string did reach the screen once.

local buff_sources = {}

buff_sources.WEAPON = "weapon"
buff_sources.TALENT = "talent"

-- The game returns the key itself when it has no string for it; treating that as a
-- name is how raw ids ended up on screen.
local function localize_key(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end

	local ok, text = pcall(Localize, key)

	if not ok or type(text) ~= "string" or text == "" or text == key then
		return nil
	end

	-- The "unlocalized" placeholder the game uses for a key it does not know.
	if string.find(text, "unlocalized", 1, true) then
		return nil
	end

	return text
end

buff_sources.localize_key = localize_key

-- The talent that granted this buff, by name, or nil.
function buff_sources.talent_name(entry)
	local talents = entry and entry.related_talents

	if type(talents) ~= "table" then
		return nil
	end

	for i = 1, #talents do
		local id = talents[i]

		if type(id) == "string" then
			local text = localize_key("loc_talent_" .. id)

			if text then
				return text
			end
		end
	end

	return nil
end

-- Where one buff belongs, and what to call it.
--   { source = "weapon" | "talent", name = <localised> }
-- Returns nil when neither source can name it, which means "do not show it".
--
-- `curated` is the hand-checked table shipped in data/buff_talent_names.lua (buff
-- template name -> talent loc key). It sits between the two derived sources on
-- purpose: a talent id cannot always be turned into its key mechanically -- some
-- carry a `_name` suffix, and some do not resemble the talent at all -- so a checked
-- mapping beats a rule when both are available.
function buff_sources.origin(entry, weapon_names, curated)
	local template_name = entry and entry.template_name

	if type(template_name) == "string" then
		if type(weapon_names) == "table" then
			local named = weapon_names[template_name]

			if type(named) == "string" and named ~= "" then
				return { source = buff_sources.WEAPON, name = named }
			end
		end

		if type(curated) == "table" then
			local key = curated[template_name]
			local text = localize_key(key)

			if text then
				return { source = buff_sources.TALENT, name = text }
			end
		end
	end

	local talent = buff_sources.talent_name(entry)

	if talent then
		return { source = buff_sources.TALENT, name = talent }
	end

	return nil
end

-- Sorts the running buffs into the two elements that display them. Entries that
-- cannot be named are dropped, and counted separately so the loss is visible in a
-- diagnostic rather than on the HUD.
--
-- Returns weapon, talent, unnamed_count. Each kept entry is the original table plus
-- `display`, so callers keep the stacks and timing.
function buff_sources.split(entries, weapon_names, curated)
	local weapon, talent, unnamed = {}, {}, 0

	for i = 1, #(entries or {}) do
		local entry = entries[i]
		local origin = buff_sources.origin(entry, weapon_names, curated)

		if origin then
			entry.display = origin.name

			if origin.source == buff_sources.WEAPON then
				weapon[#weapon + 1] = entry
			else
				talent[#talent + 1] = entry
			end
		else
			unnamed = unnamed + 1
		end
	end

	return weapon, talent, unnamed
end

return buff_sources
