# Roblox Mesh Tools

**Mesh Downloader** (Windows app) + **Mesh Tools** (Roblox Studio plugin: Mesh Collector + Mesh Inserter).

- Download Roblox meshes as real `.mesh` files (Open Cloud API key, stored encrypted on your PC - never in this repo).
- Build local copies of models whose MeshParts load your `.mesh` files (`rbxasset://meshtools/<id>.mesh`).
- Browse, preview and insert everything you've downloaded.

## Install
1. Download **[Install Mesh Downloader.bat](https://github.com/BrownPeak64495/roblox-mesh-tools/raw/main/Install%20Mesh%20Downloader.bat)** and double-click it
   (SmartScreen? More info > Run anyway).
2. Pick where to install (any drive). It makes a `Mesh Downloader` folder there, opens the app, and the app adds a
   **Mesh Downloader** icon to your Desktop and Start menu and installs the Studio plugin.
3. Restart Studio.

Full guide: [README.txt](README.txt)

## Updates
The app checks this repo every time it opens (`version.json`). If there's a newer version it downloads it,
replaces its own files, re-installs the plugin and restarts.
