ROBLOX MESH TOOLS v5.6
======================

What's in here
  Setup.bat / setup.ps1       Installs the app to a folder you choose
  Start Mesh Downloader.bat   Opens the app without the Desktop icon
  MeshDownloader.ico          The app's icon
  RobloxMeshDownloader.ps1    The Mesh Downloader app
  MeshCollector.lua           The Studio plugin (the app installs it for you)
  mesh_tools_blender.py       Blender add-on: Send to Studio (install it in Blender)
  version.json                Used by the auto-updater

--------------------------------------------------
SETUP (once)
--------------------------------------------------
1. Download the zip from the GitHub page, right-click it > Extract All.
2. Double-click Setup.bat (SmartScreen? More info -> Run anyway).
3. Pick where to install - any drive, external drives are fine.
   Setup copies the app there and opens it. The app then:
   - adds a "Mesh Downloader" icon to your Desktop and Start menu
     (right-click it > Pin to taskbar if you like),
   - installs the Studio plugin into Studio's Plugins folder.
4. Paste your Open Cloud API key (Get Key opens the page). It saves itself.
5. Restart Studio. Plugins tab -> "Mesh Collector" and "Mesh Inserter".
6. First time the plugin talks to the app, Studio may ask about HTTP access
   to localhost - click ALLOW (localhost = your own PC).

If you still have MeshIdCollector.lua (v1) in the Plugins folder, delete it.
Only .lua plugin files belong in the Plugins folder.

--------------------------------------------------
WHERE THINGS GO  (inside the folder you installed to, e.g. your external drive)
--------------------------------------------------
  <name>.mesh / <Model>\<name>.mesh   downloaded meshes
  Models\                             downloaded model IDs + "Save model"
  Local Models\                       "Build local copy" results
  Make Local\                         drop .rbxmx files here to convert them

--------------------------------------------------
MESH COLLECTOR (Studio)  - tabs: Collector | Settings
--------------------------------------------------
Click any model/part - the cards update live, grouped by model.
  click a card          -> selects that part in Studio
  click a card's NAME   -> rename it (the file gets that name)
  click a model header  -> selects the whole model

Buttons:
  Send to Downloader   downloads the meshes AND their textures, and saves
                       each mesh's "look" (texture, SurfaceAppearance,
                       colour) so the Inserter can insert it textured
  Build local copy     copy of the model whose meshes load your .mesh files
                       (and downloaded textures), saved to Local Models.
                       Parts with a SpecialMesh (classic heads, hats):
                       Settings > Local copies, default Auto -
                         mesh with bones (dynamic heads) -> becomes a
                           MeshPart, so FaceControls and bones work; its
                           texture goes in a SurfaceAppearance set to
                           Overlay so the skin colour still shows through
                           - and when that picture is downloaded, Mesh
                           Downloader paints it over the part's colour into
                           a new solid picture on your PC and uses that as
                           TextureID instead (fully local). Change the skin
                           colour later? Build the local copy again.
                         everything else -> stays SpecialMesh, only the
                           mesh link changes, so it looks exactly the same
                       (or pick Keep SpecialMesh / Make MeshPart always)
  Save model           saves the selected model to Models
  Reset pivots         see PIVOTS below
  Restore pivots       puts the original pivots back
  Copy list / Open Inserter

--------------------------------------------------
MESH INSERTER (Studio)  - tabs: Library | Settings
--------------------------------------------------
MODELS - press + (or "Open" in the big view) to open a model: its card
         grows into a model view right where it was.
           left:  3D view - click a part to pick it (the name of the part
                  under the mouse shows at the top), click empty space for
                  the whole model, drag to rotate, scroll to zoom
           right: the picked part (mesh ID, size, path) + Insert part,
                  and the list of the model's meshes - click to pick,
                  drag one into the scene to place it
           top:   Insert model, X to close
         Picked part: X-ray fades the other parts; Outline keeps them and
         draws an outline (Settings > Model view; the outline can also be
         on in X-ray). Invisible parts like HumanoidRootPart are skipped,
         so you can click what's behind them.
MESHES - every downloaded .mesh ("textured" = its look was saved)
"When inserting: Keep pivots / Reset pivots" sits at the top.

Insert:  click Insert, or DRAG a card into the 3D view: the card lifts
out and follows the mouse, flies back when you leave the window, and the
object appears under your cursor - let go (or click) to place it,
right-click to cancel.

