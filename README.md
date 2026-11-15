# Roblox Mesh Tools

**Mesh Downloader** (Windows app) + **Mesh Tools** (Roblox Studio plugin: Mesh Collector + Mesh Inserter).

- Download Roblox meshes as real `.mesh` files (Open Cloud API key, stored encrypted on your PC - never in this repo).
- Build local copies of models whose MeshParts load your `.mesh` files (`rbxasset://meshtools/<id>.mesh`).
- Browse, preview and insert everything you've downloaded.

## Install
1. Download this repo as a ZIP (Code > Download ZIP) and unzip it somewhere you'll keep it.
2. Double-click `Start Mesh Downloader.bat`. The app installs the Studio plugin by itself.
3. Restart Studio.

Full guide: [README.txt](README.txt)

## Updates
The app checks this repo every time it opens (`version.json`). If there's a newer version it downloads it,
replaces its own files, re-installs the plugin and restarts.
