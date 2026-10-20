-- The controller's punch and place, done as the victim.

local function logact(s, msg)
	if core.settings:get_bool("icu.log_actions", false) then
		core.log("action", ("[icu] %s as %s: %s"):format(s.controller, s.victim, msg))
	end
end

local REPEAT_PLACE = 0.25 -- seconds between places while the button is held
local REPEAT_PUNCH = 0.25

local function reach(victim)
	local def = victim:get_wielded_item():get_definition()
	return (def and def.range) or (core.registered_items[""] and core.registered_items[""].range) or 4
end

-- what the victim points at: the first node or object along the view
local function pointed(s, controller, victim)
	local pos = victim:get_pos()
	pos.y = pos.y + (victim:get_properties().eye_height or 1.625)
	pos = vector.add(pos, vector.divide(victim:get_eye_offset(), 10))
	local dir = controller:get_look_dir()
	local ray = core.raycast(pos, vector.add(pos, vector.multiply(dir, reach(victim))), true, false)
	for pt in ray do
		if pt.type == "object" then
			local obj = pt.ref
			local skip = obj == victim
			if not skip and obj:is_player() and icu.by_controller[obj:get_player_name()] then skip = true end
			if not skip then return pt, dir end
		else
			return pt, dir
		end
	end
	return { type = "nothing" }, dir
end

local function to_pointed_thing(pt)
	if pt.type == "node" then return { type = "node", under = pt.under, above = pt.above } end
	if pt.type == "object" then return { type = "object", ref = pt.ref } end
	return { type = "nothing" }
end

local function wield(victim, stack)
	if stack then victim:set_wielded_item(stack) end
end

-- left button: use the item, punch what's pointed at, dig the node
local function left(s, victim, pt, dir, dt, pressed)
	local d = s.dig
	local stack = victim:get_wielded_item()
	local def = stack:get_definition()
	local thing = to_pointed_thing(pt)

	if pressed and def.on_use then
		logact(s, "use " .. stack:get_name())
		wield(victim, def.on_use(stack, victim, thing))
		return
	end

	if pt.type == "object" then
		d.progress, d.hash = 0, nil
		d.punch = (d.punch or 0) - dt
		if pressed or d.punch <= 0 then
			d.punch = REPEAT_PUNCH
			logact(s, "punch an object")
			local caps = stack:get_tool_capabilities()
			pt.ref:punch(victim, caps.full_punch_interval or 1, caps, dir)
		end
		return
	end

	if pt.type ~= "node" then
		d.progress, d.hash = 0, nil
		return
	end

	local hash = core.hash_node_position(pt.under)
	local node = core.get_node(pt.under)
	local ndef = core.registered_nodes[node.name]
	if not ndef then return end
	if d.hash ~= hash then
		d.hash, d.progress = hash, 0
		if ndef.on_punch then ndef.on_punch(pt.under, node, victim, thing) end
		core.node_punch(pt.under, node, victim, thing)
	end
	local dp = core.get_dig_params(ndef.groups, stack:get_tool_capabilities(), stack:get_wear())
	d.logged = (d.logged or 0) + dt
	if d.logged >= 1 then
		d.logged = 0
		logact(s, ("digging %s %.1f/%.1f diggable=%s"):format(node.name, d.progress, dp.time or -1, tostring(dp.diggable)))
	end
	if not dp.diggable then return end
	d.progress = d.progress + dt
	if d.progress >= (core.is_creative_enabled(victim:get_player_name()) and 0 or dp.time) then
		d.progress, d.hash = 0, nil
		logact(s, "dig " .. node.name .. " at " .. core.pos_to_string(pt.under))
		if ndef.on_dig then ndef.on_dig(pt.under, node, victim) else core.node_dig(pt.under, node, victim) end
	end
end

-- right button: formspec of a node, right-click of an object, the item's own place
local function right(s, controller, victim, pt, pressed, held_for)
	local stack = victim:get_wielded_item()
	local def = stack:get_definition()
	local thing = to_pointed_thing(pt)
	local sneak = victim:get_player_control().sneak or controller:get_player_control().sneak

	if pt.type == "node" and pressed and not sneak then
		-- what a client does on its own: open the node's formspec
		if icu.show_node_formspec(s, pt.under) then logact(s, "formspec of " .. core.pos_to_string(pt.under)) return end
	end

	if pt.type == "object" and pressed then
		local ent = pt.ref:get_luaentity()
		if ent and ent.on_rightclick then
			ent:on_rightclick(victim)
			return
		end
	end

	if not pressed and not (def.type == "node" and pt.type == "node") then return end

	if pt.type == "nothing" then
		if def.on_secondary_use then wield(victim, def.on_secondary_use(stack, victim, thing)) end
		return
	end
	logact(s, "place " .. stack:get_name() .. " " .. pt.type)
	if def.on_place then
		wield(victim, def.on_place(stack, victim, thing))
	else
		wield(victim, (core.item_place(stack, victim, thing)))
	end
end

-- Runs f with the stack of the controller's selected slot as the victim's
-- wielded item (the server can't switch a player's slot): the two stacks swap
-- places for the call and go back after.
local function with_selected(controller, victim, f)
	local inv = victim:get_inventory()
	local cur = victim:get_wield_index()
	local idx = math.max(math.min(controller:get_wield_index(), inv:get_size("main")), 1)
	if idx == cur then return f() end
	local own, chosen = inv:get_stack("main", cur), inv:get_stack("main", idx)
	inv:set_stack("main", cur, chosen)
	local ok, err = pcall(f)
	inv:set_stack("main", idx, victim:get_wielded_item())
	inv:set_stack("main", cur, own)
	if not ok then error(err, 0) end
end

function icu.relay_step(s, controller, victim, dt)
	local control = controller:get_player_control()
	if not (control.dig or control.place or s.was_dig or s.was_place) then return end
	with_selected(controller, victim, function() icu.relay_inner(s, controller, victim, dt, control) end)
end

function icu.relay_inner(s, controller, victim, dt, control)
	local pt, dir = pointed(s, controller, victim)
	if control.dig and not s.was_dig then logact(s, "left button, pointing at " .. pt.type .. (pt.type == "node" and (" " .. core.get_node(pt.under).name) or "")) end

	if control.dig then
		left(s, victim, pt, dir, dt, not s.was_dig)
	else
		s.dig.progress, s.dig.hash, s.dig.punch = 0, nil, nil
	end
	s.was_dig = control.dig

	if control.place then
		s.place_timer = (s.place_timer or 0) - dt
		local first = not s.was_place
		if first or s.place_timer <= 0 then
			s.place_timer = REPEAT_PLACE
			right(s, controller, victim, pt, first)
		end
	end
	s.was_place = control.place
end
