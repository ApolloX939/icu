-- Chat: what a controller types (messages and commands, except /icu) is said
-- and run as the victim; what is sent to the victim privately (command replies,
-- private messages) is shown to the controller / viewer too.

local orig_send = core.chat_send_player
icu.raw_chat_send = orig_send

function core.chat_send_player(name, message)
	orig_send(name, message)
	local s = icu.by_victim[name]
	if s then orig_send(s.controller, message) end
end

local function on_chat(name, message)
	local s = icu.by_controller[name]
	if not s or s.mode ~= "control" then return end
	-- icu's own commands (/icu stop ...) are the controller's
	if message:match("^/icu%f[%s%z]") then return end

	local victim = core.get_player_by_name(s.victim)
	if not victim then return end
	core.log("action", ("[icu] %s says as %s: %s"):format(name, s.victim, message))
	for _, f in ipairs(core.registered_on_chat_messages) do
		if f ~= on_chat and f(s.victim, message) then return true end
	end
	if not core.check_player_privs(s.victim, { shout = true }) then
		orig_send(name, "-!- " .. s.victim .. " doesn't have permission to shout.")
		return true
	end
	core.chat_send_all(core.format_chat_message(s.victim, message))
	return true
end

core.register_on_chat_message(on_chat)

core.register_on_mods_loaded(function()
	local list = core.registered_on_chat_messages
	for i, f in ipairs(list) do
		if f == on_chat then table.remove(list, i) break end
	end
	table.insert(list, 1, on_chat)
end)
