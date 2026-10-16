// Tests for input_state.lua: the two input paths, the cache TTL, and the
// graceful degradation when neither path is available.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const MOD = path.join(__dirname, '..');
const SRC = path.join(MOD, 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'input_state.lua');

const TEST = `
local checks, failures = 0, 0
local function check(label, got, want)
	checks = checks + 1
	if got ~= want then
		failures = failures + 1
		print(string.format("  FAIL %-58s got=%s want=%s", label, tostring(got), tostring(want)))
	else
		print(string.format("  ok   %-58s %s", label, tostring(got)))
	end
end

-- ============================ stubs ============================
local installed_hooks = {}

local fake_mod = {
	hook = function (_self, obj, method, handler)
		installed_hooks[#installed_hooks + 1] = { obj = obj, method = method, handler = handler }
	end,
}

CLASS = { InputService = {} }

local input_service = nil          -- what Managers.input:get_input_service returns
local raw_values = {}              -- what the original _get would return

Managers = {
	input = {
		get_input_service = function (_self, name)
			return input_service
		end,
	},
}

local function original_get(_self, action_name)
	return raw_values[action_name]
end

-- Swap what the direct path sees.
local function set_service_reader(reader)
	if input_service == nil then
		input_service = nil
		service_reader = reader
		return
	end
	service_reader = reader
end

-- A service table whose :get delegates to a swappable reader.
local service_reader = nil
local function make_service()
	return {
		get = function (_self, action_name)
			if service_reader then return service_reader(action_name) end
			return raw_values[action_name]
		end,
	}
end

input_service = make_service()

-- ============================ tests ============================

print("== hook installation ==")
input_state.install({ mod = fake_mod, service = function () return input_service end })
check("no hook before ensure_hook", #installed_hooks, 0)
check("ensure_hook succeeds", input_state.ensure_hook(), true)
check("hook installed on _get", installed_hooks[1] and installed_hooks[1].method, "_get")
check("ensure_hook is idempotent", input_state.ensure_hook(), true)
check("only one hook", #installed_hooks, 1)

print("")
print("== path 1: direct service read ==")
service_reader = function (name) return name == "action_one_hold" and true or false end
check("held input reads true", input_state.is_held("action_one_hold"), true)
check("unheld input reads false", input_state.is_held("action_one_pressed"), false)
check("unknown input reads false", input_state.is_held("not_an_input"), false)
check("nil input name is safe", input_state.is_held(nil), false)

print("")
print("== path 1 returning a non-boolean falls through to the cache ==")
-- Simulate the direct read failing (returns nil) while the hook has seen true.
raw_values["action_one_hold"] = true
local handler = installed_hooks[1].handler
handler(original_get, input_service, "action_one_hold")
service_reader = function () return nil end
check("cached value used when direct read is nil", input_state.is_held("action_one_hold"), true)

print("")
print("== cache TTL ==")
input_state.update(0.05)
check("still fresh at 0.05s", input_state.is_held("action_one_hold"), true)
input_state.update(0.20)
check("expired after 0.25s total", input_state.is_held("action_one_hold"), false)

print("")
print("== only watched inputs are cached ==")
raw_values["some_unrelated_input"] = true
handler(original_get, input_service, "some_unrelated_input")
check("unwatched input not served from cache", input_state.is_held("some_unrelated_input"), false)

print("")
print("== path 2: the hook's return value is preserved ==")
raw_values["action_one_pressed"] = true
local returned = handler(original_get, input_service, "action_one_pressed")
check("hook passes the original value through", returned, true)
handler(original_get, input_service, "action_one_pressed")
input_state.update(-0.4)
service_reader = function () return nil end
check("cached true after re-observation", input_state.is_held("action_one_pressed"), true)

print("")
print("== neither path available ==")
input_service = nil
service_reader = nil
input_state.update(10)
check("no service, stale cache -> false", input_state.is_held("action_one_hold"), false)
local dbg = input_state.debug()
check("debug reports no service", dbg.service_available, false)
check("debug reports the hook", dbg.hooked, true)

print("")
print("== no mod handle at all (fresh instance) ==")
-- A fresh instance, because ensure_hook is deliberately sticky: once it has
-- hooked, later calls short-circuit to true.
local fresh = new_input_state()
fresh.install({})
check("ensure_hook fails cleanly", fresh.ensure_hook(), false)
check("is_held still safe", fresh.is_held("action_one_hold"), false)
check("debug exposes the error", type(fresh.debug().hook_error), "string")
check("debug reports not hooked", fresh.debug().hooked, false)

print("")
print(string.format("%d checks, %d failures", checks, failures))
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

// The module is loaded through a factory so tests can get independent instances:
// it is stateful (hook installation is sticky), so a shared instance cannot be
// used to test the unconfigured path.
const chunk = [
	'local function new_input_state()',
	'return (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	'end',
	'local input_state = new_input_state()',
	TEST,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
