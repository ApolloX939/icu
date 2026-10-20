-- The victim's HUD on the controller's / viewer's screen: the elements mods add
-- to the victim (hud_add / hud_change / hud_remove are followed), the HUD flags,
-- and health and breath bars. The controller's own mod elements are moved out of
-- sight for the session.

local SCAN = 400 -- ids looked at when copying the elements that are already there

local methods -- ObjectRef methods, patched once
local orig = {}

local function session_of_victim(obj)
	if obj.is_player and obj:is_player() then return icu.by_victim[obj:get_player_name()] end
end

local function controller_of(s) return core.get_player_by_name(s.controller) end

-- elements the controller's own HUD would get wrong (their list, their world)
local SKIP = { hotbar = true, inventory = true, minimap = true }

local function copy_def(def)
	local d = table.copy(def)
	d.z_index = d.z_index
	return d
end

local function patch(player)
	if methods then return end
	methods = getmetatable(player)
	orig.hud_add, orig.hud_change, orig.hud_remove = methods.hud_add, methods.hud_change, methods.hud_remove
	orig.hud_set_flags = methods.hud_set_flags

	function methods.hud_add(self, def)
		local id = orig.hud_add(self, def)
		local s = id and session_of_victim(self)
		if s and not SKIP[def.type or def.hud_elem_type] then
			local c = controller_of(s)
			if c then s.hudmap[id] = orig.hud_add(c, copy_def(def)) end
		end
		return id
	end

	function methods.hud_change(self, id, stat, value)
		local r = orig.hud_change(self, id, stat, value)
		local s = session_of_victim(self)
		local cid = s and s.hudmap[id]
		if cid then
			local c = controller_of(s)
			if c then orig.hud_change(c, cid, stat, type(value) == "table" and table.copy(value) or value) end
		end
		return r
	end

	function methods.hud_remove(self, id)
		local s = session_of_victim(self)
		local cid = s and s.hudmap[id]
		if cid then
			local c = controller_of(s)
			if c then orig.hud_remove(c, cid) end
			s.hudmap[id] = nil
		end
		return orig.hud_remove(self, id)
	end

	function methods.hud_set_flags(self, flags)
		local r = orig.hud_set_flags(self, flags)
		local s = session_of_victim(self)
		if s then icu.hudmirror_flags(s) end
		return r
	end
end

core.register_on_joinplayer(patch)

-- the victim's flags, but with the bars that are drawn by icu (hotbar, health,
-- breath) off and the chat always on
function icu.hudmirror_flags(s)
	local c, v = controller_of(s), core.get_player_by_name(s.victim)
	if not (c and v) then return end
	local flags = v:hud_get_flags()
	flags.hotbar, flags.healthbar, flags.breathbar, flags.chat = false, false, false, true
	orig.hud_set_flags(c, flags)
end

function icu.hudmirror_start(s, controller, victim)
	s.hudmap, s.hidden = {}, {}
	s.saved.hud_flags = controller:hud_get_flags()

	-- the controller's own mod elements: out of sight until the end
	for id = 0, SCAN do
		local def = controller:hud_get(id)
		if def then
			s.hidden[id] = { type = def.type, position = def.position, world_pos = def.world_pos }
			if def.position then orig.hud_change(controller, id, "position", { x = -10, y = -10 }) end
			if def.type == "waypoint" or def.type == "image_waypoint" then
				orig.hud_change(controller, id, "text", "")
			end
		end
	end

	-- the victim's
	for id = 0, SCAN do
		local def = victim:hud_get(id)
		if def and not SKIP[def.type or def.hud_elem_type] then s.hudmap[id] = orig.hud_add(controller, copy_def(def)) end
	end
	icu.hudmirror_flags(s)
end

function icu.hudmirror_stop(s, controller)
	for _, cid in pairs(s.hudmap or {}) do orig.hud_remove(controller, cid) end
	for id, h in pairs(s.hidden or {}) do
		if h.position then orig.hud_change(controller, id, "position", h.position) end
	end
	s.hudmap, s.hidden = nil, nil
	if s.saved.hud_flags then orig.hud_set_flags(controller, s.saved.hud_flags) end
end
