-- Formspecs: what is shown to the victim is shown to the controller too, the
-- controller's inventory lists are the victim's, and what the controller
-- submits goes to the mods as if the victim had. For a viewer the copy is the
-- same window with lists that can't be changed.

local orig_show = core.show_formspec
icu.raw_show = orig_show

-- Needed to reach the mods that saved core.show_formspec in a local before icu
-- loaded (see patch_saved_references): only there when icu is a trusted mod
-- (init.lua hands it over).
local debug_lib = ...

local function esc(s) return core.formspec_escape(s) end

---------------------------------------------------------------------------
-- Read-only copy for a viewer
---------------------------------------------------------------------------

local function inventory_at(loc, victim)
	if loc == "current_player" then
		local p = core.get_player_by_name(victim)
		return p and p:get_inventory()
	end
	local pname = loc:match("^player:(.+)$")
	if pname then
		local p = core.get_player_by_name(pname)
		return p and p:get_inventory()
	end
	local x, y, z = loc:match("^nodemeta:(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)$")
	if x then return core.get_meta(vector.new(tonumber(x), tonumber(y), tonumber(z))):get_inventory() end
	local det = loc:match("^detached:(.+)$")
	if det then return core.get_inventory({ type = "detached", name = det }) end
end

-- A viewer's copy shows the same lists, live, but from a detached inventory
-- that refuses every change: each list[loc;name] is rewritten to a list of the
-- viewer's own read-only inventory, which is kept equal to the original.
local function list_key(loc, name)
	return (loc .. "_" .. name):gsub("[^%w]", "_")
end

local function view_rewrite(s, fs)
	local function mapped(loc, name)
		local key = list_key(loc, name)
		s.view_lists[key] = { loc = loc, name = name }
		return "detached:" .. s.detached, key
	end
	fs = fs:gsub("%f[%w_]list%[([^;%]]+);([^;%]]+)", function(loc, name)
		local d, key = mapped(loc, name)
		return "list[" .. d .. ";" .. key
	end)
	fs = fs:gsub("listring%[([^;%]]+);([^;%]]+)%]", function(loc, name)
		local d, key = mapped(loc, name)
		return "listring[" .. d .. ";" .. key .. "]"
	end)
	return fs
end