--------------------------------------------------
3D PREVIEWS (every card)
--------------------------------------------------
  click the preview  -> it grows into a big view (hover can do this too:
                        Settings > "Also open the big view on hover")
  big view buttons   -> Keep open, Insert, Open (models), X
  drag               -> rotate,  scroll -> zoom
  corner "//"        -> drag to resize the big view
While the mouse is over the big view, nothing behind it can be clicked or
scrolled. It shrinks back when the mouse leaves (unless Kept open).

--------------------------------------------------
PIVOTS
--------------------------------------------------
Settings > Pivots:
  Model centre:         Middle (centre of the box around the model)
                        or Average (average position of all its parts)
  Reset pivots changes: Model only | Parts only | Both
     Model only keeps each mesh's own pivot (its offset stays).
  Reset pivots when building / saving / inserting: on/off
The ORIGINAL pivots are saved on the objects as attributes, so
"Restore pivots" always puts them back - even after saving or inserting.

--------------------------------------------------
SETTINGS TAB (same in both windows)
--------------------------------------------------
Size:       UI scale (whole window), text size, card size, spacing,
            big preview size  - all sliders
Appearance: Theme (Studio / Dark / Classic grey / Midnight), accent
            colour, font, corner roundness, animation speed (or off)
Layout:     Grid boxes or List rows, details on cards, max items,
            Inserter details panel above/below the list
Previews:   open on hover (off by default) + hover wait, grow/shrink
            speed, ignore clicks right after it opens, spin + speed,
            lighting
Naming, Pivots, Blender, Collector options, Reset all settings

--------------------------------------------------
BLENDER -> STUDIO (no upload, no moderation)
--------------------------------------------------
Sends a mesh from Blender straight into Studio as a local .mesh file. It's
private and instant: nothing goes to Roblox.

Install the add-on (once):
  1. Blender > Edit > Preferences > Add-ons.
  2. Click the down-arrow (top right) > "Install from Disk..."
     (older Blender: the "Install..." button).
  3. Go to the folder you installed Mesh Downloader in and pick
     mesh_tools_blender.py. Tick the box next to
     "Roblox Mesh Tools - Send to Studio" if it isn't ticked.
  4. In the 3D view press N > "Roblox" tab.

Use it:
  1. Open Mesh Downloader (Install meshes into Studio + Listen for Studio
     plugin both on) and Roblox Studio with your place open.
  2. In Blender select your object(s) > "Send to Studio".
  3. Within about a second a MeshPart appears in Studio in the same spot as
     in Blender, with the texture plugged into Base Color.
  4. Change it in Blender and press Send again - the SAME part updates
     (anything you moved, turned or resized in Studio is kept).
  Live: turn it on and objects you've sent once resend by themselves after
     you stop changing them for "Wait" seconds.
  Unlink (chain button): the next send makes a new part instead.
  After Mesh Downloader updates, reinstall the add-on in Blender (same
  steps) to get its newest version - Blender keeps its own copy.

Options (Send to Studio > Options):
  Studs per metre   1 = a 2 m cube becomes 2 studs. Roblox's docs count
                    1 stud as 0.28 m, so 3.57 = real-world size.
  Flip texture vertically  on by default; turn off if the texture is
                    upside-down.
  Flip faces        turn on if the mesh looks inside-out.
  Face Roblox's front  on by default: Blender's front (-Y) becomes Roblox's
                    front (-Z), like Roblox's own character meshes.
  Apply modifiers, Send texture, Port.

Plugin settings (Settings tab > Blender): receive on/off, add new objects,
select on arrival, keep my Studio moves.

