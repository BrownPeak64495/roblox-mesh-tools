ROBLOX MESH TOOLS v4.1
======================

What's in here
  Setup.bat / setup.ps1       Installs the app to a folder you choose
  Start Mesh Downloader.bat   Opens the app without the Desktop icon
  MeshDownloader.ico          The app's icon
  RobloxMeshDownloader.ps1    The Mesh Downloader app
  MeshCollector.lua           The Studio plugin (the app installs it for you)
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
Click a card's name to select that part in Studio; click a model's
header to select the whole model.

Buttons:
  Send to Downloader   download the listed meshes
  Build local copy     copy of the model with real MeshParts loading your
                       .mesh files (rbxasset://meshtools/<id>.mesh), saved
                       automatically to Local Models
  Save model           saves the selected model to Models (no save window)
  Apply pivots         applies the pivot settings to the selection now
  Copy list            fallback if the app link isn't working
  Open Inserter

--------------------------------------------------
MESH INSERTER (Studio)  - tabs: Library | Settings
--------------------------------------------------
MODELS - press + on a model card to show its meshes below
MESHES - every downloaded .mesh
Click a card's name -> details + Insert / Show in folder.
Insert: a mesh -> MeshPart loading your local .mesh; a model -> the whole
thing with its folders/models; a part -> just that part.

--------------------------------------------------
3D PREVIEWS (every card)
--------------------------------------------------
  hover   -> smoothly grows into a big preview; move away -> shrinks back
  click   -> opens big and stays open (click it again to let go)
  drag    -> rotate,  scroll -> zoom
The light follows your view (or pick Flat lighting in Settings).

--------------------------------------------------
SETTINGS TAB (same in both windows)
--------------------------------------------------
Appearance: Theme (Studio / Dark / Classic grey / Midnight), accent colour,
            font, text size, corner roundness, animation speed (or off)
Layout:     Grid boxes or List rows, card size, spacing, details on cards,
            max items shown, Inserter details panel above/below the list
Previews:   spin on/off + speed, grow on hover on/off + delay, big preview
            size, lighting
Naming:     Name files by Part / Parent / Model / Top / Custom, custom name,
            add part name, add mesh ID, folder per model
Pivots:     Model pivot Keep / Middle / Average, center part pivots
              Middle  = centre of the box around the whole model
              Average = average position of all its parts
Collector:  Live, download right away
Reset all settings

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
