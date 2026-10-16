return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`WeaponEffectiveness` encountered an error loading the Darktide Mod Framework.")

		new_mod("WeaponEffectiveness", {
			mod_script       = "WeaponEffectiveness/scripts/mods/WeaponEffectiveness/WeaponEffectiveness",
			mod_data         = "WeaponEffectiveness/scripts/mods/WeaponEffectiveness/WeaponEffectiveness_data",
			mod_localization = "WeaponEffectiveness/scripts/mods/WeaponEffectiveness/WeaponEffectiveness_localization",
		})
	end,
	packages = {},
}
