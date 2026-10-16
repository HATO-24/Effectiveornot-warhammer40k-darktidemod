// Tests for local_player.lua -- the module that exists because
// PlayerManager:local_player(1) is a native NULL dereference before any player is
// registered, which crashes the game rather than raising a Lua error.
//
// The load-bearing assertion is that the unsafe accessor is never reached when
// there is no player: that is exactly the condition that killed the process.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

// Repo layout: this file lives in <repo>/tests/, the mod itself is the repo root.
const SRC = path.join(__dirname, '..', 'scripts', 'mods', 'WeaponEffectiveness', 'modules', 'local_player.lua');

const STUBS = `
-- ============================ stubs ============================
local unsafe_calls = 0
local safe_returns = nil
local safe_raises = false
local unsafe_returns = nil
local player_manager = nil

local function make_manager(opts)
	opts = opts or {}
	local manager = {
		_num_players = opts.num_players,
	}

	if opts.with_safe then
		manager.local_player_safe = function (_self, index)
			if safe_raises then error("safe accessor exploded") end
			assert(index == 1, "expected local player index 1")
			return safe_returns
		end
	end

	-- Stands in for the engine's unsafe accessor. In the real engine this is where
	-- the process dies when there is no player, so any call here is a failure of
	-- the module under test.
	manager.local_player = function (_self, _index)
		unsafe_calls = unsafe_calls + 1
		return unsafe_returns
	end

	return manager
end

local player_manager = nil

-- Managers.player has to track the variable above, so it is served through a
-- metatable rather than copied once.
Managers = setmetatable({}, {
	__index = function (_, key)
		if key == "player" then
			return player_manager
		end
		return nil
	end,
})
`;

const TESTS = `
-- ============================ assertions ============================
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

print("== safe accessor present ==")
player_manager = make_manager({ with_safe = true, num_players = 0 })
safe_returns = { player_unit = "UNIT" }
check("unit returned", local_player.unit(), "UNIT")
check("unsafe accessor never called", unsafe_calls, 0)

safe_returns = nil
check("no player -> nil unit", local_player.unit(), nil)
check("still no unsafe call", unsafe_calls, 0)

print("")
print("== safe accessor raising is contained ==")
safe_raises = true
check("raised -> nil, not propagated", local_player.unit(), nil)
safe_raises = false

print("")
print("== THE CRASH CASE: no safe accessor, zero players ==")
player_manager = make_manager({ with_safe = false, num_players = 0 })
unsafe_returns = { player_unit = "SHOULD_NOT_BE_REACHED" }
check("returns nil", local_player.unit(), nil)
check("unsafe accessor NOT called", unsafe_calls, 0)

print("")
print("== no safe accessor, manager reports no player count field ==")
player_manager = make_manager({ with_safe = false })
check("falls through but call is pcall-wrapped", local_player.unit(), "SHOULD_NOT_BE_REACHED")
check("unsafe accessor was called once", unsafe_calls, 1)

print("")
print("== no safe accessor, players present ==")
unsafe_calls = 0
player_manager = make_manager({ with_safe = false, num_players = 3 })
check("unit returned", local_player.unit(), "SHOULD_NOT_BE_REACHED")
check("unsafe accessor called once", unsafe_calls, 1)

print("")
print("== manager itself missing ==")
player_manager = nil
check("nil manager -> nil unit", local_player.unit(), nil)
check("nil manager -> nil player", local_player.player(), nil)

print("")
print("== debug reporting ==")
player_manager = make_manager({ with_safe = true, num_players = 2 })
safe_returns = { player_unit = "UNIT" }
local d = local_player.debug()
check("manager seen", d.manager, true)
check("safe accessor seen", d.has_safe_accessor, true)
check("player count", d.num_players, 2)
check("found", d.found, true)

player_manager = nil
local d2 = local_player.debug()
check("no manager: manager=false", d2.manager, false)
check("no manager: safe=false", d2.has_safe_accessor, false)
check("no manager: found=false", d2.found, false)

print("")
print(string.format("%d checks, %d failures", checks, failures))
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const chunk = [
	STUBS,
	'local local_player = (function()',
	fs.readFileSync(SRC, 'utf8'),
	'end)()',
	TESTS,
].join('\n');

if (lauxlib.luaL_dostring(L, to_luastring(chunk)) !== lua.LUA_OK) {
	console.error('LUA ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
	process.exit(1);
}
