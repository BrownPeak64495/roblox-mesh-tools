--[[
	Mesh Tools v3 - Roblox Studio plugin (works with the Mesh Downloader app)

	MESH COLLECTOR
	- Live list of the meshes in whatever you click.
	- Name files by Part / Parent / Model / Top Model / Custom, optional part name and mesh ID.
	- Pivot tools: model pivot to Middle or Average, part pivots to their own center.
	- Send to Downloader, Build local copy (real MeshParts using your .mesh files),
	  Save model. Models are saved BY THE APP into Documents\Roblox Meshes
	  (never into the Plugins folder).

	MESH INSERTER
	- Browse every mesh and model you've downloaded or saved.
	- Models expand to show their meshes.
	- Spinning 3D preview: hover to stop, drag to look around, scroll to zoom.
	- Insert keeps the model's folders / models / other objects.

	Install: put this file in your Studio Plugins folder (Plugins tab > Plugins Folder)
	and restart Studio. Only .lua plugin files belong in that folder.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Studio = settings().Studio

local SerializationService = nil
pcall(function()
	SerializationService = game:GetService("SerializationService")
end)

local PLUGIN_VERSION = "3.5" -- keep in sync with version.json
local VERSION_URL = "https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main/version.json"
local PORT = 47820
local BASE = "http://localhost:" .. PORT
local LOCAL_PREFIX = "rbxasset://meshtools/"
local MAX_ROWS = 300

local ACCENT = Color3.fromRGB(124, 131, 245)
local WHITE = Color3.fromRGB(255, 255, 255)
local GREEN = Color3.fromRGB(61, 220, 132)
local RED = Color3.fromRGB(242, 95, 92)
local GREY = Color3.fromRGB(130, 130, 140)

local C = Enum.StudioStyleGuideColor

-------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------
local function getSetting(key, default)
	local ok, v = pcall(function()
		return plugin:GetSetting(key)
	end)
	if not ok or v == nil then
		return default
	end
	return v
end

local state = {
	nameSource = getSetting("v3_nameSource", "top"), -- part | parent | model | top | custom
	addPart = getSetting("v3_addPart", true),
	addId = getSetting("v3_addId", true),
	customName = getSetting("v3_customName", ""),
	folderPerModel = getSetting("folderPerModel", true),
	modelPivot = getSetting("v3_modelPivot", "keep"), -- keep | middle | average
	partPivots = getSetting("v3_partPivots", false),
	live = getSetting("live", true),
	autoStart = getSetting("autoStart", true),
	settingsOpen = getSetting("v3_settingsOpen", true),
}

local function saveSetting(key, value)
	state[key] = value
	local storeKey = key
	if key ~= "folderPerModel" and key ~= "live" and key ~= "autoStart" then
		storeKey = "v3_" .. key
	end
	pcall(function()
		plugin:SetSetting(storeKey, value)
	end)
end

-------------------------------------------------------------------
-- UI helpers
-------------------------------------------------------------------
local themed = {}
local function themeColor(color)
	return Studio.Theme:GetColor(color)
end
local function theme(inst, prop, color)
	table.insert(themed, { inst, prop, color })
	inst[prop] = themeColor(color)
	return inst
end

local function new(className, props, children)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	return inst
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function padding(t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b),
		PaddingLeft = UDim.new(0, l),
	})
end

local function stroke()
	local s = new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	theme(s, "Color", C.Border)
	return s
end

local function vlist(gap)
	return new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 0),
	})
end

local function hlist(gap)
	return new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, gap or 0),
	})
end

local function label(props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	})
	for k, v in pairs(props) do
		l[k] = v
	end
	if not props.TextColor3 then
		theme(l, "TextColor3", C.MainText)
	end
	return l
end

local function dimLabel(text, order, size)
	local l = label({
		Text = text,
		TextSize = size or 12,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
	})
	theme(l, "TextColor3", C.DimmedText)
	return l
end

local function button(text, primary, order)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		AutoButtonColor = true,
		LayoutOrder = order or 0,
	}, { corner(8) })
	if primary then
		b.BackgroundColor3 = ACCENT
		b.TextColor3 = WHITE
	else
		theme(b, "BackgroundColor3", C.InputFieldBackground)
		theme(b, "TextColor3", C.MainText)
		stroke().Parent = b
	end
	return b
end

local function buttonRow(order, buttons)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = order }, { hlist(8) })
	local n = #buttons
	for i, b in ipairs(buttons) do
		b.Size = UDim2.new(1 / n, -math.floor(8 * (n - 1) / n), 1, 0)
		b.LayoutOrder = i
		b.Parent = row
	end
	return row
end

local function textInput(placeholder, order, initial)
	local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order }, { corner(7) })
	theme(holder, "BackgroundColor3", C.InputFieldBackground)
	stroke().Parent = holder
	local box = new("TextBox", {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = placeholder,
		Text = initial or "",
	})
	theme(box, "TextColor3", C.MainText)
	theme(box, "PlaceholderColor3", C.DimmedText)
	box.Parent = holder
	return holder, box
end

local renderers = {} -- re-run on theme change

local function makeSegmented(order, options, getValue, setValue, textSize)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = order }, { hlist(4) })
	local buttons = {}
	local n = #options
	local function render()
		for key, b in pairs(buttons) do
			if getValue() == key then
				b.BackgroundColor3 = ACCENT
				b.TextColor3 = WHITE
			else
				b.BackgroundColor3 = themeColor(C.InputFieldBackground)
				b.TextColor3 = themeColor(C.MainText)
			end
		end
	end
	for i, opt in ipairs(options) do
		local b = new("TextButton", {
			Size = UDim2.new(1 / n, -math.floor(4 * (n - 1) / n), 1, 0),
			Text = opt.text,
			Font = Enum.Font.GothamMedium,
			TextSize = textSize or 12,
			AutoButtonColor = true,
			LayoutOrder = i,
		}, { corner(7) })
		b.Parent = row
		buttons[opt.key] = b
		b.MouseButton1Click:Connect(function()
			setValue(opt.key)
			render()
		end)
	end
	render()
	table.insert(renderers, render)
	return row, render
end

local function makeToggle(text, key, order, onChange)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
	})
	label({ Text = text, TextSize = 12, Size = UDim2.new(1, -50, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }).Parent = row
	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(38, 22),
	}, { corner(11) })
	track.Parent = row
	local knob = new("Frame", { Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE }, { corner(8) })
	knob.Parent = track
	local function render()
		if state[key] then
			track.BackgroundColor3 = ACCENT
			knob.Position = UDim2.new(1, -19, 0.5, -8)
		else
			track.BackgroundColor3 = themeColor(C.InputFieldBorder)
			knob.Position = UDim2.new(0, 3, 0.5, -8)
		end
	end
	row.MouseButton1Click:Connect(function()
		saveSetting(key, not state[key])
		render()
		if onChange then
			onChange()
		end
	end)
	render()
	table.insert(renderers, render)
	return row
end

-------------------------------------------------------------------
-- Base64 (for sending models to / from the app)
-------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
	local c = string.byte(B64, i)
	ENC[i - 1] = c
	DEC[c] = i - 1
end
local EQ = string.byte("=")

local function b64encode(buf)
	local n = buffer.len(buf)
	local out = buffer.create(math.ceil(n / 3) * 4)
	local i, o = 0, 0
	while i + 2 < n do
		local v = buffer.readu8(buf, i) * 65536 + buffer.readu8(buf, i + 1) * 256 + buffer.readu8(buf, i + 2)
		buffer.writeu8(out, o, ENC[bit32.rshift(v, 18)])
		buffer.writeu8(out, o + 1, ENC[bit32.band(bit32.rshift(v, 12), 63)])
		buffer.writeu8(out, o + 2, ENC[bit32.band(bit32.rshift(v, 6), 63)])
		buffer.writeu8(out, o + 3, ENC[bit32.band(v, 63)])
		i = i + 3
		o = o + 4
	end
	local rem = n - i
	if rem == 1 then
		local v = buffer.readu8(buf, i) * 65536
		buffer.writeu8(out, o, ENC[bit32.rshift(v, 18)])
		buffer.writeu8(out, o + 1, ENC[bit32.band(bit32.rshift(v, 12), 63)])
		buffer.writeu8(out, o + 2, EQ)
		buffer.writeu8(out, o + 3, EQ)
	elseif rem == 2 then
		local v = buffer.readu8(buf, i) * 65536 + buffer.readu8(buf, i + 1) * 256
		buffer.writeu8(out, o, ENC[bit32.rshift(v, 18)])
		buffer.writeu8(out, o + 1, ENC[bit32.band(bit32.rshift(v, 12), 63)])
		buffer.writeu8(out, o + 2, ENC[bit32.band(bit32.rshift(v, 6), 63)])
		buffer.writeu8(out, o + 3, EQ)
	end
	return buffer.tostring(out)
