-- icu: control and view; icu_view: view only
local function can_control(name) return core.check_player_privs(name, { icu = true }) end
local function can_view(name)
	return core.check_player_privs(name, { icu = true }) or core.check_player_privs(name, { icu_view = true })
end

core.register_chatcommand("icu", {
	params = "control <player> | view <player> | stop | list",
	description = "Control another player, watch them (view only), or end it",
	privs = {},
	func = function(name, param)
		local sub, arg = param:match("^%s*(%S+)%s*(.-)%s*$")
		if sub == "control" then
			if not can_control(name) then return false, "You need the icu privilege." end
			if arg == "" then return false, "Usage: /icu control <player>" end
			local ok, msg = icu.start(name, arg, "control")
			return ok, ok and ("Controlling " .. arg .. ". /icu stop to end it.") or msg
		elseif sub == "view" then
			if not can_view(name) then return false, "You need the icu or icu_view privilege." end
			if arg == "" then return false, "Usage: /icu view <player>" end
			local ok, msg = icu.start(name, arg, "view")
			return ok, ok and ("Watching " .. arg .. " (view only). /icu stop to end it.") or msg
		elseif sub == "stop" then
			if not icu.stop(name) then return false, "You're not in a session." end
			return true
		elseif sub == "list" then
			if not can_view(name) then return false, "You need the icu or icu_view privilege." end
			local lines = {}
			for controller, s in pairs(icu.by_controller) do
				lines[#lines + 1] = ("%s %s %s"):format(controller, s.mode == "control" and "controls" or "watches", s.victim)
			end
			table.sort(lines)
			return true, #lines > 0 and table.concat(lines, "\n") or "No sessions."
		end
		return false, "Usage: /icu control <player> | view <player> | stop | list"
	end,
})
