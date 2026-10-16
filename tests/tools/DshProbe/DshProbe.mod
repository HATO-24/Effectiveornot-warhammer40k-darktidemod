return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`DshProbe` requires the Darktide Mod Framework.")

		new_mod("DshProbe", {
			mod_script = "DshProbe/scripts/mods/DshProbe/DshProbe",
			mod_data = "DshProbe/scripts/mods/DshProbe/DshProbe_data",
		})
	end,
	packages = {},
}
