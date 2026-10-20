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

-- Objects that are part of the victim or controller (their held item, armor
-- and other attached things) are never what the controller points at.
local function is_part_of(obj, victim, controller)
	local parent = obj:get_attach()
	return parent == victim or parent == controller
end

-- Where the controller's camera is: the victim's eyes, moved by the camera
-- offset (which turns with the yaw, not the pitch).
local function camera_pos(controller, victim)
	local eyes = victim:get_pos()
	eyes.y = eyes.y + (victim:get_properties().eye_height or 1.625)
	local offset = controller:get_eye_offset()
	local yaw = controller:get_look_horizontal()
	local up, forward = offset.y / 10, offset.z / 10
	return { x = eyes.x - math.sin(yaw) * forward, y = eyes.y + up, z = eyes.z + math.cos(yaw) * forward }, eyes
end

-- The first node or object along a ray that the controller can point at.
local function first_hit(from, dir, length, victim, controller)
	for pt in core.raycast(from, vector.add(from, vector.multiply(dir, length)), true, false) do
		if pt.type == "object" then
			local obj = pt.ref
			local skip = obj == victim or obj == controller or is_part_of(obj, victim, controller)
			if not skip and obj:is_player() and icu.by_controller[obj:get_player_name()] then skip = true end
			if not skip then return pt end
		else
			return pt
		end
	end
end

-- What the victim points at. What's under the crosshair, seen from the
-- camera (looking down moves the camera up and forward, so from the victim's
-- eyes the crosshair and the hit node would differ by up to a node), as far as
-- the victim can reach from their eyes; if there is nothing there, the same
-- direction from the victim's eyes (so looking straight down at an edge
-- still reaches the node under the victim).
local function pointed(s, controller, victim)
	local cam, eyes = camera_pos(controller, victim)
	local dir = controller:get_look_dir()
	local range = reach(victim)
	local pt = first_hit(cam, dir, range + vector.distance(cam, eyes), victim, controller)
	if pt and vector.distance(pt.intersection_point or cam, eyes) <= range + 0.5 then return pt, dir end
	pt = first_hit(eyes, dir, range, victim, controller)
	return pt or { type = "nothing" }, dir
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
	-- (what is placed can depend on the way the victim looks)
	icu.sync_look(s, controller, victim, 0, true)
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

---------------------------------------------------------------------------
-- Movement: the controller's keys move the victim
---------------------------------------------------------------------------

local function setting(key, default) return tonumber(core.settings:get(key)) or default end

-- The server can't set what a client's own keys do; it sets the victim's
-- velocity to what the controller's keys ask for (walk, sneak, sprint, jump).
-- A client brakes its player by itself when no key is pressed, which would
-- undo most of each push between two server steps, so the victim's client
-- doesn't accelerate on its own during the session (their acceleration
-- physics are 0) and keeps the velocity it is given.
-- The server checks how fast a player moves against their walk speed, so a
-- sprinting victim would be put back: their walk speed physics (which only
-- that check uses now, their client doesn't walk by itself) are raised.
local HELD = { acceleration_default = 0, acceleration_air = 0, acceleration_fast = 0, speed_walk = 4 }

-- (other mods may change these meanwhile, sbz's realms do: what they set
-- is what the victim gets back at the end)
local function hold_physics(s, victim)
	local ov = victim:get_physics_override()
	s.held = s.held or {}
	local set
	for key, value in pairs(HELD) do
		if ov[key] ~= value then
			s.held[key] = ov[key]
			set = set or {}
			set[key] = value
		end
	end
	if set then victim:set_physics_override(set) end
end

function icu.move_stop(s, victim)
	if not s.held then return end
	local ov = victim:get_physics_override()
	local back = {}
	for key, value in pairs(s.held) do
		if ov[key] == HELD[key] then back[key] = value end
	end
	victim:set_physics_override(back)
	s.held = nil
end

local function wanted_speed(s, c, victim)
	local speed = setting("movement_speed_walk", 4)
	if c.sneak then
		speed = setting("movement_speed_crouch", 1.35)
	elseif c.aux1 then
		if core.check_player_privs(s.victim, { fast = true }) then
			speed = setting("movement_speed_fast", 20)
		else
			-- the sprint key: a game's sprint (Skyblock: Zero's is x1.8) only speeds
			-- up the player who holds the key, which is the controller
			speed = speed * setting("icu.sprint_multiplier", 1.8)
		end
	end
	return speed * (victim:get_physics_override().speed or 1)
