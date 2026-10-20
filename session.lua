-- Starting, running and ending sessions.

icu.camera_forward = tonumber(core.settings:get("icu.camera_forward")) or 4 -- 1/10 nodes
icu.camera_up = tonumber(core.settings:get("icu.camera_up")) or 2

local storage = core.get_mod_storage()

-- Players whose "interact" privilege icu took away: given back when the
-- session ends, or when they join if the server stopped meanwhile.
local pending = core.parse_json(storage:get_string("interact") ~= "" and storage:get_string("interact") or "null") or {}
local function save_pending() storage:set_string("interact", core.write_json(pending)) end

local function give_back_interact(name)
	if not pending[name] then return end
	local privs = core.get_player_privs(name)
	privs.interact = true
	core.set_player_privs(name, privs)
	pending[name] = nil
	save_pending()
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	if pending[name] and not icu.by_controller[name] then give_back_interact(name) end
end)

-- the victim is told about control (icu.notify_target), never about view only
local function notify_enabled(mode)
	return mode == "control" and core.settings:get_bool("icu.notify_target", true)
end

-- Another player's inventory can't be drawn from "player:<name>" (a client
-- only has its own), so the controller gets a detached copy of the victim's
-- inventory, and what they do with it is written back to the real one.
function icu.swap_player_words(fs, s)
	local loc = s.mode == "control" and ("detached:" .. s.detached) or ("player:" .. s.victim)
	return (fs:gsub("current_player", loc))
end

function icu.sync_inventory(s, force)
	local victim = core.get_player_by_name(s.victim)
	local det = core.get_inventory({ type = "detached", name = s.detached })
	if not victim or not det then return end
	local real = victim:get_inventory()
	for name, list in pairs(real:get_lists()) do
		local parts = {}
		for i, stack in ipairs(list) do parts[i] = stack:to_string() end
		local sig = table.concat(parts, "|")
		if force or s.sig[name] ~= sig or det:get_size(name) ~= #list then
			s.sig[name] = sig
			det:set_size(name, #list)
			det:set_list(name, list)
		end
	end
end

local function write_back(s)
	local victim = core.get_player_by_name(s.victim)
	local det = core.get_inventory({ type = "detached", name = s.detached })
	if not victim or not det then return end
	local real = victim:get_inventory()
	for name, list in pairs(det:get_lists()) do
		if real:get_size(name) > 0 then
			real:set_list(name, list)
			local parts = {}
			for i, stack in ipairs(real:get_list(name)) do parts[i] = stack:to_string() end
			s.sig[name] = table.concat(parts, "|")
		end
	end
end

local function detached_callbacks(s)
	return {
		allow_move = function(_, _, _, _, _, count) return count end,
		allow_put = function(_, _, _, stack) return stack:get_count() end,
		allow_take = function(_, _, _, stack) return stack:get_count() end,
		on_move = function() write_back(s) end,
		on_put = function() write_back(s) end,
		on_take = function() write_back(s) end,
	}
end

-- The client puts an attached player's camera at the parent's feet plus the
-- player's own eye height (the attach position doesn't move it), so the camera
-- would sit inside the victim's head model. The first person eye offset moves
-- it to just in front of the face.
local function apply_camera(controller)
	controller:set_eye_offset({ x = 0, y = icu.camera_up, z = icu.camera_forward })
end

local function hud_text(controller, text, y)
	return controller:hud_add({
		type = "text", position = { x = 0.5, y = y }, offset = { x = 0, y = 0 },
		text = text, number = 0xFFFFFF, alignment = { x = 0, y = 0 }, z_index = 100,
	})
end

function icu.start(controller_name, victim_name, mode)
	local controller = core.get_player_by_name(controller_name)
	local victim = core.get_player_by_name(victim_name)
	if not controller then return false, "You must be online." end
	if not victim then return false, victim_name .. " isn't online." end
	if controller_name == victim_name then return false, "You can't do that to yourself." end
	if icu.by_controller[controller_name] then return false, "You're already in a session. /icu stop first." end
	if icu.by_victim[controller_name] or icu.by_controller[victim_name] then
		return false, "One of you is already in a session."
	end
	if icu.by_victim[victim_name] then return false, victim_name .. " is already being controlled or watched." end
	if core.check_player_privs(victim_name, { icu_immune = true }) then
		return false, victim_name .. " can't be " .. (mode == "control" and "controlled." or "watched.")
	end
	if controller:get_attach() then return false, "You're attached to something; detach first." end

	local s = {
		controller = controller_name, victim = victim_name, mode = mode,
		forms = {}, -- formspecs mirrored to the controller: forms[formname] = the victim's formspec
		sig = {},
		detached = "icu_" .. controller_name,
		saved = {},
		dig = { progress = 0 },
	}
	local sv = s.saved
	sv.pos = controller:get_pos()
	sv.props = controller:get_properties()
	sv.nametag = controller:get_nametag_attributes()
	sv.fov = { controller:get_fov() }
	sv.invfs = controller:get_inventory_formspec()
	sv.victim_fov = { victim:get_fov() }

	icu.by_controller[controller_name] = s
	icu.by_victim[victim_name] = s

	-- nothing the controller does goes through as themselves
	local privs = core.get_player_privs(controller_name)
	if privs.interact then
		pending[controller_name] = true
		save_pending()
		privs.interact = nil
		core.set_player_privs(controller_name, privs)
	end

	controller:set_properties({ is_visible = false, pointable = false, show_on_minimap = false })
	controller:set_nametag_attributes({ text = " ", color = { a = 0, r = 0, g = 0, b = 0 }, bgcolor = false })
	controller:set_attach(victim, "", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 })
	sv.eye_offset = { controller:get_eye_offset() }
	apply_camera(controller)

	if mode == "control" then
		s.callbacks = detached_callbacks(s)
		core.create_detached_inventory(s.detached, s.callbacks, controller_name)
		icu.sync_inventory(s, true)
		local fs = victim:get_inventory_formspec()
		if fs ~= "" then controller:set_inventory_formspec(icu.swap_player_words(fs, s)) end
	end

	s.huds = {
		title = hud_text(controller, (mode == "control" and "ICU: controlling " or "ICU: viewing (view only) ")
			.. victim_name, 0.06),
		info = hud_text(controller, "", 0.09),
	}

	core.log("action", ("[icu] %s starts %s %s"):format(controller_name,
		mode == "control" and "controlling" or "viewing", victim_name))
	if notify_enabled(mode) then
		core.chat_send_player(victim_name, "*** " .. controller_name .. " is controlling you (your view and your hands).")
	end
	return true