-- the viewer's read-only inventory follows the real ones
function icu.sync_view(s)
	local det = core.get_inventory({ type = "detached", name = s.detached })
	if not det then return end
	for key, src in pairs(s.view_lists) do
		local inv = inventory_at(src.loc, s.victim)
		local list = inv and inv:get_list(src.name)
		if list then
			local parts = {}
			for i, stack in ipairs(list) do parts[i] = stack:to_string() end
			local sig = table.concat(parts, "|")
			if s.sig[key] ~= sig then
				s.sig[key] = sig
				det:set_size(key, #list)
				det:set_list(key, list)
			end
		end
	end
end

local function copy_for(s, fs)
	fs = icu.swap_player_words(fs, s)
	if s.mode == "view" then
		fs = view_rewrite(s, fs)
		icu.sync_view(s)
	end
	return fs
end

-- the formspec the viewer's inventory key opens: the victim's
function icu.mirror_inventory_formspec(s)
	local victim = core.get_player_by_name(s.victim)
	local controller = core.get_player_by_name(s.controller)
	if not victim or not controller then return end
	local fs = victim:get_inventory_formspec()
	if fs == s.last_invfs then return end
	s.last_invfs = fs
	controller:set_inventory_formspec(fs ~= "" and copy_for(s, fs) or "")
end

---------------------------------------------------------------------------
-- Mirroring what mods show to the victim
---------------------------------------------------------------------------

function core.show_formspec(name, formname, fs)
	orig_show(name, formname, fs)
	local s = icu.by_victim[name]
	if s and formname ~= "" then
		if fs == "" then
			s.forms[formname] = nil
			orig_show(s.controller, formname, "")
		else
			s.forms[formname] = fs
			orig_show(s.controller, formname, copy_for(s, fs))
		end
	end
end

-- (a viewer's lists are live: only their contents are synced)
function icu.refresh_view_forms(s)
	icu.sync_view(s)
end

-- The formspec a client opens by itself when a player right-clicks a node with
-- a "formspec" in its meta, with its lists (and the node's meta formspec is
-- read again as it changes, like a client does).
local function log_action(s, msg)
	if core.settings:get_bool("icu.log_actions", false) then
		core.log("action", ("[icu] %s / %s: %s"):format(s.controller, s.victim, msg))
	end
end

local function meta_name(pos) return ("icu:meta:%d,%d,%d"):format(pos.x, pos.y, pos.z) end

local function node_formspec(pos)
	local fs = core.get_meta(pos):get_string("formspec")
	if fs == "" then return nil end
	local loc = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	fs = fs:gsub("%[context;", "[" .. loc .. ";"):gsub("%[context_", "[" .. loc .. "_")
	fs = fs:gsub("(list%[)current_name;", "%1" .. loc .. ";"):gsub("(listring%[)current_name;", "%1" .. loc .. ";")
	return fs
end

-- closes a mirrored node window (on both sides when icu opened it for the victim)
function icu.close_meta(s, formname)
	local m = s.meta[formname]
	if not m then return end
	s.meta[formname] = nil
	s.forms[formname] = nil
	orig_show(s.controller, formname, "")
	if m.own then orig_show(s.victim, formname, "") end
	log_action(s, "closed the window of " .. core.pos_to_string(m.pos))
end

-- the controller right-clicked: the window opens for the victim, and so for the controller
function icu.show_node_formspec(s, pos)
	local fs = node_formspec(pos)
	if not fs then return false end
	local formname = meta_name(pos)
	s.meta[formname] = { pos = pos, last = fs, own = true }
	core.show_formspec(s.victim, formname, fs)
	return true
end

-- the victim right-clicked: their client opened the window itself, the controller gets a copy
function icu.mirror_victim_node_formspec(s, pos)
	local fs = node_formspec(pos)
	if not fs then return false end
	for name, m in pairs(s.meta) do
		if not m.own then icu.close_meta(s, name) end
	end
	local formname = meta_name(pos)
	s.meta[formname] = { pos = pos, last = fs, own = false }
	s.forms[formname] = fs
	orig_show(s.controller, formname, copy_for(s, fs))
	log_action(s, "mirrored the victim's own window of " .. core.pos_to_string(pos))
	return true
end

-- every tick: keep the windows current and close the ones the victim walked away from
function icu.meta_step(s, victim, tick)
	if not tick then return end
	local vpos = victim:get_pos()
	for formname, m in pairs(s.meta) do
		local fs = node_formspec(m.pos)
		if not fs or (not m.own and vector.distance(vpos, m.pos) > 8) then
			icu.close_meta(s, formname)
		elseif fs ~= m.last then
			m.last = fs
			if m.own then
				core.show_formspec(s.victim, formname, fs)
			else
				s.forms[formname] = fs
				orig_show(s.controller, formname, copy_for(s, fs))
			end
		end
	end
end

---------------------------------------------------------------------------
-- What the controller submits
---------------------------------------------------------------------------

local function dispatch_as(victim, formname, fields, skip)
	local meta_pos = formname:match("^icu:meta:(.+)$")
	if meta_pos then
		local x, y, z = meta_pos:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
		local pos = vector.new(tonumber(x), tonumber(y), tonumber(z))
		local def = core.registered_nodes[core.get_node(pos).name]
		if def and def.on_receive_fields then def.on_receive_fields(pos, "", fields, victim) end
		return
	end
	for _, f in ipairs(core.registered_on_player_receive_fields) do
		if f ~= skip and f(victim, formname, fields) then break end
	end
end

local function on_fields(player, formname, fields)
	local name = player:get_player_name()
	local s = icu.by_controller[name]
	-- (formname "" is the inventory window the inventory key opens)
	if s and (s.forms[formname] or formname == "" or formname:sub(1, 9) == "icu:meta:") then
		if s.mode == "control" then
			local victim = core.get_player_by_name(s.victim)
			if victim then dispatch_as(victim, formname, fields, on_fields) end
		end
		if fields.quit then
			s.forms[formname] = nil
			s.meta[formname] = nil
			if s.mode == "control" and formname ~= "" then orig_show(s.victim, formname, "") end
		end
		return true
	end
	s = icu.by_victim[name]
	if s then
		if formname:sub(1, 9) == "icu:meta:" then
			dispatch_as(player, formname, fields, on_fields)
			if fields.quit then icu.close_meta(s, formname) end
			return true
		elseif s.forms[formname] and fields.quit then
			s.forms[formname] = nil
			orig_show(s.controller, formname, "")
		end
	end
end

core.register_on_player_receive_fields(on_fields)

---------------------------------------------------------------------------
-- Everything below runs once all mods have registered: icu goes first, and
-- the callbacks that get the acting player get the victim when a controller acts.
---------------------------------------------------------------------------

-- the player a call is made as: a controller acts as their victim
local function actor(p)
	if type(p) == "userdata" and p.is_player and p:is_player() then
		local s = icu.by_controller[p:get_player_name()]
		if s and s.mode == "control" then return core.get_player_by_name(s.victim) or p end
	end
	return p
end

local function is_viewer(p)
	if type(p) == "userdata" and p.is_player and p:is_player() then
		local s = icu.by_controller[p:get_player_name()]
		return s ~= nil and s.mode == "view"
	end
	return false
end

-- A client opens a node's own window (a "formspec" in its meta) by itself,
-- without telling the server. When the victim then moves something in it or
-- presses a button, that is the first the server sees of it: mirror it then.
local function victim_acts_at(pos, player)
	if type(player) ~= "userdata" or not (player.is_player and player:is_player()) then return end
	local s = icu.by_victim[player:get_player_name()]
	if s and not s.meta[meta_name(pos)] then icu.mirror_victim_node_formspec(s, pos) end
end

-- f(pos, ..., player): the player is the last argument
local function wrap_last(f, forbid_viewer)
	return function(pos, ...)
		local n = select("#", ...)
		local args = { ... }
		victim_acts_at(pos, args[n])
		if forbid_viewer and is_viewer(args[n]) then return 0 end
		args[n] = actor(args[n])
		return f(pos, unpack(args, 1, n))
	end
end

-- f(player, ...)
local function wrap_first(f, forbid_viewer)
	return function(player, ...)
		if forbid_viewer and is_viewer(player) then return 0 end
		return f(actor(player), ...)
	end
end

-- A mod that did `local show_formspec = core.show_formspec` at load (smartshop,
-- for one) keeps the original function, so its windows would never reach the
-- wrapper above. Every Lua function that holds the original as an upvalue gets
-- the wrapper instead. Needs icu in secure.trusted_mods (for the debug library).
local function patch_saved_references()
	if not debug_lib then
		core.log("info", "[icu] not a trusted mod: windows of mods that load before icu and saved "
			.. "core.show_formspec in a local can't be mirrored (add icu to secure.trusted_mods).")
		return
	end
	local seen, stack, patched = {}, { _G, core }, 0
	local function visit_function(f)
		if seen[f] then return end
		seen[f] = true
		local info = debug_lib.getinfo(f, "S")
		-- (not icu's own functions: its wrapper holds the original on purpose)
		if info and info.source and info.source:find("/icu/", 1, true) then return end
		local i = 1
		while true do
			local name, value = debug_lib.getupvalue(f, i)
			if not name then break end
			if value == orig_show then
				debug_lib.setupvalue(f, i, core.show_formspec)
				patched = patched + 1
			elseif type(value) == "table" then
				stack[#stack + 1] = value
			elseif type(value) == "function" then
				visit_function(value)
			end
			i = i + 1
		end
	end
	while #stack > 0 do
		local t = table.remove(stack)
		if not seen[t] then
			seen[t] = true
			local k, v = next(t)
			while k ~= nil do
				if type(v) == "function" then visit_function(v)
				elseif type(v) == "table" and not seen[v] then stack[#stack + 1] = v end
				if type(k) == "table" and not seen[k] then stack[#stack + 1] = k end
				k, v = next(t, k)
			end
		end
	end
	core.log("action", "[icu] patched " .. patched .. " saved references to core.show_formspec")
end

core.register_on_mods_loaded(function()
	patch_saved_references()

	-- our field handler first
	local list = core.registered_on_player_receive_fields
	for i, f in ipairs(list) do
		if f == on_fields then table.remove(list, i) break end
	end
	table.insert(list, 1, on_fields)

	local node_callbacks = {
		allow_metadata_inventory_move = true, allow_metadata_inventory_put = true,
		allow_metadata_inventory_take = true,
		on_metadata_inventory_move = false, on_metadata_inventory_put = false,
		on_metadata_inventory_take = false,
	}
	for name, def in pairs(core.registered_nodes) do
		local changes
		for key, allow in pairs(node_callbacks) do
			if def[key] then
				changes = changes or {}
				changes[key] = wrap_last(def[key], allow)
			end
		end
		-- (the only way to see that a client closed a node window it opened itself)
		if def.on_receive_fields then
			local orig = def.on_receive_fields
			changes = changes or {}
			changes.on_receive_fields = function(pos, formname, fields, sender)
				local s = type(sender) == "userdata" and sender.is_player and sender:is_player()
					and icu.by_victim[sender:get_player_name()]
				if s and fields.quit then
					icu.close_meta(s, meta_name(pos))
				elseif s then
					victim_acts_at(pos, sender)
				end
				return orig(pos, formname, fields, sender)
			end
		end
		if changes then core.override_item(name, changes) end
	end

	for i, f in ipairs(core.registered_allow_player_inventory_actions) do
		core.registered_allow_player_inventory_actions[i] = wrap_first(f, true)
	end
	for _, key in ipairs({ "registered_on_player_inventory_actions" }) do
		for i, f in ipairs(core[key]) do core[key][i] = wrap_first(f) end
	end
	for i, f in ipairs(core.registered_on_crafts) do
		core.registered_on_crafts[i] = function(stack, player, ...) return f(stack, actor(player), ...) end
	end
	for i, f in ipairs(core.registered_craft_predicts) do
		core.registered_craft_predicts[i] = function(stack, player, ...) return f(stack, actor(player), ...) end
	end
end)
