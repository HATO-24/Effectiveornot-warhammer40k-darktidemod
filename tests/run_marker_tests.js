// Tests for effectiveness_marker.lua's update path.
//
// This is the code that killed the game: the marker update ran from inside the HUD
// update, probed the hit position with `vec.unbox`, and hit Vector3Box's __index
// (which is Vector3's C __index) -> "bad argument #1 to '__index'".
//
// The engine types are stubbed to behave like the real ones: a Vector3Box can only
// be unwrapped through the static Vector3Box.unbox, and indexing it as a Vector3
// raises exactly the error seen in the crash log.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'markers', 'effectiveness_marker.lua');

const STUBS = `
-- ============================ engine stubs ============================
local INDEX_ERROR = "bad argument #1 to '__index' (Vector3 or Vector4 expected, got userdata)"

local function vec3(x, y, z)
	return { _kind = "Vector3", _x = x, _y = y, _z = z }
end

local function vec3box(x, y, z)
	-- Indexing a box is what blows up in the real engine, so mirror that.
	return setmetatable({ _kind = "Vector3Box", _v = vec3(x, y, z) }, {
		__index = function () error(INDEX_ERROR) end,
	})
end

Vector3 = setmetatable({
	x = function (v)
		if type(v) ~= "table" or v._kind ~= "Vector3" then error(INDEX_ERROR) end
		return v._x
	end,
	y = function (v)
		if type(v) ~= "table" or v._kind ~= "Vector3" then error(INDEX_ERROR) end
		return v._y
	end,
	z = function (v)
		if type(v) ~= "table" or v._kind ~= "Vector3" then error(INDEX_ERROR) end
		return v._z
	end,
}, {
	__call = function (_, x, y, z) return vec3(x, y, z) end,
})

Vector3Box = setmetatable({
	unbox = function (b)
		if type(b) ~= "table" or b._kind ~= "Vector3Box" then
			error("bad argument #1 to 'unbox' (Vector3Box expected)")
		end
		return b._v
	end,
}, {
	__call = function (_, x, y, z) return vec3box(x, y, z) end,
})

UIFontSettings = { hud_body = { font_size = 20 } }
UIWidget = { create_definition = function (passes, scenegraph_id) return { passes = passes, scenegraph_id = scenegraph_id } end }

if not table.clone then
	table.clone = function (t)
		local out = {}
		for k, v in pairs(t) do out[k] = v end
		return out
	end
end

if not math.clamp then
	math.clamp = function (v, lo, hi) return math.max(lo, math.min(hi, v)) end
end

local function make_widget()
	return {
		content = { text = "" },
		style = { text = { offset = { 0, 0, 0 }, text_color = { 255, 255, 255, 255 }, font_size = 24 } },
		visible = true,
	}
end

-- A value that raises on ANY index, standing in for whatever exotic userdata the
-- engine may hand over.
local function hostile_value()
	return setmetatable({}, { __index = function () error(INDEX_ERROR) end })
end

-- The marker file requires these two game modules at load time.
local REAL_REQUIRE = require
require = function (p)
	if p == "scripts/managers/ui/ui_font_settings" then return UIFontSettings end
	if p == "scripts/managers/ui/ui_widget" then return UIWidget end
	return REAL_REQUIRE(p)
end
`;

const TESTS = `
local checks, failures = 0, 0
local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("  FAIL %-56s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-56s %s", label, tostring(got)))
	end
end

-- The whole point: update_function must never raise, whatever the position is.
local function run_case(label, hit_pos, age)
	local widget = make_widget()
	local marker = {
		data = {
			text = "42",
			color = { 220, 240, 130, 60 },
			hit_pos = hit_pos,
			lift = 0.25,
			life = 1.2,
			rise_px = 40,
			screen_offset_y_px = 26,
			font_size = 24,
		},
		_we_elapsed = age or 0,
	}

	local ok, err = pcall(template.update_function, nil, nil, widget, marker, template, 0.016, 1)

	check(label .. ": no error", ok, true)
	if not ok then
		print("        -> " .. tostring(err))
	end
	return marker, widget
end

print("== widget definition builds ==")
local defs = template.create_widget_defintion(template, "sg")
check("create_widget_defintion returns a table", type(defs) == "table", true)

print("")
print("== a plain table position resolves and pins the marker ==")
local m1, w1 = run_case("table", { 1, 2, 3 })
check("world position applied", m1._we_worldpos_applied, true)
check("not marked failed", m1._we_worldpos_failed, nil)
check("world_position set", m1.world_position ~= nil, true)
check("detached from unit", m1.unit, nil)
check("text drawn", w1.content.text, "42")
check("visible", w1.visible, true)

print("")
print("== a Vector3Box position resolves ==")
local m2 = run_case("vec3box", vec3box(4, 5, 6))
check("world position applied", m2._we_worldpos_applied, true)
check("not marked failed", m2._we_worldpos_failed, nil)

print("")
print("== a plain Vector3 position resolves ==")
local m3 = run_case("vec3", vec3(7, 8, 9))
check("world position applied", m3._we_worldpos_applied, true)

print("")
print("== THE CRASH CASE: a value that raises on any index ==")
local m4 = run_case("hostile", hostile_value())
check("no world position applied", m4._we_worldpos_applied, nil)
check("marked failed instead", m4._we_worldpos_failed, true)
check("stays attached to the unit", m4.unit, nil)

print("")
print("== retry is skipped once it has failed ==")
local m5 = run_case("hostile-again", hostile_value(), 0.5)
check("already failed, not retried", m5._we_worldpos_failed, true)

print("")
print("== nil position degrades the same way ==")
local m6 = run_case("nil", nil)
check("marked failed", m6._we_worldpos_failed, true)

print("")
print("== lifetime end returns true and hides the widget ==")
local widget7 = make_widget()
local marker7 = { data = { text = "7", color = { 255, 255, 255, 255 }, hit_pos = { 1, 1, 1 }, life = 1.0 }, _we_elapsed = 2.0 }
local done = template.update_function(nil, nil, widget7, marker7, template, 0.016, 1)
check("returns true at end of life", done, true)
check("widget hidden", widget7.visible, false)

print("")
print(string.format("%d checks, %d failures", checks, failures))
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	STUBS,
	'local template = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	TESTS,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
