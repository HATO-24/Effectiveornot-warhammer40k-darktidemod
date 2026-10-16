// Runs the shipped weapon_profiles.lua against a weapon template built to the
// real game format, taken verbatim from enginseers_workbench's power sword
// template (the file that exposed the tap-vs-hold bug).
//
// The point is the input predicates: light_attack and heavy_attack both map to
// action_one_hold and differ only in the required value, so any implementation
// that keys off the input *name* silently never fires.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const MOD = path.join(__dirname, '..');
const SRC = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'weapon_profiles.lua');

const TEST = `
local failures = 0
local checks = 0

local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("  FAIL %-52s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-52s %s", label, tostring(got)))
	end
end

-- Faithful to the real template: both attack inputs are action_one_hold and the
-- tap-vs-hold split lives in the required value.
local power_sword = {
	name = "test_powersword",
	weapon_special_class = "WeaponSpecialActivateToggle",
	action_inputs = {
		start_attack = { input_sequence = { { input = "action_one_hold", value = true } } },
		light_attack = { input_sequence = { { input = "action_one_hold", time_window = 0.35, value = false } } },
		heavy_attack = {
			input_sequence = {
				{ duration = 0.35, input = "action_one_hold", value = true },
				{ auto_complete = true, input = "action_one_hold", time_window = 1, value = false },
			},
		},
		attack_cancel = { input_sequence = { { hold_input = "action_one_hold", input = "action_two_pressed", value = true } } },
	},
	actions = {
		action_start = {
			name = "action_start", start_input = "start_attack", kind = "start_attack",
			damage_profile = { name = "light_attack_profile" },
			allowed_chain_actions = {
				light_attack = { action_name = "action_left_light", chain_time = 0.2 },
				heavy_attack = { action_name = "action_left_heavy", chain_time = 0.4 },
			},
		},
		action_left_light = {
			name = "action_left_light", kind = "light_attack",
			damage_profile = { name = "light_attack_profile" },
			damage_profile_special_active = { name = "light_special_profile" },
		},
		action_left_heavy = {
			name = "action_left_heavy", kind = "heavy_attack",
			damage_profile = { name = "heavy_attack_profile" },
			damage_profile_special_active = { name = "heavy_special_profile" },
		},
	},
}

-- A weapon that declares no action inputs at all (ranged weapons look like this).
local plain = {
	name = "test_plain",
	actions = {
		action_start = {
			name = "action_start", start_input = "start_attack", kind = "start_attack",
			damage_profile = { name = "flat_profile" },
			allowed_chain_actions = {
				light_attack = { action_name = "action_light" },
				heavy_attack = { action_name = "action_heavy" },
			},
		},
		action_light = { name = "action_light", kind = "light_attack", damage_profile = { name = "flat_profile" } },
		action_heavy = { name = "action_heavy", kind = "heavy_attack", damage_profile = { name = "heavy_profile" } },
	},
}

-- A ranged weapon. Note there is no damage_profile on the action itself: the
-- profile lives under fire_configuration.shotshell, which is exactly how the real
-- templates are built.
local rifle = {
	name = "test_rifle",
	action_inputs = {
		shoot = { input_sequence = { { input = "action_one_pressed", value = true } } },
		zoom_shoot = { input_sequence = { { input = "action_one_hold", value = true } } },
		reload = { input_sequence = { { input = "reload_pressed", value = true } } },
	},
	actions = {
		action_shoot_hip = {
			name = "action_shoot_hip", start_input = "shoot", kind = "shoot_pellets",
			fire_configuration = {
				shotshell = {
					damage_profile = {
						name = "hip_profile",
						armor_damage_modifier_ranged = {
							near = { attack = { armored = 1 } },
							far = { attack = { armored = 1 } },
						},
					},
				},
			},
		},
		action_shoot_zoomed = {
			name = "action_shoot_zoomed", start_input = "zoom_shoot", kind = "shoot_pellets",
			fire_configuration = {
				shotshell = {
					-- Reachable only through the generic scan, not a direct path.
					projectile_template = {
						sub = {
							damage_profile = {
								name = "zoom_profile",
								armor_damage_modifier_ranged = {
									near = { attack = { armored = 0.5 } },
									far = { attack = { armored = 0.5 } },
								},
							},
						},
					},
				},
			},
		},
		action_reload = { name = "action_reload", start_input = "reload", kind = "reload" },
	},
}

-- A weapon whose start action has no chain at all.
local stub = {
	name = "test_stub",
	actions = {
		action_start = { name = "action_start", start_input = "start_attack", damage_profile = { name = "only_profile" } },
	},
}

print("== chain resolution ==")
local r = weapon_profiles.resolve(power_sword)
check("light action resolved", r.light and r.light.action_name, "action_left_light")
check("heavy action resolved", r.heavy and r.heavy.action_name, "action_left_heavy")
check("light kind", r.light and r.light.kind, "light_attack")
check("has_special detected via damage_profile_special_active", r.has_special, true)
check("special profile found on light", r.light and r.light.special_profile and r.light.special_profile.name, "light_special_profile")
check("special profile found on heavy", r.heavy and r.heavy.special_profile and r.heavy.special_profile.name, "heavy_special_profile")

local rp = weapon_profiles.resolve(plain)
check("plain: light resolved", rp.light and rp.light.action_name, "action_light")
check("plain: no special mode", rp.has_special, false)

local rs = weapon_profiles.resolve(stub)
check("stub: light is nil", rs.light, nil)
check("stub: heavy is nil", rs.heavy, nil)

print("")
print("== action-input predicates (the tap-vs-hold rule) ==")
local li = weapon_profiles.input_for_action_input(power_sword, "light_attack")
local hi = weapon_profiles.input_for_action_input(power_sword, "heavy_attack")
check("light input name", li and li.input, "action_one_hold")
check("heavy input name", hi and hi.input, "action_one_hold")
check("SAME input name for both", li.input == hi.input, true)
check("light requires value false", li and li.value, false)
check("heavy requires value true", hi and hi.value, true)

local function held(names)
	return function(name)
		return names[name] == true
	end
end

check("tap (not held) -> light", weapon_profiles.attack_kind_from_input(power_sword, held({})), "light")
check("hold -> heavy", weapon_profiles.attack_kind_from_input(power_sword, held({ action_one_hold = true })), "heavy")
check("no mapping at all -> nil", weapon_profiles.attack_kind_from_input(plain, held({ action_one_hold = true })), nil)

print("")
print("== current action name, with strength ==")
local k1, s1 = weapon_profiles.current_attack_kind(power_sword, r, "action_left_heavy")
check("heavy chain action kind", k1, "heavy")
check("heavy chain action strength", s1, "strong")
local k2, s2 = weapon_profiles.current_attack_kind(power_sword, r, "action_left_light")
check("light chain action kind", k2, "light")
check("light chain action strength", s2, "strong")
local k3, s3 = weapon_profiles.current_attack_kind(power_sword, r, "action_heavy_1")
check("unknown action named heavy", k3, "heavy")
check("unknown action strength is weak", s3, "weak")
check("none -> nil", weapon_profiles.current_attack_kind(power_sword, r, "none"), nil)

print("")
print("== attack_modes: a ranged weapon's fire modes ==")
local modes = weapon_profiles.attack_modes(rifle)
check("two modes found", #modes, 2)
check("first mode input", modes[1] and modes[1].input, "shoot")
check("first mode action", modes[1] and modes[1].action_name, "action_shoot_hip")
check("first mode profile", modes[1] and modes[1].profile and modes[1].profile.name, "hip_profile")
check("first mode path", modes[1] and modes[1].path, "fire_configuration.shotshell.damage_profile")
check("first mode label", modes[1] and modes[1].label, "attack_shoot")
check("second mode input", modes[2] and modes[2].input, "zoom_shoot")
check("second mode profile", modes[2] and modes[2].profile and modes[2].profile.name, "zoom_profile")
check("second mode label", modes[2] and modes[2].label, "attack_aimed_shoot")
check("modes are cached per template", weapon_profiles.attack_modes(rifle), modes)
check("no action_inputs -> no modes", #weapon_profiles.attack_modes(plain), 0)

print("")
print("== mode_probe reports every start_input action ==")
local probe = weapon_profiles.mode_probe(rifle)
check("shoot probed", probe.shoot and probe.shoot.actions[1], "action_shoot_hip")
check("shoot profiles found", probe.shoot and #probe.shoot.profiles, 1)
check("zoom_shoot profiles found", probe.zoom_shoot and #probe.zoom_shoot.profiles, 1)
check("zoom_shoot path recorded", probe.zoom_shoot and probe.zoom_shoot.profiles[1].path, "fire_configuration.shotshell.projectile_template.sub.damage_profile")
check("reload probed but empty", probe.reload and #probe.reload.profiles, 0)
check("reload flagged non-damage", probe.reload and probe.reload.skipped_as_non_damage, true)

print("")
print("== THE REGRESSION: an action input no list mentions ==")
-- The revolver and plasma showed nothing because detection depended on a known input
-- name. Any input-triggered action with a profile must now become a mode.
local exotic = {
	name = "test_exotic",
	actions = {
		action_primary = {
			name = "action_primary", start_input = "primary_action", kind = "shoot_pellets",
			fire_configuration = {
				shotshell = {
					damage_profile = {
						name = "exotic_profile",
						armor_damage_modifier_ranged = {
							near = { attack = { armored = 0.25 } },
							far = { attack = { armored = 0.25 } },
						},
					},
				},
			},
		},
	},
}
local exotic_modes = weapon_profiles.attack_modes(exotic)
check("unknown input still yields a mode", #exotic_modes, 1)
check("its profile", exotic_modes[1] and exotic_modes[1].profile.name, "exotic_profile")
check("'primary' names the main shot", exotic_modes[1] and exotic_modes[1].label, "attack_shoot")
check("source is the template", exotic_modes[1] and exotic_modes[1].source, "template")

print("")
print("== bookkeeping inputs are excluded, identical profiles collapse ==")
local noisy = {
	name = "test_noisy",
	actions = {
		action_shoot = {
			name = "action_shoot", start_input = "shoot", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "shared_profile",
				armor_damage_modifier_ranged = { near = { attack = { armored = 1 } } },
			} } },
		},
		-- A release action carrying an equivalent profile must not add a second row.
		action_shoot_release = {
			name = "action_shoot_release", start_input = "shoot_release", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "release_profile",
				armor_damage_modifier_ranged = { near = { attack = { armored = 1 } } },
			} } },
		},
		-- A distinct profile under a follow-up input: excluded by role, not by name list.
		action_push_follow = {
			name = "action_push_follow", start_input = "push_follow_up", kind = "sweep",
			damage_profile = {
				name = "push_profile",
				armor_damage_modifier = { attack = { armored = 0.2 } },
			},
		},
	},
}
local noisy_modes = weapon_profiles.attack_modes(noisy)
check("only the real fire mode survives", #noisy_modes, 1)
check("and it is the shoot one", noisy_modes[1] and noisy_modes[1].input, "shoot")

print("")
print("== an unmatched input keeps its own name as the label ==")
local unnamed = {
	name = "test_unnamed",
	actions = {
		action_weird = {
			name = "action_weird", start_input = "zap_the_heretic", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "zap_profile",
				armor_damage_modifier_ranged = { near = { attack = { armored = 1 } } },
			} } },
		},
	},
}
local unnamed_modes = weapon_profiles.attack_modes(unnamed)
check("still a mode", #unnamed_modes, 1)
check("no hint anywhere -> generic label", unnamed_modes[1] and unnamed_modes[1].label, "attack_other")

print("")
print("== the PROFILE name labels a mode whose input name says nothing ==")
-- This is the plasma case: the input name is opaque, but the profile is called
-- ..._charged, so the row can still say "charged" on its own.
local profile_named = {
	name = "test_profile_named",
	actions = {
		action_a = {
			name = "action_a", start_input = "ghjk_a", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "plasma_p1_m2_charged",
				armor_damage_modifier_ranged = { near = { attack = { armored = 1.33 } } },
			} } },
		},
		action_b = {
			name = "action_b", start_input = "ghjk_b", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "plasma_p1_m2",
				armor_damage_modifier_ranged = { near = { attack = { armored = 0.69 } } },
			} } },
		},
		-- "alt" appears inside a longer word: must NOT be read as alt-fire.
		action_c = {
			name = "action_c", start_input = "halter_shot", kind = "shoot_pellets",
			fire_configuration = { shotshell = { damage_profile = {
				name = "walter_special_profile",
				armor_damage_modifier_ranged = { near = { attack = { armored = 0.1 } } },
			} } },
		},
	},
}
local named_modes = weapon_profiles.attack_modes(profile_named)
local by_profile = {}
for i = 1, #named_modes do
	by_profile[named_modes[i].profile.name] = named_modes[i].label
end
check("charged profile -> charged label", by_profile["plasma_p1_m2_charged"], "attack_charged_shoot")
check("plain profile -> generic label", by_profile["plasma_p1_m2"], "attack_other")
check("'alt' inside a word is not alt-fire", by_profile["walter_special_profile"], "attack_special")

print("")
print("== learning: a profile observed in play becomes a mode ==")
local learnable = {
	name = "test_learnable",
	actions = {
		action_weird = { name = "action_weird", start_input = "weird_input", kind = "shoot_pellets" },
	},
}
check("nothing detected at first", #weapon_profiles.attack_modes(learnable), 0)
local observed = {
	name = "weird_profile",
	armor_damage_modifier_ranged = { near = { attack = { armored = 0.5 } }, far = { attack = { armored = 0.5 } } },
}
check("learn_profile accepts it", weapon_profiles.learn_profile(learnable, observed), true)
check("learning it twice is a no-op", weapon_profiles.learn_profile(learnable, observed), false)
local learned_modes = weapon_profiles.attack_modes(learnable)
check("now a mode exists", #learned_modes, 1)
check("it is the observed profile", learned_modes[1] and learned_modes[1].profile.name, "weird_profile")
check("marked as learned", learned_modes[1] and learned_modes[1].source, "learned")
check("non-damage inputs are skipped", weapon_profiles.attack_modes(rifle) and #weapon_profiles.attack_modes(rifle), 2)

print("")
print("== active profile selection ==")
local normal, normal_variant = weapon_profiles.active_profile(r.light, false)
local special, special_variant = weapon_profiles.active_profile(r.light, true)
check("special off -> normal profile", normal and normal.name, "light_attack_profile")
check("special off -> variant", normal_variant, "normal")
check("special on -> special profile", special and special.name, "light_special_profile")
check("special on -> variant", special_variant, "special")

print("")
print("== the game's resolver is preferred, and it reaches deep profiles ==")
-- Reproduces the plasma / revolver / Lucius failure: the real profile sits at
-- fire_configuration.hit_scan_template.damage.impact.damage_profile, five levels
-- down, past the depth-limited table scan. Only the game's resolver can reach it.
local deep_action = {
	name = "action_deep", start_input = "deep_shoot", kind = "shoot_hit_scan",
	fire_configuration = {
		hit_scan_template = {
			damage = {
				impact = {
					damage_profile = {
						name = "deep_profile",
						armor_damage_modifier_ranged = { near = { attack = { armored = 1.33 } } },
					},
				},
			},
		},
	},
}
local deep_profile = deep_action.fire_configuration.hit_scan_template.damage.impact.damage_profile

-- Register it with the stubbed game module only.
ACTION_BY_ACTION[deep_action] = { { deep_profile } }

local deep_profiles = weapon_profiles.profiles_in_action(deep_action)
check("deep profile found", #deep_profiles, 1)
check("via the game resolver", deep_profiles[1] and deep_profiles[1].path, "Action.damage_template(1)")
check("and it is the right profile", deep_profiles[1] and deep_profiles[1].profile.name, "deep_profile")

-- Prove the table-scan fallback alone would have missed it.
ACTION_BY_ACTION[deep_action] = nil
check("table scan alone cannot reach it", #weapon_profiles.profiles_in_action(deep_action), 0)

print("")
print("== a special variant comes back as the resolver's second return ==")
local special_action = { name = "action_special_deep", start_input = "deep_special" }
local base_profile = { name = "deep_base", armor_damage_modifier = { attack = { armored = 1 } } }
local special_variant = { name = "deep_special_profile", armor_damage_modifier = { attack = { armored = 1.5 } } }
ACTION_BY_ACTION[special_action] = { { base_profile, special_variant } }

local got_special, got_source = weapon_profiles.special_profile_of(special_action)
check("special variant via the resolver", got_special and got_special.name, "deep_special_profile")
check("and its source is named", got_source, "Action.damage_template")

print("")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
`;

const PRELUDE = `
-- The module asks the game for damage profiles at load time. Stubbing that module
-- makes the primary path testable; without the stub the module correctly falls
-- back to inspecting tables, which the other assertions already cover.
ACTION_BY_ACTION = {}
local REAL_REQUIRE = require
require = function (name)
	if name == "scripts/utilities/action/action" then
		return {
			by_action = ACTION_BY_ACTION,
			num_damage_templates = function (action)
				local list = ACTION_BY_ACTION[action]
				return list and #list or 1
			end,
			damage_template = function (action, index)
				local list = ACTION_BY_ACTION[action]
				if list and list[index] then
					return list[index][1], list[index][2]
				end
				return nil
			end,
		}
	end
	if REAL_REQUIRE then return REAL_REQUIRE(name) end
	return nil
end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	PRELUDE,
	'local weapon_profiles = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	'local os_exit_stub = nil',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