end

local function b64decode(str)
	local len = #str
	if len == 0 then
		return buffer.create(0)
	end
	local pad = 0
	if string.byte(str, len) == EQ then
		pad = pad + 1
	end
	if len >= 2 and string.byte(str, len - 1) == EQ then
		pad = pad + 1
	end
	local outLen = math.floor(len / 4) * 3 - pad
	local out = buffer.create(math.max(outLen, 0))
	local o = 0
	for i = 1, len - 3, 4 do
		local a, b, c, d = string.byte(str, i, i + 3)
		local v = (DEC[a] or 0) * 262144 + (DEC[b] or 0) * 4096 + (DEC[c] or 0) * 64 + (DEC[d] or 0)
		if o < outLen then
			buffer.writeu8(out, o, bit32.rshift(v, 16))
		end
		if o + 1 < outLen then
			buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(v, 8), 255))
		end
		if o + 2 < outLen then
			buffer.writeu8(out, o + 2, bit32.band(v, 255))
		end
		o = o + 3
	end
	return out
end

-------------------------------------------------------------------
-- Talking to Mesh Downloader
-------------------------------------------------------------------
local function request(method, path, body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = BASE .. path,
			Method = method,
			Headers = body and { ["Content-Type"] = "application/json" } or nil,
			Body = body,
		})
	end)
	if ok and res.Success then
		return true, res
	end
	return false, ok and res or tostring(res)
end

local function decodeBody(res)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(res.Body)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function serialize(instances)
	if not SerializationService then
		return nil, "SerializationService isn't available in this Studio"
	end
	local ok, res = pcall(function()
		return SerializationService:SerializeInstancesAsync(instances)
	end)
	if ok and typeof(res) == "buffer" then
		return res
	end
	return nil, tostring(res)
end

local function deserialize(buf)
	if not SerializationService then
		return nil, "SerializationService isn't available in this Studio"
	end
	local ok, res = pcall(function()
		return SerializationService:DeserializeInstancesAsync(buf)
	end)
	if ok and type(res) == "table" then
		return res
	end
	return nil, tostring(res)
end

-- Sends a model to the app, which writes the .rbxm into
-- Documents\Roblox Meshes\Local Models (kind="local") or \Models (kind="saved").
local function saveToApp(instances, name, kind, folder)
	local buf, err = serialize(instances)
	if not buf then
		return false, err
	end
	local data = b64encode(buf)
	local CHUNK = 700000 -- characters per request (multiple of 4)
	local count = math.max(1, math.ceil(#data / CHUNK))
	local uid = HttpService:GenerateGUID(false)
	for i = 0, count - 1 do
		local part = string.sub(data, i * CHUNK + 1, (i + 1) * CHUNK)
		local body = HttpService:JSONEncode({
			id = uid,
			index = i,
			count = count,
			name = name,
			kind = kind,
			folder = folder,
			data = part,
		})
		local ok, res = request("POST", "/savemodel", body)
		if not ok then
			return false, "couldn't reach Mesh Downloader (is it open?)"
		end
		if i == count - 1 then
			local d = decodeBody(res)
			if d and d.ok and d.done then
				return true, d.path
			end
			return false, (d and d.error) or "Mesh Downloader didn't confirm the save"
		end
	end
	return false, "nothing was sent"
end

-------------------------------------------------------------------
-- Mesh / model helpers
-------------------------------------------------------------------
local function clean(s)
	s = string.gsub(tostring(s or ""), "[|\r\n]", " ")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	return s
end

-- Returns meshId, the part that owns it
local function meshIdOf(inst)
	if inst:IsA("MeshPart") then
		return inst.MeshId, inst
	elseif inst:IsA("SpecialMesh") then
		if inst.MeshType == Enum.MeshType.FileMesh then
			return inst.MeshId, inst.Parent
		end
	elseif inst:IsA("FileMesh") then
		return inst.MeshId, inst.Parent
	end
	return nil, nil
end

local function idFrom(meshId)
	local id = meshId and string.match(meshId, "%d+")
	if id and #id >= 5 then
		return id
	end
	return nil
end

-- Outermost Model (ignores Workspace and services)
local function topModel(inst)
	local top = nil
	local p = inst and inst.Parent
	while p and p ~= game do
		if p:IsA("Model") and p.Parent ~= game then
			top = p
		end
		p = p.Parent
	end
	return top
end

-- Closest Model above this instance
local function nearestModel(inst)
	local p = inst and inst.Parent
	while p and p ~= game do
		if p:IsA("Model") and p.Parent ~= game then
			return p
		end
		p = p.Parent
	end
	return nil
end

local function parentName(inst)
	local p = inst and inst.Parent
	if p and p ~= game and p.Parent ~= game then
		return p.Name
	end
	return nil
end

local function selectionRoots()
	local roots, seen = {}, {}
	for _, obj in ipairs(Selection:Get()) do
		local r = obj
		if not obj:IsA("Model") then
			r = topModel(obj) or obj
		end
		if not seen[r] then
			seen[r] = true
			table.insert(roots, r)
		end
	end
	return roots
end

-- File name (without ".mesh") for one mesh
local function meshBaseName(owner)
	local partName = clean(owner.Name)
	local src = state.nameSource
	if src == "part" then
		return partName
	end
	local base = nil
	if src == "parent" then
		base = parentName(owner)
	elseif src == "model" then
		local m = nearestModel(owner)
		base = m and m.Name
	elseif src == "top" then
		local m = topModel(owner)
		base = m and m.Name
	elseif src == "custom" then
		if clean(state.customName) ~= "" then
			base = state.customName
		end
	end
	if not base then
		return partName
	end
	base = clean(base)
	if state.addPart and base ~= partName then
		return base .. "_" .. partName
	end
	return base
end

local function folderFor(owner)
	if not state.folderPerModel then
		return nil
	end
	if state.nameSource == "custom" and clean(state.customName) ~= "" then
		return clean(state.customName)
	end
	local m = topModel(owner)
	return m and clean(m.Name) or nil
end

local function modelFileName(roots, suffix)
	if clean(state.customName) ~= "" then
		return clean(state.customName)
	end
	local n = roots[1] and clean(roots[1].Name) or "Model"
	if #roots > 1 then
		n = n .. " +" .. (#roots - 1)
	end
	return n .. (suffix or "")
end

-------------------------------------------------------------------
-- Pivots
-------------------------------------------------------------------
local function centerPartPivots(root)
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, d in ipairs(list) do
		if d:IsA("BasePart") then
			pcall(function()
				d.PivotOffset = CFrame.new()
			end)
		end
	end
end

local function averagePosition(model)
	local sum, n = Vector3.zero, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			sum = sum + d.Position
			n = n + 1
		end
	end
	if n == 0 then
		return nil
	end
	return sum / n
end

local function setModelPivot(model, mode)
	if mode == "keep" or not model:IsA("Model") then
		return
	end
	pcall(function()
		local pivot = model:GetPivot()
		local rot = pivot - pivot.Position
		local pos = nil
		if mode == "middle" then
			local cf = model:GetBoundingBox()
			pos = cf.Position
		else
			pos = averagePosition(model)
		end
		if pos then
			model.WorldPivot = CFrame.new(pos) * rot
		end
	end)
end

local function applyPivots(roots)
	for _, r in ipairs(roots) do
		if state.partPivots then
			centerPartPivots(r)
		end
		setModelPivot(r, state.modelPivot)
	end
end

local function beginRecording(name)
	local rec = nil
	pcall(function()
		rec = ChangeHistoryService:TryBeginRecording(name)
	end)
	return function(commit)
		if rec then
			pcall(function()
				ChangeHistoryService:FinishRecording(
					rec,
					commit and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
				)
			end)
		elseif commit then
			pcall(function()
				ChangeHistoryService:SetWaypoint(name)
			end)
		end
	end
end

-------------------------------------------------------------------
-- Local MeshParts (rbxasset://meshtools/<id>.mesh)
-------------------------------------------------------------------
local COPY_PROPS = {
	"Name", "Size", "CFrame", "PivotOffset", "Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless",
	"Color", "Material", "MaterialVariant", "Transparency", "Reflectance", "CastShadow", "Locked",
	"CollisionGroup", "CustomPhysicalProperties", "RootPriority", "Archivable", "TextureID",
}

local function createLocalMeshPart(id, mp)
	local uri = LOCAL_PREFIX .. id .. ".mesh"
	local options = {}
	if mp then
		pcall(function()
			options.CollisionFidelity = mp.CollisionFidelity
		end)
		pcall(function()
			options.RenderFidelity = mp.RenderFidelity
		end)
	end
	local ok, res = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromUri(uri), options)
	end)
	if not ok then
		ok, res = pcall(function()
			return AssetService:CreateMeshPartAsync(uri, options)
		end)
	end
	if ok and typeof(res) == "Instance" then
		return res
	end
	return nil, tostring(res)
end

local function copyAttributesAndTags(from, to)
	pcall(function()
		for k, v in pairs(from:GetAttributes()) do
			to:SetAttribute(k, v)
		end
		for _, tag in ipairs(from:GetTags()) do
			to:AddTag(tag)
		end
	end)
end

local function convertMeshPart(mp, id)
	local p, err = createLocalMeshPart(id, mp)
	if not p then
		return nil, err
	end
	for _, prop in ipairs(COPY_PROPS) do
		pcall(function()
			p[prop] = mp[prop]
		end)
	end
	copyAttributesAndTags(mp, p)
	for _, child in ipairs(mp:GetChildren()) do
		pcall(function()
			child.Parent = p
		end)
	end
	p.Parent = mp.Parent
	return p
end

local SKIP_FOR_SPECIAL = { Size = true, CFrame = true, PivotOffset = true, TextureID = true }
local function convertSpecialMesh(host, sm, id)
	local p, err = createLocalMeshPart(id, nil)
	if not p then
		return nil, err
	end
	local native = p.Size
	for _, prop in ipairs(COPY_PROPS) do
		if not SKIP_FOR_SPECIAL[prop] then
			pcall(function()
				p[prop] = host[prop]
			end)
		end
	end
	copyAttributesAndTags(host, p)
	local sc = sm.Scale
	p.Size = Vector3.new(
		math.max(native.X * math.abs(sc.X), 0.001),
		math.max(native.Y * math.abs(sc.Y), 0.001),
		math.max(native.Z * math.abs(sc.Z), 0.001)
	)
	p.CFrame = host.CFrame * CFrame.new(sm.Offset)
	pcall(function()
		p.TextureID = sm.TextureId
	end)
	for _, child in ipairs(host:GetChildren()) do
		if child ~= sm then
			pcall(function()
				child.Parent = p
			end)
		end
	end
	p.Parent = host.Parent
	return p
end

-------------------------------------------------------------------
-- Toolbar
-------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Mesh Tools")
local collectorButton = toolbar:CreateButton("Mesh Collector", "Collect, download and save meshes", "")
collectorButton.ClickableWhenViewportHidden = true
local inserterButton = toolbar:CreateButton("Mesh Inserter", "Browse and insert your downloaded meshes and models", "")
inserterButton.ClickableWhenViewportHidden = true

local alive = true
plugin.Unloading:Connect(function()
	alive = false
end)

-- Shared downloader-status pills
local pills = {}
local function makePill(parent)
	local pill = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
	}, { corner(12), padding(0, 10, 0, 10), hlist(6) })
	theme(pill, "BackgroundColor3", C.InputFieldBackground)
	stroke().Parent = pill
	local dot = new("Frame", { Size = UDim2.fromOffset(8, 8), BackgroundColor3 = GREY, LayoutOrder = 1 }, { corner(4) })
	dot.Parent = pill
	local text = label({
		Text = "Downloader: checking",
		TextSize = 11,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
	})
	text.Parent = pill
	pill.Parent = parent
	table.insert(pills, { dot = dot, text = text })
