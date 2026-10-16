-- local_player.lua -- the local player, obtained in a way that cannot kill the game.
--
-- `PlayerManager:local_player(1)` dereferences the player it expects to find and
-- calls `peer_id` on it. When no player has been registered yet -- i.e. the whole
-- time the process sits at the main menu -- that is a NULL dereference *inside the
-- engine*, so it surfaces as an access violation (0xc0000005) and takes the
-- process down. A pcall does not save you: this is not a Lua error.
--
-- That actually happened: a per-frame update ran while still at the menu, reached
-- local_player(1), and the game died on startup with a peer_id access violation.
--
-- The engine ships its own guarded accessor, `local_player_safe`, which returns
-- nil in that situation, and dozens of mods in this install use it. This module
-- wraps it and, if a build ever lacks it, counts players before touching the
-- unsafe one.

local local_player = {}

local function player_manager()
	return Managers and Managers.player or nil
end

function local_player.player()
	local manager = player_manager()

	if type(manager) ~= "table" then
		return nil
	end

	if type(manager.local_player_safe) == "function" then
		local ok, player = pcall(manager.local_player_safe, manager, 1)

		if ok then
			return player
		end

		return nil
	end

	-- No safe accessor on this build, so only touch the unsafe one when the manager
	-- admits to holding a player at all.
	local count = manager._num_players

	if type(count) == "number" and count <= 0 then
		return nil
	end

	local ok, player = pcall(manager.local_player, manager, 1)

	if ok then
		return player
	end

	return nil
end

function local_player.unit()
	local player = local_player.player()

	return player and player.player_unit or nil
end

-- Reported by /wepcheckstate and the dump, so "no player yet" is distinguishable
-- from "the accessor is missing".
function local_player.debug()
	local manager = player_manager()
	local has_safe = type(manager) == "table" and type(manager.local_player_safe) == "function"

	return {
		manager = manager ~= nil,
		has_safe_accessor = has_safe,
		num_players = type(manager) == "table" and manager._num_players or nil,
		found = local_player.player() ~= nil,
	}
end

return local_player
