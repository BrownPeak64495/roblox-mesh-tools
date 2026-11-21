# Roblox Mesh Tools

**Mesh Downloader** (Windows app) + **Mesh Tools** (Roblox Studio plugin: Mesh Collector + Mesh Inserter).

- Download Roblox meshes as real `.mesh` files (Open Cloud API key, stored encrypted on your PC - never in this repo).
- Build local copies of models whose MeshParts load your `.mesh` files (`rbxasset://meshtools/<id>.mesh`).
- Browse, preview and insert everything you've downloaded.
- **Blender to Studio, no upload:** the `mesh_tools_blender.py` add-on sends your object to Studio as a local `.mesh` (with its texture, bones and weights). Resending updates the same part; Live mode resends as you edit and moves the bones as you pose. See README.txt.
- **Studio to Blender:** select parts > **Send to Blender** (toolbar). They arrive with their texture, colour, see-through spots and bones, and stay linked both ways - move or recolour in Studio and Blender follows, edit in Blender and Studio updates.
- **Import .obj** in the Studio plugin: converts it to a local `.mesh` and inserts it.

## Install
1. **[Click here to download Mesh Downloader](https://github.com/BrownPeak64495/roblox-mesh-tools/archive/refs/heads/main.zip)** (a .zip).
2. Right-click the zip > **Extract All** > Extract.
3. In the extracted folder, double-click **Setup.bat**
   (SmartScreen? **More info** > **Run anyway**).
4. Pick where to install (any drive - external drives are fine). Setup copies the app there, opens it,
   and the app adds a **Mesh Downloader** icon to your Desktop and Start menu and installs the Studio plugin.
5. Restart Studio. You can delete the zip and the extracted folder.

Setup doesn't download anything - it only copies the files that are in the zip.

## Updates
The app checks this repo every time it opens (`version.json`). If there's a newer version it downloads it,
replaces its own files, re-installs the plugin and restarts.