BONES: an object with an Armature (modifier or armature parent) is sent with
its bones and weights (.mesh version 7.00 - the same layout as Roblox's own
dynamic head, tested in Studio). Studio gets real Bone instances inside the
part, named like your Blender bones.
  - Each vertex can follow up to 4 bones (Roblox's limit). If Blender has
    more, the strongest 4 are kept and the panel tells you how many.
  - Pose the armature with Live on: the Bones in Studio move to match
    (only the pose is sent - quick). Playing the timeline streams it.
    "Send pose" sends it once by hand.
  - Selecting the armature and pressing Send sends the meshes it moves.
  - Face controls (dynamic faces) are not made yet - bones first.
MATERIAL (Options > Send material, on by default) - from the Principled BSDF
of the object's first material:
  - Base Color picture -> texture (or, with no picture, the part's Color)
  - Normal Map / Roughness / Metallic pictures and see-through (Alpha) are
    sent, but NOT shown yet: they need a SurfaceAppearance, and Studio's
    SurfaceAppearances won't load pictures from your PC (tested). Being
    tested: a second local folder (content\textures\meshtools).
  - Backface Culling off (Blender's default) -> DoubleSided, so thin cards,
    leaves and hair show from behind like in Blender
  - New parts use SmoothPlastic (Roblox's Plastic adds a faint pattern) and
    full detail at any distance
  If you add your own SurfaceAppearance in Studio, it's left alone.
  Colours look different? Blender shows colours through a "View Transform"
  (AgX or Filmic by default) that Roblox doesn't use. To compare fairly:
  Render Properties > Color Management > View Transform = Standard.
  Procedural (node) textures have no picture to send - bake them first.
Each send gets a new number so Studio never shows an old cached copy; the
library keeps only the newest one, and Studio's folder keeps the last 3.

--------------------------------------------------
IMPORT .OBJ (in the Studio plugin)
--------------------------------------------------
Mesh Inserter > "Import .obj" (next to Refresh):
  1. Pick one or more .obj files. Pick the .mtl and the texture picture
     (.png / .jpg) at the same time if you have them (Ctrl+click).
  2. Each .obj is turned into a .mesh inside Studio, saved by Mesh
     Downloader, and inserted in front of the camera as a local MeshPart,
     with its texture. Nothing is uploaded.
  3. They also show up in the Inserter library for later.
Notes: OBJ from Blender's default export already faces the right way. Only
the shape + material (no bones - use the Blender add-on for those). From the
.mtl: map_Kd (colour picture), map_Bump / norm (normal picture), d / Tr /
map_d (see-through -> both sides shown), Kd (colour). Pictures are matched by
the names in the .mtl; with one .obj and one picture it just uses that one.

--------------------------------------------------
APP OPTIONS
--------------------------------------------------
  Center origin of saved .mesh files - the named .mesh files in your save
    folder get their origin moved to the middle of the mesh (static meshes
    only; skinned meshes are left alone so bones still line up). The copy
    Studio uses is never changed.
  Install meshes into Studio - needed for local copies and the Inserter.

--------------------------------------------------
AUTOMATIC UPDATES
--------------------------------------------------
Every time the app starts it:
  - re-installs the Studio plugin if it changed (BOTH the app and the
    plugin update - restart Studio to load a new plugin), and
  - if an Update source is set (Advanced Settings), checks it for a newer
    version, downloads it, replaces its own files and restarts.

The Update source is already set to:
  https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main
New versions are pushed there, and the app installs them on its own the next
time it opens (then restart Studio to load a new plugin version).
"Check for updates" in Advanced Settings checks right away.

The Studio plugin also checks when you open its window (and every 30 min).
If there's a newer version it shows a banner at the top: open Mesh
Downloader (it updates itself + the plugin), then restart Studio.
The first time, Studio asks to allow raw.githubusercontent.com - click Allow.

--------------------------------------------------
LIMITS
--------------------------------------------------
 - Installed on an external drive? Plug it in before opening the app.
   Studio's own copies of your meshes (in its content folder) stay on C:
   - Studio can only load local meshes from there. Settings + your
   encrypted API key also stay in AppData (tiny).
 - Local meshes (rbxasset://) only load in Studio on a PC that has the
   files. Players in a published game will NOT see them.
 - Studio updates wipe its content folder; the app re-installs the meshes
   when it starts and every minute while open.
 - Saving/inserting models through the plugin needs Studio's
   SerializationService. If your Studio doesn't have it, the plugin tells
   you and you can use right-click > Save to File / drag files in instead.

--------------------------------------------------
ERRORS
--------------------------------------------------
401  Key problem: wrong key, missing legacy-asset:manage, or IP not allowed.
403  Private, paid, or taken-down asset - can't be downloaded.
404  Wrong ID, or deleted.
429  Too many requests - the app retries automatically.
"port 47820 is busy"  Another copy of the app is already open.

Reminder: using someone else's mesh outside Roblox needs their permission.
