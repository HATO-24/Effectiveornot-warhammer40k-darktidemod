return {
	mod_name = {
		en = "Weapon Effectiveness",
		["zh-cn"] = "武器有效性",
		["zh-tw"] = "武器有效性",
	},
	mod_description = {
		en = "Shows, next to the crosshair, which armour type the enemy you are aiming at has, and whether the weapon you are holding can actually hurt it.\n\nLight attack and heavy attack are evaluated separately; weapons with an activated special mode (power sword, relic blade, chain weapons, arc weapons, power maul, crusher) additionally show the special-mode verdict.\n\nNote: the armour modifier is a multiplier on damage, not the final damage number. Rending, brittleness, blessings and talents all change the real result, so treat this as a fast read on 'is this the right weapon for this enemy', not as a damage promise.",
		["zh-cn"] = "在准星旁显示你瞄准的敌人是什么护甲类型，以及你手持的武器能否真正打得动它。\n\n轻击与重击分别判定；带特殊模式的武器（动力剑、圣物剑、链锯类、电弧类、动力锤、粉碎者）会额外显示特殊模式下的判定。\n\n注意：护甲倍率只是伤害的乘数，不等于最终伤害数字。撕裂（rending）、脆化（brittleness）、祝福和天赋都会改变实际结果。所以请把它当作“这把武器是否适合打这个敌人”的快速判断，而不是伤害承诺。",
		["zh-tw"] = "在準星旁顯示你瞄準的敵人是什么護甲類型，以及你手持的武器能否真正打得動它。\n\n輕擊與重擊分別判定；帶特殊模式的武器（動力劍、聖物劍、鏈鋸類、電弧類、動力錘、粉碎者）會額外顯示特殊模式下的判定。\n\n注意：護甲倍率只是傷害的乘數，不等於最終傷害數字。撕裂、脆化、祝福和天賦都會改變實際結果。",
	},

	-- option groups
	we_settings_general = {
		en = "General",
		["zh-cn"] = "常规",
	},
	we_settings_numbers = {
		en = "Damage Numbers",
		["zh-cn"] = "伤害数字",
	},
	we_settings_thresholds = {
		en = "Verdict Thresholds",
		["zh-cn"] = "判定阈值",
	},
	we_settings_appearance = {
		en = "Appearance",
		["zh-cn"] = "外观",
	},
	we_settings_position = {
		en = "Position",
		["zh-cn"] = "位置",
	},

	-- general
	show_indicator = {
		en = "Show the indicator",
		["zh-cn"] = "显示指示器",
	},
	show_indicator_desc = {
		en = "Master switch for the crosshair indicator.",
		["zh-cn"] = "准星指示器的总开关。",
	},
	show_armor_name = {
		en = "Show the enemy's armour type",
		["zh-cn"] = "显示敌人护甲类型",
	},
	show_armor_name_desc = {
		en = "Show the enemy's overall armour type after its name.",
		["zh-cn"] = "在敌人名字后面显示它的整体护甲类型。",
	},
	show_multiplier = {
		en = "Show the armour multiplier",
		["zh-cn"] = "显示护甲倍率",
	},
	show_multiplier_desc = {
		en = "Append the raw armour modifier, e.g. x0.25.",
		["zh-cn"] = "在判定后面附上原始护甲倍率，例如 x0.25。",
	},
	only_in_training_grounds = {
		en = "Only in the Psykhanium",
		["zh-cn"] = "仅在灵能室显示",
	},
	only_in_training_grounds_desc = {
		en = "Restrict the indicator to the training grounds.",
		["zh-cn"] = "只在训练场（灵能室）显示指示器。",
	},
	raycast_filter = {
		en = "Crosshair raycast filter",
		["zh-cn"] = "准星射线过滤器",
	},
	raycast_filter_desc = {
		en = "Which physics collision filter the crosshair ray uses to find the enemy. Auto tries the player shooting raycast first, then the smart-tag selection filter, and records which one worked in /wepcheck. Only change this if the indicator fails to see enemies.",
		["zh-cn"] = "准星射线用哪个物理碰撞过滤器来找敌人。自动模式先试「玩家射击射线」，再试「智能标记选择」，并把实际生效的那个写进 /wepcheck。只有在指示器看不到敌人时才需要改这里。",
	},
	raycast_filter_auto = {
		en = "Auto (try in order)",
		["zh-cn"] = "自动（依次尝试）",
	},
	raycast_filter_shooting = {
		en = "Player shooting raycast",
		["zh-cn"] = "玩家射击射线",
	},
	raycast_filter_ping = {
		en = "Smart-tag target selection",
		["zh-cn"] = "智能标记目标选择",
	},
	raycast_filter_aim_assist = {
		en = "Aim-assist line of sight",
		["zh-cn"] = "瞄准辅助视线",
	},

	-- damage numbers
	show_hit_numbers = {
		en = "Show a number on ineffective hits",
		["zh-cn"] = "无效命中显示数字",
	},
	show_hit_numbers_desc = {
		en = "Draw your own damage number, coloured by effectiveness, on hits that came out reduced or ineffective. Effective hits are left alone, so a healthy number is never duplicated.",
		["zh-cn"] = "对判定为「削弱 / 微弱 / 免疫」的命中，在命中位置画出自己上色的伤害数字。有效命中不动，所以不会和游戏原有的数字重影。",
	},
	number_show_multiplier = {
		en = "Append the armour multiplier",
		["zh-cn"] = "附上护甲倍率",
	},
	number_show_multiplier_desc = {
		en = "Show the raw armour modifier next to the number, e.g. 42 x0.25.",
		["zh-cn"] = "在数字后面附上原始护甲倍率，例如 42 x0.25。",
	},
	number_font_size = {
		en = "Damage number size",
		["zh-cn"] = "伤害数字大小",
	},
	number_font_size_desc = {
		en = "Font size of the effectiveness damage numbers.",
		["zh-cn"] = "有效性伤害数字的字号。",
	},

	-- thresholds
	effective_min_percent = {
		en = "Effective at (%%)",
		["zh-cn"] = "有效的下限（%%）",
	},
	effective_min_percent_desc = {
		en = "Armour modifier at or above this percentage counts as effective. 100%% means at least nominal damage.",
		["zh-cn"] = "护甲倍率达到该百分比即算“有效”。100%% 表示至少打出名义伤害。",
	},
	reduced_min_percent = {
		en = "Reduced at (%%)",
		["zh-cn"] = "削弱的下降（%%）",
	},
	reduced_min_percent_desc = {
		en = "Armour modifier at or above this percentage (but below the effective threshold) counts as reduced. Below it, the hit is weak; zero is immune.",
		["zh-cn"] = "护甲倍率达到该百分比（但低于“有效”阈值）算“削弱”。低于它算“微弱”，为 0 算“免疫”。",
	},
	ranged_band = {
		en = "Ranged distance band",
		["zh-cn"] = "远程距离档位",
	},
	ranged_band_desc = {
		en = "Ranged weapons store their armour modifiers in two distance bands, near and far. This picks which one the crosshair verdict judges against. Melee weapons are unaffected.",
		["zh-cn"] = "远程武器的护甲倍率分「近 / 远」两个距离档位，这里选择准星判定按哪个档位来算。近战武器不受影响。",
	},
	ranged_band_near = {
		en = "Near",
		["zh-cn"] = "近",
	},
	ranged_band_far = {
		en = "Far",
		["zh-cn"] = "远",
	},

	-- appearance
	font_type = {
		en = "Font",
		["zh-cn"] = "字体",
	},
	font_type_desc = {
		en = "Font of the indicator text.",
		["zh-cn"] = "指示器文本字体。",
	},
	font_machine_medium = {
		en = "Machine Medium",
		["zh-cn"] = "Machine Medium",
	},
	font_proxima_nova_medium = {
		en = "Proxima Nova Medium",
		["zh-cn"] = "Proxima Nova Medium",
	},
	font_proxima_nova_bold = {
		en = "Proxima Nova Bold",
		["zh-cn"] = "Proxima Nova Bold",
	},
	font_itc_novarese_medium = {
		en = "ITC Novarese Medium",
		["zh-cn"] = "ITC Novarese Medium",
	},
	font_itc_novarese_bold = {
		en = "ITC Novarese Bold",
		["zh-cn"] = "ITC Novarese Bold",
	},
	font_size = {
		en = "Font size",
		["zh-cn"] = "字体大小",
	},
	font_size_desc = {
		en = "Font size of the indicator text.",
		["zh-cn"] = "指示器文本的字号。",
	},
	indicator_opacity = {
		en = "Opacity",
		["zh-cn"] = "不透明度",
	},
	indicator_opacity_desc = {
		en = "Opacity of the indicator text.",
		["zh-cn"] = "指示器文本的不透明度。",
	},
	color_effective_desc = {
		en = "Colour used for the 'effective' verdict.",
		["zh-cn"] = "“有效”判定的颜色。",
	},
	color_reduced_desc = {
		en = "Colour used for the 'reduced' verdict.",
		["zh-cn"] = "“削弱”判定的颜色。",
	},
	color_weak_desc = {
		en = "Colour used for the 'weak' verdict.",
		["zh-cn"] = "“微弱”判定的颜色。",
	},
	color_immune_desc = {
		en = "Colour used for the 'immune' verdict.",
		["zh-cn"] = "“免疫”判定的颜色。",
	},

	-- position
	indicator_horizontal_offset = {
		en = "Horizontal offset",
		["zh-cn"] = "水平偏移",
	},
	indicator_horizontal_offset_desc = {
		en = "Horizontal offset from the screen centre.",
		["zh-cn"] = "相对屏幕中心的水平偏移。",
	},
	indicator_vertical_offset = {
		en = "Vertical offset",
		["zh-cn"] = "垂直偏移",
	},
	indicator_vertical_offset_desc = {
		en = "Vertical offset from the screen centre. Negative is up.",
		["zh-cn"] = "相对屏幕中心的垂直偏移。负值向上。",
	},

	-- verdict labels
	verdict_effective = {
		en = "EFFECTIVE",
		["zh-cn"] = "有效",
		["zh-tw"] = "有效",
	},
	verdict_reduced = {
		en = "REDUCED",
		["zh-cn"] = "削弱",
		["zh-tw"] = "削弱",
	},
	verdict_weak = {
		en = "WEAK",
		["zh-cn"] = "微弱",
		["zh-tw"] = "微弱",
	},
	verdict_immune = {
		en = "IMMUNE",
		["zh-cn"] = "免疫",
		["zh-tw"] = "免疫",
	},
	verdict_unknown = {
		en = "?",
		["zh-cn"] = "?",
		["zh-tw"] = "?",
	},

	-- attack labels
	attack_light = {
		en = "Light",
		["zh-cn"] = "轻击",
		["zh-tw"] = "輕擊",
	},
	attack_heavy = {
		en = "Heavy",
		["zh-cn"] = "重击",
		["zh-tw"] = "重擊",
	},
	attack_special = {
		en = "Special",
		["zh-cn"] = "特殊",
		["zh-tw"] = "特殊",
	},
	attack_shoot = {
		en = "Shoot",
		["zh-cn"] = "射击",
		["zh-tw"] = "射擊",
	},
	attack_aimed_shoot = {
		en = "Aimed",
		["zh-cn"] = "瞄准射击",
		["zh-tw"] = "瞄準射擊",
	},
	attack_charged_shoot = {
		en = "Charged",
		["zh-cn"] = "蓄力射击",
		["zh-tw"] = "蓄力射擊",
	},
	attack_bash = {
		en = "Melee",
		["zh-cn"] = "近战攻击",
		["zh-tw"] = "近戰攻擊",
	},
	attack_alt_shoot = {
		en = "Alt fire",
		["zh-cn"] = "副射击",
		["zh-tw"] = "副射擊",
	},
	attack_other = {
		en = "Attack",
		["zh-cn"] = "攻击",
		["zh-tw"] = "攻擊",
	},
	attack_current = {
		en = "Current",
		["zh-cn"] = "当前动作",
		["zh-tw"] = "當前動作",
	},
	zone_whole_body = {
		en = "Anywhere",
		["zh-cn"] = "全身",
		["zh-tw"] = "全身",
	},
	zone_head = {
		en = "Head",
		["zh-cn"] = "头部",
		["zh-tw"] = "頭部",
	},
	zone_torso = {
		en = "Torso",
		["zh-cn"] = "躯干",
		["zh-tw"] = "軀幹",
	},
	zone_center_mass = {
		en = "Center Mass",
		["zh-cn"] = "身体中央",
		["zh-tw"] = "身體中央",
	},
	zone_upper_left_arm = {
		en = "Left Arm (Upper)",
		["zh-cn"] = "左臂（上）",
		["zh-tw"] = "左臂（上）",
	},
	zone_lower_left_arm = {
		en = "Left Arm (Lower)",
		["zh-cn"] = "左臂（下）",
		["zh-tw"] = "左臂（下）",
	},
	zone_upper_right_arm = {
		en = "Right Arm (Upper)",
		["zh-cn"] = "右臂（上）",
		["zh-tw"] = "右臂（上）",
	},
	zone_lower_right_arm = {
		en = "Right Arm (Lower)",
		["zh-cn"] = "右臂（下）",
		["zh-tw"] = "右臂（下）",
	},
	zone_upper_left_leg = {
		en = "Left Leg (Upper)",
		["zh-cn"] = "左腿（上）",
		["zh-tw"] = "左腿（上）",
	},
	zone_lower_left_leg = {
		en = "Left Leg (Lower)",
		["zh-cn"] = "左腿（下）",
		["zh-tw"] = "左腿（下）",
	},
	zone_upper_right_leg = {
		en = "Right Leg (Upper)",
		["zh-cn"] = "右腿（上）",
		["zh-tw"] = "右腿（上）",
	},
	zone_lower_right_leg = {
		en = "Right Leg (Lower)",
		["zh-cn"] = "右腿（下）",
		["zh-tw"] = "右腿（下）",
	},
	zone_shield = {
		en = "Shield",
		["zh-cn"] = "盾牌",
		["zh-tw"] = "盾牌",
	},
	zone_captain_void_shield = {
		en = "Void Shield",
		["zh-cn"] = "虚空护盾",
		["zh-tw"] = "虛空護盾",
	},
	zone_corruptor_armor = {
		en = "Corruptor Armor",
		["zh-cn"] = "腐化装甲",
		["zh-tw"] = "腐化裝甲",
	},
	zone_backpack = {
		en = "Backpack",
		["zh-cn"] = "背包",
		["zh-tw"] = "背包",
	},
	zone_tentacle = {
		en = "Tentacle",
		["zh-cn"] = "触手",
		["zh-tw"] = "觸手",
	},
	zone_right_shoulderguard = {
		en = "Shoulderguard",
		["zh-cn"] = "右肩甲",
		["zh-tw"] = "右肩甲",
	},
	zone_weakspot = {
		en = "Weakspot",
		["zh-cn"] = "弱点",
		["zh-tw"] = "弱點",
	},
	zone_afro = {
		en = "Afro",
		["zh-cn"] = "爆炸发型",
		["zh-tw"] = "爆炸髮型",
	},
	zone_tongue = {
		en = "Tongue",
		["zh-cn"] = "舌头",
		["zh-tw"] = "舌頭",
	},
	zone_upper_tail = {
		en = "Tail (Upper)",
		["zh-cn"] = "尾巴（上）",
		["zh-tw"] = "尾巴（上）",
	},
	zone_lower_tail = {
		en = "Tail (Lower)",
		["zh-cn"] = "尾巴（下）",
		["zh-tw"] = "尾巴（下）",
	},
	special_active_marker = {
		en = "[SPECIAL ON]",
		["zh-cn"] = "[特殊模式]",
		["zh-tw"] = "[特殊模式]",
	},
}