end

local function setLink(connected)
	for _, p in ipairs(pills) do
		if connected then
			p.dot.BackgroundColor3 = GREEN
			p.text.Text = "Downloader connected"
		else
			p.dot.BackgroundColor3 = GREY
			p.text.Text = "Downloader not open"
		end
	end
end

-- Update banner (top of both windows)
local banners = {}
local function makeBanner(root)
	local b = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = ACCENT,
		TextColor3 = WHITE,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		LayoutOrder = 0,
		Text = "",
	}, { corner(8), padding(8, 10, 8, 10) })
	b.Parent = root
	table.insert(banners, b)
end

local function setBanner(text)
	for _, b in ipairs(banners) do
		b.Text = text or ""
		b.Visible = text ~= nil
	end
end

-- true if version a is newer than version b ("3.10" > "3.9")
local function versionNewer(a, b)
	local function parts(v)
		local t = {}
		for n in string.gmatch(tostring(v or ""), "%d+") do
			table.insert(t, tonumber(n))
		end
		return t
	end
	local x, y = parts(a), parts(b)
	for i = 1, math.max(#x, #y) do
		local p, q = x[i] or 0, y[i] or 0
		if p ~= q then
			return p > q
		end
	end
	return false
end

local appVersion = nil -- reported by Mesh Downloader
local lastUpdateCheck = 0

local function checkForUpdate()
	lastUpdateCheck = os.time()
	local latest = nil
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = VERSION_URL .. "?t=" .. tostring(os.time()), Method = "GET" })
	end)
	if ok and res.Success then
		local okD, d = pcall(function()
			return HttpService:JSONDecode(res.Body)
		end)
		if okD and type(d) == "table" and d.version then
			latest = tostring(d.version)
		end
	end
	if appVersion and (not latest or versionNewer(appVersion, latest)) then
		latest = appVersion
	end
	if latest and versionNewer(latest, PLUGIN_VERSION) then
		if appVersion and not versionNewer(latest, appVersion) then
			setBanner(string.format("Mesh Tools v%s is installed - restart Studio to load it (this is v%s).", latest, PLUGIN_VERSION))
		else
			setBanner(string.format(
				"Update available: v%s (you have v%s). Open Mesh Downloader - it updates itself and this plugin - then restart Studio.",
				latest,
				PLUGIN_VERSION
			))
		end
	else
		setBanner(nil)
	end
end

local function makeWidget(id, title, w, h, dock)
	local info = DockWidgetPluginGuiInfo.new(dock or Enum.InitialDockState.Right, false, false, w, h, 300, 380)
	local widget = plugin:CreateDockWidgetPluginGui(id, info)
	widget.Title = title
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local root = new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, { padding(10, 10, 10, 10), vlist(8) })
	theme(root, "BackgroundColor3", C.MainBackground)
	root.Parent = widget
	makeBanner(root)
	return widget, root
end

-- =================================================================
-- MESH COLLECTOR
-- =================================================================
local colWidget, colRoot = makeWidget("MeshCollectorV2", "Mesh Collector", 360, 640)

local header = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 1 })
header.Parent = colRoot
label({ Text = "Mesh Collector  v" .. PLUGIN_VERSION, Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.new(0.6, 0, 1, 0) }).Parent = header
makePill(header)

local summary = dimLabel("Select a model or part in Explorer.", 2)
summary.Parent = colRoot

-- Settings (collapsible)
local settingsHeader = new("TextButton", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	LayoutOrder = 3,
})
settingsHeader.Parent = colRoot
local settingsTitle = label({ Text = "", Font = Enum.Font.GothamBold, TextSize = 13, Size = UDim2.fromScale(1, 1) })
settingsTitle.Parent = settingsHeader

local settingsFrame = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = 4,
}, { vlist(6) })
settingsFrame.Parent = colRoot

local function renderSettingsHeader()
	settingsTitle.Text = (state.settingsOpen and "v  " or ">  ") .. "Settings"
	settingsFrame.Visible = state.settingsOpen
end
settingsHeader.MouseButton1Click:Connect(function()
	saveSetting("settingsOpen", not state.settingsOpen)
	renderSettingsHeader()
end)
renderSettingsHeader()

local refresh -- forward declaration (collector list)

