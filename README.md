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
  face, outside the head model) and shows what the victim sees. The victim's
  hotbar is drawn on the controller's HUD, with the controller's own selected
  slot highlighted.
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
- **Node windows** are mirrored for every kind of node:
  - nodes that keep a `formspec` in their meta (Skyblock: Zero's storinators,
    Minetest Game's furnaces ...): when the controller right-clicks one, the
    window opens for the victim and the controller, and is **kept current** as
    the node changes its formspec (a furnace's fire and progress);
  - nodes whose `on_rightclick` opens a window with `core.show_formspec`
    (Minetest Game's chests ...): the controller's click runs it as the victim
    and the window is mirrored;
  - windows the victim opens by themselves (a client opens a meta formspec on
    its own and never tells the server): they are mirrored to the controller or
    viewer at the victim's first action in them (moving an item, a button), and
    closed when the victim closes them (if the node has `on_receive_fields`),
    walks more than 8 nodes away, or the node changes.
- Mods' inventory callbacks, craft callbacks and `on_receive_fields` see the
  victim as the actor, not the controller.
- **Chat**: what the controller types, messages and commands alike, is said and
  run **as the victim** (with the victim's privileges), except `/icu ...`, which
  stays the controller's (so `/icu stop` works). Replies the victim gets, such as
  command output and private messages, are shown to the controller too.
- **Movement**: the controller's keys (forward, back, left, right in the
  direction they look, sneak, jump, and sprint when the victim has `fast`) move
  the victim. The controller's own body stays attached to the victim.
- The controller is made invisible and tiny for the session, and what is
  attached to them (worn armor ...) is hidden, so even a third person camera
  shows only the victim.
- Nothing the controller does goes through as themselves: the `interact`
  privilege is taken away for the session (and given back when it ends, or at
  their next join if the server stopped meanwhile). The server still counts
  them as having it, because the engine refuses inventory changes and crafting
  without it, and stops what their client sends as themselves instead
  (punching, using or placing their own item, right-clicking, dropping).

## View only

View only shows the viewer **everything the victim sees**, the way control does,
but nothing the viewer does changes anything:

- The camera, **pitch, yaw and fov** follow the victim (the viewer can't change
  them).
- The victim's HUD is shown (see below), with their hotbar (selected slot
  highlighted) and health and breath, plus who and what they hold.
- Every window shown to the victim (chests, machines, mod windows) is shown to
  the viewer too, with the real lists (items, counts, tooltips), kept up to
  date but **read-only**: the viewer can't move, take or put anything.
- The viewer's inventory key opens the victim's inventory window, read-only.
- The viewer's chat is their own, and their movement keys do nothing (they
  follow the victim).
- No `interact`, no relayed actions: nothing the viewer does reaches the world or
  the victim, and fields they submit in those windows are dropped.

## The victim's HUD

(The hotbar shows the victim's items with counts and tool wear bars, and the
item they hold is drawn large at the bottom right in place of the controller's
own hand.)

In both modes the controller / viewer's HUD is the victim's: every element mods
add to the victim (bars, texts, images, waypoints), with later changes and
removals, the HUD flags (crosshair, chat..., with chat always on), the hotbar,
and health and breath bars. The viewer's own mod elements are moved out of sight
for the session and restored at the end. Not mirrored: the minimap element, and
`inventory` type elements (they would show the controller's own list).

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
- A node window the victim's client opens by itself is only mirrored from the
  victim's first action in it (see above), and only closed with it if the node
  has `on_receive_fields`. Mods that kept `core.show_formspec` in a local before
  icu loaded can't be mirrored.
- The crafting grid works for the controller like the player's own: the
  preview is worked out as the controller changes the grid, and moving the
  result out crafts (use up the ingredients, replacements, craft callbacks as
  the victim, so quests count). Shift-click and "craft all" buttons that read
  the victim's inventory work from what's written back. The result can only
  be taken whole.
- What the controller punches or places on is what's under the crosshair, seen
  from the camera, as far as the victim can reach; if there's nothing there,
  the same direction from the victim's eyes (so looking straight down at an
  edge reaches the node under the victim). The victim's own held item and
  armor are never hit.
- Movement works by pushing the victim's velocity (a server can't press a
  client's keys): it is not exact (acceleration, ice, ladders, flying and
  swimming aren't handled specially). The victim's client slows them down
  a fixed fraction every step when they press nothing; icu learns that fraction
  from the victim's speed and pushes harder to make up for it, so the victim
  walks at about the normal walking speed (measured 4.1 of 4 nodes/s; it was 1.25).
  The sprint key (Aux1) speeds the victim up by `icu.sprint_multiplier`.

## Mods that saved `core.show_formspec`

icu wraps `core.show_formspec` to mirror windows. A mod that loads before icu and
keeps the original in a local (`local show = core.show_formspec`) would bypass
it. If icu is in `secure.trusted_mods`, icu finds those saved references at
startup and points them at the wrapper (the server log says how many). Mods that
load after icu (smartshop does) need nothing.

## Settings

| Setting | Default | |
| --- | --- | --- |
| `icu.notify_target` | true | Tell the victim when a control session starts and ends (view only is never announced). |
| `icu.return_to_origin` | true | Put the controller back where they were at the end. |
| `icu.sprint_multiplier` | 1.8 | Walking speed multiplier while the controller holds the sprint key (Aux1), for victims without `fast` (a game's own sprint only speeds up the player holding the key, i.e. the controller). |
| `icu.camera_forward` / `icu.camera_up` | 4 / 2 | Camera offset from the victim's eyes (1/10 node) when looking straight ahead. Looking down moves the camera up and forward (up to 0.6 node more each, from 17 to 69 degrees down) so the victim's tilted head stays out of the view. |
| `icu.log_actions` | false | Log every relayed action. |

Every session start and end, control or view, is always logged on the server (`[icu] ...`).

## License

MIT
