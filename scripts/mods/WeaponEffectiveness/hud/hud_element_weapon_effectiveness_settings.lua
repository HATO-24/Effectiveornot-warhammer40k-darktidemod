local hud_element_weapon_effectiveness_settings = {
	vertical_alignment = "center",
	horizontal_alignment = "center",
	scenegraph_size = { 100, 100 },
	scenegraph_position = { 0, 0, 0 },
	-- Width is the text region each row draws into; the header line ("enemy name ·
	-- head armour · torso armour") is the longest string this mod produces, so the
	-- region is sized for it rather than for the attack rows.
	widget_size = { 700, 240 },
	widget_vertical_offset = 38,
	widget_horizontal_offset = 96,
}

return settings("HudElementWeaponEffectivenessSettings", hud_element_weapon_effectiveness_settings)