dimLabel("Name files by", 1).Parent = settingsFrame
makeSegmented(2, {
	{ key = "part", text = "Part" },
	{ key = "parent", text = "Parent" },
	{ key = "model", text = "Model" },
	{ key = "top", text = "Top" },
	{ key = "custom", text = "Custom" },
}, function()
	return state.nameSource
end, function(v)
	saveSetting("nameSource", v)
	refresh()
end, 11).Parent = settingsFrame

local customHolder, customBox = textInput("Custom name (also names saved models)", 3, state.customName)
customHolder.Parent = settingsFrame
customBox.FocusLost:Connect(function()
	saveSetting("customName", clean(customBox.Text))
	customBox.Text = state.customName
	refresh()
end)

makeToggle("Add part name (e.g. AK47_Magazine)", "addPart", 4, function()
	refresh()
end).Parent = settingsFrame
makeToggle("Add mesh ID to file names", "addId", 5, function()
	refresh()
end).Parent = settingsFrame
makeToggle("Folder per model", "folderPerModel", 6, function()
	refresh()
end).Parent = settingsFrame

dimLabel("Model pivot (used by Build, Save, Insert and Apply pivots)", 7).Parent = settingsFrame
makeSegmented(8, {
	{ key = "keep", text = "Keep" },
	{ key = "middle", text = "Middle" },
	{ key = "average", text = "Average" },
}, function()
	return state.modelPivot
end, function(v)
	saveSetting("modelPivot", v)
end).Parent = settingsFrame
makeToggle("Center each part's pivot on itself", "partPivots", 9).Parent = settingsFrame

local collectButton -- shown when Live is off
makeToggle("Live (follow what I click)", "live", 10, function()
	collectButton.Visible = not state.live
	refresh()
end).Parent = settingsFrame
makeToggle("Download right away when sent", "autoStart", 11).Parent = settingsFrame

collectButton = button("Collect current selection", false, 5)
collectButton.Visible = not state.live
collectButton.Parent = colRoot

local listHeader = label({ Text = "Meshes (0)", Font = Enum.Font.GothamBold, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 6 })
listHeader.Parent = colRoot

local listFrame = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 140),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	BorderSizePixel = 0,
	LayoutOrder = 7,
}, { corner(8), vlist(0) })
theme(listFrame, "BackgroundColor3", C.InputFieldBackground)
stroke().Parent = listFrame
pcall(function()
	new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }).Parent = listFrame
end)
listFrame.Parent = colRoot

local sendButton = button("Send to Downloader", true, 8)
sendButton.Parent = colRoot
local buildButton = button("Build local copy (real MeshParts, local .mesh)", false, 9)
buildButton.Parent = colRoot
local saveModelButton = button("Save model", false)
local pivotButton = button("Apply pivots", false)
buttonRow(10, { saveModelButton, pivotButton }).Parent = colRoot
local copyButton = button("Copy list", false)
local openInserterButton = button("Open Inserter", false)
buttonRow(11, { copyButton, openInserterButton }).Parent = colRoot

local statusLine = dimLabel("", 12, 11)
statusLine.Parent = colRoot

local function setStatus(text, color)
	statusLine.Text = text
	statusLine.TextColor3 = color or themeColor(C.DimmedText)
end

-- Copy overlay
local overlay = new("Frame", { Size = UDim2.fromScale(1, 1), ZIndex = 10, Visible = false, BorderSizePixel = 0 }, {
	padding(10, 10, 10, 10),
	vlist(8),
})
theme(overlay, "BackgroundColor3", C.MainBackground)
overlay.Parent = colWidget
label({ Text = "Copy list", Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 1 }).Parent = overlay
dimLabel("The text is selected - press Ctrl+C now, then paste it into Mesh Downloader.", 2, 11).Parent = overlay
local overlayScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 200),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	BorderSizePixel = 0,
	LayoutOrder = 3,
}, { corner(8) })
theme(overlayScroll, "BackgroundColor3", C.InputFieldBackground)
pcall(function()
	new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }).Parent = overlayScroll
end)
overlayScroll.Parent = overlay
local copyBox = new("TextBox", {
	Size = UDim2.new(1, -16, 0, 0),
	Position = UDim2.fromOffset(8, 8),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	ClearTextOnFocus = false,
	MultiLine = true,
	TextEditable = true,
	TextWrapped = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.Code,
	TextSize = 13,
	Text = "",
})
theme(copyBox, "TextColor3", C.MainText)
copyBox.Parent = overlayScroll
local closeOverlay = button("Close", true, 4)
closeOverlay.Parent = overlay
closeOverlay.MouseButton1Click:Connect(function()
	overlay.Visible = false
end)

-- Collecting
local frozenSelection = {}
local currentEntries = {}

local function collect(selected)
	local entries, seen, models = {}, {}, {}
	local modelCount = 0
	local function check(inst)
		local ok, meshId, owner = pcall(meshIdOf, inst)
		if not ok or not meshId or meshId == "" then
			return
		end
		local id = idFrom(meshId)
		if not id or seen[id] then
			return
		end
		seen[id] = true
		owner = owner or inst
		local m = topModel(owner)
		if m and not models[m] then
			models[m] = true
			modelCount = modelCount + 1
		end
		table.insert(entries, { id = id, name = meshBaseName(owner), folder = folderFor(owner) })
	end
	for _, obj in ipairs(selected) do
		if obj and obj.Parent then
			check(obj)
			for _, d in ipairs(obj:GetDescendants()) do
				check(d)
			end
		end
	end
	return entries, modelCount
end

local function fileNameOf(e)
	if state.addId then
		return e.name .. "_" .. e.id .. ".mesh"
	end
	return e.name .. ".mesh"
end

local function makeRow(parent, i, title, sub)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BorderSizePixel = 0, LayoutOrder = i })
	if i % 2 == 0 then
		row.BackgroundColor3 = themeColor(C.MainBackground)
		row.BackgroundTransparency = 0.5
	else
		row.BackgroundTransparency = 1
	end
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -20, 0, 18),
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = themeColor(C.MainText),
		Text = title,
	}).Parent = row
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 22),
		Size = UDim2.new(1, -20, 0, 14),
		Font = Enum.Font.Code,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = themeColor(C.DimmedText),
		Text = sub,
	}).Parent = row
	row.Parent = parent
end

local function makeNote(parent, text, order)
	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextWrapped = true,
		TextColor3 = themeColor(C.DimmedText),
		Text = text,
		LayoutOrder = order,
	}).Parent = parent
end

local function clearRows(frame)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

