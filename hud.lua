-- The victim's hotbar, drawn on the controller's / viewer's HUD in place of
-- their own (their own is hidden for the session). The selected slot is the
-- controller's own selection while controlling (that picks the victim's stack
-- that is used) and the victim's while viewing.

local SIZE = 48
local STEP = 56

-- (the base texture only: modifiers don't survive inside [inventorycube)
local function tile_name(t)
	if type(t) == "table" then t = t.name or t.image end
	t = t or "unknown_node.png"
	return t:match("^[^%^&]+") or "unknown_node.png"
end

local function icon(stack)
	if stack:is_empty() then return "[fill:1x1:#00000000" end
	local def = stack:get_definition() or {}
	local tex = def.inventory_image
	if not tex or tex == "" then
		local tiles = def.tiles or {}
		if def.type == "node" and #tiles > 0 then
			tex = ("[inventorycube{%s{%s{%s"):format(tile_name(tiles[1]), tile_name(tiles[3] or tiles[1]),
				tile_name(tiles[5] or tiles[3] or tiles[1]))
		else
			tex = def.wield_image
			if not tex or tex == "" then tex = "unknown_item.png" end
		end
	end
	return tex .. ("^[resize:%dx%d"):format(SIZE, SIZE)
end

local function add(controller, def)
	def.position = { x = 0.5, y = 1 }
	def.alignment = def.alignment or { x = 0, y = 0 }
	if def.type == "image" then def.scale = { x = 1, y = 1 } end
	return controller:hud_add(def)
end

function icu.hotbar_start(s, controller, victim)
	local n = victim:hud_get_hotbar_itemcount()
	local h = { n = n, slots = {}, last = {} }
	h.sel = add(controller, { type = "image", text = ("[fill:%dx%d:#ffffffcc"):format(STEP, STEP),
		offset = { x = 0, y = -44 }, z_index = 95 })
	for i = 1, n do
		local x = (i - (n + 1) / 2) * STEP
		h.slots[i] = {
			bg = add(controller, { type = "image", text = ("[fill:%dx%d:#000000aa"):format(STEP - 4, STEP - 4),
				offset = { x = x, y = -44 }, z_index = 96 }),
			icon = add(controller, { type = "image", text = icon(ItemStack()),
				offset = { x = x, y = -44 }, z_index = 97 }),
			count = add(controller, { type = "text", text = "", number = 0xFFFFFF,
				offset = { x = x + 14, y = -30 }, z_index = 98 }),
		}
	end
	h.x = function(i) return (i - (n + 1) / 2) * STEP end

	-- health and breath, left and right above the hotbar
	h.health = add(controller, { type = "statbar", text = "heart.png",
		number = victim:get_hp(), item = victim:get_properties().hp_max or 20, direction = 0,
		size = { x = 24, y = 24 }, offset = { x = -(10 * 24) - 25, y = -(48 + 24 + 16) },
		alignment = { x = -1, y = -1 }, z_index = 90 })
	h.breath = add(controller, { type = "statbar", text = "bubble.png", number = 0, item = 20, direction = 0,
		size = { x = 24, y = 24 }, offset = { x = 25, y = -(48 + 24 + 16) },
		alignment = { x = -1, y = -1 }, z_index = 90 })
	s.hotbar = h
end

function icu.hotbar_update(s, controller, victim)
	local h = s.hotbar
	if not h then return end
	local inv = victim:get_inventory()
	for i = 1, h.n do
		local stack = inv:get_stack("main", i)
		local img = icon(stack)
		local count = stack:get_count() > 1 and tostring(stack:get_count()) or ""
		local last = h.last[i] or {}
		if last.img ~= img then controller:hud_change(h.slots[i].icon, "text", img) end
		if last.count ~= count then controller:hud_change(h.slots[i].count, "text", count) end
		h.last[i] = { img = img, count = count }
	end
	controller:hud_change(h.health, "number", victim:get_hp())
	local breath = victim:get_breath()
	local max = victim:get_properties().breath_max or 10
	controller:hud_change(h.breath, "number", breath < max and breath * 2 or 0)
	local idx = s.mode == "control" and controller:get_wield_index() or victim:get_wield_index()
	idx = math.max(1, math.min(idx, h.n))
	if h.selected ~= idx then
		h.selected = idx
		controller:hud_change(h.sel, "offset", { x = h.x(idx), y = -44 })
	end
end

function icu.hotbar_stop(s, controller)
	local h = s.hotbar
	if not h then return end
	controller:hud_remove(h.sel)
	controller:hud_remove(h.health)
	controller:hud_remove(h.breath)
	for _, e in ipairs(h.slots) do
		controller:hud_remove(e.bg) controller:hud_remove(e.icon) controller:hud_remove(e.count)
	end
	s.hotbar = nil
end
