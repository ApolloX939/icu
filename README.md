# icu: I control U

A server operator tool: **control** another player, or **watch** them
**view only**.

```
/icu control <player>    needs `icu`
/icu view <player>       needs `icu` or `icu_view`
/icu stop                end your session
/icu list                who controls / watches whom (needs `icu` or `icu_view`)
```

## Privileges

| Privilege | Gives | By default |
| --- | --- | --- |
| `icu_view` | watching, view only | nobody (grant it) |
| `icu` | watching and controlling | the server admin |
| `icu_immune` | can be neither watched nor controlled | the server admin |

## Control

- The controller's camera sits at the victim's eyes (a little in front of the
  face, outside the head model) and shows what the victim sees.
- The victim's look follows the controller's: **pitch, yaw and fov**.
- The controller's **punch, place and use** act as the victim, with the
  victim's items and permissions: digging (with the tool's dig time and wear),
  placing, punching entities, right-clicking nodes and entities, items with
  `on_use` / `on_secondary_use`. The controller's selected hotbar slot picks
  which of the victim's stacks is used (the HUD shows it).
- Formspecs the victim is shown (chests, furnaces, machines, mod windows) are
  shown to the controller too, and what the controller submits goes to the mods
  **as if the victim had submitted it**. In those windows the controller's
  inventory list *is* the victim's: items they move come from and go to the
  victim's inventory. The controller's own inventory key opens the victim's
  inventory.
- Mods' inventory callbacks, craft callbacks and `on_receive_fields` see the
  victim as the actor, not the controller.
- Nothing the controller does goes through as themselves: the `interact`
  privilege is taken away for the session (and given back when it ends, or at
  their next join if the server stopped meanwhile).

## View only

The viewer's camera and look (and fov) follow the victim, and the HUD shows who
and what they hold. Nothing the viewer does reaches the world or the victim:
no `interact`, no relayed actions, and formspecs are shown as read-only pictures
(refreshed twice a second).

## Limits

- A server mod can't draw a second camera in a window on the HUD: the
  controller's whole view is the victim's.
- The server doesn't know a client's own fov setting, only what mods set with
  `set_fov` (zoom): that is what is mirrored.
- The server can't change which hotbar slot a player has selected: the
  controller's selected stack is swapped into the victim's wielded slot for each
  action and swapped back.
- `core.item_place` reads the *victim's* sneak key for "right-click the node or
  place against it".
- Formspecs a client opens itself when the victim right-clicks a node (a node's
  meta formspec) aren't mirrored; the ones the controller opens that way are
  shown to both. Mods that kept `core.show_formspec` in a local before icu loaded
  can't be mirrored either.
- The crafting grid isn't mirrored for the controller (the inventory lists
  `main` and other plain lists are).
- The victim keeps moving themselves (movement isn't relayed).

## Settings

| Setting | Default | |
| --- | --- | --- |
| `icu.notify_target` | true | Tell the victim when a control session starts and ends (view only is never announced). |
| `icu.return_to_origin` | true | Put the controller back where they were at the end. |
| `icu.camera_forward` / `icu.camera_up` | 4 / 2 | Camera offset from the victim's eyes (1/10 node). |
| `icu.log_actions` | false | Log every relayed action. |

Every session start and end, control or view, is always logged on the server (`[icu] ...`).

## License

MIT