refresh = function()
	if not colWidget.Enabled then
		return
	end
	local selected
	if state.live then
		selected = Selection:Get()
		frozenSelection = selected
	else
		selected = frozenSelection
	end
	clearRows(listFrame)
	local entries, modelCount = collect(selected)
	currentEntries = entries
	listHeader.Text = string.format("Meshes (%d)", #entries)

	if #selected == 0 then
		summary.Text = state.live and "Click a model or part in Explorer or the viewport."
			or "Live is off - select something, then press Collect current selection."
		makeNote(listFrame, "Nothing selected", 1)
		return
	end
	local first = selected[1]
	local what = (#selected == 1) and first.Name or string.format("%d objects", #selected)
	summary.Text = string.format("Selected: %s  -  %d mesh(es) in %d model(s)", what, #entries, modelCount)
	if #entries == 0 then
		makeNote(listFrame, "No meshes in this selection", 1)
		return
	end
	for i, e in ipairs(entries) do
		if i > MAX_ROWS then
			makeNote(listFrame, string.format("...and %d more (all will be sent)", #entries - MAX_ROWS), i)
			break
		end
		local sub = e.id
		if e.folder then
			sub = sub .. "   ->  " .. e.folder .. "/"
		end
		makeRow(listFrame, i, fileNameOf(e), sub)
	end
end

local refreshQueued = false
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.delay(0.12, function()
		refreshQueued = false
		refresh()
	end)
end

local function listText()
	local lines = {}
	for _, e in ipairs(currentEntries) do
		local line = e.id .. " | " .. e.name .. " | " .. (e.folder or "")
		if not state.addId then
			line = line .. " | noid"
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

-- Actions -----------------------------------------------------------
local refreshInserter -- forward declaration

sendButton.MouseButton1Click:Connect(function()
	if #currentEntries == 0 then
		setStatus("Nothing to send - select something that has meshes.", RED)
		return
	end
	local items = {}
	for _, e in ipairs(currentEntries) do
		table.insert(items, { id = e.id, name = e.name, folder = e.folder, noId = not state.addId })
	end
	setStatus("Sending...", nil)
	local ok = request("POST", "/queue", HttpService:JSONEncode({ autoStart = state.autoStart, items = items }))
	setLink(ok)
	if ok then
		local verb = state.autoStart and "Downloading" or "Queued"
		setStatus(string.format("%s %d mesh(es) in Mesh Downloader.", verb, #items), GREEN)
	else
		setStatus("Couldn't reach Mesh Downloader. Make sure it's open with 'Listen for Studio plugin' on.", RED)
	end
end)

copyButton.MouseButton1Click:Connect(function()
	if #currentEntries == 0 then
		setStatus("Nothing to copy - select something that has meshes.", RED)
		return
	end
	local text = listText()
	copyBox.Text = text
	overlay.Visible = true
	task.defer(function()
		copyBox:CaptureFocus()
		copyBox.SelectionStart = 1
		copyBox.CursorPosition = #text + 1
	end)
	print(string.format("[Mesh Collector] %d mesh ID(s):\n%s", #currentEntries, text))
end)

local function manualSaveHelp(reason)
	return "Couldn't save through Mesh Downloader (" .. tostring(reason) .. "). "
		.. "Right-click the model > Save/Export > Save to File instead."
end

saveModelButton.MouseButton1Click:Connect(function()
	local roots = selectionRoots()
	if #roots == 0 then
		setStatus("Select the model you want to save first.", RED)
		return
	end
	setStatus("Saving...", nil)
	local clones = {}
	for _, r in ipairs(roots) do
		local ok, c = pcall(function()
			return r:Clone()
		end)
		if ok and c then
			table.insert(clones, c)
		end
	end
	if #clones == 0 then
		setStatus("That selection can't be copied, so it can't be saved.", RED)
		return
	end
	applyPivots(clones)
	local ok, result = saveToApp(clones, modelFileName(roots), "saved", nil)
	for _, c in ipairs(clones) do
		c:Destroy()
	end
	if ok then
		setStatus("Saved to Roblox Meshes\\" .. result, GREEN)
		if refreshInserter then
			refreshInserter()
		end
	else
		setStatus(manualSaveHelp(result), RED)
	end
end)

pivotButton.MouseButton1Click:Connect(function()
	local roots = selectionRoots()
	if #roots == 0 then
		setStatus("Select a model or part first.", RED)
		return
	end
	if state.modelPivot == "keep" and not state.partPivots then
		setStatus("Pick Middle or Average under Model pivot (or turn on 'Center each part's pivot') first.", RED)
		return
	end
	local finish = beginRecording("Apply pivots")
	applyPivots(roots)
	finish(true)
	setStatus(string.format("Pivots updated on %d object(s).", #roots), GREEN)
end)

-- Build local copy ----------------------------------------------------
local function buildLocal()
	local roots = selectionRoots()
	if #roots == 0 then
		setStatus("Select the model you want to make local first.", RED)
		return
	end
	local ids, seen = {}, {}
	for _, r in ipairs(roots) do
		local all = r:GetDescendants()
		table.insert(all, r)
		for _, d in ipairs(all) do
			local ok, meshId = pcall(meshIdOf, d)
			local id = ok and idFrom(meshId)
			if id and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	if #ids == 0 then
		setStatus("No meshes in this selection.", RED)
		return
	end

	setStatus("Checking which meshes are downloaded...", nil)
	local ok, res = request("POST", "/status", HttpService:JSONEncode({ ids = ids }))
	setLink(ok)
	if not ok then
		setStatus("Couldn't reach Mesh Downloader. Open it (with 'Listen for Studio plugin' on) and try again.", RED)
		return
	end
	local data = decodeBody(res)
	if not data then
		setStatus("Mesh Downloader sent a reply this plugin couldn't read.", RED)
		return
	end
	if not data.installOn then
		setStatus("Turn on 'Install meshes into Studio' in Mesh Downloader, then try again.", RED)
		return
	end
	if not data.studioFound then
		setStatus("Mesh Downloader couldn't find Studio's content folder on this PC.", RED)
		return
	end
	local ready, readyCount = {}, 0
	for _, item in ipairs(data.installed or {}) do
		ready[tostring(item.id)] = true
		readyCount = readyCount + 1
	end
	if readyCount == 0 then
		setStatus("None of these meshes are downloaded yet. Press 'Send to Downloader', wait for Done, then try again.", RED)
		return
	end

	local finish = beginRecording("Build local copy")
	local copies, clones = {}, {}
	local replaced, missing, upgraded = 0, 0, 0
	local failure = nil

	for _, r in ipairs(roots) do
		if failure then
			break
		end
		local clone = nil
		pcall(function()
			clone = r:Clone()
		end)
		if clone then
			clone.Name = r.Name .. " [local]"
			clone.Parent = r.Parent
			table.insert(clones, clone)
			local all = clone:GetDescendants()
			table.insert(all, 1, clone)
			local partMap = {}
			local oldPrimary = clone:IsA("Model") and clone.PrimaryPart or nil

			for _, d in ipairs(all) do
				if d:IsA("MeshPart") then
					local id = idFrom(d.MeshId)
					if id and ready[id] then
						local newPart, err = convertMeshPart(d, id)
						if not newPart then
							failure = err
							break
						end
						partMap[d] = newPart
						replaced = replaced + 1
					elseif id then
						missing = missing + 1
					end
				elseif d:IsA("FileMesh") then
					local id = idFrom(d.MeshId)
					local host = d.Parent
					if id and ready[id] then
						if host and host:IsA("BasePart") and not host:IsA("MeshPart") and not partMap[host] then
							local newPart, err = convertSpecialMesh(host, d, id)
							if not newPart then
								failure = err
								break
							end
							partMap[host] = newPart
							upgraded = upgraded + 1
						else
							d.MeshId = LOCAL_PREFIX .. id .. ".mesh"
						end
						replaced = replaced + 1
					elseif id then
						missing = missing + 1
					end
				end
			end

			if not failure then
				local newRoot = partMap[clone] or clone
				local after = newRoot:GetDescendants()
				table.insert(after, newRoot)
				for _, d in ipairs(after) do
					for _, prop in ipairs({ "Part0", "Part1" }) do
						pcall(function()
							local v = d[prop]
							if v and partMap[v] then
								d[prop] = partMap[v]
							end
						end)
					end
				end
				if oldPrimary and partMap[oldPrimary] and newRoot:IsA("Model") then
					newRoot.PrimaryPart = partMap[oldPrimary]
				end
				for old in pairs(partMap) do
					old:Destroy()
				end
				table.insert(copies, newRoot)
			else
				for _, p in pairs(partMap) do
					p:Destroy()
				end
			end
		end
	end

	if failure then
		for _, c in ipairs(clones) do
			pcall(function()
				c:Destroy()
			end)
		end
		finish(false)
		warn("[Mesh Tools] CreateMeshPartAsync failed: " .. tostring(failure))
		local inbox = (type(data.inbox) == "string" and data.inbox ~= "") and data.inbox or "Roblox Meshes\\Make Local"
		setStatus(
			"Studio blocked making MeshParts from local files. Right-click the model > Save/Export > Save to File, "
				.. "pick .rbxmx, and save into:\n" .. inbox .. "\nMesh Downloader converts it automatically.",
			RED
		)
		return
	end
	if #copies == 0 then
		finish(false)
		setStatus("Couldn't copy the selection (it may not be copyable).", RED)
		return
	end
	applyPivots(copies)
	finish(true)
	Selection:Set(copies)

	local msg = string.format("Built local copy: %d mesh(es) load from your PC as real MeshParts.", replaced)
	if upgraded > 0 then
		msg = msg .. string.format(" %d old SpecialMesh part(s) upgraded.", upgraded)
	end
	if missing > 0 then
		msg = msg .. string.format(" %d not downloaded (kept as-is).", missing)
	end
	setStatus(msg .. " Saving...", GREEN)

	local saved, result = saveToApp(copies, modelFileName(roots, " [local]"), "local", nil)
	if saved then
		setStatus(msg .. "\nSaved to Roblox Meshes\\" .. result, GREEN)
		if refreshInserter then
			refreshInserter()
		end
	else
		setStatus(msg .. "\n" .. manualSaveHelp(result), RED)
	end
end
buildButton.MouseButton1Click:Connect(buildLocal)

collectButton.MouseButton1Click:Connect(function()
	frozenSelection = Selection:Get()
	refresh()
end)

Selection.SelectionChanged:Connect(function()
	if state.live and colWidget.Enabled then
		queueRefresh()
	end
end)

-- =================================================================
-- MESH INSERTER
-- =================================================================
local insWidget, insRoot = makeWidget("MeshInserterV3", "Mesh Inserter", 380, 700)

local insHeader = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 1 })
insHeader.Parent = insRoot
label({ Text = "Mesh Inserter", Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.new(0.5, 0, 1, 0) }).Parent = insHeader
makePill(insHeader)

local searchHolder, searchBox = textInput("Search meshes and models...", 2)
local refreshLibButton = button("Refresh", false)
refreshLibButton.TextSize = 12
local searchRow = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 2 }, { hlist(6) })
searchHolder.Size = UDim2.new(1, -86, 1, 0)
searchHolder.LayoutOrder = 1
searchHolder.Parent = searchRow
refreshLibButton.Size = UDim2.new(0, 80, 1, 0)
refreshLibButton.LayoutOrder = 2
refreshLibButton.Parent = searchRow
searchRow.Parent = insRoot

local insList = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 160),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	BorderSizePixel = 0,
	LayoutOrder = 3,
}, { corner(8), vlist(0) })
theme(insList, "BackgroundColor3", C.InputFieldBackground)
stroke().Parent = insList
pcall(function()
	new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }).Parent = insList
end)
insList.Parent = insRoot

-- 3D preview
local viewport = new("ViewportFrame", {
	Size = UDim2.new(1, 0, 0, 220),
	BackgroundColor3 = Color3.fromRGB(22, 22, 26),
	Ambient = Color3.fromRGB(165, 165, 175),
	LightColor = Color3.fromRGB(255, 255, 255),
	LightDirection = Vector3.new(-1, -1.4, -0.8),
	Active = true,
	LayoutOrder = 4,
}, { corner(8) })
stroke().Parent = viewport
viewport.Parent = insRoot
local previewCamera = Instance.new("Camera")
previewCamera.FieldOfView = 40
previewCamera.Parent = viewport
viewport.CurrentCamera = previewCamera
local world = Instance.new("WorldModel")
world.Parent = viewport
local previewHint = new("TextLabel", {
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	Font = Enum.Font.GothamMedium,
	TextSize = 12,
	TextColor3 = Color3.fromRGB(140, 140, 150),
	TextWrapped = true,
	Text = "Pick a mesh or model to preview it",
})
previewHint.Parent = viewport
local controlsHint = new("TextLabel", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 8, 1, -6),
	Size = UDim2.new(1, -16, 0, 14),
	Font = Enum.Font.Gotham,
	TextSize = 10,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(120, 120, 130),
	Text = "Hover to stop  -  drag to look around  -  scroll to zoom",
	Visible = false,
})
controlsHint.Parent = viewport

