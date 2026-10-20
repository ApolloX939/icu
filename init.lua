-- icu ("I control U"): control another player, or watch them view-only.
--
-- Control: the controller's camera sits at the victim's eyes, the victim's
-- look (pitch, yaw, fov) follows the controller's, and the controller's punch,
-- place and formspec use act as the victim.
-- View only: the viewer's camera follows the victim's eyes and look, and
-- nothing the viewer does reaches the world.
--
-- A server mod can't draw a second camera in a window on the HUD, so the
-- controller's whole view is the victim's.

icu = {
	by_controller = {}, -- by_controller[name] = session
	by_victim = {},     -- by_victim[name] = session
}

-- view only: never given unless granted
core.register_privilege("icu_view", {
	description = "Watch other players without interfering (/icu view)",
	give_to_singleplayer = false,
	give_to_admin = false,
})
-- view only and control: the server admin has it by default
core.register_privilege("icu", {
	description = "Control other players and watch them (/icu control, /icu view)",
	give_to_singleplayer = false,
	give_to_admin = true,
})
-- can be neither watched nor controlled: the server admin has it by default
core.register_privilege("icu_immune", {
	description = "Can't be controlled or watched with icu",
	give_to_singleplayer = false,
	give_to_admin = true,
})

local modpath = core.get_modpath(core.get_current_modname())

-- The insecure environment can only be requested from the mod's main file. Only
-- its debug library is kept, and only handed to forms.lua (never stored in `icu`).
local ie = core.request_insecure_environment()
local debug_lib = ie and ie.debug
ie = nil
dofile(modpath .. "/session.lua")
dofile(modpath .. "/hudmirror.lua")
dofile(modpath .. "/chat.lua")
dofile(modpath .. "/hud.lua")
assert(loadfile(modpath .. "/forms.lua"))(debug_lib)
dofile(modpath .. "/relay.lua")
dofile(modpath .. "/commands.lua")
