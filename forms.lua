-- Formspecs: what is shown to the victim is shown to the controller too, the
-- controller's inventory lists are the victim's, and what the controller
-- submits goes to the mods as if the victim had. For a viewer the copy is the
-- same window with lists that can't be changed.

local orig_show = core.show_formspec
icu.raw_show = orig_show

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

-- the node formspec a player's client would open itself (right-click on a
-- node with a "formspec" in its meta)
function icu.show_node_formspec(s, pos)
	local fs = core.get_meta(pos):get_string("formspec")
	if fs == "" then return false end
	local loc = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	fs = fs:gsub("%[context;", "[" .. loc .. ";"):gsub("%[context_", "[" .. loc .. "_")
	local formname = ("icu:meta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	core.show_formspec(s.victim, formname, fs)
	return true
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
			if s.mode == "control" and formname ~= "" then orig_show(s.victim, formname, "") end
		end
		return true
	end
	s = icu.by_victim[name]
	if s then
		if formname:sub(1, 9) == "icu:meta:" then
			dispatch_as(player, formname, fields, on_fields)
			if fields.quit then s.forms[formname] = nil orig_show(s.controller, formname, "") end
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

-- f(..., player): the player is the last argument
local function wrap_last(f, forbid_viewer)
	return function(...)
		local n = select("#", ...)
		local args = { ... }
		if forbid_viewer and is_viewer(args[n]) then return 0 end
		args[n] = actor(args[n])
		return f(unpack(args, 1, n))
	end
end

-- f(player, ...)
local function wrap_first(f, forbid_viewer)
	return function(player, ...)
		if forbid_viewer and is_viewer(player) then return 0 end
		return f(actor(player), ...)
	end
end

core.register_on_mods_loaded(function()
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
