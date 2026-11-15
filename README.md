# Roblox Mesh Tools

**Mesh Downloader** (Windows app) + **Mesh Tools** (Roblox Studio plugin: Mesh Collector + Mesh Inserter).

- Download Roblox meshes as real `.mesh` files (Open Cloud API key, stored encrypted on your PC - never in this repo).
- Build local copies of models whose MeshParts load your `.mesh` files (`rbxasset://meshtools/<id>.mesh`).
- Browse, preview and insert everything you've downloaded.

## Install
1. **[Click here to download the installer](https://github.com/BrownPeak64495/roblox-mesh-tools/raw/main/Install%20Mesh%20Downloader.zip)** (a small .zip).
2. Open the downloaded zip and double-click **Install Mesh Downloader.bat** inside it
   (Windows may ask "Extract all?" - either way works).
   SmartScreen? Click **More info** > **Run anyway**.
3. Pick where to install (any drive, external drives are fine). It makes a `Mesh Downloader` folder there,
   opens the app, and the app adds a **Mesh Downloader** icon to your Desktop and Start menu and installs the Studio plugin.
4. Restart Studio.

## Updates
The app checks this repo every time it opens (`version.json`). If there's a newer version it downloads it,
replaces its own files, re-installs the plugin and restarts.
