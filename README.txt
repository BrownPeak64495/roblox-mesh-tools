ROBLOX MESH TOOLS v3.4
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
MESH COLLECTOR (Studio)
--------------------------------------------------
Click any model/part - the list updates live.

Settings (click "Settings" to fold them away):
  Name files by:  Part | Parent | Model (closest) | Top (outermost) | Custom
  Custom name:    used when Custom is picked, AND as the file name for
                  saved / built models (leave empty to use the model's name)
  Add part name:  AK47_Magazine instead of AK47
  Add mesh ID:    off = Magazine.mesh instead of Magazine_123456.mesh
                  (two different meshes with the same name become "Name (2)")
  Folder per model
  Model pivot:    Keep | Middle (center of the bounding box) | Average
                  (average position of all parts)
  Center each part's pivot on itself
  (Pivot settings are used by Build local copy, Save model, Insert, and the
   "Apply pivots" button - which works on ANY selected model or part.)

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
MESH INSERTER (Studio)
--------------------------------------------------
Shows everything you've downloaded or saved:
  MODELS - click the arrow to expand a model and see its meshes
  MESHES - every downloaded .mesh
Search box filters both. Refresh reloads the list.

Preview: the item spins on its own. Hover to stop it, drag to look around,
scroll to zoom. Name and details (verts, tris, bones, size, file size,
date) show underneath.

Insert:
  a mesh   -> a MeshPart that loads your local .mesh
  a model  -> the whole thing, keeping its folders / models / other objects
  a part   -> just that part (with its texture)
It lands in front of the camera and gets selected.
Show in folder opens the file in File Explorer.

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