end

local RESYNC = 0.3 -- seconds the target must stay the same before trusting the client's velocity

function icu.move_step(s, controller, victim, dt)
	hold_physics(s, victim)
	local c = controller:get_player_control()
	local forward = (c.up and 1 or 0) - (c.down and 1 or 0)
	local side = (c.right and 1 or 0) - (c.left and 1 or 0)
	local tx, tz = 0, 0
	if forward ~= 0 or side ~= 0 then
		-- the way they face, whatever the pitch (looking straight down still walks forward)
		local yaw = controller:get_look_horizontal()
		local fx, fz = -math.sin(yaw), math.cos(yaw)
		local dx, dz = fx * forward + fz * side, fz * forward - fx * side
		local n = math.sqrt(dx * dx + dz * dz)
		local speed = wanted_speed(s, c, victim)
		tx, tz = dx / n * speed, dz / n * speed
	end

	-- What the client's velocity is, as far as the pushes go: the velocity
	-- the client reports comes a step or two late, so pushing by it would
	-- overshoot. It is trusted only once the target stayed the same for a
	-- while (after hitting a wall or being knocked back).
	local vel = victim:get_velocity()
	local cmd = s.cmd or { x = vel.x, z = vel.z }
	if s.target and (math.abs(s.target.x - tx) > 0.01 or math.abs(s.target.z - tz) > 0.01) then
		s.steady = 0
	else
		s.steady = (s.steady or 0) + dt
	end
	s.target = { x = tx, z = tz }
	if s.steady >= RESYNC and (math.abs(vel.x - cmd.x) > 0.3 or math.abs(vel.z - cmd.z) > 0.3) then
		cmd = { x = vel.x, z = vel.z }
		s.steady = 0
	end
	if math.abs(tx - cmd.x) > 0.01 or math.abs(tz - cmd.z) > 0.01 then
		victim:add_velocity({ x = tx - cmd.x, y = 0, z = tz - cmd.z })
	end
	s.cmd = { x = tx, z = tz }

	s.jump_wait = (s.jump_wait or 0) - dt
	if c.jump and s.jump_wait <= 0 and math.abs(vel.y) < 0.05 then
		s.jump_wait = 0.4
		victim:add_velocity({ x = 0, y = setting("movement_speed_jump", 6.5) * (victim:get_physics_override().jump or 1), z = 0 })
	end
end

---------------------------------------------------------------------------
-- Look: the victim looks the way the controller does
---------------------------------------------------------------------------

-- Setting a player's look sends them their position too, as the server last
-- heard it, which is a little behind where their client already is: a
-- walking victim would be pulled back every time. So the look is sent only
-- when it changed, while walking at most every LOOK_INTERVAL and followed by
-- the distance the client had covered meanwhile, and not in mid-air unless an
-- action needs it.
local LOOK_INTERVAL = 0.2

local function angle_diff(a, b)
	local d = (a - b) % (2 * math.pi)
	return d > math.pi and d - 2 * math.pi or d
end

function icu.sync_look(s, controller, victim, dt, urgent)
	s.look_wait = (s.look_wait or 0) - dt
	local yaw, pitch = controller:get_look_horizontal(), controller:get_look_vertical()
	if math.abs(angle_diff(yaw, victim:get_look_horizontal())) < 0.005
			and math.abs(pitch - victim:get_look_vertical()) < 0.005 then
		return
	end
	local cmd = s.cmd or { x = 0, z = 0 }
	local moving = math.abs(cmd.x) + math.abs(cmd.z) > 0.01
	if math.abs(victim:get_velocity().y) > 0.1 and not urgent then return end
	if moving and s.look_wait > 0 then return end
	s.look_wait = LOOK_INTERVAL
	victim:set_look_horizontal(yaw)
	victim:set_look_vertical(pitch)
	if moving then
		-- how far behind the server is: half a client position report
		-- interval, plus the trip there and back
		local info = core.get_player_information(s.victim)
		local lag = ((info and info.avg_rtt) or 0.05) + 0.05
		victim:add_pos({ x = cmd.x * lag, y = 0, z = cmd.z * lag })
	end
end