local infoLabel = label({
	Text = "",
	RichText = true,
	TextSize = 12,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = 5,
})
infoLabel.Parent = insRoot

local insertButton = button("Insert", true)
local revealButton = button("Show in folder", false)
buttonRow(6, { insertButton, revealButton }).Parent = insRoot
local insStatus = dimLabel("", 7, 11)
insStatus.Parent = insRoot
local function setInsStatus(text, color)
	insStatus.Text = text
	insStatus.TextColor3 = color or themeColor(C.DimmedText)
end

-- Preview camera ------------------------------------------------------
local preview = { model = nil, radius = 2, yaw = 0.6, pitch = 0.35, zoom = 1, hovering = false, dragging = false, last = nil }

local function updateCamera()
	local fov = math.rad(previewCamera.FieldOfView)
	local dist = (preview.radius / math.sin(fov / 2)) * preview.zoom
	local rot = CFrame.Angles(0, preview.yaw, 0) * CFrame.Angles(-preview.pitch, 0, 0)
	local pos = rot * Vector3.new(0, 0, dist)
	previewCamera.CFrame = CFrame.lookAt(pos, Vector3.zero)
end

local function setPreview(instances)
	world:ClearAllChildren()
	preview.model = nil
	if not instances or #instances == 0 then
		previewHint.Visible = true
		controlsHint.Visible = false
		return
	end
	local holder = Instance.new("Model")
	holder.Name = "Preview"
	for _, inst in ipairs(instances) do
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		inst.Parent = holder
	end
	holder.Parent = world
	local ok, cf, size = pcall(function()
		return holder:GetBoundingBox()
	end)
	if ok and size and size.Magnitude > 0 then
		holder:TranslateBy(-cf.Position)
		preview.radius = math.max(size.Magnitude / 2, 0.25)
	else
		preview.radius = 2
	end
	preview.model = holder
	preview.yaw, preview.pitch, preview.zoom = 0.6, 0.35, 1
	previewHint.Visible = false
	controlsHint.Visible = true
	updateCamera()
end

viewport.MouseEnter:Connect(function()
	preview.hovering = true
end)
viewport.MouseLeave:Connect(function()
	preview.hovering = false
	preview.dragging = false
end)
viewport.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		preview.dragging = true
		preview.last = input.Position
	end
end)
viewport.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		preview.dragging = false
	end
end)
viewport.InputChanged:Connect(function(input)
	if not preview.model then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement and preview.dragging and preview.last then
		local delta = input.Position - preview.last
		preview.last = input.Position
		preview.yaw = preview.yaw - delta.X * 0.012
		preview.pitch = math.clamp(preview.pitch + delta.Y * 0.012, -1.45, 1.45)
		updateCamera()
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		preview.zoom = math.clamp(preview.zoom * (1 - input.Position.Z * 0.12), 0.15, 6)
		updateCamera()
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if insWidget.Enabled and preview.model and not preview.hovering and not preview.dragging then
		preview.yaw = preview.yaw + dt * 0.6
		updateCamera()
	end
end)

-- Library data ----------------------------------------------------------
local lib = { meshes = {}, models = {}, loaded = false }
local sectionOpen = { models = true, meshes = true }
local expanded = {}
local modelCache = {} -- key -> { loading, err, roots, parts, partCount, date }
local meshTemplates = {} -- id -> MeshPart
local selected = nil
local selectToken = 0
local renderInserter -- forward

local function fmtBytes(n)
	n = tonumber(n) or 0
	if n >= 1048576 then
		return string.format("%.1f MB", n / 1048576)
	end
	return string.format("%d KB", math.ceil(n / 1024))
end

local function fmtSize(size)
	if type(size) == "table" and #size == 3 then
		return string.format("%.2f x %.2f x %.2f", size[1], size[2], size[3])
	end
	return "?"
end

local function escapeRich(s)
	s = string.gsub(tostring(s), "&", "&amp;")
	s = string.gsub(s, "<", "&lt;")
	s = string.gsub(s, ">", "&gt;")
	return s
end

local function getMeshTemplate(id)
	if meshTemplates[id] then
		return meshTemplates[id]
	end
	local p, err = createLocalMeshPart(id, nil)
	if p then
		p.Anchored = true
		meshTemplates[id] = p
	end
	return p, err
end

local function scanModelParts(roots)
	local parts, partCount = {}, 0
	for _, r in ipairs(roots) do
		local all = r:GetDescendants()
		table.insert(all, 1, r)
		for _, d in ipairs(all) do
			if d:IsA("BasePart") then
				partCount = partCount + 1
				local meshId = nil
				if d:IsA("MeshPart") then
					meshId = d.MeshId
				else
					local sm = d:FindFirstChildWhichIsA("FileMesh")
					if sm then
						meshId = sm.MeshId
					end
				end
				if meshId and meshId ~= "" then
					local path = d.Name
					local p = d.Parent
					while p and p ~= r.Parent do
						path = p.Name .. "/" .. path
						p = p.Parent
					end
					table.insert(parts, { inst = d, name = d.Name, id = idFrom(meshId) or "?", path = path })
				end
			end
		end
	end
	return parts, partCount
end

