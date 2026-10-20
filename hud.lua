-- The victim's hotbar, drawn on the controller's / viewer's HUD in place of
-- their own (their own is hidden for the session). The selected slot is the
-- controller's own selection while controlling (that picks the victim's stack
-- that is used) and the victim's while viewing.

local SIZE = 48
local STEP = 56
local HAND = 96 -- the held item, bottom right

-- (the base texture only: modifiers don't survive inside [inventorycube)
local function tile_name(t)
	if type(t) == "table" then t = t.name or t.image end
	t = t or "unknown_node.png"
	return t:match("^[^%^&]+") or "unknown_node.png"
end

local function icon(stack, size)
	size = size or SIZE
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
	return tex .. ("^[resize:%dx%d"):format(size, size)
end

-- the wear bar of a tool: green full to red empty, as wide as the icon
local function wear_bar(stack)
	local wear = stack:get_wear()
	if wear <= 0 then return "[fill:1x1:#00000000" end
	local left = 1 - wear / 65535
	local w = math.max(1, math.floor((SIZE - 4) * left))
	local r, g = math.floor(255 * math.min(1, 2 * (1 - left))), math.floor(255 * math.min(1, 2 * left))
	return ("[fill:%dx4:#%02x%02x00"):format(w, r, g)
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
			wear = add(controller, { type = "image", text = "[fill:1x1:#00000000",
				offset = { x = x, y = -22 }, z_index = 99 }),
		}
	end
	-- the held item (the controller's own hand is hidden)
	h.hand = add(controller, { type = "image", text = "[fill:1x1:#00000000",
		position = nil, offset = { x = 0, y = 0 }, z_index = 90 })
	controller:hud_change(h.hand, "position", { x = 0.88, y = 0.97 })
	controller:hud_change(h.hand, "alignment", { x = 0, y = 1 })
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
		local wear = wear_bar(stack)
		local last = h.last[i] or {}
		if last.img ~= img then controller:hud_change(h.slots[i].icon, "text", img) end
		if last.count ~= count then controller:hud_change(h.slots[i].count, "text", count) end
		if last.wear ~= wear then controller:hud_change(h.slots[i].wear, "text", wear) end
		h.last[i] = { img = img, count = count, wear = wear }
	end
	controller:hud_change(h.health, "number", victim:get_hp())
	local breath = victim:get_breath()
	local max = victim:get_properties().breath_max or 10
	controller:hud_change(h.breath, "number", breath < max and breath * 2 or 0)
	local idx = s.mode == "control" and controller:get_wield_index() or victim:get_wield_index()
	idx = math.max(1, math.min(idx, h.n))
	-- the held item: the controller's selected stack of the victim's, or what the victim holds
	local held = s.mode == "control" and inv:get_stack("main", idx) or victim:get_wielded_item()
	local hand = victim:hud_get_flags().wielditem == false and "[fill:1x1:#00000000" or icon(held, HAND)
	if h.hand_img ~= hand then
		h.hand_img = hand
		controller:hud_change(h.hand, "text", hand)
	end
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
		controller:hud_remove(e.wear)
	end
	controller:hud_remove(h.hand)
	s.hotbar = nil
end
