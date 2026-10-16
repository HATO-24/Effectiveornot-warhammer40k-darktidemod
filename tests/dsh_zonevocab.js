// Answers the question the previous breed test could not: does the zone-name
// vocabulary actually match the keys used by breed.hitzone_armor_override?
//
// The old test compared armor.armor_type_for_hitzone(breed, zone.name) against
// override[zone.name], which is self-consistent by construction and therefore
// proves nothing about which names the ENGINE hands us at runtime.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');

const BUNDLE = path.join(__dirname, 'bundles', 'breeds_bundle.lua');

const TEST = `
local override_keys, zone_names = {}, {}
local override_count, zone_count = 0, 0
local super_overrides = {}
local breeds_with_override = 0

for bname, breed in pairs(bundle.breeds) do
	local ov = breed.hitzone_armor_override
	if type(ov) == "table" then
		local any = false
		for k, v in pairs(ov) do
			any = true
			override_count = override_count + 1
			override_keys[k] = (override_keys[k] or 0) + 1
			if v == "super_armor" then
				super_overrides[#super_overrides + 1] = string.format("%s zone=%s breed_armor=%s", bname, tostring(k), tostring(breed.armor_type))
			end
		end
		if any then breeds_with_override = breeds_with_override + 1 end
	end
	local zs = breed.hit_zones
	if type(zs) == "table" then
		for _, z in pairs(zs) do
			if type(z) == "table" and type(z.name) == "string" then
				zone_count = zone_count + 1
				zone_names[z.name] = (zone_names[z.name] or 0) + 1
			end
		end
	end
end

local function show(title, t)
	local list = {}
	for k, v in pairs(t) do list[#list + 1] = string.format("%s(%d)", tostring(k), v) end
	table.sort(list)
	print(title .. ": " .. table.concat(list, "  "))
end

print("breeds with any override: " .. breeds_with_override)
print("override entries: " .. override_count .. "   hit_zones entries: " .. zone_count)
print("")
show("OVERRIDE KEYS", override_keys)
print("")
show("ZONE NAMES   ", zone_names)
print("")

local only_override, only_zone = {}, {}
for k in pairs(override_keys) do if not zone_names[k] then only_override[#only_override + 1] = tostring(k) end end
for k in pairs(zone_names) do if not override_keys[k] then only_zone[#only_zone + 1] = tostring(k) end end
table.sort(only_override); table.sort(only_zone)

print("KEYS ONLY IN OVERRIDE: " .. table.concat(only_override, ", "))
print("ZONE NAMES NEVER OVERRIDDEN: " .. table.concat(only_zone, ", "))
print("")
print("=== breeds with a super_armor (carapace) override ===")
table.sort(super_overrides)
for i = 1, math.min(#super_overrides, 30) do print("   " .. super_overrides[i]) end
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	'local bundle = (function()',
	fs.readFileSync(BUNDLE, 'utf8'),
	'end)()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + lua.lua_tojsstring(L, -1));
	process.exit(1);
}