local function loadModel(m, callback)
	local cached = modelCache[m.key]
	if cached and cached.date == m.date and not cached.loading then
		callback(cached)
		return
	end
	if cached and cached.loading then
		return
	end
	modelCache[m.key] = { loading = true, date = m.date }
	task.spawn(function()
		local entry = { date = m.date }
		if string.lower(m.ext or "") == ".rbxmx" then
			entry.err = "XML (.rbxmx) models can't be previewed here - use Show in folder and drag it into Studio."
		elseif not SerializationService then
			entry.err = "This Studio can't load model files from plugins - use Show in folder and drag it into Studio."
		else
			local chunks, count, i = {}, 1, 0
			while i < count do
				local ok, res = request("GET", "/model?key=" .. HttpService:UrlEncode(m.key) .. "&chunk=" .. i)
				local d = ok and decodeBody(res)
				if not d or not d.ok then
					entry.err = "Couldn't load it from Mesh Downloader."
					break
				end
				count = tonumber(d.count) or 1
				table.insert(chunks, b64decode(d.data or ""))
				i = i + 1
			end
			if not entry.err then
				local total = 0
				for _, b in ipairs(chunks) do
					total = total + buffer.len(b)
				end
				local all = buffer.create(total)
				local o = 0
				for _, b in ipairs(chunks) do
					buffer.copy(all, o, b, 0, buffer.len(b))
					o = o + buffer.len(b)
				end
				local roots, err = deserialize(all)
				if not roots then
					entry.err = "Couldn't open this model: " .. tostring(err)
				else
					entry.roots = roots
					entry.parts, entry.partCount = scanModelParts(roots)
				end
			end
		end
		modelCache[m.key] = entry
		callback(entry)
	end)
end

local function showMeshInfo(m)
	local bones = tonumber(m.bones) or 0
	local boneText = bones > 0 and string.format("<b>SKINNED</b> - %d bones", bones) or (bones < 0 and "skinned" or "no bones")
	infoLabel.Text = string.format(
		"<b>%s</b>\nMesh  -  ID %s  -  %s\n%s verts  -  %s tris  -  %s\nSize %s studs  -  %s  -  %s",
		escapeRich(m.name),
		escapeRich(m.id),
		escapeRich(m.version or "?"),
		tostring(m.verts or "?"),
		tostring(m.tris or "?"),
		boneText,
		fmtSize(m.size),
		fmtBytes(m.bytes),
		escapeRich(m.date or "")
	)
end

local function showModelInfo(m, entry)
	local extra = "Loading..."
	if entry and entry.err then
		extra = entry.err
	elseif entry and entry.roots then
		extra = string.format("%d object(s) at top  -  %d parts  -  %d meshes", #entry.roots, entry.partCount or 0, #(entry.parts or {}))
	end
	infoLabel.Text = string.format(
		"<b>%s</b>\nModel  -  %s  -  %s  -  %s\nFolder: %s\n%s",
		escapeRich(m.name),
		escapeRich(m.ext or ""),
		fmtBytes(m.bytes),
		escapeRich(m.date or ""),
		escapeRich((m.folder and m.folder ~= "") and m.folder or "(save folder)"),
		escapeRich(extra)
	)
end

local function showPartInfo(m, p)
	local inst = p.inst
	local size = inst.Size
	infoLabel.Text = string.format(
		"<b>%s</b>\nPart in %s  -  mesh ID %s\n%s\nSize %.2f x %.2f x %.2f studs  -  %s",
		escapeRich(p.name),
		escapeRich(m.name),
		escapeRich(p.id),
		escapeRich(p.path),
		size.X,
		size.Y,
		size.Z,
		inst.ClassName
	)
end

local function selectMesh(m)
	selectToken = selectToken + 1
	local token = selectToken
	selected = { kind = "mesh", item = m }
	showMeshInfo(m)
	renderInserter()
	task.spawn(function()
		local tpl, err = getMeshTemplate(m.id)
		if token ~= selectToken then
			return
		end
		if tpl then
			setPreview({ tpl:Clone() })
		else
			setPreview(nil)
			setInsStatus("Couldn't load this mesh: " .. tostring(err), RED)
		end
	end)
end

local function selectModel(m)
	selectToken = selectToken + 1
	local token = selectToken
	selected = { kind = "model", item = m }
	showModelInfo(m, nil)
	setPreview(nil)
	renderInserter()
	loadModel(m, function(entry)
		if token ~= selectToken then
			renderInserter()
			return
		end
		showModelInfo(m, entry)
		if entry.roots then
			local clones = {}
			for _, r in ipairs(entry.roots) do
				local ok, c = pcall(function()
					return r:Clone()
				end)
				if ok and c then
					table.insert(clones, c)
				end
			end
			setPreview(clones)
		end
		renderInserter()
	end)
end

local function selectPart(m, p)
	selectToken = selectToken + 1
	selected = { kind = "part", item = m, part = p }
	showPartInfo(m, p)
	local ok, c = pcall(function()
		return p.inst:Clone()
	end)
	setPreview(ok and c and { c } or nil)
	renderInserter()
end

-- List rows -------------------------------------------------------------
local function insRow(order, indent, title, sub, isSelected, onClick, arrow, onArrow)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, sub and 38 or 26),
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		LayoutOrder = order,
	})
	if isSelected then
		row.BackgroundColor3 = ACCENT
		row.BackgroundTransparency = 0.55
	else
		row.BackgroundTransparency = 1
	end
	local x = 8 + indent
	if arrow then
		local a = new("TextButton", {
			Position = UDim2.fromOffset(x - 2, 0),
			Size = UDim2.new(0, 18, 1, 0),
			BackgroundTransparency = 1,
			Text = arrow,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = themeColor(C.DimmedText),
		})
		a.Parent = row
		a.MouseButton1Click:Connect(onArrow)
		x = x + 18
	end
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(x, sub and 3 or 0),
		Size = UDim2.new(1, -(x + 8), 0, sub and 18 or 26),
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = themeColor(C.MainText),
		Text = title,
	}).Parent = row
	if sub then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(x, 21),
			Size = UDim2.new(1, -(x + 8), 0, 14),
			Font = Enum.Font.Code,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = themeColor(C.DimmedText),
			Text = sub,
		}).Parent = row
	end
	row.MouseButton1Click:Connect(onClick)
	row.Parent = insList
	return row
end

local function sectionRow(order, key, title)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		AutoButtonColor = true,
		Text = "",
		BorderSizePixel = 0,
		LayoutOrder = order,
		BackgroundColor3 = themeColor(C.MainBackground),
		BackgroundTransparency = 0.3,
	})
	new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = themeColor(C.MainText),
		Text = (sectionOpen[key] and "v  " or ">  ") .. title,
	}).Parent = row
	row.MouseButton1Click:Connect(function()
		sectionOpen[key] = not sectionOpen[key]
		renderInserter()
	end)
	row.Parent = insList
end

local function matches(text, filter)
	if filter == "" then
		return true
	end
	return string.find(string.lower(tostring(text or "")), filter, 1, true) ~= nil
end