end

function icu.stop(controller_name, reason)
	local s = icu.by_controller[controller_name]
	if not s then return false end
	icu.by_controller[controller_name] = nil
	icu.by_victim[s.victim] = nil
	local controller = core.get_player_by_name(controller_name)
	local victim = core.get_player_by_name(s.victim)
	local sv = s.saved

	if controller then
		controller:set_detach()
		controller:set_properties({
			is_visible = sv.props.is_visible, pointable = sv.props.pointable,
			show_on_minimap = sv.props.show_on_minimap,
		})
		controller:set_nametag_attributes(sv.nametag)
		controller:set_eye_offset(unpack(sv.eye_offset))
		controller:set_fov(unpack(sv.fov))
		controller:set_inventory_formspec(sv.invfs)
		for _, id in pairs(s.huds) do controller:hud_remove(id) end
		for formname in pairs(s.forms) do icu.raw_show(controller_name, formname, "") end
		if core.settings:get_bool("icu.return_to_origin", true) then controller:set_pos(sv.pos) end
	end
	if s.mode == "control" then core.remove_detached_inventory(s.detached) end
	give_back_interact(controller_name)
	if victim and s.mode == "control" then victim:set_fov(unpack(sv.victim_fov)) end

	core.log("action", ("[icu] %s stops %s %s%s"):format(controller_name,
		s.mode == "control" and "controlling" or "viewing", s.victim, reason and (" (" .. reason .. ")") or ""))
	if victim and notify_enabled(s.mode) then
		core.chat_send_player(s.victim, "*** " .. controller_name .. " is no longer controlling you.")
	end
	if controller then core.chat_send_player(controller_name, "ICU: session ended" .. (reason and (": " .. reason) or ".")) end
	return true
end

-- The stack in the slot the controller has selected, in the victim's inventory
-- (the server can't change which slot a player has selected).
function icu.selected_stack(controller, victim)
	local inv = victim:get_inventory()
	local idx = math.min(controller:get_wield_index(), inv:get_size("main"))
	return inv:get_stack("main", math.max(idx, 1))
end

-- the victim's view, every step
local info_timer = 0
core.register_globalstep(function(dtime)
	info_timer = info_timer + dtime
	local refresh_info = info_timer >= 0.5
	if refresh_info then info_timer = 0 end

	for cname, s in pairs(icu.by_controller) do
		local controller = core.get_player_by_name(cname)
		local victim = core.get_player_by_name(s.victim)
		if not controller or not victim then
			-- (a player leaving is handled below; this is for anything else)
			icu.stop(cname, "a player is gone")
		else
			if not controller:get_attach() then controller:set_attach(victim, "", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }) end
			apply_camera(controller)
			if s.mode == "control" then
				icu.sync_inventory(s)
				victim:set_look_horizontal(controller:get_look_horizontal())
				victim:set_look_vertical(controller:get_look_vertical())
				local fov, mult = controller:get_fov()
				if s.last_fov ~= fov or s.last_mult ~= mult then
					s.last_fov, s.last_mult = fov, mult
					victim:set_fov(fov, mult, 0)
				end
				icu.relay_step(s, controller, victim, dtime)
			else
				controller:set_look_horizontal(victim:get_look_horizontal())
				controller:set_look_vertical(victim:get_look_vertical())
				local fov, mult = victim:get_fov()
				if s.last_fov ~= fov or s.last_mult ~= mult then
					s.last_fov, s.last_mult = fov, mult
					controller:set_fov(fov, mult, 0)
				end
			end
			if refresh_info then
				local wield = s.mode == "control" and icu.selected_stack(controller, victim) or victim:get_wielded_item()
				local def = wield:get_definition()
				controller:hud_change(s.huds.info, "text", ("%s  HP %d  holding %s%s"):format(
					s.victim, victim:get_hp(),
					wield:is_empty() and "nothing" or (def.short_description or def.description or wield:get_name()):gsub("\n.*", ""),
					wield:get_count() > 1 and (" x" .. wield:get_count()) or ""))
				if s.mode == "view" then icu.refresh_view_forms(s) end
			end
		end
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	if icu.by_controller[name] then
		icu.stop(name, "left")
	elseif icu.by_victim[name] then
		icu.stop(icu.by_victim[name].controller, name .. " left")
	end
end)

core.register_on_shutdown(function()
	for cname in pairs(icu.by_controller) do icu.stop(cname, "server shutdown") end
end)
