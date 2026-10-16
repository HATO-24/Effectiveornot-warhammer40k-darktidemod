local mod = get_mod("WeaponEffectiveness")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "we_settings_general",
				type = "group",
				sub_widgets = {
					{
						setting_id = "show_indicator",
						type = "checkbox",
						default_value = true,
						tooltip = "show_indicator_desc",
					},
					{
						setting_id = "show_armor_name",
						type = "checkbox",
						default_value = true,
						tooltip = "show_armor_name_desc",
					},
					{
						setting_id = "show_multiplier",
						type = "checkbox",
						default_value = true,
						tooltip = "show_multiplier_desc",
					},
					{
						-- Reads the player's live damage bonuses every frame and folds
						-- them into the number. Off = the plain armour table, which is
						-- what the mod showed before this existed.
						setting_id = "use_live_stats",
						type = "checkbox",
						default_value = true,
						tooltip = "use_live_stats_desc",
					},
					{
						setting_id = "show_live_stats_panel",
						type = "checkbox",
						default_value = true,
						tooltip = "show_live_stats_panel_desc",
					},
					{
						-- Equipped blessings, read from the loadout. Shows what is on the
						-- weapon, not what has procced.
						setting_id = "show_blessings",
						type = "checkbox",
						default_value = true,
						tooltip = "show_blessings_desc",
					},
					{
						-- Per-row number switches: `show_multiplier` remains the master.
						setting_id = "show_light_multiplier",
						type = "checkbox",
						default_value = true,
						tooltip = "show_light_multiplier_desc",
					},
					{
						setting_id = "show_heavy_multiplier",
						type = "checkbox",
						default_value = true,
						tooltip = "show_heavy_multiplier_desc",
					},
					{
						setting_id = "show_special_multiplier",
						type = "checkbox",
						default_value = true,
						tooltip = "show_special_multiplier_desc",
					},
					{
						setting_id = "detail_mode",
						type = "dropdown",
						default_value = "total",
						tooltip = "detail_mode_desc",
						options = {
							{ value = "total", text = "detail_mode_total" },
							{ value = "breakdown", text = "detail_mode_breakdown" },
						},
					},
					{
						setting_id = "only_in_training_grounds",
						type = "checkbox",
						default_value = false,
						tooltip = "only_in_training_grounds_desc",
					},
					{
						-- Which physics collision filter the crosshair raycast uses.
						-- "auto" walks the candidates and takes the first that finds
						-- an enemy; the dump records which one that was.
						setting_id = "raycast_filter",
						type = "dropdown",
						default_value = "auto",
						tooltip = "raycast_filter_desc",
						options = {
							{ text = "raycast_filter_auto", value = "auto", show_widgets = {} },
							{ text = "raycast_filter_shooting", value = "filter_player_character_shooting_raycast", show_widgets = {} },
							{ text = "raycast_filter_ping", value = "filter_player_ping_target_selection", show_widgets = {} },
							{ text = "raycast_filter_aim_assist", value = "filter_ray_aim_assist_line_of_sight", show_widgets = {} },
						},
					},
				},
			},
			{
				setting_id = "we_settings_numbers",
				type = "group",
				sub_widgets = {
					{
						setting_id = "show_hit_numbers",
						type = "checkbox",
						default_value = true,
						tooltip = "show_hit_numbers_desc",
					},
					{
						setting_id = "number_show_multiplier",
						type = "checkbox",
						default_value = false,
						tooltip = "number_show_multiplier_desc",
					},
					{
						setting_id = "number_font_size",
						type = "numeric",
						default_value = 24,
						range = { 10, 48 },
						tooltip = "number_font_size_desc",
					},
				},
			},
			{
				setting_id = "we_settings_thresholds",
				type = "group",
				sub_widgets = {
					{
						-- percentage of the damage profile's armour modifier.
						-- 100 == x1.00, i.e. the weapon does at least its nominal damage.
						setting_id = "effective_min_percent",
						type = "numeric",
						default_value = 100,
						range = { 0, 300 },
						tooltip = "effective_min_percent_desc",
					},
					{
						setting_id = "reduced_min_percent",
						type = "numeric",
						default_value = 50,
						range = { 0, 300 },
						tooltip = "reduced_min_percent_desc",
					},
					{
						-- Ranged damage profiles carry their armour modifiers in two
						-- distance bands, so the readout has to pick one.
						setting_id = "ranged_band",
						type = "dropdown",
						default_value = "near",
						tooltip = "ranged_band_desc",
						options = {
							{ text = "ranged_band_near", value = "near", show_widgets = {} },
							{ text = "ranged_band_far", value = "far", show_widgets = {} },
						},
					},
				},
			},
			{
				setting_id = "we_settings_appearance",
				type = "group",
				sub_widgets = {
					{
						setting_id = "font_type",
						type = "dropdown",
						default_value = "proxima_nova_bold",
						tooltip = "font_type_desc",
						options = {
							{ text = "font_machine_medium", value = "machine_medium", show_widgets = {} },
							{ text = "font_proxima_nova_medium", value = "proxima_nova_medium", show_widgets = {} },
							{ text = "font_proxima_nova_bold", value = "proxima_nova_bold", show_widgets = {} },
							{ text = "font_itc_novarese_medium", value = "itc_novarese_medium", show_widgets = {} },
							{ text = "font_itc_novarese_bold", value = "itc_novarese_bold", show_widgets = {} },
						},
					},
					{
						setting_id = "font_size",
						type = "numeric",
						default_value = 20,
						range = { 8, 60 },
						tooltip = "font_size_desc",
					},
					{
						setting_id = "indicator_opacity",
						type = "numeric",
						default_value = 220,
						range = { 0, 255 },
						tooltip = "indicator_opacity_desc",
					},
					{
						setting_id = "color_effective_R",
						type = "numeric",
						default_value = 110,
						range = { 0, 255 },
						tooltip = "color_effective_desc",
					},
					{
						setting_id = "color_effective_G",
						type = "numeric",
						default_value = 235,
						range = { 0, 255 },
						tooltip = "color_effective_desc",
					},
					{
						setting_id = "color_effective_B",
						type = "numeric",
						default_value = 110,
						range = { 0, 255 },
						tooltip = "color_effective_desc",
					},
					{
						setting_id = "color_reduced_R",
						type = "numeric",
						default_value = 245,
						range = { 0, 255 },
						tooltip = "color_reduced_desc",
					},
					{
						setting_id = "color_reduced_G",
						type = "numeric",
						default_value = 200,
						range = { 0, 255 },
						tooltip = "color_reduced_desc",
					},
					{
						setting_id = "color_reduced_B",
						type = "numeric",
						default_value = 80,
						range = { 0, 255 },
						tooltip = "color_reduced_desc",
					},
					{
						setting_id = "color_weak_R",
						type = "numeric",
						default_value = 240,
						range = { 0, 255 },
						tooltip = "color_weak_desc",
					},
					{
						setting_id = "color_weak_G",
						type = "numeric",
						default_value = 130,
						range = { 0, 255 },
						tooltip = "color_weak_desc",
					},
					{
						setting_id = "color_weak_B",
						type = "numeric",
						default_value = 60,
						range = { 0, 255 },
						tooltip = "color_weak_desc",
					},
					{
						setting_id = "color_immune_R",
						type = "numeric",
						default_value = 235,
						range = { 0, 255 },
						tooltip = "color_immune_desc",
					},
					{
						setting_id = "color_immune_G",
						type = "numeric",
						default_value = 75,
						range = { 0, 255 },
						tooltip = "color_immune_desc",
					},
					{
						setting_id = "color_immune_B",
						type = "numeric",
						default_value = 75,
						range = { 0, 255 },
						tooltip = "color_immune_desc",
					},
				},
			},
			{
				setting_id = "we_settings_position",
				type = "group",
				sub_widgets = {
					{
						-- Pixels from the crosshair-centred default. The range covers a
						-- 1920x1080 screen in both directions, so the panel can be parked
						-- wherever it is readable.
						setting_id = "indicator_horizontal_offset",
						type = "numeric",
						default_value = 96,
						range = { -1920, 1920 },
						decimals_number = 0,
						tooltip = "indicator_horizontal_offset_desc",
					},
					{
						setting_id = "indicator_vertical_offset",
						type = "numeric",
						default_value = 38,
						range = { -1080, 1080 },
						decimals_number = 0,
						tooltip = "indicator_vertical_offset_desc",
					},
				},
			},
		},
	},
}