renderInserter = function()
	if not insWidget.Enabled then
		return
	end
	clearRows(insList)
	local filter = string.lower(clean(searchBox.Text))
	local order = 0
	local function nextOrder()
		order = order + 1
		return order
	end

	if not lib.loaded then
		makeNote(insList, "Open Mesh Downloader, then press Refresh.", nextOrder())
		return
	end

	-- Models
	local models = {}
	for _, m in ipairs(lib.models) do
		local cache = modelCache[m.key]
		local hit = matches(m.name, filter) or matches(m.folder, filter)
		if not hit and cache and cache.parts then
			for _, p in ipairs(cache.parts) do
				if matches(p.name, filter) or matches(p.id, filter) then
					hit = true
					break
				end
			end
		end
		if hit then
			table.insert(models, m)
		end
	end
	sectionRow(nextOrder(), "models", string.format("MODELS (%d)", #models))
	if sectionOpen.models then
		if #models == 0 then
			makeNote(insList, "No saved or downloaded models yet.", nextOrder())
		end
		for _, m in ipairs(models) do
			local isOpen = expanded[m.key]
			local isSel = selected and selected.kind == "model" and selected.item == m
			local sub = (m.folder ~= nil and m.folder ~= "" and (m.folder .. "  -  ") or "") .. fmtBytes(m.bytes) .. "  -  " .. (m.date or "")
			insRow(nextOrder(), 0, m.name, sub, isSel, function()
				selectModel(m)
			end, isOpen and "v" or ">", function()
				expanded[m.key] = not expanded[m.key]
				if expanded[m.key] then
					loadModel(m, function()
						renderInserter()
					end)
				end
				renderInserter()
			end)
			if isOpen then
				local cache = modelCache[m.key]
				if not cache or cache.loading then
					makeNote(insList, "Loading...", nextOrder())
				elseif cache.err then
					makeNote(insList, cache.err, nextOrder())
				elseif #cache.parts == 0 then
					makeNote(insList, "No meshes in this model.", nextOrder())
				else
					local shown = 0
					for _, p in ipairs(cache.parts) do
						if filter == "" or matches(m.name, filter) or matches(p.name, filter) or matches(p.id, filter) then
							shown = shown + 1
							if shown > MAX_ROWS then
								makeNote(insList, "...more parts hidden - use Search to narrow it down.", nextOrder())
								break
							end
							local isPartSel = selected and selected.kind == "part" and selected.part == p
							insRow(nextOrder(), 22, p.name, p.id .. "  -  " .. p.path, isPartSel, function()
								selectPart(m, p)
							end)
						end
					end
				end
			end
		end
	end

	-- Meshes
	local meshes = {}
	for _, m in ipairs(lib.meshes) do
		if matches(m.name, filter) or matches(m.id, filter) then
			table.insert(meshes, m)
		end
	end
	sectionRow(nextOrder(), "meshes", string.format("MESHES (%d)", #meshes))
	if sectionOpen.meshes then
		if #meshes == 0 then
			makeNote(insList, "No downloaded meshes yet.", nextOrder())
		end
		for i, m in ipairs(meshes) do
			if i > MAX_ROWS then
				makeNote(insList, string.format("...and %d more - use Search to narrow it down.", #meshes - MAX_ROWS), nextOrder())
				break
			end
			local bones = tonumber(m.bones) or 0
			local sub = m.id .. "  -  " .. tostring(m.tris or "?") .. " tris" .. (bones ~= 0 and "  -  skinned" or "")
			local isSel = selected and selected.kind == "mesh" and selected.item == m
			insRow(nextOrder(), 0, m.name, sub, isSel, function()
				selectMesh(m)
			end)
		end
	end
end

refreshInserter = function()
	task.spawn(function()
		setInsStatus("Loading library...", nil)
		local ok, res = request("GET", "/library")
		setLink(ok)
		local d = ok and decodeBody(res)
		if not d or not d.ok then
			lib.loaded = false
			setInsStatus("Couldn't reach Mesh Downloader. Open it, then press Refresh.", RED)
			renderInserter()
			return
		end
		local function byName(a, b)
			return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
		end
		lib.meshes = d.meshes or {}
		lib.models = d.models or {}
		table.sort(lib.meshes, byName)
		table.sort(lib.models, byName)
		lib.loaded = true
		-- keep the selection pointing at the fresh data
		if selected then
			local list = selected.kind == "mesh" and lib.meshes or lib.models
			local keyName = selected.kind == "mesh" and "id" or "key"
			local found = nil
			for _, x in ipairs(list) do
				if x[keyName] == selected.item[keyName] then
					found = x
					break
				end
			end
			if found then
				selected.item = found
			else
				selected = nil
				setPreview(nil)
				infoLabel.Text = ""
			end
		end
		setInsStatus(string.format("%d model(s), %d mesh(es) in your library.", #lib.models, #lib.meshes), nil)
		renderInserter()
	end)
end

local searchQueued = false
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if searchQueued then
		return
	end
	searchQueued = true
	task.delay(0.2, function()
		searchQueued = false
		renderInserter()
	end)
end)
refreshLibButton.MouseButton1Click:Connect(refreshInserter)

local function insertInstances(instances, label_)
	local finish = beginRecording("Insert " .. label_)
	local holder = Instance.new("Model")
	holder.Name = "_MeshInserterTemp"
	for _, inst in ipairs(instances) do
		inst.Parent = holder
	end
	holder.Parent = workspace
	local ok, cf, size = pcall(function()
		return holder:GetBoundingBox()
	end)
	local cam = workspace.CurrentCamera
	if ok and cam and size then
		local dist = math.max(size.Magnitude * 1.2, 8)
		local target = cam.CFrame.Position + cam.CFrame.LookVector * dist
		holder:TranslateBy(target - cf.Position)
	end
	for _, inst in ipairs(instances) do
		inst.Parent = workspace
	end
	holder:Destroy()
	applyPivots(instances)
	Selection:Set(instances)
	finish(true)
end

insertButton.MouseButton1Click:Connect(function()
	if not selected then
		setInsStatus("Pick a mesh or model first.", RED)
		return
	end
	if selected.kind == "mesh" then
		local m = selected.item
		local tpl, err = getMeshTemplate(m.id)
		if not tpl then
			setInsStatus("Couldn't create the mesh: " .. tostring(err), RED)
			return
		end
		local p = tpl:Clone()
		p.Name = m.name
		insertInstances({ p }, m.name)
		setInsStatus("Inserted " .. m.name .. " (loads from your PC: rbxasset://meshtools/" .. m.id .. ".mesh).", GREEN)
	elseif selected.kind == "part" then
		local p = selected.part
		local ok, c = pcall(function()
			return p.inst:Clone()
		end)
		if not ok or not c then
			setInsStatus("Couldn't copy that part.", RED)
			return
		end
		insertInstances({ c }, p.name)
		setInsStatus("Inserted " .. p.name .. ".", GREEN)
	else
		local m = selected.item
		local entry = modelCache[m.key]
		if not entry or entry.loading then
			setInsStatus("Still loading - try again in a second.", nil)
			return
		end
		if entry.err or not entry.roots then
			setInsStatus(entry.err or "This model couldn't be loaded.", RED)
			return
		end
		local clones = {}
		for _, r in ipairs(entry.roots) do
			local ok, c = pcall(function()
				return r:Clone()
			end)
			if ok and c then
				table.insert(clones, c)
			end
		end
		insertInstances(clones, m.name)
		setInsStatus(string.format("Inserted %s (%d object(s), folders and models kept).", m.name, #clones), GREEN)
	end
end)

revealButton.MouseButton1Click:Connect(function()
	if not selected then
		setInsStatus("Pick a mesh or model first.", RED)
		return
	end
	local path
	if selected.kind == "mesh" then
		path = "/reveal?mesh=" .. HttpService:UrlEncode(selected.item.id)
	else
		path = "/reveal?key=" .. HttpService:UrlEncode(selected.item.key)
	end
	local ok = request("GET", path)
	if not ok then
		setInsStatus("Couldn't open the folder - is Mesh Downloader open?", RED)
	end
end)

-- =================================================================
-- Wiring
-- =================================================================
collectorButton.Click:Connect(function()
	colWidget.Enabled = not colWidget.Enabled
end)
inserterButton.Click:Connect(function()
	insWidget.Enabled = not insWidget.Enabled
end)
openInserterButton.MouseButton1Click:Connect(function()
	insWidget.Enabled = true
end)

colWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	collectorButton:SetActive(colWidget.Enabled)
	if colWidget.Enabled then
		refresh()
	end
end)
insWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	inserterButton:SetActive(insWidget.Enabled)
	if insWidget.Enabled then
		refreshInserter()
	end
end)

Studio.ThemeChanged:Connect(function()
	for _, t in ipairs(themed) do
		pcall(function()
			t[1][t[2]] = themeColor(t[3])
		end)
	end
	for _, r in ipairs(renderers) do
		r()
	end
	refresh()
	renderInserter()
end)

-- Downloader status (only while a window is open)
task.spawn(function()
	while alive do
		if colWidget.Enabled or insWidget.Enabled then
			local ok, res = request("GET", "/ping")
			setLink(ok)
			if ok then
				local d = decodeBody(res)
				if d and d.version then
					appVersion = tostring(d.version)
				end
			end
			-- check GitHub when a window opens, then every 30 minutes
			if os.time() - lastUpdateCheck > 1800 then
				checkForUpdate()
			end
		end
		task.wait(3)
	end
end)

collectorButton:SetActive(colWidget.Enabled)
inserterButton:SetActive(insWidget.Enabled)
refresh()
if insWidget.Enabled then
	refreshInserter()
end
