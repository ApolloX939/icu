-- The controller's own interact privilege.
--
-- The engine refuses every inventory change outside a player's own inventory,
-- and every craft, from a player without "interact". The controller works in
-- a detached copy of the victim's inventory, so while controlling, the server
-- counts them as having interact, but their stored privileges (and so what
-- their client was told) stay without it: their client doesn't dig or place
-- nodes on its own. What it still sends as the controller (punching objects,
-- using or placing their own held item, right-clicking, dropping their own
-- items) is stopped here; the controller's actions reach the world only as the
-- victim, through relay.lua.

local function controlling(name)
	local s = icu.by_controller[name]
	return s and s.server_interact
end

-- the player (or fake player) is the controller of a session
local function is_controller(p)
	if not p or type(p.is_player) ~= "function" or not p:is_player() then return false end
	return icu.by_controller[p:get_player_name()] ~= nil
end
icu.is_controller = is_controller

local function wrap_auth(handler)
	if handler.icu_wrapped then return end
	handler.icu_wrapped = true
	local get_auth, set_privileges = handler.get_auth, handler.set_privileges
	handler.get_auth = function(name, ...)
		local auth = get_auth(name, ...)
		if auth and controlling(name) and not auth.privileges.interact then
			auth = table.copy(auth)
			auth.privileges.interact = true
		end
		return auth
	end
	if set_privileges then
		-- privileges read during the session (a /grant) include interact: it
		-- isn't stored (session.lua gives it back at the end if it was taken)
		handler.set_privileges = function(name, privs, ...)
			if controlling(name) and privs.interact then
				privs = table.copy(privs)
				privs.interact = nil
			end
			return set_privileges(name, privs, ...)
		end
	end
end

-- Calls f unless `who` (the argument at position `at`) is a controller; then
-- returns `blocked` instead.
local function guarded(f, at, blocked)
	return function(...)
		if is_controller((select(at, ...))) then return blocked end
		if f then return f(...) end
	end
end

-- (item definitions ignore new keys, and their default callbacks come from
-- their metatable, so the wrapped ones are set with rawset)
local function guard(def, key, at, blocked, always)
	if def[key] or always then rawset(def, key, guarded(def[key], at, blocked)) end
end

local function guard_all()
	wrap_auth(core.get_auth_handler())

	for _, def in pairs(core.registered_items) do
		guard(def, "on_place", 2)
		guard(def, "on_secondary_use", 2)
		guard(def, "on_use", 2)
		guard(def, "on_drop", 2)
		if def.type == "node" then
			guard(def, "on_punch", 3)
			guard(def, "on_dig", 3, false)
			guard(def, "on_rightclick", 3)
		end
	end
	for _, def in pairs(core.registered_entities) do
		-- (self, puncher, ...): true = no damage
		guard(def, "on_punch", 2, true, true)
		guard(def, "on_rightclick", 2)
	end
	-- (player, hitter, ...): true = no damage; (player, clicker)
	for i, f in ipairs(core.registered_on_punchplayers) do
		core.registered_on_punchplayers[i] = guarded(f, 2, true)
	end
	for i, f in ipairs(core.registered_on_rightclickplayers) do
		core.registered_on_rightclickplayers[i] = guarded(f, 2)
	end
end

-- after every mod's own changes made when loading
core.register_on_mods_loaded(function() core.after(0, guard_all) end)

core.register_on_punchplayer(function(_, hitter) return is_controller(hitter) end)

-- the controller's own inventory (and dropping from it) stays as it is
core.register_allow_player_inventory_action(function(player)
	if is_controller(player) then return 0 end
end)

-- What the engine crafts in the controller's copy is crafted by the victim.
local function as_victim(orig)
	return function(itemstack, player, old_craft_list, craft_inv)
		local s = is_controller(player) and icu.by_controller[player:get_player_name()]
		local victim = s and s.mode == "control" and core.get_player_by_name(s.victim)
		return orig(itemstack, victim or player, old_craft_list, craft_inv)
	end
end
core.on_craft = as_victim(core.on_craft)
core.craft_predict = as_victim(core.craft_predict)
