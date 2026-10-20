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
-- In a window that isn't a node's, "context" and "current_name" in a list
-- mean the player's own inventory too (the game's craft page uses it for
-- shift-click), the controller's own one if it stayed.
function icu.swap_player_words(fs, s)
	local loc = s.mode == "control" and ("detached:" .. s.detached) or ("player:" .. s.victim)
	for _, word in ipairs({ "context", "current_name" }) do
		fs = fs:gsub("(list%[)" .. word .. ";", "%1current_player;"):gsub("(listring%[)" .. word .. ";", "%1current_player;")
	end
	return (fs:gsub("current_player", loc))
end

local function list_sig(list)
	local parts = {}
	for i, stack in ipairs(list or {}) do parts[i] = stack:to_string() end
	return table.concat(parts, "|")
end

-- The engine works out a player's craft preview, but only for the player's own
-- inventory, not for the detached copy the controller works in, so the copy's
-- preview is worked out here. (Taking the result is a craft action, which the
-- engine does in the copy itself, with guard.lua's interact.)
local function craft_width(list)
	return math.max(1, math.floor(math.sqrt(#list) + 0.5))
end

local function craft_preview(s, victim, det)
	local real = victim:get_inventory()
	local grid = det:get_list("craft")
	if not grid then return end
	local out = ItemStack()
	local res = core.get_craft_result({ method = "normal", width = craft_width(grid), items = grid })
	if res and res.item and not res.item:is_empty() then
		out = core.craft_predict(res.item, victim, grid, det)
	end
	for _, inv in ipairs({ det, real }) do
		if inv:get_size("craftpreview") > 0 then inv:set_stack("craftpreview", 1, out) end
	end
end

-- Both ways: a list that changed in the victim's inventory since the last
-- sync is copied to the copy, one that changed in the copy (the controller's
-- moves, the engine's crafting) goes to the victim's. If both changed, the
-- victim's wins. The craft preview is never copied (craft_preview does it).
function icu.sync_inventory(s, force)
	local victim = core.get_player_by_name(s.victim)
	local det = core.get_inventory({ type = "detached", name = s.detached })
	if not victim or not det then return end
	local real = victim:get_inventory()
	local craft_changed = force
	for name, list in pairs(real:get_lists()) do
		if name ~= "craftpreview" or force then
			local rsig = list_sig(list)
			local same_size = det:get_size(name) == #list
			if force or not same_size or rsig ~= s.sig[name] then
				det:set_size(name, #list)
				det:set_list(name, list)
				if s.sig[name] ~= rsig and name == "craft" then craft_changed = true end
				s.sig[name] = rsig
			elseif list_sig(det:get_list(name)) ~= s.sig[name] then
				real:set_list(name, det:get_list(name))
				s.sig[name] = list_sig(real:get_list(name))
				if name == "craft" then craft_changed = true end
			end
		end
	end
	if craft_changed then craft_preview(s, victim, det) end
end

local function craft_list(name) return name == "craftpreview" or name == "craftresult" end

local function detached_callbacks(s)
	local function changed() icu.sync_inventory(s) end
	return {
		-- (the engine itself refuses moves out of the preview and into the result)
		allow_move = function(_, _, _, to_list, _, count) return craft_list(to_list) and 0 or count end,
		allow_put = function(_, listname, _, stack) return craft_list(listname) and 0 or stack:get_count() end,
		allow_take = function(_, listname, _, stack) return listname == "craftpreview" and 0 or stack:get_count() end,
		on_move = changed,
		on_put = changed,
		on_take = changed,
	}
end

-- The client puts an attached player's camera at the parent's feet plus the
-- player's own eye height (the attach position doesn't move it), so the camera
-- would sit inside the victim's head model. The first person eye offset moves
-- it to just in front of the face (icu.camera_forward / icu.camera_up).
-- The victim's head turns up and down with the look, about the neck, so the
-- camera turns with it like a camera fixed to the face: looking down, it
-- swings forward and down in front of the chest. Looking up it turns only
-- half as much, so it stays in front of the face (behind the head, the
-- victim's nametag would be in the view). The head never gets in the view.
local NECK = 0.2 -- how far below the eyes the head turns (the usual player model)

local function apply_camera(controller)
	local pitch = controller:get_look_vertical() -- (down is positive)
	if pitch < 0 then pitch = pitch / 2 end
	local f0, u0 = icu.camera_forward / 10, icu.camera_up / 10 + NECK
	local forward = f0 * math.cos(pitch) + u0 * math.sin(pitch)
	local up = u0 * math.cos(pitch) - f0 * math.sin(pitch) - NECK
	controller:set_eye_offset({ x = 0, y = up * 10, z = forward * 10 })
end

-- What the controller's body looks like during a session. Other mods change
-- these properties all the time (sbt's playeranim sets visual_size back to 1
-- every step to apply crouching), which would undo the shrinking, so
-- set_properties is patched to keep them while the player is in a session.
local HIDDEN_PROPS = { is_visible = false, pointable = false, show_on_minimap = false }
local function hidden_size() return { x = 0.01, y = 0.01, z = 0.01 } end

local orig_set_properties
local function patch_set_properties(obj)
	if orig_set_properties then return end
	local methods = getmetatable(obj)
	orig_set_properties = methods.set_properties
	function methods.set_properties(self, props)
		if props and self.is_player and self:is_player() and icu.by_controller[self:get_player_name()] then
			props = table.copy(props)
			for k, v in pairs(HIDDEN_PROPS) do
				if props[k] ~= nil then props[k] = v end
			end
			if props.visual_size ~= nil then props.visual_size = hidden_size() end
		end
		return orig_set_properties(self, props)
	end
end

-- Things attached to the controller (worn armor, the held item ...) are hidden
-- too, also the ones made after the session started.
local function hide_children(s, controller)
	for _, child in ipairs(controller:get_children()) do
		if s.hidden_children[child] == nil then
			s.hidden_children[child] = child:get_properties().is_visible
			child:set_properties({ is_visible = false })
		end
	end
end

-- What is attached to the victim (their held item, armor ...) would be right
-- in front of the controller's camera: the controller doesn't see it, the
-- other players still do.
local function hide_victim_children(s, victim)
	for _, child in ipairs(victim:get_children()) do
		if not child:is_player() and s.unseen[child] == nil and child:get_observers() == nil then
			local names = {}
			for _, p in ipairs(core.get_connected_players()) do
				local n = p:get_player_name()
				if n ~= s.controller then names[n] = true end
			end
			child:set_observers(names)
			s.unseen[child] = true
		end
	end
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	for _, s in pairs(icu.by_controller) do
		for obj in pairs(s.unseen or {}) do
			if obj:is_valid() then
				local o = obj:get_observers() or {}
				o[name] = true
				obj:set_observers(o)
			end
		end
	end
end)

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
		meta = {}, -- node windows mirrored: meta[formname] = { pos, last formspec, own = icu opened it for the victim }
		view_lists = {}, -- a viewer's read-only lists
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
	-- but the server counts them as having it, for the inventory (guard.lua)
	s.server_interact = mode == "control"

	-- invisible and tiny: even a third person camera shows only the victim (the
	-- controller's own armor and other attached things are hidden too)
	patch_set_properties(controller)
	controller:set_properties({ is_visible = false, pointable = false, show_on_minimap = false,
		visual_size = hidden_size() })
	s.hidden_children = {} -- child object -> was it visible
	hide_children(s, controller)
	s.unseen = {} -- objects attached to the victim the controller doesn't see
	hide_victim_children(s, victim)
	controller:set_nametag_attributes({ text = " ", color = { a = 0, r = 0, g = 0, b = 0 }, bgcolor = false })
	controller:set_attach(victim, "", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 })
	sv.eye_offset = { controller:get_eye_offset() }
	apply_camera(controller)

	if mode == "control" then
		s.callbacks = detached_callbacks(s)
		core.create_detached_inventory(s.detached, s.callbacks, controller_name)
		icu.sync_inventory(s, true)
	else
		-- every list of every window the viewer sees is a read-only copy
		local deny = {
			allow_move = function() return 0 end, allow_put = function() return 0 end,
			allow_take = function() return 0 end,
		}
		core.create_detached_inventory(s.detached, deny, controller_name)
	end
	icu.mirror_inventory_formspec(s)

	icu.hudmirror_start(s, controller, victim)

	s.huds = {
		title = hud_text(controller, (mode == "control" and "ICU: controlling " or "ICU: viewing (view only) ")
			.. victim_name, 0.06),
		info = hud_text(controller, "", 0.09),
	}

	icu.hotbar_start(s, controller, victim)

	core.log("action", ("[icu] %s starts %s %s"):format(controller_name,
		mode == "control" and "controlling" or "viewing", victim_name))
	if notify_enabled(mode) then
		icu.raw_chat_send(victim_name, "*** " .. controller_name .. " is controlling you (your view and your hands).")
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
			show_on_minimap = sv.props.show_on_minimap, visual_size = sv.props.visual_size,
		})
		for obj, visible in pairs(s.hidden_children or {}) do
			if obj:is_valid() then obj:set_properties({ is_visible = visible }) end
		end
		controller:set_nametag_attributes(sv.nametag)
		controller:set_eye_offset(unpack(sv.eye_offset))
		controller:set_fov(unpack(sv.fov))
		controller:set_inventory_formspec(sv.invfs)
		for _, id in pairs(s.huds) do controller:hud_remove(id) end
		icu.hotbar_stop(s, controller)
		icu.hudmirror_stop(s, controller)
		for formname in pairs(s.forms) do icu.raw_show(controller_name, formname, "") end
		for formname, m in pairs(s.meta) do
			if m.own and victim then icu.raw_show(s.victim, formname, "") end
		end
		if core.settings:get_bool("icu.return_to_origin", true) then controller:set_pos(sv.pos) end
	end
	for obj in pairs(s.unseen or {}) do
		if obj:is_valid() then obj:set_observers(nil) end
	end
	core.remove_detached_inventory(s.detached)
	give_back_interact(controller_name)
	if victim and s.mode == "control" then
		victim:set_fov(unpack(sv.victim_fov))
		icu.move_stop(s, victim)
	end

	core.log("action", ("[icu] %s stops %s %s%s"):format(controller_name,
		s.mode == "control" and "controlling" or "viewing", s.victim, reason and (" (" .. reason .. ")") or ""))
	if victim and notify_enabled(s.mode) then
		icu.raw_chat_send(s.victim, "*** " .. controller_name .. " is no longer controlling you.")
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
				local fov, mult = controller:get_fov()
				if s.last_fov ~= fov or s.last_mult ~= mult then
					s.last_fov, s.last_mult = fov, mult
					victim:set_fov(fov, mult, 0)
				end
				icu.move_step(s, controller, victim, dtime)
				icu.sync_look(s, controller, victim, dtime)
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
				hide_children(s, controller)
				hide_victim_children(s, victim)
			end
			icu.hotbar_update(s, controller, victim)
			icu.meta_step(s, victim, refresh_info)
			if refresh_info then
				local wield = s.mode == "control" and icu.selected_stack(controller, victim) or victim:get_wielded_item()
				local def = wield:get_definition()
				controller:hud_change(s.huds.info, "text", ("%s  HP %d  holding %s%s"):format(
					s.victim, victim:get_hp(),
					wield:is_empty() and "nothing" or (def.short_description or def.description or wield:get_name()):gsub("\n.*", ""),
					wield:get_count() > 1 and (" x" .. wield:get_count()) or ""))
				if s.mode == "view" then icu.refresh_view_forms(s) end
				icu.mirror_inventory_formspec(s)
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
