-- input_state.lua -- reads the live state of the player's combat inputs.
--
-- This is the one place in the mod that leans on an API surface which cannot be
-- confirmed from the game files, and the tap-vs-hold verdict is the whole point of
-- requirement (1). So there are two independent paths:
--
--   1. a direct read through `Managers.input:get_input_service("Ingame")`
--   2. a hook on `InputService:_get`, which observes every input the game itself
--      queries and caches the watched ones with a short expiry
--
-- If either works, the verdict works. `input_state.debug()` is reported in the
-- diagnostics dump so a single in-game run says which path produced the answer.

local input_state = {}

-- Short on purpose: a cached value is only trusted while it is plausibly current.
local CACHE_TTL = 0.15

-- Only these are cached, so the hook cannot grow a table over arbitrary input
-- names and stays cheap on a per-query hot path.
local WATCHED = {
	action_one_hold = true,
	action_one_pressed = true,
	action_one_release = true,
	action_two_hold = true,
	action_two_pressed = true,
}

local config = {}
local cached_value = {}
local cached_time = {}
local hooked = false
local hook_error = nil
local clock = 0

function input_state.install(settings)
	config = settings or {}
end

function input_state.update(dt)
	clock = clock + (tonumber(dt) or 0)
end

function input_state.ensure_hook()
	if hooked then
		return true
	end

	local mod = config.mod

	if not mod then
		hook_error = "no mod handle"

		return false
	end

	-- The class is registered by name, which is how dozens of working mods hook it.
	--
	-- Only `_get` is hooked, deliberately: `_get_simulate` reports input that other
	-- mods inject (auto-fire, auto-swing and friends), and letting another mod's
	-- synthetic input decide whether the heavy row lights up would be wrong.
	local ok, err = pcall(function ()
		mod:hook("InputService", "_get", function (func, self, action_name)
			local value = func(self, action_name)

			if type(action_name) == "string" and WATCHED[action_name] then
				cached_value[action_name] = value
				cached_time[action_name] = clock
			end

			return value
		end)
	end)

	if ok then
		hooked = true

		return true
	end

	hook_error = tostring(err)

	return false
end

local function direct_service()
	local input_manager = Managers and Managers.input

	if not input_manager then
		return nil
	end

	local ok, service = pcall(function ()
		return input_manager:get_input_service("Ingame")
	end)

	if ok then
		return service
	end

	return nil
end

function input_state.service()
	if config.service then
		return config.service()
	end

	return direct_service()
end

-- True when the named player input is currently held down.
function input_state.is_held(action_name)
	if type(action_name) ~= "string" then
		return false
	end

	local service = input_state.service()

	if service then
		local ok, value = pcall(function ()
			return service:get(action_name)
		end)

		if ok and type(value) == "boolean" then
			return value
		end
	end

	local stamp = cached_time[action_name]

	if stamp and (clock - stamp) <= CACHE_TTL then
		return cached_value[action_name] == true
	end

	return false
end

function input_state.debug()
	local cached = {}

	for name in pairs(WATCHED) do
		local stamp = cached_time[name]

		if stamp then
			cached[name] = {
				value = cached_value[name],
				age = clock - stamp,
			}
		end
	end

	return {
		hooked = hooked,
		hook_error = hook_error,
		service_available = input_state.service() ~= nil,
		cached = cached,
	}
end

return input_state
