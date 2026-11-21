--[[
	Mesh Tools v4 - Roblox Studio plugin (works with the Mesh Downloader app)

	MESH COLLECTOR  - live cards of the meshes in whatever you click, download them,
	                  build local copies (real MeshParts using your .mesh files), save models.
	MESH INSERTER   - browse, preview and insert every mesh and model you've downloaded.
	SETTINGS        - themes (Studio / Dark / Classic / Midnight), accent colour, fonts,
	                  grid or list, card size, spacing, previews, animations and more.

	Every card has a small spinning 3D preview:
	  hover   -> it smoothly grows into a big preview (move away -> it shrinks back)
	  click   -> opens it big and keeps it open (click again to let it go)
	  drag    -> rotate,  scroll -> zoom

	Installed and updated automatically by Mesh Downloader.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Studio = settings().Studio

local SerializationService = nil
pcall(function()
	SerializationService = game:GetService("SerializationService")
end)

local PLUGIN_VERSION = "6.6" -- keep in sync with version.json
local VERSION_URL = "https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main/version.json"
local PORT = 47820
local BASE = "http://localhost:" .. PORT
local LOCAL_PREFIX = "rbxasset://meshtools/"

local C = Enum.StudioStyleGuideColor
local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end
local RED = rgb(235, 90, 85)
local GREEN = rgb(52, 190, 110)
local WHITE = rgb(255, 255, 255)

-------------------------------------------------------------------
-- Settings (saved per Studio user)
-------------------------------------------------------------------
local DEFAULTS = {
	-- collector behaviour
	nameSource = "top", -- part | parent | model | top | custom
	addPart = true,
	addId = true,
	customName = "",
	folderPerModel = true,
	modelPivot = "keep", -- keep | middle | average
	partPivots = false,
	live = true,
	autoStart = true,
	pivotMode = "middle", -- middle | average
	pivotScope = "both", -- model | parts | both
	pivotOnInsert = false, -- reset pivots when building / saving / inserting
	-- Blender (Send to Studio add-on)
	blenderReceive = true, -- pick up meshes sent from Blender
	blenderInsert = true, -- put new Blender objects into the scene (off = only update parts already there)
	blenderSelect = true, -- select a part when it first arrives
	blenderKeepMoves = true, -- keep where you moved / how you resized a part in Studio when Blender resends it
	blenderBones = true, -- build Bones and follow poses for meshes sent with an armature
	blenderSync = true, -- parts sent with "Send to Blender" keep Blender up to date as you change them
	showObjImport = false, -- "Import .obj" in the Inserter (Blender does all of it and more)
	blenderShareBones = true, -- meshes on one Blender armature share one set of Bones (one skeleton)
	-- appearance
	uiScale = 100, -- percent
	theme = "studio", -- studio | dark | classic | midnight
	accent = "purple",
	font = "gotham", -- gotham | sourcesans | arial
	textScale = 100, -- percent
	corner = 8, -- px
	anim = "normal", -- off | fast | normal | slow
	-- layout
	layout = "grid", -- grid | list
	cardSize = 96, -- preview size in px
	gap = 8,
	showDetails = true,
	infoPos = "bottom", -- inserter details panel: top | bottom
	maxItems = 300,
	-- previews
	spin = true,
	spinSpeed = 8, -- tenths
	hoverExpand = false, -- open the big preview on hover (clicking always works)
	hoverDelay = 4, -- tenths of a second
	expandSpeed = 3, -- tenths of a second for the grow / shrink animation
	clickGuard = 3, -- tenths of a second: clicks ignored right after the big preview opens
	bigSize = 260,
	-- local copies: parts that use a SpecialMesh (old heads, hats ...)
	specialMeshes = "auto", -- auto (MeshPart only when the mesh has bones) | keep | meshpart
	bakeOverlay = true, -- paint the skin colour into a local picture, repainted when the colour changes
	lighting = "follow", -- follow | flat
	-- model view (Inserter)
	inspectMode = "xray", -- xray (fade the other parts) | outline (keep them, outline the picked one)
	inspectOutline = true, -- in X-ray mode, also outline the picked part
	inspectHeight = 320, -- px
}

local LEGACY = {
	nameSource = "v3_nameSource",
	addPart = "v3_addPart",
	addId = "v3_addId",
	customName = "v3_customName",
	modelPivot = "v3_modelPivot",
	partPivots = "v3_partPivots",
	folderPerModel = "folderPerModel",
	live = "live",
	autoStart = "autoStart",
}

local function readSetting(key)
	local v = nil
	pcall(function()
		v = plugin:GetSetting(key)
	end)
	return v
end

local S = {}
for k, d in pairs(DEFAULTS) do
	local v = readSetting("v4_" .. k)
	if v == nil and LEGACY[k] then
		v = readSetting(LEGACY[k])
	end
	if v == nil or type(v) ~= type(d) then
		v = d
	end
	S[k] = v
end

-- move old pivot settings over
if readSetting("v4_pivotMode") == nil and (S.modelPivot == "middle" or S.modelPivot == "average") then
	S.pivotMode = S.modelPivot
	S.pivotOnInsert = true
end
if readSetting("v4_pivotScope") == nil then
	S.pivotScope = S.partPivots and "both" or "model"
end

-- names you typed for meshes in the Collector (mesh id -> name)
local renames = readSetting("v4_renames")
if type(renames) ~= "table" then
	renames = {}
end
local function saveRenames()
	pcall(function()
		plugin:SetSetting("v4_renames", renames)
	end)
end

local function save(key, value)
	S[key] = value
	pcall(function()
		plugin:SetSetting("v4_" .. key, value)
	end)
end

-------------------------------------------------------------------
-- Animation
-------------------------------------------------------------------
local ANIM = { off = 0, fast = 0.12, normal = 0.22, slow = 0.4 }
local function animTime(mult)
	return (ANIM[S.anim] or 0.22) * (mult or 1)
end

local function tween(inst, props, mult, style)
	local t = animTime(mult)
	if t <= 0 then
		for k, v in pairs(props) do
			pcall(function()
				inst[k] = v
			end)
		end
		return nil
	end
	local ok, tw = pcall(function()
		return TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
	end)
	if ok and tw then
		tw:Play()
		return tw
	end
	return nil
end

local function tweenFor(inst, props, seconds, style)
	if S.anim == "off" or seconds <= 0 then
		for k, v in pairs(props) do
			pcall(function()
				inst[k] = v
			end)
		end
		return nil
	end
	local ok, tw = pcall(function()
		return TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
	end)
	if ok and tw then
		tw:Play()
		return tw
	end
	return nil
end

-------------------------------------------------------------------
-- Themes
-------------------------------------------------------------------
local ACCENTS = {
	purple = rgb(124, 131, 245),
	blue = rgb(64, 140, 240),
	green = rgb(46, 180, 115),
	orange = rgb(240, 140, 50),
	pink = rgb(232, 92, 160),
	red = rgb(226, 78, 78),
	gray = rgb(120, 124, 135),
}
local ACCENT_ORDER = { "purple", "blue", "green", "orange", "pink", "red", "gray" }

local PALETTES = {
	dark = {
		bg = rgb(14, 14, 17), panel = rgb(20, 20, 24), input = rgb(26, 26, 31), border = rgb(46, 46, 54),
		text = rgb(236, 236, 240), dim = rgb(140, 140, 150), button = rgb(30, 30, 36), buttonText = rgb(230, 230, 235),
		card = rgb(24, 24, 29), cardHover = rgb(36, 36, 44), preview = rgb(17, 17, 21), header = rgb(30, 30, 36),
	},
	-- light grey "classic plugin" look: grey gradient, white boxes, grey buttons, dark bold text
	classic = {
		bg = rgb(204, 204, 204), bg2 = rgb(156, 156, 156), panel = rgb(255, 255, 255), input = rgb(255, 255, 255),
		border = rgb(150, 150, 150), text = rgb(28, 28, 28), dim = rgb(105, 105, 105), button = rgb(226, 226, 226),
		buttonText = rgb(24, 24, 24), card = rgb(255, 255, 255), cardHover = rgb(236, 236, 236),
		preview = rgb(255, 255, 255), header = rgb(218, 218, 218),
	},
	midnight = {
		bg = rgb(11, 15, 28), panel = rgb(17, 23, 42), input = rgb(21, 29, 52), border = rgb(42, 54, 90),
		text = rgb(230, 236, 250), dim = rgb(132, 146, 182), button = rgb(28, 38, 68), buttonText = rgb(225, 232, 250),
		card = rgb(19, 27, 50), cardHover = rgb(30, 41, 74), preview = rgb(13, 19, 36), header = rgb(26, 34, 62),
	},
}

local function studioPalette()
	local th = Studio.Theme
	local function g(c, m)
		local ok, v = pcall(function()
			return th:GetColor(c, m)
		end)
		return ok and v or rgb(128, 128, 128)
	end
	return {
		bg = g(C.MainBackground), panel = g(C.MainBackground), input = g(C.InputFieldBackground), border = g(C.Border),
		text = g(C.MainText), dim = g(C.DimmedText), button = g(C.Button), buttonText = g(C.ButtonText),
		card = g(C.InputFieldBackground), cardHover = g(C.Button, Enum.StudioStyleGuideModifier.Hover),
		preview = g(C.ViewPortBackground), header = g(C.Titlebar),
	}
end

local palette = {}
local function refreshPalette()
	local p
	if S.theme == "studio" then
		p = studioPalette()
	else
		p = {}
		for k, v in pairs(PALETTES[S.theme] or PALETTES.dark) do
			p[k] = v
		end
	end
	p.accent = ACCENTS[S.accent] or ACCENTS.purple
	p.accentText = WHITE
	palette = p
end
refreshPalette()

local function T(key)
	return palette[key] or palette.text
end

local FONTS = {
	gotham = { regular = Enum.Font.GothamMedium, bold = Enum.Font.GothamBold, mono = Enum.Font.Code },
	sourcesans = { regular = Enum.Font.SourceSans, bold = Enum.Font.SourceSansBold, mono = Enum.Font.Code },
	arial = { regular = Enum.Font.Arial, bold = Enum.Font.ArialBold, mono = Enum.Font.Code },
}
local function fontFor(weight)
	local f = FONTS[S.font] or FONTS.gotham
	return f[weight] or f.regular
end
local function textSize(base)
	return math.max(8, math.floor(base * S.textScale / 100 + 0.5))
end

-- Everything themed is registered here so a theme change can recolour it.
local reg = setmetatable({}, { __mode = "k" })
local gradients = setmetatable({}, { __mode = "k" })

local function regOf(inst)
	local r = reg[inst]
	if not r then
		r = { props = {} }
		reg[inst] = r
	end
	return r
end

local function bind(inst, prop, key)
	regOf(inst).props[prop] = key
	inst[prop] = T(key)
	return inst
end

local function bindText(inst, base, weight)
	local r = regOf(inst)
	r.text = { base, weight or "regular" }
	inst.TextSize = textSize(base)
	inst.Font = fontFor(weight or "regular")
	return inst
end

local function bindCorner(c, mult)
	regOf(c).corner = mult or 1
	c.CornerRadius = UDim.new(0, math.floor(S.corner * (mult or 1) + 0.5))
	return c
end

local function applyGradient(g)
	if palette.bg2 then
		g.Enabled = true
		g.Color = ColorSequence.new(WHITE, WHITE)
		g.Transparency = NumberSequence.new(0)
		-- gradient tints the frame colour: top = bg, bottom = bg2 (relative brightness)
		local top, bottom = palette.bg, palette.bg2
		g.Color = ColorSequence.new(
			rgb(255, 255, 255),
			Color3.new(bottom.R / math.max(top.R, 0.01), bottom.G / math.max(top.G, 0.01), bottom.B / math.max(top.B, 0.01))
		)
	else
		g.Enabled = false
	end
end

local controlRenderers = {}
local function syncControls(anim)
	for _, r in ipairs(controlRenderers) do
		pcall(r, anim)
	end
end

local function applyAppearance(animated)
	refreshPalette()
	for inst, r in pairs(reg) do
		for prop, key in pairs(r.props) do
			if animated then
				tween(inst, { [prop] = T(key) }, 1.4)
			else
				pcall(function()
					inst[prop] = T(key)
				end)
			end
		end
		if r.text then
			pcall(function()
				inst.TextSize = textSize(r.text[1])
				inst.Font = fontFor(r.text[2])
			end)
		end
		if r.corner then
			pcall(function()
				inst.CornerRadius = UDim.new(0, math.floor(S.corner * r.corner + 0.5))
			end)
		end
	end
	for g in pairs(gradients) do
		pcall(applyGradient, g)
	end
	syncControls(false)
end

-------------------------------------------------------------------
-- UI building blocks
-------------------------------------------------------------------
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

local function corner(mult)
	return bindCorner(Instance.new("UICorner"), mult)
end

local function padding(t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b),
		PaddingLeft = UDim.new(0, l),
	})
end

local function stroke(key)
	local s = new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	bind(s, "Color", key or "border")
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

local function flexFill(inst)
	pcall(function()
		new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }).Parent = inst
	end)
end

local function text(props, base, weight, colorKey)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	})
	for k, v in pairs(props) do
		l[k] = v
	end
	bindText(l, base or 13, weight or "regular")
	bind(l, "TextColor3", colorKey or "text")
	return l
end

local function dimText(str, order, base)
	return text({
		Text = str,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
	}, base or 12, "regular", "dim")
end

local function pressable(b)
	local sc = Instance.new("UIScale")
	sc.Parent = b
	b.MouseButton1Down:Connect(function()
		tween(sc, { Scale = 0.96 }, 0.4)
	end)
	b.MouseButton1Up:Connect(function()
		tween(sc, { Scale = 1 }, 0.7)
	end)
	b.MouseLeave:Connect(function()
		tween(sc, { Scale = 1 }, 0.7)
	end)
end

local function button(label_, kind, order)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		Text = label_,
		AutoButtonColor = false,
		LayoutOrder = order or 0,
	}, { corner(1) })
	bindText(b, 13, "bold")
	if kind == "primary" then
		bind(b, "BackgroundColor3", "accent")
		bind(b, "TextColor3", "accentText")
		b.MouseEnter:Connect(function()
			tween(b, { BackgroundTransparency = 0.15 }, 0.6)
		end)
		b.MouseLeave:Connect(function()
			tween(b, { BackgroundTransparency = 0 }, 0.8)
		end)
	else
		bind(b, "BackgroundColor3", "button")
		bind(b, "TextColor3", "buttonText")
		stroke().Parent = b
		b.MouseEnter:Connect(function()
			tween(b, { BackgroundColor3 = T("cardHover") }, 0.6)
		end)
		b.MouseLeave:Connect(function()
			tween(b, { BackgroundColor3 = T("button") }, 0.8)
		end)
	end
	pressable(b)
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
	local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order }, { corner(0.85) })
	bind(holder, "BackgroundColor3", "input")
	local st = stroke()
	st.Parent = holder
	local box = new("TextBox", {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = placeholder,
		Text = initial or "",
	})
	bindText(box, 12, "regular")
	bind(box, "TextColor3", "text")
	bind(box, "PlaceholderColor3", "dim")
	box.Parent = holder
	box.Focused:Connect(function()
		tween(st, { Color = T("accent"), Thickness = 2 }, 0.8)
	end)
	box.FocusLost:Connect(function()
		tween(st, { Color = T("border"), Thickness = 1 }, 0.8)
	end)
	return holder, box
end

-- On/off switch with a sliding knob
local function toggle(label_, key, order, onChange)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
	})
	text({ Text = label_, Size = UDim2.new(1, -50, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }, 12, "regular", "text").Parent = row
	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(38, 22),
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	track.Parent = row
	local knob = new("Frame", { Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE }, {
		new("UICorner", { CornerRadius = UDim.new(1, 0) }),
	})
	knob.Parent = track
	local function render(anim)
		local on = S[key]
		local col = on and T("accent") or T("border")
		local pos = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
		if anim then
			tween(track, { BackgroundColor3 = col })
			tween(knob, { Position = pos }, 1, Enum.EasingStyle.Back)
		else
			track.BackgroundColor3 = col
			knob.Position = pos
		end
	end
	row.MouseButton1Click:Connect(function()
		save(key, not S[key])
		syncControls(true)
		if onChange then
			onChange()
		end
	end)
	render(false)
	table.insert(controlRenderers, render)
	return row
end

-- Row of choices; the picked one slides to the accent colour
local function segmented(order, options, key, onChange, base)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = order }, { hlist(4) })
	local buttons = {}
	local n = #options
	local function render(anim)
		for k, b in pairs(buttons) do
			local sel = S[key] == k
			local props = {
				BackgroundColor3 = sel and T("accent") or T("button"),
				TextColor3 = sel and T("accentText") or T("buttonText"),
			}
			if anim then
				tween(b, props)
			else
				b.BackgroundColor3 = props.BackgroundColor3
				b.TextColor3 = props.TextColor3
			end
		end
	end
	for i, opt in ipairs(options) do
		local b = new("TextButton", {
			Size = UDim2.new(1 / n, -math.floor(4 * (n - 1) / n), 1, 0),
			Text = opt.text,
			AutoButtonColor = false,
			LayoutOrder = i,
		}, { corner(0.85) })
		bindText(b, base or 12, "regular")
		b.Parent = row
		pressable(b)
		buttons[opt.key] = b
		b.MouseButton1Click:Connect(function()
			save(key, opt.key)
			syncControls(true)
			if onChange then
				onChange()
			end
		end)
	end
	render(false)
	table.insert(controlRenderers, render)
	return row
end

-- "Label      [-]  value  [+]"
local function stepper(label_, key, order, min, max, step, fmt, onChange)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = order })
	text({ Text = label_, Size = UDim2.new(1, -130, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }, 12, "regular", "text").Parent = row
	local box = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(124, 26) }, { corner(0.85) })
	bind(box, "BackgroundColor3", "input")
	stroke().Parent = box
	box.Parent = row
	local function mk(t, x)
		local b = new("TextButton", { Position = UDim2.fromOffset(x, 0), Size = UDim2.fromOffset(28, 26), BackgroundTransparency = 1, Text = t })
		bindText(b, 15, "bold")
		bind(b, "TextColor3", "text")
		b.Parent = box
		pressable(b)
		return b
	end
	local minus = mk("-", 0)
	local plus = mk("+", 96)
	local value = text({ Position = UDim2.fromOffset(28, 0), Size = UDim2.fromOffset(68, 26), TextXAlignment = Enum.TextXAlignment.Center }, 12, "bold", "text")
	value.Parent = box
	local function render()
		value.Text = fmt(S[key])
	end
	local function set(v)
		v = math.clamp(v, min, max)
		if v == S[key] then
			return
		end
		save(key, v)
		syncControls(true)
		local sc = Instance.new("UIScale")
		sc.Scale = 1.15
		sc.Parent = value
		local tw = tween(sc, { Scale = 1 }, 1)
		if tw then
			tw.Completed:Connect(function()
				sc:Destroy()
			end)
		else
			sc:Destroy()
		end
		if onChange then
			onChange()
		end
	end
	minus.MouseButton1Click:Connect(function()
		set(S[key] - step)
	end)
	plus.MouseButton1Click:Connect(function()
		set(S[key] + step)
	end)
	render()
	table.insert(controlRenderers, render)
	return row
end

-- Draggable slider: "Label            value" over a track with a knob
local function slider(label_, key, order, min, max, step, fmt, onChange)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = order })
	text({ Text = label_, Size = UDim2.new(1, -80, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd }, 12, "regular", "text").Parent = row
	local value = text({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(80, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
	}, 12, "bold", "text")
	value.Parent = row
	local track = new("Frame", { Position = UDim2.new(0, 9, 0, 26), Size = UDim2.new(1, -18, 0, 6), BorderSizePixel = 0 }, {
		new("UICorner", { CornerRadius = UDim.new(1, 0) }),
	})
	bind(track, "BackgroundColor3", "border")
	track.Parent = row
	local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0 }, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	bind(fill, "BackgroundColor3", "accent")
	fill.Parent = track
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = WHITE,
		ZIndex = 2,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local ks = new("UIStroke", { Thickness = 2 })
	bind(ks, "Color", "accent")
	ks.Parent = knob
	knob.Parent = track
	local hit = new("TextButton", {
		Position = UDim2.new(0, -9, 0, -12),
		Size = UDim2.new(1, 18, 1, 24),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
	})
	hit.Parent = track
	local dragging = false
	local function render(anim)
		local f = math.clamp((S[key] - min) / (max - min), 0, 1)
		value.Text = fmt(S[key])
		if anim and not dragging then
			tween(fill, { Size = UDim2.new(f, 0, 1, 0) })
			tween(knob, { Position = UDim2.new(f, 0, 0.5, 0) })
		else
			fill.Size = UDim2.new(f, 0, 1, 0)
			knob.Position = UDim2.new(f, 0, 0.5, 0)
		end
	end
	local function setFromX(x)
		local f = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = min + f * (max - min)
		v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
		if v ~= S[key] then
			S[key] = v
			render(false)
		end
	end
	local function finish()
		if not dragging then
			return
		end
		dragging = false
		tween(knob, { Size = UDim2.fromOffset(16, 16) })
		save(key, S[key])
		syncControls(true)
		if onChange then
			onChange()
		end
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			tween(knob, { Size = UDim2.fromOffset(20, 20) }, 0.6)
			setFromX(input.Position.X)
		end
	end)
	hit.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			setFromX(input.Position.X)
		end
	end)
	hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			finish()
		end
	end)
	row.MouseLeave:Connect(finish)
	render(false)
	table.insert(controlRenderers, render)
	return row
end

-- Accent colour picker
local function swatches(order, onChange)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = order }, { hlist(8) })
	local dots = {}
	local function render(anim)
		for k, d in pairs(dots) do
			local sel = S.accent == k
			if anim then
				tween(d.stroke, { Thickness = sel and 3 or 0 })
				tween(d.scale, { Scale = sel and 1.12 or 1 }, 1, Enum.EasingStyle.Back)
			else
				d.stroke.Thickness = sel and 3 or 0
				d.scale.Scale = sel and 1.12 or 1
			end
			d.stroke.Color = T("text")
		end
	end
	for i, k in ipairs(ACCENT_ORDER) do
		local b = new("TextButton", {
			Size = UDim2.fromOffset(24, 24),
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = ACCENTS[k],
			LayoutOrder = i,
		}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		local st = new("UIStroke", { Thickness = 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
		st.Parent = b
		local sc = Instance.new("UIScale")
		sc.Parent = b
		b.Parent = row
		dots[k] = { stroke = st, scale = sc }
		b.MouseButton1Click:Connect(function()
			save("accent", k)
			if onChange then
				onChange()
			end
			syncControls(true)
		end)
	end
	render(false)
	table.insert(controlRenderers, render)
	return row
end

local function sectionTitle(str, order)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = order })
	text({ Text = str, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 8) }, 14, "bold", "text").Parent = f
	local line = new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BorderSizePixel = 0 })
	bind(line, "BackgroundColor3", "border")
	line.Parent = f
	return f
end

local b64encode, b64decode
do
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

b64encode = function(buf)
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

b64decode = function(str)
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

-- Sends bytes (a buffer) to the app in base64 chunks. Returns true + the app's reply.
local function uploadToApp(buf, name, kind, folder)
	local data = b64encode(buf)
	local CHUNK = 700000 -- characters per request (multiple of 4)
	local count = math.max(1, math.ceil(#data / CHUNK))
	local uid = HttpService:GenerateGUID(false)
	for i = 0, count - 1 do
		local body = HttpService:JSONEncode({
			id = uid,
			index = i,
			count = count,
			name = name,
			kind = kind,
			folder = folder,
			data = string.sub(data, i * CHUNK + 1, (i + 1) * CHUNK),
		})
		local ok, res = request("POST", "/savemodel", body)
		if not ok then
			local d = type(res) == "table" and decodeBody(res)
			return false, (d and d.error) or "couldn't reach Mesh Downloader (is it open?)"
		end
		if i == count - 1 then
			local d = decodeBody(res)
			if d and d.ok and d.done then
				return true, d
			end
			return false, (d and d.error) or "Mesh Downloader didn't confirm"
		end
	end
	return false, "nothing was sent"
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
-- Newer Studio keeps some meshes only in MeshContent (MeshId can be empty)
local function contentUri(inst, prop)
	local uri = ""
	pcall(function()
		local c = inst[prop]
		if typeof(c) == "Content" then
			uri = c.Uri or ""
		elseif type(c) == "string" then
			uri = c
		end
	end)
	return uri
end

-- A MeshPart's texture link, wherever Studio keeps it (TextureID or TextureContent)
local function textureOf(mp)
	local t = ""
	pcall(function()
		t = mp.TextureID
	end)
	if t == "" then
		t = contentUri(mp, "TextureContent")
	end
	return t
end

local function meshIdOf(inst)
	if inst:IsA("MeshPart") then
		local id = ""
		pcall(function()
			id = inst.MeshId
		end)
		if id == "" then
			id = contentUri(inst, "MeshContent")
		end
		return id, inst
	elseif inst:IsA("SpecialMesh") then
		if inst.MeshType == Enum.MeshType.FileMesh then
			return inst.MeshId, inst.Parent
		end
	elseif inst:IsA("FileMesh") then
		return inst.MeshId, inst.Parent
	end
	return nil, nil
end

-- The asset number in rbxassetid://123, https://assetdelivery.roblox.com/v1/asset/?id=123,
-- rbxasset://meshtools/123.mesh ... (not the "1" in "v1")
local function idFrom(meshId)
	if type(meshId) ~= "string" or meshId == "" then
		return nil
	end
	local id = string.match(meshId, "[?&][iI][dD]=(%d+)")
	if id and #id >= 5 then
		return id
	end
	local best = nil
	for run in string.gmatch(meshId, "%d+") do
		if #run >= 5 and (not best or #run > #best) then
			best = run
		end
	end
	return best
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
	local src = S.nameSource
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
		if clean(S.customName) ~= "" then
			base = S.customName
		end
	end
	if not base then
		return partName
	end
	base = clean(base)
	if S.addPart and base ~= partName then
		return base .. "_" .. partName
	end
	return base
end

local function folderFor(owner)
	if not S.folderPerModel then
		return nil
	end
	if S.nameSource == "custom" and clean(S.customName) ~= "" then
		return clean(S.customName)
	end
	local m = topModel(owner)
	return m and clean(m.Name) or nil
end

local function modelFileName(roots, suffix)
	if clean(S.customName) ~= "" then
		return clean(S.customName)
	end
	local n = roots[1] and clean(roots[1].Name) or "Model"
	if #roots > 1 then
		n = n .. " +" .. (#roots - 1)
	end
	return n .. (suffix or "")
end

-------------------------------------------------------------------
-- Pivots
-- Reset saves the ORIGINAL pivots as attributes on the objects, so
-- "Restore pivots" can always put them back (even after saving/inserting).
-------------------------------------------------------------------
local PIVOT_ATTR = "MeshTools_OriginalPivot" -- models: WorldPivot before a reset
local OFFSET_ATTR = "MeshTools_OriginalPivotOffset" -- parts: PivotOffset before a reset

local function partsOf(root)
	local list = root:GetDescendants()
	table.insert(list, root)
	local out = {}
	for _, d in ipairs(list) do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function averagePosition(model)
	local sum, n = Vector3.zero, 0
	for _, p in ipairs(partsOf(model)) do
		sum = sum + p.Position
		n = n + 1
	end
	if n == 0 then
		return nil
	end
	return sum / n
end

local function pivotTarget(model)
	local pivot = model:GetPivot()
	local rot = pivot - pivot.Position
	local pos
	if S.pivotMode == "average" then
		pos = averagePosition(model)
	else
		local cf = model:GetBoundingBox()
		pos = cf.Position
	end
	if pos then
		return CFrame.new(pos) * rot
	end
	return nil
end

-- What "Reset pivots" does, in words (shown under the buttons)
local function pivotSummary()
	local center = S.pivotMode == "average" and "Average" or "Middle"
	if S.pivotScope == "model" then
		return "Reset pivots: the model's pivot -> " .. center .. ". Each part keeps its own pivot."
	elseif S.pivotScope == "parts" then
		return "Reset pivots: every part's pivot -> its own center. The model's pivot is kept."
	end
	return "Reset pivots: model -> " .. center .. ", and every part -> its own center."
end

local function resetPivots(roots)
	local changed = 0
	for _, r in ipairs(roots) do
		local doModel = S.pivotScope ~= "parts" and r:IsA("Model")
		local doParts = S.pivotScope ~= "model"
		if doModel and r:GetAttribute(PIVOT_ATTR) == nil then
			pcall(function()
				r:SetAttribute(PIVOT_ATTR, r.WorldPivot)
			end)
		end
		if doParts then
			for _, p in ipairs(partsOf(r)) do
				pcall(function()
					if p:GetAttribute(OFFSET_ATTR) == nil then
						p:SetAttribute(OFFSET_ATTR, p.PivotOffset)
					end
					p.PivotOffset = CFrame.new()
				end)
				changed = changed + 1
			end
		end
		if doModel then
			pcall(function()
				local target = pivotTarget(r)
				if target then
					r.WorldPivot = target
				end
			end)
			changed = changed + 1
		end
	end
	return changed
end

local function restorePivots(roots)
	local restored = 0
	for _, r in ipairs(roots) do
		for _, p in ipairs(partsOf(r)) do
			local o = p:GetAttribute(OFFSET_ATTR)
			if typeof(o) == "CFrame" then
				pcall(function()
					p.PivotOffset = o
					p:SetAttribute(OFFSET_ATTR, nil)
				end)
				restored = restored + 1
			end
		end
		local list = r:GetDescendants()
		table.insert(list, r)
		for _, d in ipairs(list) do
			if d:IsA("Model") then
				local o = d:GetAttribute(PIVOT_ATTR)
				if typeof(o) == "CFrame" then
					pcall(function()
						d.WorldPivot = o
						d:SetAttribute(PIVOT_ATTR, nil)
					end)
					restored = restored + 1
				end
			end
		end
	end
	return restored
end

-- Used by Build / Save / Insert: only resets when that option is on
local function applyPivots(roots)
	if S.pivotOnInsert then
		resetPivots(roots)
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

local function createLocalMeshPart(id, mp, extra)
	local uri = LOCAL_PREFIX .. id .. ".mesh"
	local options = {}
	for k, v in pairs(extra or {}) do
		options[k] = v
	end
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

-- Look for parts made from Blender / .obj: colour picture, or a SurfaceAppearance when
-- there are normal / roughness / metal pictures or see-through parts, plain colour,
-- and both sides (Blender shows the back of faces unless Backface Culling is on).
-- look = { maps = { color, normal, roughness, metalness = file names }, alpha, tint = {r,g,b}, double }
local LOCAL_SA_PATH = nil -- set once a local folder SurfaceAppearances accept is found
local watchBaked -- (below) repaints picture-over-colour parts when their colour changes

local function applyLocalLook(p, look)
	local maps = type(look.maps) == "table" and look.maps or {}
	local function path(f)
		return f and (LOCAL_PREFIX .. "textures/" .. tostring(f)) or nil
	end
	local function saPath(f)
		return f and (LOCAL_SA_PATH .. tostring(f)) or nil
	end
	local color = maps.color
	if look.look == "overlay" and color and S.bakeOverlay and watchBaked then
		if type(look.color) == "table" then
			p.Color = Color3.new(tonumber(look.color[1]) or 1, tonumber(look.color[2]) or 1, tonumber(look.color[3]) or 1)
		end
		local same = p:GetAttribute("MeshToolsTextureFile") == tostring(color)
		p:SetAttribute("MeshToolsTextureFile", tostring(color))
		p:SetAttribute("MeshToolsTint", "ffffff")
		if not same or not string.find(textureOf(p), "_c%x%x%x%x%x%x") then
			pcall(function()
				p.TextureID = path(color) -- until the painted picture is ready
			end)
		end
		watchBaked(p, true)
		if look.double ~= nil then
			pcall(function()
				p.DoubleSided = look.double and true or false
			end)
		end
		return
	elseif p:GetAttribute("MeshToolsTextureFile") and look.maps then
		for _, a in ipairs({ "MeshToolsTextureFile", "MeshToolsTint", "MeshToolsPaintedColor", "MeshToolsTextureId" }) do
			p:SetAttribute(a, nil)
		end
	end
	-- SurfaceAppearances can't load pictures from your PC (tested in Studio), so local
	-- pictures go on TextureID. Normal / roughness / metal pictures need a SurfaceAppearance,
	-- so they only work once there's a local path Studio accepts for them.
	local useSA = LOCAL_SA_PATH ~= nil and (maps.normal or maps.roughness or maps.metalness or (look.alpha and color))
	local theirs = false
	for _, d in ipairs(p:GetChildren()) do
		if d:IsA("SurfaceAppearance") then
			if d:GetAttribute("MeshToolsLook") then
				d:Destroy()
			else
				theirs = true -- you added your own: leave it alone
			end
		end
	end
	if useSA and not theirs then
		local sa = Instance.new("SurfaceAppearance")
		sa.Name = "MeshToolsLook"
		sa:SetAttribute("MeshToolsLook", true)
		for prop, f in pairs({ ColorMap = color, NormalMap = maps.normal, RoughnessMap = maps.roughness, MetalnessMap = maps.metalness }) do
			pcall(function()
				sa[prop] = saPath(f)
			end)
		end
		pcall(function()
			sa.AlphaMode = look.alpha and Enum.AlphaMode.Transparency or Enum.AlphaMode.Overlay
		end)
		sa.Parent = p
		pcall(function()
			p.TextureID = ""
		end)
	elseif color then
		pcall(function()
			p.TextureID = path(color)
		end)
	end
	if not color and type(look.tint) == "table" then
		p.Color = Color3.new(tonumber(look.tint[1]) or 1, tonumber(look.tint[2]) or 1, tonumber(look.tint[3]) or 1)
	end
	if look.double ~= nil then
		pcall(function()
			p.DoubleSided = look.double and true or false
		end)
	end
end

-- Overlay SurfaceAppearances (made for converted dynamic heads) need a Roblox picture ID.
-- When the picture is downloaded, Mesh Downloader paints it over the part's colour into a
-- solid picture instead, which TextureID loads from your PC - fully local.
-- texMap = picture id -> file name in the library
local function colorHex(c)
	return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

-- Painted heads repaint themselves: when a part's Color changes (by you, Body Colors,
-- undo ...), Mesh Downloader paints the picture over the new colour and TextureID switches
-- to it. Parts are found by the attribute MeshToolsTextureFile (the unpainted picture).
do
	local watched = setmetatable({}, { __mode = "k" })
	local TRASH_KEY = "v4_paintTrash" -- painted pictures you've moved away from (deleted on next place open)

	local function paintedName(file, hex, tint)
		local base = string.gsub(file, "%.%w+$", "")
		return base .. "_c" .. hex .. ((tint ~= "ffffff") and ("_t" .. tint) or "") .. ".png"
	end
	local function paintedFileOf(textureId)
		local f = string.match(tostring(textureId or ""), "meshtools/textures/([%w_%.%-]+)$")
		if f and string.match(f, "_c%x%x%x%x%x%x") then
			return f
		end
		return nil
	end
	local function addTrash(f)
		local list = readSetting(TRASH_KEY)
		if type(list) ~= "table" then
			list = {}
		end
		if not table.find(list, f) then
			table.insert(list, f)
			if #list > 2000 then
				table.remove(list, 1)
			end
			pcall(function()
				plugin:SetSetting(TRASH_KEY, list)
			end)
		end
	end

	watchBaked = function(p, again)
		if watched[p] then
			if again and type(watched[p]) == "function" then
				task.defer(watched[p]) -- new picture: paint it now
			end
			return
		end
		watched[p] = true
		local pending = false
		local function repaint(firstLook)
			pending = false
			if not p.Parent then
				return
			end
			local file = p:GetAttribute("MeshToolsTextureFile")
			if type(file) ~= "string" then
				return
			end
			local want = colorHex(p.Color)
			local tint = p:GetAttribute("MeshToolsTint")
			tint = type(tint) == "string" and tint or "ffffff"
			local target = LOCAL_PREFIX .. "textures/" .. paintedName(file, want, tint)
			local already = p.TextureID == target -- e.g. Ctrl+Z / Ctrl+Y put both back together
			-- /bake makes the picture if it's missing (old colours are deleted right away; Studio
			-- still shows them from memory, so undo works - this just puts the file back on disk)
			local ok, res = request("GET", "/bake?file=" .. HttpService:UrlEncode(file) .. "&color=" .. want .. "&tint=" .. tint)
			local d = ok and decodeBody(res)
			if not (d and d.ok and d.file) then
				return
			end
			local path = LOCAL_PREFIX .. "textures/" .. d.file
			if already then
				if firstLook and d.created then
					-- place just opened and its picture was missing: make Studio load the new file
					p.TextureID = ""
					p.TextureID = path
				end
				return
			end
			local old = paintedFileOf(p.TextureID)
			-- join the colour change's undo step, so Ctrl+Z / Ctrl+Y change colour and picture together
			local rec = nil
			pcall(function()
				rec = ChangeHistoryService:TryBeginRecording("Repaint skin colour")
			end)
			p.TextureID = path
			p:SetAttribute("MeshToolsPaintedColor", want)
			if rec then
				local appended = pcall(function()
					ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Append)
				end)
				if not appended then
					pcall(function()
						ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
					end)
				end
			end
			if old and old ~= d.file then
				-- delete the old colour's picture now, unless another painted part uses it
				local shared = false
				for other in pairs(watched) do
					if other ~= p and other.Parent and paintedFileOf(other.TextureID) == old then
						shared = true
						break
					end
				end
				if not shared then
					task.spawn(function()
						local okD, resD = request("POST", "/unbake", HttpService:JSONEncode({ files = { old } }))
						local dd = okD and decodeBody(resD)
						if not (dd and dd.ok) then
							addTrash(old) -- app busy / closed: delete it next time a place opens
						end
					end)
				end
			end
		end
		watched[p] = repaint
		p:GetPropertyChangedSignal("Color"):Connect(function()
			if not pending then
				pending = true
				task.delay(0.25, repaint) -- dragging the colour picker: wait until it settles
			end
		end)
		task.defer(repaint, true) -- catch up if the colour changed while Studio / the plugin was closed
	end
	local function maybeWatch(d)
		if d:IsA("MeshPart") and d:GetAttribute("MeshToolsTextureFile") then
			watchBaked(d)
		end
	end
	task.defer(function()
		-- a place just opened (no undo history yet): delete painted pictures you moved away
		-- from earlier, unless something here still uses them
		local inUse = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("MeshPart") then
				local f = paintedFileOf(d.TextureID)
				if f then
					inUse[f] = true
				end
			end
		end
		local list = readSetting(TRASH_KEY)
		if type(list) == "table" and #list > 0 then
			local gone, keep = {}, {}
			for _, f in ipairs(list) do
				if inUse[f] then
					table.insert(keep, f)
				else
					table.insert(gone, f)
				end
			end
			if #gone > 0 then
				local ok, res = request("POST", "/unbake", HttpService:JSONEncode({ files = gone }))
				local d = ok and decodeBody(res)
				if not (d and d.ok) then
					keep = list -- app closed: try again next time
				end
			end
			pcall(function()
				plugin:SetSetting(TRASH_KEY, keep)
			end)
		end
		for _, d in ipairs(workspace:GetDescendants()) do
			maybeWatch(d)
		end
		workspace.DescendantAdded:Connect(maybeWatch)
	end)
end

local function bakeLooks(root, texMap)
	if not S.bakeOverlay or type(texMap) ~= "table" then
		return 0
	end
	local list = root:GetDescendants()
	table.insert(list, root)
	local baked = 0
	for _, sa in ipairs(list) do
		if sa:IsA("SurfaceAppearance") and sa:GetAttribute("MeshToolsLook") and sa.Parent and sa.Parent:IsA("MeshPart") then
			local okA, mode = pcall(function()
				return sa.AlphaMode
			end)
			local cm = ""
			pcall(function()
				cm = tostring(sa.ColorMap)
			end)
			if cm == "" then
				cm = contentUri(sa, "ColorMapContent")
			end
			local tid = idFrom(cm)
			local file = tid and texMap[tid]
			if okA and mode == Enum.AlphaMode.Overlay and file then
				local p = sa.Parent
				local tint = "ffffff"
				pcall(function()
					tint = colorHex(sa.Color)
				end)
				local want = colorHex(p.Color)
				local ok, res = request("GET", "/bake?file=" .. HttpService:UrlEncode(file) .. "&color=" .. want .. "&tint=" .. tint)
				local d = ok and decodeBody(res)
				if d and d.ok and d.file then
					p.TextureID = LOCAL_PREFIX .. "textures/" .. d.file
					p:SetAttribute("MeshToolsTextureFile", file) -- the unpainted picture, for repainting
					p:SetAttribute("MeshToolsTint", tint)
					p:SetAttribute("MeshToolsPaintedColor", want)
					p:SetAttribute("MeshToolsTextureId", "rbxassetid://" .. tid)
					sa:Destroy()
					watchBaked(p)
					baked = baked + 1
				end
			end
		end
	end
	return baked
end

local LOCAL_PART_OPTIONS = { RenderFidelity = Enum.RenderFidelity.Precise } -- full detail at any distance

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
	if p.TextureID == "" then
		local t = textureOf(mp) -- texture kept only in TextureContent
		if t ~= "" then
			pcall(function()
				p.TextureID = t
			end)
		end
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
	-- A SpecialMesh shows the part's colour through see-through spots of its texture (that's
	-- how classic heads get their skin colour). A MeshPart's TextureID makes those spots
	-- see-through instead, so the texture goes in a SurfaceAppearance set to Overlay, which
	-- shows the colour through them, like the SpecialMesh did.
	if sm.TextureId ~= "" then
		local sa = Instance.new("SurfaceAppearance")
		sa.Name = "MeshToolsLook"
		sa:SetAttribute("MeshToolsLook", true)
		local ok = pcall(function()
			sa.ColorMap = sm.TextureId
			sa.AlphaMode = Enum.AlphaMode.Overlay
		end)
		pcall(function()
			local vc = sm.VertexColor -- SpecialMesh tint -> SurfaceAppearance tint
			sa.Color = Color3.new(math.clamp(vc.X, 0, 1), math.clamp(vc.Y, 0, 1), math.clamp(vc.Z, 0, 1))
		end)
		if ok then
			sa.Parent = p
		else
			sa:Destroy()
			pcall(function()
				p.TextureID = sm.TextureId
			end)
		end
	end
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
-- Toolbar, windows, tabs
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

-- Downloader status pills -------------------------------------------
local pills = {}
local function makePill(parent)
	local pill = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }), padding(0, 10, 0, 10), hlist(6) })
	bind(pill, "BackgroundColor3", "input")
	stroke().Parent = pill
	local dot = new("Frame", { Size = UDim2.fromOffset(8, 8), BackgroundColor3 = rgb(130, 130, 140), LayoutOrder = 1 }, {
		new("UICorner", { CornerRadius = UDim.new(1, 0) }),
	})
	dot.Parent = pill
	local label_ = text({ Text = "Downloader: checking", Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2 }, 11, "regular", "text")
	label_.Parent = pill
	pill.Parent = parent
	table.insert(pills, { dot = dot, text = label_, state = nil })
end

local function setLink(connected)
	for _, p in ipairs(pills) do
		if p.state ~= connected then
			p.state = connected
			tween(p.dot, { BackgroundColor3 = connected and GREEN or rgb(130, 130, 140) })
			p.text.Text = connected and "Downloader connected" or "Downloader not open"
		end
	end
end

-- Update banner ---------------------------------------------------------
local banners = {}
local function makeBanner(root)
	local b = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		LayoutOrder = 0,
		Text = "",
	}, { corner(1), padding(8, 10, 8, 10) })
	bind(b, "BackgroundColor3", "accent")
	bind(b, "TextColor3", "accentText")
	bindText(b, 12, "bold")
	b.Parent = root
	table.insert(banners, b)
end

local function setBanner(str)
	for _, b in ipairs(banners) do
		if str then
			b.Text = str
			if not b.Visible then
				b.Visible = true
				b.BackgroundTransparency = 1
				b.TextTransparency = 1
				tween(b, { BackgroundTransparency = 0, TextTransparency = 0 }, 2)
			end
		else
			b.Visible = false
		end
	end
end

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

local appVersion = nil
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

-- Windows with tabs ---------------------------------------------------
local widgets = {}
local switchTab -- forward

local function makeWidget(id, title, w, h, tabNames)
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, w, h, 300, 400)
	local widget = plugin:CreateDockWidgetPluginGui(id, info)
	widget.Title = title
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local root = new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, { padding(10, 10, 10, 10), vlist(8) })
	bind(root, "BackgroundColor3", "bg")
	-- UI scale: shrink/grow everything, and resize the root so it still fills the window
	local uiScale = new("UIScale", { Scale = S.uiScale / 100 })
	uiScale.Parent = root
	root.Size = UDim2.fromScale(100 / S.uiScale, 100 / S.uiScale)
	local grad = new("UIGradient", { Rotation = 90 })
	grad.Parent = root
	gradients[grad] = true
	applyGradient(grad)
	root.Parent = widget

	makeBanner(root)

	local header = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 1 })
	text({ Text = title, Size = UDim2.new(0.6, 0, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }, 15, "bold", "text").Parent = header
	makePill(header)
	header.Parent = root

	-- tab bar with a sliding underline
	local n = #tabNames
	local tabBar = new("Frame", { Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 2 }, { corner(1) })
	bind(tabBar, "BackgroundColor3", "input")
	stroke().Parent = tabBar
	tabBar.Parent = root
	local tabButtons = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, { hlist(0) })
	tabButtons.Parent = tabBar
	local indicator = new("Frame", {
		Size = UDim2.new(1 / n, -16, 0, 3),
		Position = UDim2.new(0, 8, 1, -4),
		BorderSizePixel = 0,
		ZIndex = 2,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	bind(indicator, "BackgroundColor3", "accent")
	indicator.Parent = tabBar

	local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 200), BackgroundTransparency = 1, LayoutOrder = 3, ClipsDescendants = true })
	flexFill(holder)
	holder.Parent = root

	local ctx = {
		id = id, widget = widget, root = root, holder = holder, pages = {}, tabs = {}, uiScale = uiScale,
		tabIndex = {}, tabCount = n, indicator = indicator, current = nil,
	}
	for i, name in ipairs(tabNames) do
		local page = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, { vlist(8) })
		page.Parent = holder
		local b = new("TextButton", { Size = UDim2.new(1 / n, 0, 1, 0), BackgroundTransparency = 1, Text = name, LayoutOrder = i })
		bindText(b, 12, "bold")
		bind(b, "TextColor3", "dim")
		b.Parent = tabButtons
		b.MouseButton1Click:Connect(function()
			switchTab(ctx, name)
		end)
		ctx.pages[name] = page
		ctx.tabs[name] = b
		ctx.tabIndex[name] = i
	end
	table.insert(widgets, ctx)
	return ctx
end

local function applyUiScale()
	for _, ctx in ipairs(widgets) do
		local sc = S.uiScale / 100
		tween(ctx.uiScale, { Scale = sc }, 1.2)
		tween(ctx.root, { Size = UDim2.fromScale(1 / sc, 1 / sc) }, 1.2)
	end
end

switchTab = function(ctx, name, instant)
	if ctx.current == name then
		return
	end
	for n, page in pairs(ctx.pages) do
		if n ~= name then
			page.Visible = false
		end
	end
	local page = ctx.pages[name]
	page.Visible = true
	if not instant and animTime() > 0 then
		page.Position = UDim2.fromOffset(22, 0)
		tween(page, { Position = UDim2.fromOffset(0, 0) }, 1.3)
	else
		page.Position = UDim2.fromOffset(0, 0)
	end
	for n, b in pairs(ctx.tabs) do
		local key = (n == name) and "text" or "dim"
		regOf(b).props.TextColor3 = key
		tween(b, { TextColor3 = T(key) })
	end
	local idx = ctx.tabIndex[name]
	local target = UDim2.new((idx - 1) / ctx.tabCount, 8, 1, -4)
	if instant then
		ctx.indicator.Position = target
	else
		tween(ctx.indicator, { Position = target }, 1.3)
	end
	ctx.current = name
	if ctx.onTab then
		ctx.onTab(name)
	end
end

local registerThumbList, resetThumbs, stripScripts, orbitCamera, newViewport, frameContent, attachPop, closePop, cardContainer, card, groupHeader, makeNote, clearRows, scrollList
do
-------------------------------------------------------------------
-- 3D previews
--  * every card has a small spinning preview
--  * CLICK it (or hover, if turned on in Settings) and it grows into a
--    big view with buttons: Keep open, Insert, Open (models), close
--  * the big view can be resized from its corner; while your mouse is
--    over it, nothing behind it can be clicked or scrolled
-------------------------------------------------------------------
local thumbLists = {} -- list -> { ctx, thumbs }
local loadingThumbs = 0
local MAX_LOADING = 2

registerThumbList = function(list, ctx)
	thumbLists[list] = { ctx = ctx, thumbs = {} }
end

resetThumbs = function(list)
	local e = thumbLists[list]
	if e then
		e.thumbs = {}
	end
end

stripScripts = function(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			pcall(function()
				d:Destroy()
			end)
		end
	end
end

local function setupLighting(vp, cam)
	if S.lighting == "flat" then
		vp.Ambient = WHITE
		vp.LightColor = rgb(0, 0, 0)
	else
		vp.Ambient = rgb(172, 172, 180)
		vp.LightColor = rgb(125, 125, 125)
		vp.LightDirection = cam.CFrame.LookVector
	end
end

orbitCamera = function(o)
	local fov = math.rad(o.cam.FieldOfView)
	local dist = (o.radius / math.sin(fov / 2)) * o.zoom
	local rot = CFrame.Angles(0, o.yaw, 0) * CFrame.Angles(-o.pitch, 0, 0)
	o.cam.CFrame = CFrame.lookAt(rot * Vector3.new(0, 0, dist), Vector3.zero)
	if S.lighting ~= "flat" then
		o.vp.LightDirection = o.cam.CFrame.LookVector
	end
end

newViewport = function(props)
	local vp = new("ViewportFrame", props)
	bind(vp, "BackgroundColor3", "preview")
	local cam = Instance.new("Camera")
	cam.FieldOfView = 35
	cam.Parent = vp
	vp.CurrentCamera = cam
	local world = Instance.new("WorldModel")
	world.Parent = vp
	setupLighting(vp, cam)
	return vp, cam, world
end

frameContent = function(o, holder)
	local ok, cf, size = pcall(function()
		return holder:GetBoundingBox()
	end)
	if ok and size and size.Magnitude > 0 then
		holder:TranslateBy(-cf.Position)
		o.radius = math.max(size.Magnitude / 2, 0.1)
		return true
	end
	o.radius = 2
	return false
end

-- Why might a preview be blank? (shown on the card)
local function invisibleReason(holder)
	local parts, visible = 0, 0
	for _, d in ipairs(holder:GetDescendants()) do
		if d:IsA("BasePart") then
			parts = parts + 1
			if d.Transparency < 0.98 then
				visible = visible + 1
			end
		end
	end
	if parts == 0 then
		return "nothing to show"
	elseif visible == 0 then
		return "invisible part (Transparency 1)"
	end
	return nil
end

local function expandSeconds()
	if S.anim == "off" then
		return 0
	end
	return S.expandSpeed / 10
end

-- Big view (one per window) ---------------------------------------------
local function popButton(label_, primary)
	local b = new("TextButton", {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = label_,
		AutoButtonColor = false,
		ZIndex = 44,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }), padding(0, 10, 0, 10) })
	bindText(b, 11, "bold")
	if primary then
		bind(b, "BackgroundColor3", "accent")
		bind(b, "TextColor3", "accentText")
	else
		bind(b, "BackgroundColor3", "button")
		bind(b, "TextColor3", "buttonText")
	end
	pressable(b)
	return b
end

attachPop = function(ctx)
	local layer = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40 })
	layer.Parent = ctx.widget
	local box = new("Frame", { Visible = false, ZIndex = 41 }, { corner(1.5) })
	bind(box, "BackgroundColor3", "panel")
	local st = new("UIStroke", { Thickness = 2 })
	bind(st, "Color", "accent")
	st.Parent = box
	box.Parent = layer
	-- invisible shield: swallows clicks so nothing behind the big view reacts
	local shield = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 41 })
	shield.Parent = box
	local bar = new("Frame", { Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 24), BackgroundTransparency = 1, ZIndex = 43 }, {
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})
	bar.Parent = box
	local vp, cam, world = newViewport({ Position = UDim2.fromOffset(6, 36), Size = UDim2.new(1, -12, 1, -70), ZIndex = 42, Active = true })
	corner(1).Parent = vp
	vp.Parent = box
	local title = text({ Position = UDim2.new(0, 10, 1, -30), Size = UDim2.new(1, -40, 0, 26), ZIndex = 42, TextTruncate = Enum.TextTruncate.AtEnd }, 12, "bold", "text")
	title.Parent = box
	local grip = new("TextButton", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -3, 1, -3),
		Size = UDim2.fromOffset(18, 18),
		BackgroundTransparency = 1,
		Text = "//",
		ZIndex = 45,
	})
	bindText(grip, 11, "bold")
	bind(grip, "TextColor3", "dim")
	grip.Parent = box

	local pop = {
		ctx = ctx, layer = layer, box = box, stroke = st, bar = bar, vp = vp, cam = cam, world = world, title = title,
		open = false, pinned = false, src = nil, radius = 1, yaw = 0, pitch = 0.35, zoom = 1,
		dragging = false, resizing = false, moved = 0, last = nil, outside = 0, openedAt = 0, lockedList = nil,
	}
	local function guardOk()
		return os.clock() - pop.openedAt >= S.clickGuard / 10
	end
	pop.guardOk = guardOk

	vp.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pop.dragging = true
			pop.last = input.Position
			pop.moved = 0
		end
	end)
	vp.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pop.dragging = false
		end
	end)
	vp.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and pop.dragging and pop.last then
			local d = input.Position - pop.last
			pop.last = input.Position
			pop.moved = pop.moved + math.abs(d.X) + math.abs(d.Y)
			pop.yaw = pop.yaw - d.X * 0.012
			pop.pitch = math.clamp(pop.pitch + d.Y * 0.012, -1.45, 1.45)
			orbitCamera(pop)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			pop.zoom = math.clamp(pop.zoom * (1 - input.Position.Z * 0.12), 0.15, 6)
			orbitCamera(pop)
		end
	end)

	-- resize from the corner
	grip.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pop.resizing = true
			pop.resizeStart = ctx.widget:GetRelativeMousePosition()
			pop.resizeSize = box.AbsoluteSize
		end
	end)
	local function endResize(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and pop.resizing then
			pop.resizing = false
			local sc = S.uiScale / 100
			save("bigSize", math.clamp(math.floor(box.AbsoluteSize.X / sc / 10 + 0.5) * 10, 140, 700))
			syncControls(true)
		end
	end
	grip.InputEnded:Connect(endResize)
	shield.InputEnded:Connect(endResize)
	vp.InputEnded:Connect(endResize)

	ctx.pop = pop
	return pop
end


local function rebuildPopBar(pop, t)
	for _, c in ipairs(pop.bar:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local order = 0
	for _, a in ipairs(t.actions or {}) do
		order = order + 1
		local b = popButton(a.text, a.primary)
		b.LayoutOrder = order
		b.Parent = pop.bar
		b.MouseButton1Click:Connect(function()
			if not pop.guardOk() then
				return
			end
			if a.closes then
				closePop(pop.ctx, true)
			end
			a.fn()
		end)
	end
	order = order + 1
	local keep = popButton(pop.pinned and "Kept open" or "Keep open", pop.pinned)
	keep.LayoutOrder = order
	keep.Parent = pop.bar
	keep.MouseButton1Click:Connect(function()
		if not pop.guardOk() then
			return
		end
		pop.pinned = not pop.pinned
		keep.Text = pop.pinned and "Kept open" or "Keep open"
		local r = regOf(keep).props
		r.BackgroundColor3 = pop.pinned and "accent" or "button"
		r.TextColor3 = pop.pinned and "accentText" or "buttonText"
		tween(keep, { BackgroundColor3 = T(r.BackgroundColor3), TextColor3 = T(r.TextColor3) })
		tween(pop.stroke, { Thickness = pop.pinned and 3 or 2 })
	end)
	order = order + 1
	local x = popButton("X", false)
	x.LayoutOrder = order
	x.Parent = pop.bar
	x.MouseButton1Click:Connect(function()
		closePop(pop.ctx)
	end)
end

local function openPop(ctx, t)
	local pop = ctx.pop
	if not pop or not t.holder or not t.vp.Parent then
		return
	end
	pop.world:ClearAllChildren()
	local h = t.holder:Clone()
	h.Parent = pop.world
	pop.radius, pop.yaw, pop.pitch, pop.zoom = t.radius, t.yaw, t.pitch, 1
	pop.src = t
	pop.title.Text = t.title or ""
	pop.pinned = false
	pop.stroke.Thickness = 2
	rebuildPopBar(pop, t)
	if pop.lockedList and pop.lockedList ~= t.list then
		pop.lockedList.ScrollingEnabled = true
	end
	pop.lockedList = t.list

	local lp, ls = pop.layer.AbsolutePosition, pop.layer.AbsoluteSize
	local sp, ss = t.vp.AbsolutePosition - lp, t.vp.AbsoluteSize
	local sc = S.uiScale / 100
	local bw = math.clamp(S.bigSize * sc, 160, math.max(160, ls.X - 16))
	local bh = math.clamp(bw + 70, 200, math.max(200, ls.Y - 16))
	local tx = math.clamp(sp.X + ss.X / 2 - bw / 2, 8, math.max(8, ls.X - bw - 8))
	local ty = math.clamp(sp.Y + ss.Y / 2 - bh / 2, 8, math.max(8, ls.Y - bh - 8))
	if not pop.open then
		pop.box.Position = UDim2.fromOffset(sp.X, sp.Y)
		pop.box.Size = UDim2.fromOffset(ss.X, ss.Y)
	end
	pop.box.Visible = true
	pop.open = true
	pop.outside = 0
	pop.openedAt = os.clock()
	setupLighting(pop.vp, pop.cam)
	orbitCamera(pop)
	tweenFor(pop.box, { Position = UDim2.fromOffset(tx, ty), Size = UDim2.fromOffset(bw, bh) }, expandSeconds())
end

closePop = function(ctx, instant)
	local pop = ctx.pop
	if not pop or not pop.open then
		return
	end
	pop.open = false
	pop.pinned = false
	pop.dragging = false
	pop.resizing = false
	if pop.lockedList then
		pop.lockedList.ScrollingEnabled = true
	end
	local t = pop.src
	local function hide()
		if not pop.open then
			pop.box.Visible = false
			pop.world:ClearAllChildren()
		end
	end
	if not instant and t and t.vp.Parent and t.vp.AbsoluteSize.X > 0 and expandSeconds() > 0 then
		local sp = t.vp.AbsolutePosition - pop.layer.AbsolutePosition
		local tw = tweenFor(pop.box, {
			Position = UDim2.fromOffset(sp.X, sp.Y),
			Size = UDim2.fromOffset(t.vp.AbsoluteSize.X, t.vp.AbsoluteSize.Y),
		}, expandSeconds() * 0.85)
		if tw then
			tw.Completed:Connect(hide)
		else
			hide()
		end
	else
		hide()
	end
end

-- Small previews ----------------------------------------------------------
local function thumbSetContent(t, instances, reason)
	t.world:ClearAllChildren()
	t.holder = nil
	if not instances or #instances == 0 then
		t.state = "empty"
		t.note.Text = "no preview" .. (reason and ("\n" .. tostring(reason)) or "")
		t.note.Visible = true
		return
	end
	local holder = Instance.new("Model")
	for _, inst in ipairs(instances) do
		stripScripts(inst)
		inst.Parent = holder
	end
	frameContent(t, holder)
	holder.Parent = t.world
	t.holder = holder
	t.state = "ready"
	local why = invisibleReason(holder)
	t.note.Text = why or ""
	t.note.Visible = why ~= nil
	orbitCamera(t)
	if animTime() > 0 then
		t.vp.ImageTransparency = 1
		tween(t.vp, { ImageTransparency = 0 }, 2)
	end
end

local function makeThumb(list, o)
	local entry = thumbLists[list]
	local vp, cam, world = newViewport({ Active = true, ZIndex = 2 })
	local note = text({ Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, Text = "...", ZIndex = 3 }, 10, "regular", "dim")
	note.Parent = vp
	local t = {
		vp = vp, cam = cam, world = world, note = note, loader = o.loader, title = o.title, actions = o.actions,
		ctx = entry.ctx, list = list, state = "idle", radius = 1, yaw = math.random() * math.pi * 2, pitch = 0.35,
		zoom = 1, hovering = false, dragging = false, hoverToken = 0, moved = 0, last = nil,
	}
	vp.MouseEnter:Connect(function()
		t.hovering = true
		t.hoverToken = t.hoverToken + 1
		local tok = t.hoverToken
		if S.hoverExpand then
			task.delay(S.hoverDelay / 10, function()
				if t.hovering and tok == t.hoverToken and t.holder then
					openPop(t.ctx, t)
				end
			end)
		end
	end)
	vp.MouseLeave:Connect(function()
		t.hovering = false
		t.dragging = false
		t.hoverToken = t.hoverToken + 1
	end)
	vp.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			t.dragging = true
			t.last = input.Position
			t.moved = 0
		end
	end)
	vp.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			t.dragging = false
			if t.moved <= 4 and t.holder then
				openPop(t.ctx, t) -- click = open the big view
			end
		end
	end)
	vp.InputChanged:Connect(function(input)
		if t.state == "ready" and input.UserInputType == Enum.UserInputType.MouseMovement and t.dragging and t.last then
			local d = input.Position - t.last
			t.last = input.Position
			t.moved = t.moved + math.abs(d.X) + math.abs(d.Y)
			t.yaw = t.yaw - d.X * 0.012
			t.pitch = math.clamp(t.pitch + d.Y * 0.012, -1.45, 1.45)
			orbitCamera(t)
		end
	end)
	table.insert(entry.thumbs, t)
	return t
end

-- Load visible previews, spin them, manage the big views
RunService.Heartbeat:Connect(function(dt)
	local spin = S.spin and dt * (S.spinSpeed / 10) or 0
	for list, entry in pairs(thumbLists) do
		if entry.ctx.widget.Enabled then
			local top = list.AbsolutePosition.Y
			local bottom = top + list.AbsoluteSize.Y
			for _, t in ipairs(entry.thumbs) do
				local vp = t.vp
				if vp.Parent then
					local y = vp.AbsolutePosition.Y
					if y + vp.AbsoluteSize.Y > top and y < bottom then
						if t.state == "idle" and loadingThumbs < MAX_LOADING then
							t.state = "loading"
							loadingThumbs = loadingThumbs + 1
							task.spawn(function()
								local ok, err = pcall(t.loader, function(instances, reason)
									if vp.Parent then
										thumbSetContent(t, instances, reason)
									end
								end)
								if not ok and t.state == "loading" then
									thumbSetContent(t, nil, err)
								end
								loadingThumbs = loadingThumbs - 1
							end)
						elseif t.state == "ready" and spin > 0 and not t.hovering and not t.dragging then
							t.yaw = t.yaw + spin
							orbitCamera(t)
						end
					end
				end
			end
		end
	end
	for _, ctx in ipairs(widgets) do
		local pop = ctx.pop
		if pop and pop.open then
			if not ctx.widget.Enabled then
				closePop(ctx, true)
			else
				local m = ctx.widget:GetRelativeMousePosition()
				local lp = pop.layer.AbsolutePosition
				local bp = pop.box.AbsolutePosition - lp
				local bs = pop.box.AbsoluteSize
				if pop.resizing and pop.resizeStart then
					local ls = pop.layer.AbsoluteSize
					local w = math.clamp(pop.resizeSize.X + (m.X - pop.resizeStart.X), 160, math.max(160, ls.X - bp.X - 4))
					local h = math.clamp(pop.resizeSize.Y + (m.Y - pop.resizeStart.Y), 200, math.max(200, ls.Y - bp.Y - 4))
					pop.box.Size = UDim2.fromOffset(w, h)
				end
				local inside = m.X >= bp.X - 6 and m.X <= bp.X + bs.X + 6 and m.Y >= bp.Y - 6 and m.Y <= bp.Y + bs.Y + 6
				-- while the mouse is over the big view, the list behind it can't scroll
				if pop.lockedList then
					pop.lockedList.ScrollingEnabled = not inside
				end
				if inside or pop.pinned or pop.dragging or pop.resizing then
					pop.outside = 0
				else
					pop.outside = pop.outside + dt
					if pop.outside > 0.25 then
						closePop(ctx)
					end
				end
				if pop.open and spin > 0 and not inside and not pop.dragging then
					pop.yaw = pop.yaw + spin
					orbitCamera(pop)
				end
			end
		end
	end
end)

-------------------------------------------------------------------
-- Cards (grid boxes or list rows)
-------------------------------------------------------------------
local function cardHeight()
	local th = textSize(13) + 4
	local dh = S.showDetails and (textSize(10) + 3) * 2 or 0
	return 6 + S.cardSize + 6 + th + dh + 6
end

local function listRowHeight()
	local small = math.floor(S.cardSize * 0.55)
	local th = textSize(13) + 4
	local dh = S.showDetails and (textSize(10) + 3) * 2 or 0
	return math.max(small + 10, 10 + th + dh)
end

cardContainer = function(list, order)
	local f = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
	})
	if S.layout == "grid" then
		local g = new("UIGridLayout", {
			CellPadding = UDim2.fromOffset(S.gap, S.gap),
			CellSize = UDim2.fromOffset(S.cardSize + 12, cardHeight()),
			SortOrder = Enum.SortOrder.LayoutOrder,
		})
		g.Parent = f
		local function fit()
			local w = f.AbsoluteSize.X / (S.uiScale / 100)
			if w <= 0 then
				return
			end
			local minW = S.cardSize + 12
			local cols = math.max(1, math.floor((w + S.gap) / (minW + S.gap)))
			local cw = math.floor((w - S.gap * (cols - 1)) / cols)
			g.CellSize = UDim2.fromOffset(cw, cardHeight())
		end
		f:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		task.defer(fit)
	else
		new("UIListLayout", { Padding = UDim.new(0, math.max(2, math.floor(S.gap / 2))), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = f
	end
	f.Parent = list
	return f
end

-- o = { title, lines, selected, onClick, loader, badge, onBadge, actions,
--       editTitle (text to edit), onRename(newText), onDrag(cardFrame, startPos) }
card = function(container, list, order, o)
	local grid = S.layout == "grid"
	local c = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, { corner(1) })
	bind(c, "BackgroundColor3", "card")
	local st = new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	st.Parent = c
	local function paint(sel, anim)
		local props = { Color = sel and T("accent") or T("border"), Thickness = sel and 2 or 1 }
		if anim then
			tween(st, props)
		else
			st.Color = props.Color
			st.Thickness = props.Thickness
		end
	end
	paint(o.selected, false)
	if not grid then
		c.Size = UDim2.new(1, 0, 0, listRowHeight())
	end

	local t = makeThumb(list, { loader = o.loader, title = o.title, actions = o.actions })
	corner(0.75).Parent = t.vp
	t.vp.Parent = c

	local title
	if o.onRename then
		-- click the name to rename it
		title = new("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = o.editTitle or o.title or "",
			ZIndex = 3,
		})
		bindText(title, 13, "bold")
		bind(title, "TextColor3", "text")
		local line = new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(0, 0, 0, 1), BorderSizePixel = 0 })
		bind(line, "BackgroundColor3", "accent")
		line.Parent = title
		title.Focused:Connect(function()
			tween(line, { Size = UDim2.new(1, 0, 0, 1) })
		end)
		title.FocusLost:Connect(function()
			tween(line, { Size = UDim2.new(0, 0, 0, 1) })
			o.onRename(title.Text)
		end)
	else
		title = text({ Text = o.title or "", TextTruncate = Enum.TextTruncate.AtEnd }, 13, "bold", "text")
	end
	title.Parent = c
	local lines = {}
	if S.showDetails then
		for i, line in ipairs(o.lines or {}) do
			if i > 2 then
				break
			end
			local l = text({ Text = line, TextTruncate = Enum.TextTruncate.AtEnd }, 10, "mono", "dim")
			l.Parent = c
			lines[i] = l
		end
	end
	local th, lh = textSize(13) + 4, textSize(10) + 3
	if grid then
		t.vp.Position = UDim2.fromOffset(6, 6)
		t.vp.Size = UDim2.new(1, -12, 0, S.cardSize)
		title.Position = UDim2.fromOffset(8, S.cardSize + 12)
		title.Size = UDim2.new(1, -16, 0, th)
		for i, l in ipairs(lines) do
			l.Position = UDim2.fromOffset(8, S.cardSize + 12 + th + (i - 1) * lh)
			l.Size = UDim2.new(1, -16, 0, lh)
		end
	else
		local small = math.floor(S.cardSize * 0.55)
		t.vp.Position = UDim2.fromOffset(6, 5)
		t.vp.Size = UDim2.fromOffset(small, small)
		local x = small + 14
		title.Position = UDim2.fromOffset(x, 5)
		title.Size = UDim2.new(1, -(x + 36), 0, th)
		for i, l in ipairs(lines) do
			l.Position = UDim2.fromOffset(x, 5 + th + (i - 1) * lh)
			l.Size = UDim2.new(1, -(x + 8), 0, lh)
		end
	end

	if o.badge then
		local b = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 10),
			Size = UDim2.fromOffset(24, 24),
			Text = o.badge,
			ZIndex = 4,
			AutoButtonColor = false,
		}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		bind(b, "BackgroundColor3", "accent")
		bind(b, "TextColor3", "accentText")
		bindText(b, 15, "bold")
		pressable(b)
		b.MouseButton1Click:Connect(o.onBadge)
		b.Parent = c
	end

	c.MouseEnter:Connect(function()
		tween(c, { BackgroundColor3 = T("cardHover") }, 0.6)
	end)
	c.MouseLeave:Connect(function()
		tween(c, { BackgroundColor3 = T("card") }, 0.9)
	end)
	local sc = Instance.new("UIScale")
	sc.Parent = c
	if animTime() > 0 then
		sc.Scale = 0.92
		c.BackgroundTransparency = 1
		task.delay(math.min(order, 24) * 0.012, function()
			tween(sc, { Scale = 1 }, 1.5, Enum.EasingStyle.Back)
			tween(c, { BackgroundTransparency = 0 }, 1.5)
		end)
	end

	-- dragging the card (Inserter -> workspace)
	local dragged = false
	if o.onDrag then
		local downPos = nil
		c.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				downPos = input.Position
				dragged = false
			end
		end)
		c.InputChanged:Connect(function(input)
			if downPos and input.UserInputType == Enum.UserInputType.MouseMovement then
				local d = input.Position - downPos
				if math.abs(d.X) + math.abs(d.Y) > 10 then
					local p = downPos
					downPos = nil
					dragged = true
					o.onDrag(c, p)
				end
			end
		end)
		c.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				downPos = nil
			end
		end)
	end
	c.MouseButton1Click:Connect(function()
		if dragged then
			dragged = false
			return
		end
		o.onClick()
	end)
	c.Parent = container
	return { frame = c, paint = paint, thumb = t, sc = sc }
end

-- Full-width header row (optionally with a turning arrow)
groupHeader = function(list, order, label_, onClick, open)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 28),
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, { corner(1) })
	bind(row, "BackgroundColor3", "header")
	local x = 10
	local arrow = nil
	if open ~= nil then
		arrow = text({ Text = ">", Size = UDim2.fromOffset(14, 28), Position = UDim2.fromOffset(8, 0), TextXAlignment = Enum.TextXAlignment.Center, Rotation = open and 90 or 0 }, 12, "bold", "dim")
		arrow.Parent = row
		x = 28
	end
	text({ Text = label_, Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -(x + 8), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }, 12, "bold", "text").Parent = row
	row.MouseEnter:Connect(function()
		tween(row, { BackgroundColor3 = T("cardHover") }, 0.6)
	end)
	row.MouseLeave:Connect(function()
		tween(row, { BackgroundColor3 = T("header") }, 0.9)
	end)
	row.MouseButton1Click:Connect(function()
		if arrow then
			tween(arrow, { Rotation = (arrow.Rotation > 45) and 0 or 90 })
			task.delay(animTime(0.7), onClick)
		else
			onClick()
		end
	end)
	row.Parent = list
	return row
end

makeNote = function(parent, str, order)
	text({ Size = UDim2.new(1, 0, 0, 34), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Text = str, LayoutOrder = order }, 12, "regular", "dim").Parent = parent
end

clearRows = function(frame)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

scrollList = function(order)
	local list = new("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 160),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		BorderSizePixel = 0,
		LayoutOrder = order,
	}, { corner(1), vlist(8), padding(6, 10, 6, 6) })
	bind(list, "BackgroundColor3", "panel")
	bind(list, "ScrollBarImageColor3", "dim")
	stroke().Parent = list
	flexFill(list)
	return list
end

end

-- Names shared between the Collector, Inserter and Settings blocks
-- (each block is wrapped in do ... end so Roblox's per-script variable limit isn't hit)
local col, ins
local refresh, queueRefresh, refreshInserter, renderInserter, rerenderAll, applyInfoPos
local collectButton, openInserterButton
local frozenSelection = {}
local suppressLiveUntil = 0

-- ===== COLLECTOR BLOCK =====
;(function() -- COLLECTOR BLOCK (own function: keeps the main body under Luau's local limit)
-- =================================================================
-- MESH COLLECTOR
-- =================================================================
col = makeWidget("MeshCollectorV2", "Mesh Collector  v" .. PLUGIN_VERSION, 380, 700, { "Collector", "Settings" })
attachPop(col)
local colPage = col.pages.Collector

local summary = dimText("Select a model or part in Explorer.", 1)
summary.Parent = colPage


dimText("Name files by", 2, 11).Parent = colPage
segmented(3, {
	{ key = "part", text = "Part" },
	{ key = "parent", text = "Parent" },
	{ key = "model", text = "Model" },
	{ key = "top", text = "Top" },
	{ key = "custom", text = "Custom" },
}, "nameSource", function()
	refresh()
end, 11).Parent = colPage

collectButton = button("Collect current selection", "secondary", 4)
collectButton.Visible = not S.live
collectButton.Parent = colPage

local listHeader = text({ Text = "Meshes (0)  -  click a card's name to rename it", Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 5, TextTruncate = Enum.TextTruncate.AtEnd }, 13, "bold", "text")
listHeader.Parent = colPage

local listFrame = scrollList(6)
listFrame.Parent = colPage
registerThumbList(listFrame, col)

local sendButton = button("Send to Downloader", "primary", 7)
sendButton.Parent = colPage
local buildButton = button("Build local copy (real MeshParts, local .mesh)", "secondary", 8)
buildButton.Parent = colPage
local saveModelButton = button("Save model", "secondary")
local pivotButton = button("Reset pivots", "secondary")
local restorePivotButton = button("Restore pivots", "secondary")
buttonRow(9, { saveModelButton, pivotButton, restorePivotButton }).Parent = colPage
local pivotText = dimText(pivotSummary() .. " Originals are saved - Restore puts them back.", 10, 10)
pivotText.Parent = colPage
table.insert(controlRenderers, function()
	pivotText.Text = pivotSummary() .. " Originals are saved - Restore puts them back."
end)
local copyButton = button("Copy list", "secondary")
openInserterButton = button("Open Inserter", "secondary")
buttonRow(11, { copyButton, openInserterButton }).Parent = colPage

local statusLine = dimText("", 12, 11)
statusLine.Parent = colPage

local function setStatus(str, color)
	statusLine.Text = str
	regOf(statusLine).props.TextColor3 = nil
	statusLine.TextColor3 = color or T("dim")
	if animTime() > 0 and str ~= "" then
		statusLine.TextTransparency = 1
		tween(statusLine, { TextTransparency = 0 }, 1.5)
	end
end

-- Copy panel (fallback when the app link isn't working)
local overlay = new("Frame", { Size = UDim2.fromScale(1, 1), ZIndex = 30, Visible = false, BorderSizePixel = 0 }, {
	padding(10, 10, 10, 10),
	vlist(8),
})
bind(overlay, "BackgroundColor3", "bg")
overlay.Parent = col.widget
text({ Text = "Copy list", Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 1 }, 15, "bold", "text").Parent = overlay
dimText("The text is selected - press Ctrl+C now, then paste it into Mesh Downloader.", 2, 11).Parent = overlay
local overlayScroll = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 200),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
	BorderSizePixel = 0,
	LayoutOrder = 3,
}, { corner(1) })
bind(overlayScroll, "BackgroundColor3", "input")
flexFill(overlayScroll)
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
	Text = "",
})
bindText(copyBox, 13, "mono")
bind(copyBox, "TextColor3", "text")
copyBox.Parent = overlayScroll
local closeOverlay = button("Close", "primary", 4)
closeOverlay.Parent = overlay
closeOverlay.MouseButton1Click:Connect(function()
	overlay.Visible = false
end)

-- Collecting ------------------------------------------------------------
local currentEntries = {}
local colSelected = nil
local colCards = {} -- part -> card

-- Image IDs used by a mesh (TextureID + SurfaceAppearance maps), so the app can save them too
local function texturesOf(meshInst, owner)
	local ids, seen = {}, {}
	local function add(v)
		local id = idFrom(tostring(v or ""))
		if id and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	pcall(function()
		if meshInst:IsA("MeshPart") then
			add(meshInst.TextureID)
			add(contentUri(meshInst, "TextureContent"))
		elseif meshInst:IsA("FileMesh") then
			add(meshInst.TextureId)
		end
	end)
	for _, d in ipairs(owner:GetChildren()) do
		if d:IsA("SurfaceAppearance") then
			for _, prop in ipairs({ "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap" }) do
				pcall(function()
					add(d[prop])
				end)
			end
		end
	end
	return ids
end

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
		local auto = meshBaseName(owner)
		table.insert(entries, {
			id = id,
			name = renames[id] or auto,
			autoName = auto,
			folder = folderFor(owner),
			owner = owner,
			model = m,
			textures = texturesOf(inst, owner),
		})
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
	if S.addId then
		return e.name .. "_" .. e.id .. ".mesh"
	end
	return e.name .. ".mesh"
end

local function partSizeText(inst)
	if inst:IsA("BasePart") then
		local s = inst.Size
		return string.format("%.2f x %.2f x %.2f", s.X, s.Y, s.Z)
	end
	return "?"
end

local function selectInStudio(inst)
	if not inst or not inst.Parent then
		return
	end
	suppressLiveUntil = os.clock() + 0.5
	Selection:Set({ inst })
	colSelected = inst
	for owner, cd in pairs(colCards) do
		cd.paint(owner == inst, true)
	end
end

refresh = function()
	if not col.widget.Enabled then
		return
	end
	collectButton.Visible = not S.live
	local selected
	if S.live then
		selected = Selection:Get()
		frozenSelection = selected
	else
		selected = frozenSelection
	end
	closePop(col)
	clearRows(listFrame)
	resetThumbs(listFrame)
	colCards = {}
	local entries, modelCount = collect(selected)
	currentEntries = entries
	listHeader.Text = string.format("Meshes (%d)  -  click a card's name to rename it", #entries)

	if #selected == 0 then
		summary.Text = S.live and "Click a model or part in Explorer or the viewport."
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

	local groups, groupOrder = {}, {}
	for _, e in ipairs(entries) do
		local key = e.model or "none"
		if not groups[key] then
			groups[key] = { model = e.model, list = {} }
			table.insert(groupOrder, key)
		end
		table.insert(groups[key].list, e)
	end

	local order, shown = 0, 0
	for _, key in ipairs(groupOrder) do
		local g = groups[key]
		local n = #g.list
		order = order + 1
		local headerText
		if g.model then
			headerText = string.format("%s  (%d mesh%s)  - click to select", g.model.Name, n, n == 1 and "" or "es")
		else
			headerText = string.format("Not in a model  (%d)", n)
		end
		groupHeader(listFrame, order, headerText, function()
			if g.model then
				selectInStudio(g.model)
			end
		end)
		order = order + 1
		local cont = cardContainer(listFrame, order)
		for i, e in ipairs(g.list) do
			shown = shown + 1
			if shown > S.maxItems then
				break
			end
			local cd = card(cont, listFrame, i, {
				title = fileNameOf(e),
				editTitle = e.name,
				onRename = function(newName)
					newName = clean(newName)
					if newName == "" or newName == e.autoName then
						renames[e.id] = nil
					else
						renames[e.id] = newName
					end
					saveRenames()
					e.name = renames[e.id] or e.autoName
					queueRefresh()
				end,
				lines = {
					fileNameOf(e),
					e.id .. "  -  " .. partSizeText(e.owner) .. (e.folder and ("  ->  " .. e.folder .. "/") or ""),
				},
				selected = (colSelected == e.owner),
				onClick = function()
					selectInStudio(e.owner)
				end,
				loader = function(cb)
					local ok, c = pcall(function()
						return e.owner:Clone()
					end)
					if ok and c then
						cb({ c })
					else
						cb(nil, ok and "can't be copied (Archivable off)" or tostring(c))
					end
				end,
			})
			colCards[e.owner] = cd
		end
		if shown > S.maxItems then
			order = order + 1
			makeNote(listFrame, string.format("...and %d more (all will be sent). Raise 'Max items' in Settings to see them.", #entries - S.maxItems), order)
			break
		end
	end
end

local refreshQueued = false
queueRefresh = function()
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
		if not S.addId then
			line = line .. " | noid"
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

sendButton.MouseButton1Click:Connect(function()
	if #currentEntries == 0 then
		setStatus("Nothing to send - select something that has meshes.", RED)
		return
	end
	local items = {}
	for _, e in ipairs(currentEntries) do
		table.insert(items, { id = e.id, name = e.name, folder = e.folder, noId = not S.addId, textures = e.textures })
	end
	setStatus("Sending...", nil)
	local ok = request("POST", "/queue", HttpService:JSONEncode({ autoStart = S.autoStart, items = items }))
	setLink(ok)
	if ok then
		local verb = S.autoStart and "Downloading" or "Queued"
		setStatus(string.format("%s %d mesh(es) + their textures in Mesh Downloader. Saving their looks...", verb, #items), GREEN)
		-- save each mesh's "look" (texture, SurfaceAppearance, colour, material) so the
		-- Inserter can give a lone mesh its real appearance later
		local entries = currentEntries
		task.spawn(function()
			local saved = 0
			for i, e in ipairs(entries) do
				if i > 300 then
					break
				end
				local ok, c = pcall(function()
					return e.owner:Clone()
				end)
				if ok and c then
					stripScripts(c)
					for _, d in ipairs(c:GetChildren()) do
						if not (d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") or d:IsA("FileMesh") or d:IsA("WrapLayer") or d:IsA("WrapTarget")) then
							d:Destroy()
						end
					end
					if saveToApp({ c }, e.id, "look", nil) then
						saved = saved + 1
					end
					c:Destroy()
				end
			end
			setStatus(string.format("%s %d mesh(es) + textures. Saved %d look(s) for the Inserter.", verb, #items, saved), GREEN)
		end)
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
	local finish = beginRecording("Reset pivots")
	local n = resetPivots(roots)
	finish(true)
	setStatus(string.format("Reset %d pivot(s). %s", n, pivotSummary()), GREEN)
end)

restorePivotButton.MouseButton1Click:Connect(function()
	local roots = selectionRoots()
	if #roots == 0 then
		setStatus("Select a model or part first.", RED)
		return
	end
	local finish = beginRecording("Restore pivots")
	local n = restorePivots(roots)
	finish(true)
	if n == 0 then
		setStatus("Nothing to restore - these pivots were never reset by Mesh Tools.", nil)
	else
		setStatus(string.format("Restored %d original pivot(s).", n), GREEN)
	end
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
	local skinned = {} -- meshes with bones (dynamic heads ...): only a MeshPart can move them
	for _, item in ipairs(data.installed or {}) do
		ready[tostring(item.id)] = true
		readyCount = readyCount + 1
		if (tonumber(item.bones) or 0) ~= 0 then
			skinned[tostring(item.id)] = true
		end
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
					local id = idFrom((meshIdOf(d)))
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
						local toMeshPart = S.specialMeshes == "meshpart" or (S.specialMeshes == "auto" and skinned[id])
						if toMeshPart and host and host:IsA("BasePart") and not host:IsA("MeshPart") and not partMap[host] then
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
	-- use downloaded textures too, when Mesh Downloader has them
	local texMap = type(data.textures) == "table" and data.textures or {}
	local function swapTex(v)
		local tid = idFrom(tostring(v or ""))
		local f = tid and texMap[tid]
		return f and (LOCAL_PREFIX .. "textures/" .. f) or nil
	end
	for _, root in ipairs(copies) do
		local list = root:GetDescendants()
		table.insert(list, root)
		for _, d in ipairs(list) do
			pcall(function()
				if d:IsA("MeshPart") then
					local l = swapTex(textureOf(d))
					if l then
						d.TextureID = l
					end
				elseif d:IsA("FileMesh") then
					local l = swapTex(d.TextureId)
					if l then
						d.TextureId = l
					end
				end
				-- SurfaceAppearances are left on their Roblox picture IDs: they can't load
				-- pictures from the meshtools folder on your PC (tested in Studio)
			end)
		end
		bakeLooks(root, texMap) -- converted dynamic heads: skin colour painted into a local picture
	end
	applyPivots(copies)
	finish(true)
	Selection:Set(copies)

	local msg = string.format("Built local copy: %d mesh(es) load from your PC.", replaced)
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
	if os.clock() < suppressLiveUntil then
		return
	end
	if S.live and col.widget.Enabled and col.current == "Collector" then
		queueRefresh()
	end
end)
end)() -- COLLECTOR BLOCK

-- ===== INSERTER BLOCK =====
;(function() -- INSERTER BLOCK (own function, same reason)
-- =================================================================
-- MESH INSERTER
-- =================================================================
ins = makeWidget("MeshInserterV3", "Mesh Inserter", 400, 720, { "Library", "Settings" })
attachPop(ins)
local insPage = ins.pages.Library

local searchHolder, searchBox = textInput("Search meshes and models...", 1)
local refreshLibButton = button("Refresh", "secondary")
local importObjButton = button("Import .obj", "secondary")
local searchRow = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 1 }, { hlist(6) })
searchHolder.Size = UDim2.new(1, S.showObjImport and -184 or -86, 1, 0)
searchHolder.LayoutOrder = 1
searchHolder.Parent = searchRow
refreshLibButton.Size = UDim2.new(0, 80, 1, 0)
refreshLibButton.LayoutOrder = 2
refreshLibButton.Parent = searchRow
importObjButton.Size = UDim2.new(0, 92, 1, 0)
importObjButton.LayoutOrder = 3
importObjButton.Visible = S.showObjImport and true or false
importObjButton.Parent = searchRow
searchRow.Parent = insPage

local pivotRow = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = 3 })
text({ Text = "When inserting:", Size = UDim2.new(0, 104, 1, 0) }, 11, "regular", "dim").Parent = pivotRow
local pivotSeg = segmented(1, {
	{ key = false, text = "Keep pivots" },
	{ key = true, text = "Reset pivots" },
}, "pivotOnInsert", nil, 11)
pivotSeg.Position = UDim2.fromOffset(106, 0)
pivotSeg.Size = UDim2.new(1, -106, 1, 0)
pivotSeg.Parent = pivotRow
pivotRow.Parent = insPage
dimText("Click a preview for the big view. Drag a card into the 3D view to place it.", 3, 10).Parent = insPage

local insList = scrollList(4)
insList.Parent = insPage
registerThumbList(insList, ins)

-- details + buttons (can sit above or below the list - see Settings)
local infoBlock = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = 5,
}, { vlist(8) })
infoBlock.Parent = insPage
local infoCard = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, {
	corner(1),
	padding(8, 10, 8, 10),
})
bind(infoCard, "BackgroundColor3", "panel")
stroke().Parent = infoCard
infoCard.Parent = infoBlock
local infoLabel = text({
	Text = "Click a card's name to see its details here.",
	RichText = true,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
}, 12, "regular", "text")
infoLabel.Parent = infoCard

local insertButton = button("Insert", "primary")
local revealButton = button("Show in folder", "secondary")
local deleteButton = button("Delete", "secondary")
buttonRow(2, { insertButton, revealButton, deleteButton }).Parent = infoBlock
local insStatus = dimText("", 3, 11)
insStatus.Parent = infoBlock

local function setInsStatus(str, color)
	insStatus.Text = str
	regOf(insStatus).props.TextColor3 = nil
	insStatus.TextColor3 = color or T("dim")
	if animTime() > 0 and str ~= "" then
		insStatus.TextTransparency = 1
		tween(insStatus, { TextTransparency = 0 }, 1.5)
	end
end

applyInfoPos = function()
	infoBlock.LayoutOrder = (S.infoPos == "top") and 2 or 5
	pivotRow.LayoutOrder = 3
end
applyInfoPos()

local function setInfo(str)
	infoLabel.Text = str
	if animTime() > 0 then
		infoLabel.TextTransparency = 1
		tween(infoLabel, { TextTransparency = 0 }, 1.2)
	end
end

-- Library state ------------------------------------------------------------
local lib = { meshes = {}, models = {}, textures = {}, loaded = false }
local sectionOpen = { models = true, meshes = true }
local expanded = {}
local modelCache = {}
local meshTemplates = {}
local selected = nil
local selectToken = 0
local insCards = {} -- item/part table -> card

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

-- Downloads a file from the app in base64 chunks and opens it as instances
local function fetchRoots(path)
	if not SerializationService then
		return nil, "this Studio can't load model files from plugins"
	end
	local chunks, count, i = {}, 1, 0
	while i < count do
		local sep = string.find(path, "?", 1, true) and "&" or "?"
		local ok, res = request("GET", path .. sep .. "chunk=" .. i)
		local dd = ok and decodeBody(res)
		if not dd or not dd.ok then
			return nil, "couldn't load it from Mesh Downloader"
		end
		count = tonumber(dd.count) or 1
		table.insert(chunks, b64decode(dd.data or ""))
		i = i + 1
	end
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
	return deserialize(all)
end

-- Swap image IDs for downloaded local copies (rbxasset://meshtools/textures/...)
local function localTex(v)
	local id = idFrom(tostring(v or ""))
	local f = id and lib.textures and lib.textures[id]
	if f then
		return LOCAL_PREFIX .. "textures/" .. f
	end
	return nil
end

local function applyLocalTextures(root)
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, d in ipairs(list) do
		if d:IsA("MeshPart") then
			local l = localTex(textureOf(d))
			if l then
				pcall(function()
					d.TextureID = l
				end)
			end
		elseif d:IsA("FileMesh") then
			local l = localTex(d.TextureId)
			if l then
				pcall(function()
					d.TextureId = l
				end)
			end
		end
		-- SurfaceAppearances keep their Roblox picture IDs (they can't load local pictures)
	end
end

-- A ready-to-insert MeshPart for a library mesh: uses its saved "look"
-- (texture / SurfaceAppearance / colour) when there is one.
local function getMeshTemplate(m)
	local id = m.id
	if meshTemplates[id] then
		return meshTemplates[id]
	end
	local part, err = nil, nil
	if m.look then
		local roots = fetchRoots("/look?id=" .. id)
		local look = roots and roots[1]
		if look and look:IsA("MeshPart") then
			part, err = convertMeshPart(look, id)
		elseif look and look:IsA("BasePart") then
			local sm = look:FindFirstChildWhichIsA("FileMesh")
			if sm and (S.specialMeshes == "keep" or (S.specialMeshes == "auto" and (tonumber(m.bones) or 0) == 0)) then
				sm.MeshId = LOCAL_PREFIX .. id .. ".mesh" -- same Part + SpecialMesh, mesh from your PC
				part = look
			elseif sm then
				part, err = convertSpecialMesh(look, sm, id)
			end
		end
	end
	if not part then
		part, err = createLocalMeshPart(id, nil)
	end
	if part then
		part.Anchored = true
		applyLocalTextures(part)
		bakeLooks(part, lib.textures)
		meshTemplates[id] = part
	end
	return part, err
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
					meshId = (meshIdOf(d))
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
	if cached and cached.date == m.date then
		if cached.loading then
			table.insert(cached.waiters, callback)
		else
			callback(cached)
		end
		return
	end
	local pending = { loading = true, date = m.date, waiters = { callback } }
	modelCache[m.key] = pending
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
		for _, w in ipairs(pending.waiters) do
			task.spawn(w, entry)
		end
	end)
end

-- Same as loadModel but waits for the result (for previews)
local function waitModel(m)
	local result, done = nil, false
	loadModel(m, function(entry)
		result = entry
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 120 do
		task.wait(0.05)
	end
	return result
end

local function cloneAll(list)
	local out = {}
	for _, r in ipairs(list) do
		local ok, c = pcall(function()
			return r:Clone()
		end)
		if ok and c then
			table.insert(out, c)
		end
	end
	return out
end

local function showMeshInfo(m)
	local bones = tonumber(m.bones) or 0
	local boneText = bones > 0 and string.format("<b>SKINNED</b> - %d bones", bones) or (bones < 0 and "skinned" or "no bones")
	setInfo(string.format(
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
	))
end

local function showModelInfo(m, entry)
	local extra = "Loading..."
	if entry and entry.err then
		extra = entry.err
	elseif entry and entry.roots then
		extra = string.format("%d object(s) at top  -  %d parts  -  %d meshes", #entry.roots, entry.partCount or 0, #(entry.parts or {}))
	end
	setInfo(string.format(
		"<b>%s</b>\nModel  -  %s  -  %s  -  %s\nFolder: %s\n%s",
		escapeRich(m.name),
		escapeRich(m.ext or ""),
		fmtBytes(m.bytes),
		escapeRich(m.date or ""),
		escapeRich((m.folder and m.folder ~= "") and m.folder or "(save folder)"),
		escapeRich(extra)
	))
end

local function showPartInfo(m, p)
	local inst = p.inst
	local size = inst.Size
	setInfo(string.format(
		"<b>%s</b>\nPart in %s  -  mesh ID %s\n%s\nSize %.2f x %.2f x %.2f studs  -  %s",
		escapeRich(p.name),
		escapeRich(m.name),
		escapeRich(p.id),
		escapeRich(p.path),
		size.X,
		size.Y,
		size.Z,
		inst.ClassName
	))
end


-- Model view: an opened model grows out of its card into a big 3D view with a side
-- panel (the picked part + a list of the model's meshes). Click a part in 3D to pick it.
local inspector = nil
local justOpened = nil -- model key whose view should grow out of its card

local function inspectorHighlight(p)
	if inspector then
		inspector.pick(p)
	end
end

local function updateInsHighlights()
	local key = selected and (selected.kind == "part" and selected.part or selected.item) or nil
	for k, cd in pairs(insCards) do
		cd.paint(k == key, true)
	end
end

local function selectMesh(m)
	selectToken = selectToken + 1
	selected = { kind = "mesh", item = m }
	showMeshInfo(m)
	updateInsHighlights()
	inspectorHighlight(nil)
end

local function selectModel(m)
	selectToken = selectToken + 1
	local token = selectToken
	selected = { kind = "model", item = m }
	showModelInfo(m, modelCache[m.key])
	updateInsHighlights()
	inspectorHighlight(nil)
	loadModel(m, function(entry)
		if token == selectToken then
			showModelInfo(m, entry)
		end
	end)
end

local function selectPart(m, p)
	selectToken = selectToken + 1
	selected = { kind = "part", item = m, part = p }
	showPartInfo(m, p)
	updateInsHighlights()
	inspectorHighlight(p)
end

local function matches(str, filter)
	if filter == "" then
		return true
	end
	return string.find(string.lower(tostring(str or "")), filter, 1, true) ~= nil
end

local startCardDrag -- forward (drag into the 3D view)
local insertTarget -- forward

local function buildInspector(m, cache, order, grow, filter)
	local H = S.inspectHeight
	local frame = new("Frame", { Size = UDim2.new(1, 0, 0, H), LayoutOrder = order, ClipsDescendants = true }, { corner(1) })
	bind(frame, "BackgroundColor3", "panel")
	stroke("accent").Parent = frame

	-- header: name, Insert model, close
	text({ Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -160, 0, 20), Text = m.name, TextTruncate = Enum.TextTruncate.AtEnd }, 13, "bold", "text").Parent = frame
	local insertModelBtn = button("Insert model", "primary")
	insertModelBtn.Size = UDim2.fromOffset(104, 24)
	insertModelBtn.Position = UDim2.new(1, -142, 0, 5)
	insertModelBtn.Parent = frame
	local closeBtn = button("X", "secondary")
	closeBtn.Size = UDim2.fromOffset(30, 24)
	closeBtn.Position = UDim2.new(1, -35, 0, 5)
	closeBtn.Parent = frame
	insertModelBtn.MouseButton1Click:Connect(function()
		insertTarget({ kind = "model", item = m })
	end)
	closeBtn.MouseButton1Click:Connect(function()
		expanded = {}
		renderInserter()
	end)

	if grow then
		-- grows out of the card it replaced
		if S.layout == "grid" then
			frame.Size = UDim2.fromOffset(S.cardSize + 12, S.cardSize + 56)
		else
			frame.Size = UDim2.new(1, 0, 0, math.floor(S.cardSize * 0.55) + 10)
		end
		tween(frame, { Size = UDim2.new(1, 0, 0, H) }, 1.6, Enum.EasingStyle.Quint)
	end
	frame.Parent = insList

	if not cache or cache.loading or cache.err then
		local msg = (cache and cache.err) or "Loading..."
		text({ Position = UDim2.fromOffset(10, 36), Size = UDim2.new(1, -20, 1, -46), Text = msg, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center }, 12, "regular", "dim").Parent = frame
		return
	end

	local body = new("Frame", { Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40), BackgroundTransparency = 1 })
	body.Parent = frame
	local vp, cam, world = newViewport({ Size = UDim2.new(0.62, -3, 1, 0), Active = true, ZIndex = 2, ClipsDescendants = true })
	corner(1).Parent = vp
	vp.Parent = body
	local hover = text({ Position = UDim2.fromOffset(8, 6), Size = UDim2.new(1, -16, 0, 16), Text = "", ZIndex = 6, TextTruncate = Enum.TextTruncate.AtEnd }, 11, "bold", "text")
	hover.Parent = vp
	text({ Position = UDim2.new(0, 8, 1, -20), Size = UDim2.new(1, -16, 0, 16), Text = "Click a part  -  drag to rotate  -  scroll to zoom", ZIndex = 6, TextTruncate = Enum.TextTruncate.AtEnd }, 10, "regular", "dim").Parent = vp

	-- side panel
	local side = new("Frame", { Position = UDim2.new(0.62, 3, 0, 0), Size = UDim2.new(0.38, -3, 1, 0), BackgroundTransparency = 1 })
	side.Parent = body
	local infoBox = new("Frame", { Size = UDim2.new(1, 0, 0, 78) }, { corner(1), padding(6, 8, 6, 8) })
	bind(infoBox, "BackgroundColor3", "card")
	infoBox.Parent = side
	local partName = text({ Size = UDim2.new(1, 0, 0, 16), Text = "", TextTruncate = Enum.TextTruncate.AtEnd }, 12, "bold", "text")
	partName.Parent = infoBox
	local partInfo = text({ Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 1, -18), Text = "", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd }, 10, "regular", "dim")
	partInfo.Parent = infoBox
	local insertPartBtn = button("Insert part", "primary")
	insertPartBtn.Size = UDim2.new(1, 0, 0, 26)
	insertPartBtn.Position = UDim2.fromOffset(0, 84)
	insertPartBtn.Parent = side
	local listLabel = text({ Position = UDim2.fromOffset(2, 116), Size = UDim2.new(1, -4, 0, 14), Text = "" }, 10, "bold", "dim")
	listLabel.Parent = side
	local partList = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 132),
		Size = UDim2.new(1, 0, 1, -132),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }) })
	bind(partList, "ScrollBarImageColor3", "dim")
	partList.Parent = side

	-- the 3D copy of the model
	local holder = Instance.new("Model")
	local map, back, baseT = {}, {}, {}
	for _, r in ipairs(cache.roots) do
		local ok, c = pcall(function()
			return r:Clone()
		end)
		if ok and c then
			local o = r:GetDescendants()
			table.insert(o, 1, r)
			local cl = c:GetDescendants()
			table.insert(cl, 1, c)
			if #o == #cl then
				for i = 1, #o do
					if o[i]:IsA("BasePart") then
						map[o[i]] = cl[i]
					end
				end
			end
			c.Parent = holder
		end
	end
	stripScripts(holder)
	for _, cl in pairs(map) do
		baseT[cl] = cl.Transparency
		pcall(function()
			cl.CanQuery = true
		end)
	end
	for _, p in ipairs(cache.parts or {}) do
		local cl = map[p.inst]
		if cl then
			back[cl] = p
		end
	end
	local insp = { vp = vp, cam = cam, radius = 2, yaw = 0.6, pitch = 0.35, zoom = 1 }
	frameContent(insp, holder)
	holder.Parent = world

	-- outline: the picked part drawn again on top, plus 8 accent-coloured copies nudged
	-- 2px around it. ViewportFrames can't show Highlights, so this is how it gets an edge.
	local outline = nil
	local function clearOutline()
		if outline then
			for _, o in ipairs(outline) do
				o.vp:Destroy()
			end
			outline = nil
		end
	end
	local function buildOutline(cl)
		clearOutline()
		if not cl or not (S.inspectMode == "outline" or S.inspectOutline) then
			return
		end
		outline = {}
		local function overlay(dx, dy, sil)
			local copy = nil
			pcall(function()
				copy = cl:Clone()
			end)
			if not copy then
				return
			end
			local ov = Instance.new("ViewportFrame")
			ov.BackgroundTransparency = 1
			ov.Size = UDim2.new(1, 0, 1, 0)
			ov.Position = UDim2.fromOffset(dx, dy)
			ov.ZIndex = sil and 3 or 4
			ov.Active = false
			pcall(function()
				ov.Interactable = false
			end)
			local c2 = Instance.new("Camera")
			c2.FieldOfView = cam.FieldOfView
			c2.CFrame = cam.CFrame
			c2.Parent = ov
			ov.CurrentCamera = c2
			if sil then
				for _, ch in ipairs(copy:GetDescendants()) do
					if ch:IsA("SurfaceAppearance") or ch:IsA("Decal") or ch:IsA("Texture") then
						ch:Destroy()
					end
				end
				pcall(function()
					copy.TextureID = ""
				end)
				copy.Color = WHITE
				copy.Material = Enum.Material.SmoothPlastic
				copy.Reflectance = 0
				copy.Transparency = 0
				ov.Ambient = WHITE
				ov.LightColor = rgb(0, 0, 0)
				ov.ImageColor3 = T("accent")
			else
				copy.Transparency = baseT[cl] or 0
				ov.Ambient = vp.Ambient
				ov.LightColor = vp.LightColor
				ov.LightDirection = vp.LightDirection
			end
			copy.Parent = ov
			ov.Parent = vp
			table.insert(outline, { vp = ov, cam = c2, sil = sil })
		end
		for _, d in ipairs({ { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 }, { -2, -2 }, { 2, 2 }, { -2, 2 }, { 2, -2 } }) do
			overlay(d[1], d[2], true)
		end
		overlay(0, 0, false)
	end
	local function orbit()
		orbitCamera(insp)
		if outline then
			for _, o in ipairs(outline) do
				o.cam.CFrame = cam.CFrame
				if not o.sil then
					o.vp.LightDirection = vp.LightDirection
				end
			end
		end
	end
	orbit()

	-- side list of the model's meshes
	local rows = {}
	local function paintRow(row, on)
		row.BackgroundColor3 = on and T("accent") or T("card")
		row.TextColor3 = on and T("accentText") or T("text")
	end
	local shown = 0
	for i, p in ipairs(cache.parts or {}) do
		if filter == "" or matches(m.name, filter) or matches(p.name, filter) or matches(p.id, filter) then
			shown = shown + 1
			local row = new("TextButton", {
				Size = UDim2.new(1, -6, 0, 22),
				Text = "  " .. p.name,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				AutoButtonColor = false,
				LayoutOrder = i,
			}, { corner(0.5) })
			bindText(row, 11, "regular")
			paintRow(row, false)
			row.Parent = partList
			rows[p] = row
			local downPos, dragged = nil, false
			row.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					downPos, dragged = input.Position, false
				end
			end)
			row.InputChanged:Connect(function(input)
				if downPos and input.UserInputType == Enum.UserInputType.MouseMovement then
					local d = input.Position - downPos
					if math.abs(d.X) + math.abs(d.Y) > 10 then
						downPos, dragged = nil, true
						startCardDrag(ins, row, { kind = "part", item = m, part = p }, p.name)
					end
				end
			end)
			row.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					downPos = nil
				end
			end)
			row.MouseButton1Click:Connect(function()
				if dragged then
					dragged = false
					return
				end
				selectPart(m, p)
			end)
		end
	end
	listLabel.Text = string.format("MESHES (%d)  -  click to pick, drag to place", shown)

	local picked = nil
	local function pick(p)
		picked = p
		for orig, cl in pairs(map) do
			local base = baseT[cl] or 0
			local target = base
			if p and S.inspectMode ~= "outline" and orig ~= p.inst then
				target = math.max(base, 0.88)
			end
			tween(cl, { Transparency = target }, 0.8)
		end
		buildOutline(p and map[p.inst] or nil)
		if p then
			local sz = p.inst.Size
			partName.Text = p.name
			partInfo.Text = string.format("Mesh ID %s\n%.2f x %.2f x %.2f studs\n%s", p.id, sz.X, sz.Y, sz.Z, p.path)
			insertPartBtn.Visible = true
		else
			partName.Text = "Whole model"
			partInfo.Text = string.format("%d parts  -  %d meshes\nPick a part in 3D or in the list.", cache.partCount or 0, #(cache.parts or {}))
			insertPartBtn.Visible = false
		end
		for pp, row in pairs(rows) do
			paintRow(row, pp == p)
		end
		-- only the side list scrolls to it - the window stays where it is
		local row = p and rows[p]
		if row then
			task.defer(function()
				if not row.Parent then
					return
				end
				local top = row.AbsolutePosition.Y - partList.AbsolutePosition.Y + partList.CanvasPosition.Y
				local viewH = partList.AbsoluteSize.Y
				local cur = partList.CanvasPosition.Y
				if top < cur or top + row.AbsoluteSize.Y > cur + viewH then
					tween(partList, { CanvasPosition = Vector2.new(0, math.max(0, top - viewH / 2)) }, 1.2)
				end
			end)
		end
	end
	insertPartBtn.MouseButton1Click:Connect(function()
		if picked then
			insertTarget({ kind = "part", item = m, part = picked })
		end
	end)

	-- which mesh part is under the mouse (skips invisible parts like HumanoidRootPart)
	local function partAt(pos)
		local sz = vp.AbsoluteSize
		local rx = (pos.X - vp.AbsolutePosition.X) / math.max(sz.X, 1)
		local ry = (pos.Y - vp.AbsolutePosition.Y) / math.max(sz.Y, 1)
		local tanY = math.tan(math.rad(cam.FieldOfView) / 2)
		local aspect = sz.X / math.max(sz.Y, 1)
		local dir = cam.CFrame:VectorToWorldSpace(Vector3.new((rx * 2 - 1) * tanY * aspect, (1 - ry * 2) * tanY, -1)).Unit
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local skip = {}
		for _ = 1, 32 do
			params.FilterDescendantsInstances = skip
			local r = world:Raycast(cam.CFrame.Position, dir * 10000, params)
			if not r then
				return nil
			end
			local p = back[r.Instance]
			if p and (baseT[r.Instance] or 0) < 0.95 then
				return p
			end
			table.insert(skip, r.Instance)
		end
		return nil
	end

	local dragging, moved, last = false, 0, nil
	vp.MouseEnter:Connect(function()
		insList.ScrollingEnabled = false -- scroll = zoom while over the 3D view
	end)
	vp.MouseLeave:Connect(function()
		insList.ScrollingEnabled = true
		dragging = false
		hover.Text = ""
	end)
	frame.Destroying:Connect(function()
		insList.ScrollingEnabled = true
	end)
	vp.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging, moved, last = true, 0, input.Position
		end
	end)
	vp.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if dragging and last then
				local d = input.Position - last
				last = input.Position
				moved = moved + math.abs(d.X) + math.abs(d.Y)
				insp.yaw = insp.yaw - d.X * 0.012
				insp.pitch = math.clamp(insp.pitch + d.Y * 0.012, -1.45, 1.45)
				orbit()
			else
				local p = partAt(input.Position)
				hover.Text = p and p.name or ""
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			insp.zoom = math.clamp(insp.zoom * (1 - input.Position.Z * 0.12), 0.1, 6)
			orbit()
		end
	end)
	vp.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		dragging = false
		if moved > 4 then
			return
		end
		local p = partAt(input.Position)
		if p then
			selectPart(m, p)
		else
			selectModel(m) -- clicked empty space: back to the whole model
		end
	end)

	inspector = { pick = pick }
	if selected and selected.kind == "part" and selected.item == m then
		pick(selected.part)
	else
		pick(nil)
	end
end

renderInserter = function()
	if not ins.widget.Enabled then
		return
	end
	closePop(ins, true)
	clearRows(insList)
	resetThumbs(insList)
	insCards = {}
	inspector = nil
	insList.ScrollingEnabled = true
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

	local function expandModel(m)
		local open = not expanded[m.key]
		expanded = {}
		if open then
			expanded[m.key] = true
			justOpened = m.key
		end
		renderInserter()
		if open then
			local c = modelCache[m.key]
			if not (c and (c.roots or c.err)) then
				loadModel(m, function()
					if expanded[m.key] then
						renderInserter()
					end
				end)
			end
		end
	end
	infoBlock.Visible = next(expanded) == nil -- the open model view has its own details + buttons

	-- MODELS -------------------------------------------------------------
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
	groupHeader(insList, nextOrder(), string.format("MODELS  (%d)", #models), function()
		sectionOpen.models = not sectionOpen.models
		renderInserter()
	end, sectionOpen.models)
	if sectionOpen.models then
		if #models == 0 then
			makeNote(insList, "No saved or downloaded models yet.", nextOrder())
		else
			local cont = nil
			for i, m in ipairs(models) do
				if i > S.maxItems then
					break
				end
				local cache = modelCache[m.key]
				if expanded[m.key] then
					-- the open model takes the card's place, full width
					local grow = justOpened == m.key
					if grow and cache and (cache.roots or cache.err) then
						justOpened = nil
					end
					buildInspector(m, cache, nextOrder(), grow, filter)
					cont = nil
				else
					if not cont then
						cont = cardContainer(insList, nextOrder())
					end
					local detail = "press + to open it"
					if cache and cache.roots then
						detail = string.format("%d parts  -  %d meshes", cache.partCount or 0, #(cache.parts or {}))
					elseif cache and cache.err then
						detail = "can't preview (see details)"
					end
					local target = { kind = "model", item = m }
					local cd = card(cont, insList, i, {
						title = m.name,
						lines = { fmtBytes(m.bytes) .. "  -  " .. (m.date or ""), detail },
						selected = selected and selected.kind == "model" and selected.item == m,
						onClick = function()
							selectModel(m)
						end,
						loader = function(cb)
							local entry = waitModel(m)
							if entry and entry.roots then
								cb(cloneAll(entry.roots))
							else
								cb(nil, entry and entry.err)
							end
						end,
						badge = "+",
						onBadge = function()
							expandModel(m)
						end,
						actions = {
							{ text = "Insert", primary = true, closes = true, fn = function()
								insertTarget(target)
							end },
							{ text = "Open", closes = true, fn = function()
								expandModel(m)
							end },
						},
						onDrag = function(frame)
							startCardDrag(ins, frame, target, m.name)
						end,
					})
					insCards[m] = cd
				end
			end
		end
	end

	-- MESHES -------------------------------------------------------------
	local meshes = {}
	for _, m in ipairs(lib.meshes) do
		if matches(m.name, filter) or matches(m.id, filter) then
			table.insert(meshes, m)
		end
	end
	groupHeader(insList, nextOrder(), string.format("MESHES  (%d)", #meshes), function()
		sectionOpen.meshes = not sectionOpen.meshes
		renderInserter()
	end, sectionOpen.meshes)
	if sectionOpen.meshes then
		if #meshes == 0 then
			makeNote(insList, "No downloaded meshes yet.", nextOrder())
		else
			local cont = cardContainer(insList, nextOrder())
			for i, m in ipairs(meshes) do
				if i > S.maxItems then
					makeNote(insList, string.format("...and %d more - search, or raise 'Max items' in Settings.", #meshes - S.maxItems), nextOrder())
					break
				end
				local bones = tonumber(m.bones) or 0
				local target = { kind = "mesh", item = m }
				local cd = card(cont, insList, i, {
					title = m.name,
					lines = {
						m.id .. "  -  " .. tostring(m.tris or "?") .. " tris" .. (bones ~= 0 and "  -  skinned" or "") .. (m.look and "  -  textured" or ""),
						fmtSize(m.size) .. " studs  -  " .. fmtBytes(m.bytes),
					},
					selected = selected and selected.kind == "mesh" and selected.item == m,
					onClick = function()
						selectMesh(m)
					end,
					loader = function(cb)
						local tpl, err = getMeshTemplate(m)
						if tpl then
							cb({ tpl:Clone() })
						else
							cb(nil, err)
						end
					end,
					actions = {
						{ text = "Insert", primary = true, closes = true, fn = function()
							insertTarget(target)
						end },
					},
					onDrag = function(frame)
						startCardDrag(ins, frame, target, m.name)
					end,
				})
				insCards[m] = cd
			end
		end
	end
end

refreshInserter = function()
	importObjButton.Visible = S.showObjImport and true or false
	searchHolder.Size = UDim2.new(1, S.showObjImport and -184 or -86, 1, 0)
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
		lib.textures = d.textures or {}
		table.sort(lib.meshes, byName)
		table.sort(lib.models, byName)
		lib.loaded = true
		meshTemplates = {} -- looks / textures may have changed
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
			if found and selected.kind ~= "part" then
				selected.item = found
			else
				selected = nil
				setInfo("Click a card's name to see its details here.")
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
	task.delay(0.25, function()
		searchQueued = false
		renderInserter()
	end)
end)
refreshLibButton.MouseButton1Click:Connect(refreshInserter)

-- Inserting -----------------------------------------------------------------
-- What to insert for a mesh / part / model
local function instancesFor(target)
	if target.kind == "mesh" then
		local m = target.item
		local tpl, err = getMeshTemplate(m)
		if not tpl then
			return nil, "Couldn't create the mesh: " .. tostring(err)
		end
		local p = tpl:Clone()
		p.Name = m.name
		return { p }, m.name
	elseif target.kind == "part" then
		local clones = cloneAll({ target.part.inst })
		if #clones == 0 then
			return nil, "Couldn't copy that part."
		end
		applyLocalTextures(clones[1])
		return clones, target.part.name
	end
	local m = target.item
	local entry = modelCache[m.key]
	if not entry or entry.loading then
		entry = waitModel(m)
	end
	if not entry or entry.err or not entry.roots then
		return nil, (entry and entry.err) or "This model couldn't be loaded."
	end
	local clones = cloneAll(entry.roots)
	for _, c in ipairs(clones) do
		applyLocalTextures(c)
	end
	return clones, m.name
end

-- in front of the camera
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

insertTarget = function(target)
	local instances, labelOrErr = instancesFor(target)
	if not instances then
		setInsStatus(labelOrErr, RED)
		return
	end
	insertInstances(instances, labelOrErr)
	setInsStatus("Inserted " .. labelOrErr .. ".", GREEN)
end

insertButton.MouseButton1Click:Connect(function()
	if not selected then
		setInsStatus("Pick a mesh or model first (click its card).", RED)
		return
	end
	insertTarget(selected)
end)

revealButton.MouseButton1Click:Connect(function()
	if not selected then
		setInsStatus("Pick a mesh or model first (click its card).", RED)
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

-- Delete: click twice (the first click asks). Files go to the Recycle Bin.
do
	local armed, armedFor = false, nil
	deleteButton.MouseButton1Click:Connect(function()
		if not selected or (selected.kind ~= "mesh" and selected.kind ~= "model") then
			setInsStatus("Pick a mesh or model first (click its card).", RED)
			return
		end
		local target = selected
		if not armed or armedFor ~= target.item then
			armed, armedFor = true, target.item
			deleteButton.Text = "Sure? Click again"
			setInsStatus(target.kind == "mesh"
				and "Deletes this mesh from your library and from Studio (to the Recycle Bin). Parts that use it go blank after Studio restarts."
				or "Deletes this model file (to the Recycle Bin).", RED)
			task.delay(4, function()
				if armedFor == target.item then
					armed, armedFor = false, nil
					deleteButton.Text = "Delete"
				end
			end)
			return
		end
		armed, armedFor = false, nil
		deleteButton.Text = "Delete"
		local body = target.kind == "mesh" and { mesh = target.item.id } or { model = target.item.key }
		local ok, res = request("POST", "/delete", HttpService:JSONEncode(body))
		local d = ok and decodeBody(res)
		if d and d.ok then
			selected = nil
			setInfo("Click a card's name to see its details here.")
			refreshInserter()
			task.delay(0.6, function()
				setInsStatus("Deleted " .. tostring(target.item.name or target.item.id) .. " (it's in the Recycle Bin).", GREEN)
			end)
		else
			setInsStatus("Couldn't delete it - " .. tostring(d and d.error or "is Mesh Downloader open?"), RED)
		end
	end)
end

-- Drag a card into the 3D view ------------------------------------------------
-- The card lifts out and follows the mouse; once the mouse leaves the window it
-- flies back into place and the object appears under your cursor in the 3D
-- view. Let go (or click) to place it, right-click to cancel.
local pluginMouse = plugin:GetMouse()
local placing = nil
local ghost = nil

local function stopPlacing(commit)
	local p = placing
	if not p then
		return
	end
	placing = nil
	for _, c in ipairs(p.conns) do
		c:Disconnect()
	end
	pcall(function()
		plugin:Deactivate()
	end)
	if commit and p.holder.Parent then
		for _, inst in ipairs(p.instances) do
			inst.Parent = workspace
		end
		p.holder:Destroy()
		applyPivots(p.instances)
		Selection:Set(p.instances)
		p.finish(true)
		setInsStatus("Placed " .. p.label .. ".", GREEN)
	else
		pcall(function()
			p.holder:Destroy()
		end)
		p.finish(false)
		setInsStatus("Cancelled.", nil)
	end
end

local function startPlacing(target)
	if placing then
		stopPlacing(false)
	end
	local instances, labelOrErr = instancesFor(target)
	if not instances then
		setInsStatus(labelOrErr, RED)
		return
	end
	local finish = beginRecording("Drag in " .. labelOrErr)
	local holder = Instance.new("Model")
	holder.Name = "_MeshInserterPlacing"
	for _, inst in ipairs(instances) do
		inst.Parent = holder
	end
	holder.Parent = workspace
	local ok, _, size = pcall(function()
		return holder:GetBoundingBox()
	end)
	local p = {
		holder = holder, instances = instances, label = labelOrErr, finish = finish, conns = {},
		height = (ok and size) and size.Y or 2, startedAt = os.clock(),
	}
	placing = p
	pluginMouse.TargetFilter = holder
	pcall(function()
		plugin:Activate(true)
	end)
	local function follow()
		if placing ~= p then
			return
		end
		local hit = pluginMouse.Hit
		if hit then
			local okb, cf2 = pcall(function()
				return holder:GetBoundingBox()
			end)
			if okb then
				holder:TranslateBy((hit.Position + Vector3.new(0, p.height / 2, 0)) - cf2.Position)
			end
		end
	end
	table.insert(p.conns, RunService.Heartbeat:Connect(follow))
	table.insert(p.conns, pluginMouse.Button1Up:Connect(function()
		if os.clock() - p.startedAt > 0.15 then
			stopPlacing(true)
		end
	end))
	table.insert(p.conns, pluginMouse.Button1Down:Connect(function()
		stopPlacing(true)
	end))
	table.insert(p.conns, pluginMouse.Button2Down:Connect(function()
		stopPlacing(false)
	end))
	table.insert(p.conns, plugin.Deactivation:Connect(function()
		if placing == p then
			stopPlacing(true)
		end
	end))
	follow()
	setInsStatus("Let go (or click) in the 3D view to place " .. labelOrErr .. ". Right-click cancels.", nil)
end

local function returnGhost()
	local gh = ghost
	if not gh then
		return
	end
	ghost = nil
	pcall(function()
		gh.catcher:Destroy()
	end)
	local home = gh.home
	if gh.card.Parent then
		home = gh.card.AbsolutePosition - gh.layer.AbsolutePosition
	end
	tween(gh.cardScale, { Scale = 1 }, 1.2)
	local tw = tween(gh.frame, {
		Position = UDim2.fromOffset(home.X, home.Y),
		Size = UDim2.fromOffset(gh.homeSize.X, gh.homeSize.Y),
		BackgroundTransparency = 0.7,
	}, 1.4)
	if tw then
		tw.Completed:Connect(function()
			gh.frame:Destroy()
		end)
	else
		gh.frame:Destroy()
	end
end

local function leaveWindow()
	if ghost and not ghost.left then
		ghost.left = true
		local target = ghost.target
		returnGhost()
		task.spawn(startPlacing, target)
	end
end

startCardDrag = function(ctx, cardFrame, target, label_)
	if ghost then
		return
	end
	closePop(ctx, true)
	local layer = ctx.pop.layer
	local home = cardFrame.AbsolutePosition - layer.AbsolutePosition
	local size = cardFrame.AbsoluteSize
	local g = new("Frame", { Position = UDim2.fromOffset(home.X, home.Y), Size = UDim2.fromOffset(size.X, size.Y), ZIndex = 60 }, { corner(1) })
	bind(g, "BackgroundColor3", "card")
	local st = new("UIStroke", { Thickness = 2 })
	bind(st, "Color", "accent")
	st.Parent = g
	text({ Text = label_, Position = UDim2.fromOffset(8, 6), Size = UDim2.new(1, -16, 0, 18), ZIndex = 61, TextTruncate = Enum.TextTruncate.AtEnd }, 12, "bold", "text").Parent = g
	text({ Text = "drag into the 3D view", Position = UDim2.fromOffset(8, 24), Size = UDim2.new(1, -16, 0, 14), ZIndex = 61, TextTruncate = Enum.TextTruncate.AtEnd }, 10, "regular", "dim").Parent = g
	g.Parent = layer
	-- covers the window while dragging: catches "let go inside the window" and "left the window"
	local catcher = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 59 })
	catcher.Parent = layer
	local cardScale = cardFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", cardFrame)
	tween(cardScale, { Scale = 0.9 }, 1)
	ghost = {
		frame = g, catcher = catcher, layer = layer, ctx = ctx, home = home, homeSize = size, target = target,
		card = cardFrame, cardScale = cardScale, left = false, pos = Vector2.new(home.X, home.Y),
	}
	tween(g, { Size = UDim2.fromOffset(math.max(120, size.X * 0.75), 44) }, 1)
	catcher.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and ghost and not ghost.left then
			returnGhost() -- let go inside the window: put it back
		end
	end)
	catcher.MouseButton1Down:Connect(function()
		if ghost and not ghost.left then
			returnGhost()
		end
	end)
	catcher.MouseLeave:Connect(leaveWindow)
end

RunService.Heartbeat:Connect(function()
	local gh = ghost
	if not gh or gh.left then
		return
	end
	local m = gh.ctx.widget:GetRelativeMousePosition()
	local ls = gh.layer.AbsoluteSize
	if m.X < 0 or m.Y < 0 or m.X > ls.X or m.Y > ls.Y then
		leaveWindow()
		return
	end
	local target = Vector2.new(m.X - 20, m.Y - 18)
	gh.pos = gh.pos:Lerp(target, 0.35)
	gh.frame.Position = UDim2.fromOffset(gh.pos.X, gh.pos.Y)
end)

-- ---------------------------------------------------------------
-- Import .obj: converted to a .mesh right here, saved by the app, inserted as a local MeshPart
-- ---------------------------------------------------------------
do
	local StudioService = game:GetService("StudioService")

	local function baseName(path)
		path = string.gsub(tostring(path or ""), "\\", "/")
		return string.match(path, "([^/]+)$") or path
	end

	-- OBJ text -> Roblox .mesh version 2.00 (buffer). OBJ is already Y-up / front -Z
	-- (Blender's default OBJ export), the same as Roblox, so no turning needed.
	local function objToMesh(src)
		local px, py, pz, tu, tv, nx, ny, nz = {}, {}, {}, {}, {}, {}, {}, {}
		local vPos, vTex, vNrm = {}, {}, {}
		local faces = {}
		local seen = {}
		local mtllib, usemtl = nil, nil
		local count = 0

		local function vertex(tok)
			local a, b, c = string.match(tok, "^(-?%d+)/?(-?%d*)/?(-?%d*)$")
			if not a then
				return nil
			end
			local vi, ti, ni = tonumber(a), tonumber(b), tonumber(c)
			if vi < 0 then
				vi = #px + vi + 1
			end
			if ti and ti < 0 then
				ti = #tu + ti + 1
			end
			if ni and ni < 0 then
				ni = #nx + ni + 1
			end
			if not px[vi] then
				return nil
			end
			ti = (ti and tu[ti]) and ti or 0
			ni = (ni and nx[ni]) and ni or 0
			local key = vi .. "/" .. ti .. "/" .. ni
			local idx = seen[key]
			if not idx then
				table.insert(vPos, vi)
				table.insert(vTex, ti)
				table.insert(vNrm, ni)
				idx = #vPos - 1
				seen[key] = idx
			end
			return idx
		end

		for line in string.gmatch(src, "[^\r\n]+") do
			count = count + 1
			if count % 20000 == 0 then
				task.wait()
			end
			local kind, rest = string.match(line, "^%s*(%S+)%s*(.-)%s*$")
			if kind == "v" then
				local x, y, z = string.match(rest, "^(%S+)%s+(%S+)%s+(%S+)")
				table.insert(px, tonumber(x) or 0)
				table.insert(py, tonumber(y) or 0)
				table.insert(pz, tonumber(z) or 0)
			elseif kind == "vt" then
				local u, v = string.match(rest, "^(%S+)%s*(%S*)")
				table.insert(tu, tonumber(u) or 0)
				table.insert(tv, tonumber(v) or 0)
			elseif kind == "vn" then
				local x, y, z = string.match(rest, "^(%S+)%s+(%S+)%s+(%S+)")
				table.insert(nx, tonumber(x) or 0)
				table.insert(ny, tonumber(y) or 0)
				table.insert(nz, tonumber(z) or 0)
			elseif kind == "f" then
				local ids = {}
				for tok in string.gmatch(rest, "%S+") do
					local i = vertex(tok)
					if i then
						table.insert(ids, i)
					end
				end
				for k = 2, #ids - 1 do -- fan: works for triangles, quads and simple polygons
					table.insert(faces, ids[1])
					table.insert(faces, ids[k])
					table.insert(faces, ids[k + 1])
				end
			elseif kind == "mtllib" and not mtllib then
				mtllib = rest
			elseif kind == "usemtl" and not usemtl then
				usemtl = rest
			end
		end

		local nv, nf = #vPos, #faces / 3
		if nv == 0 or nf == 0 then
			error("no faces found in this .obj")
		end

		-- normals for vertices that don't have one: average of the faces around each point
		local acc = {}
		local needs = false
		for i = 1, nv do
			if vNrm[i] == 0 then
				needs = true
				break
			end
		end
		if needs then
			for f = 0, nf - 1 do
				local a, b, c = vPos[faces[f * 3 + 1] + 1], vPos[faces[f * 3 + 2] + 1], vPos[faces[f * 3 + 3] + 1]
				local A = Vector3.new(px[a], py[a], pz[a])
				local n = (Vector3.new(px[b], py[b], pz[b]) - A):Cross(Vector3.new(px[c], py[c], pz[c]) - A)
				for _, p in ipairs({ a, b, c }) do
					acc[p] = (acc[p] or Vector3.zero) + n
				end
			end
		end

		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = -lo
		for i = 1, nv do
			local p = vPos[i]
			local v = Vector3.new(px[p], py[p], pz[p])
			lo = lo:Min(v)
			hi = hi:Max(v)
		end
		local center = (lo + hi) / 2

		local b = buffer.create(13 + 12 + nv * 40 + nf * 12)
		buffer.writestring(b, 0, "version 2.00\n")
		buffer.writeu16(b, 13, 12)
		buffer.writeu8(b, 15, 40)
		buffer.writeu8(b, 16, 12)
		buffer.writeu32(b, 17, nv)
		buffer.writeu32(b, 21, nf)
		local o = 25
		for i = 1, nv do
			local p, t, n = vPos[i], vTex[i], vNrm[i]
			buffer.writef32(b, o, px[p] - center.X)
			buffer.writef32(b, o + 4, py[p] - center.Y)
			buffer.writef32(b, o + 8, pz[p] - center.Z)
			local nn
			if n > 0 then
				nn = Vector3.new(nx[n], ny[n], nz[n])
			else
				nn = acc[p] or Vector3.yAxis
			end
			if nn.Magnitude > 1e-8 then
				nn = nn.Unit
			end
			buffer.writef32(b, o + 12, nn.X)
			buffer.writef32(b, o + 16, nn.Y)
			buffer.writef32(b, o + 20, nn.Z)
			buffer.writef32(b, o + 24, t > 0 and tu[t] or 0)
			buffer.writef32(b, o + 28, t > 0 and (1 - tv[t]) or 0) -- Roblox stores V upside-down
			buffer.writef32(b, o + 32, 0)
			buffer.writeu32(b, o + 36, 0xFFFFFFFF) -- white vertex colour
			o = o + 40
		end
		for i = 1, #faces do
			buffer.writeu32(b, o, faces[i])
			o = o + 4
		end
		return b, { verts = nv, tris = nf, center = center, mtllib = mtllib, usemtl = usemtl }
	end

	-- what the .mtl says about the material the .obj uses: pictures (map_Kd colour,
	-- map_Bump / norm normal), see-through (d < 1, Tr > 0 or map_d) and colour (Kd)
	local function mtlLook(src, wanted)
		local mats, first, cur = {}, nil, nil
		local function fileOf(rest)
			local file = rest
			if string.sub(file, 1, 1) == "-" then -- options before the file name
				file = string.match(rest, "(%S+)$") or rest
			end
			return baseName(file)
		end
		for line in string.gmatch(src, "[^\r\n]+") do
			local kind, rest = string.match(line, "^%s*(%S+)%s*(.-)%s*$")
			kind = kind and string.lower(kind)
			if kind == "newmtl" then
				cur = { maps = {} }
				mats[rest] = cur
				first = first or cur
			elseif cur and kind == "map_kd" then
				cur.maps.color = fileOf(rest)
			elseif cur and (kind == "map_bump" or kind == "bump" or kind == "norm") then
				cur.maps.normal = fileOf(rest)
			elseif cur and kind == "map_d" then
				cur.alpha = true
			elseif cur and kind == "d" and (tonumber(rest) or 1) < 0.999 then
				cur.alpha = true
			elseif cur and kind == "tr" and (tonumber(rest) or 0) > 0.001 then
				cur.alpha = true
			elseif cur and kind == "kd" then
				local r, g, bb = string.match(rest, "^(%S+)%s+(%S+)%s+(%S+)")
				if r then
					-- .mtl colours are linear (like Blender's); Roblox colours are sRGB
					local function srgb(c)
						c = math.clamp(tonumber(c) or 1, 0, 1)
						return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
					end
					cur.tint = { srgb(r), srgb(g), srgb(bb) }
				end
			end
		end
		return (wanted and mats[wanted]) or first
	end

	local function pickFiles()
		local ok, files = pcall(function()
			return StudioService:PromptImportFiles({ "obj", "mtl", "png", "jpg", "jpeg" })
		end)
		if ok and type(files) == "table" then
			return files
		end
		local ok2, one = pcall(function()
			return StudioService:PromptImportFile({ "obj" })
		end)
		if ok2 and one then
			return { one }
		end
		return nil
	end

	local busy = false
	importObjButton.MouseButton1Click:Connect(function()
		if busy then
			return
		end
		local files = pickFiles()
		if not files or #files == 0 then
			return
		end
		busy = true
		local objs, mtls, imgs = {}, {}, {}
		for _, f in ipairs(files) do
			local n = string.lower(f.Name)
			if string.match(n, "%.obj$") then
				table.insert(objs, f)
			elseif string.match(n, "%.mtl$") then
				table.insert(mtls, f)
			elseif string.match(n, "%.png$") or string.match(n, "%.jpe?g$") then
				imgs[n] = f
				imgs[1] = imgs[1] or f
			end
		end
		if #objs == 0 then
			setInsStatus("Pick an .obj file (you can pick its .mtl and texture at the same time).", RED)
			busy = false
			return
		end

		local finish = beginRecording("Import .obj")
		local made, firstErr = {}, nil
		local cam = workspace.CurrentCamera
		local anchor = nil
		local function importOne(f)
			local name = string.gsub(f.Name, "%.[oO][bB][jJ]$", "")
			setInsStatus("Converting " .. f.Name .. "...", nil)
			local okC, mesh, info = pcall(function()
				return objToMesh(f:GetBinaryContents())
			end)
			if not okC then
				return nil, mesh
			end
			local okU, d = uploadToApp(mesh, name, "mesh")
			if not okU then
				return nil, d
			end
			-- material: what its .mtl names (pictures you picked), or the only picture you picked
			local mat = nil
			for _, mf in ipairs(mtls) do
				mat = mtlLook(mf:GetBinaryContents(), info.usemtl)
				if mat then
					break
				end
			end
			local look = { maps = {}, alpha = mat and mat.alpha or false, tint = mat and mat.tint or nil }
			local pics = {}
			if mat then
				for kind, file in pairs(mat.maps) do
					pics[kind] = imgs[string.lower(file)]
				end
			end
			if not pics.color and #objs == 1 and imgs[1] and imgs[1] ~= pics.normal then
				pics.color = imgs[1]
			end
			for kind, img in pairs(pics) do
				local okT, dt = uploadToApp(buffer.fromstring(img:GetBinaryContents()), name, "texture")
				if okT and dt.file then
					look.maps[kind] = dt.file
				end
			end
			if look.alpha then
				look.double = true -- see-through cards / leaves: show both sides
			end
			local part, err = createLocalMeshPart(d.id, nil, LOCAL_PART_OPTIONS)
			if not part then
				return nil, err
			end
			part.Name = name
			part.Anchored = true
			part.Material = Enum.Material.SmoothPlastic
			applyLocalLook(part, look)
			-- in front of the camera; several files keep their places relative to each other
			if not anchor then
				local sz = part.Size
				local dist = math.max(sz.X, sz.Y, sz.Z) * 1.5 + 6
				anchor = { at = cam.CFrame.Position + cam.CFrame.LookVector * dist, center = info.center }
			end
			part.CFrame = CFrame.new(anchor.at + (info.center - anchor.center))
			part.Parent = workspace
			return part
		end
		for _, f in ipairs(objs) do
			local part, err = importOne(f)
			if part then
				table.insert(made, part)
			else
				firstErr = firstErr or (f.Name .. ": " .. tostring(err))
			end
		end
		finish(#made > 0)
		if #made > 0 then
			Selection:Set(made)
			setInsStatus(
				string.format("Imported %d .obj as local mesh%s (nothing uploaded).", #made, #made == 1 and "" or "es")
					.. (firstErr and ("  Problem: " .. firstErr) or ""),
				firstErr and RED or GREEN
			)
			if refreshInserter then
				task.defer(refreshInserter)
			end
		else
			setInsStatus("Couldn't import: " .. tostring(firstErr), RED)
		end
		busy = false
	end)
end
end)() -- INSERTER BLOCK

-- =================================================================
-- SETTINGS TAB (same settings in both windows)
-- =================================================================
do -- SETTINGS BLOCK
rerenderAll = function()
	collectButton.Visible = not S.live
	applyInfoPos()
	refresh()
	renderInserter()
end

local customBoxes = {}
local function px(v)
	return v .. " px"
end
local function pct(v)
	return v .. "%"
end
local function secs(v)
	return string.format("%.1f s", v / 10)
end

local NAME_OPTIONS = {
	{ key = "part", text = "Part" },
	{ key = "parent", text = "Parent" },
	{ key = "model", text = "Model" },
	{ key = "top", text = "Top" },
	{ key = "custom", text = "Custom" },
}

local function buildSettingsPage(ctx)
	local page = ctx.pages.Settings
	local sf = new("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
	}, { vlist(6), padding(0, 12, 14, 2) })
	bind(sf, "ScrollBarImageColor3", "dim")
	flexFill(sf)
	sf.Parent = page

	local o = 0
	local function nx()
		o = o + 1
		return o
	end
	local function add(inst)
		inst.Parent = sf
		return inst
	end
	local function appearance()
		applyAppearance(true)
		rerenderAll()
	end

	add(sectionTitle("Size", nx()))
	add(slider("UI scale (whole window)", "uiScale", nx(), 60, 160, 5, pct, function()
		applyUiScale()
		task.delay(animTime(1.3), rerenderAll)
	end))
	add(slider("Text size", "textScale", nx(), 70, 150, 5, pct, appearance))
	add(slider("Card / preview size", "cardSize", nx(), 56, 220, 4, px, rerenderAll))
	add(slider("Space between cards", "gap", nx(), 0, 24, 1, px, rerenderAll))
	add(slider("Big preview size (or drag its corner)", "bigSize", nx(), 140, 700, 10, px))

	add(sectionTitle("Appearance", nx()))
	add(dimText("Theme", nx(), 11))
	add(segmented(nx(), {
		{ key = "studio", text = "Studio" },
		{ key = "dark", text = "Dark" },
		{ key = "classic", text = "Classic" },
		{ key = "midnight", text = "Midnight" },
	}, "theme", appearance))
	add(dimText("Accent colour", nx(), 11))
	add(swatches(nx(), appearance))
	add(dimText("Font", nx(), 11))
	add(segmented(nx(), {
		{ key = "gotham", text = "Gotham" },
		{ key = "sourcesans", text = "Source Sans" },
		{ key = "arial", text = "Arial" },
	}, "font", appearance))
	add(slider("Corner roundness", "corner", nx(), 0, 20, 1, px, appearance))
	add(dimText("Animations", nx(), 11))
	add(segmented(nx(), {
		{ key = "off", text = "Off" },
		{ key = "fast", text = "Fast" },
		{ key = "normal", text = "Normal" },
		{ key = "slow", text = "Slow" },
	}, "anim"))

	add(sectionTitle("Layout", nx()))
	add(segmented(nx(), {
		{ key = "grid", text = "Grid (boxes)" },
		{ key = "list", text = "List (rows)" },
	}, "layout", rerenderAll))
	add(toggle("Show details on cards", "showDetails", nx(), rerenderAll))
	add(slider("Max items shown", "maxItems", nx(), 50, 2000, 50, tostring, rerenderAll))
	add(dimText("Inserter details panel", nx(), 11))
	add(segmented(nx(), {
		{ key = "top", text = "Above the list" },
		{ key = "bottom", text = "Below the list" },
	}, "infoPos", applyInfoPos))

	add(sectionTitle("3D previews", nx()))
	add(dimText("Click a preview to open the big view. Its buttons: Keep open, Insert, Open (models), X.", nx(), 11))
	add(toggle("Also open the big view on hover", "hoverExpand", nx()))
	add(slider("Hover wait before it opens", "hoverDelay", nx(), 0, 20, 1, secs))
	add(slider("Grow / shrink speed", "expandSpeed", nx(), 0, 15, 1, secs))
	add(slider("Ignore clicks right after it opens", "clickGuard", nx(), 0, 15, 1, secs))
	add(toggle("Spin previews", "spin", nx()))
	add(slider("Spin speed", "spinSpeed", nx(), 1, 30, 1, function(v)
		return string.format("%.1fx", v / 10)
	end))
	add(dimText("Lighting", nx(), 11))
	add(segmented(nx(), {
		{ key = "follow", text = "Follows view" },
		{ key = "flat", text = "Flat (no shading)" },
	}, "lighting", rerenderAll))

	add(sectionTitle("Local copies", nx()))
	add(dimText("Parts that use a SpecialMesh (classic heads, hats, old models)", nx(), 11))
	add(segmented(nx(), {
		{ key = "auto", text = "Auto" },
		{ key = "keep", text = "Keep SpecialMesh" },
		{ key = "meshpart", text = "Make MeshPart" },
	}, "specialMeshes"))
	add(toggle("Fully local skin colour (repaints when you change it)", "bakeOverlay", nx()))
	add(dimText("On = the face picture is painted over the head's colour on your PC and repainted by itself whenever the Color changes (while this plugin and Mesh Downloader are running). Off = a SurfaceAppearance (Overlay) using the picture's Roblox ID.", nx(), 10))
	add(dimText("Auto = meshes with bones (dynamic heads) become MeshParts so FaceControls / bones work; the rest stay SpecialMesh. Keep = only the mesh link changes, so it looks exactly the same. MeshPart = always a real MeshPart; its texture goes in a SurfaceAppearance (Overlay) so the part colour still shows through.", nx(), 10))

	add(sectionTitle("Model view (Inserter)", nx()))
	add(dimText("When you pick a part in an open model", nx(), 11))
	add(segmented(nx(), {
		{ key = "xray", text = "X-ray (fade the rest)" },
		{ key = "outline", text = "Outline only" },
	}, "inspectMode", rerenderAll))
	add(toggle("Also outline the picked part in X-ray", "inspectOutline", nx(), rerenderAll))
	add(slider("Model view height", "inspectHeight", nx(), 220, 700, 10, px, rerenderAll))

	add(sectionTitle("Naming & saving", nx()))
	add(dimText("Name files by", nx(), 11))
	add(segmented(nx(), NAME_OPTIONS, "nameSource", rerenderAll, 11))
	local holder, box = textInput("Custom name (also names saved models)", nx(), S.customName)
	add(holder)
	table.insert(customBoxes, box)
	box.FocusLost:Connect(function()
		save("customName", clean(box.Text))
		for _, b in ipairs(customBoxes) do
			b.Text = S.customName
		end
		rerenderAll()
	end)
	add(toggle("Add part name (e.g. AK47_Magazine)", "addPart", nx(), rerenderAll))
	add(toggle("Add mesh ID to file names", "addId", nx(), rerenderAll))
	add(toggle("Folder per model", "folderPerModel", nx(), rerenderAll))
	local clearNames = add(button("Forget names I typed on cards", "secondary", nx()))
	clearNames.MouseButton1Click:Connect(function()
		renames = {}
		saveRenames()
		rerenderAll()
	end)

	add(sectionTitle("Pivots", nx()))
	add(dimText("Model centre", nx(), 11))
	add(segmented(nx(), {
		{ key = "middle", text = "Middle" },
		{ key = "average", text = "Average" },
	}, "pivotMode"))
	add(dimText("Middle = centre of the box around the whole model. Average = average position of all its parts (leans toward where most parts are).", nx(), 10))
	add(dimText("Reset pivots changes", nx(), 11))
	add(segmented(nx(), {
		{ key = "model", text = "Model only" },
		{ key = "parts", text = "Parts only" },
		{ key = "both", text = "Both" },
	}, "pivotScope"))
	add(dimText("Model only keeps every mesh's own pivot (offsets stay). Parts only moves each mesh's pivot to its own centre. The originals are always saved on the objects, so Restore pivots puts them back - even after saving or inserting.", nx(), 10))
	add(toggle("Reset pivots when building / saving / inserting", "pivotOnInsert", nx()))

	add(sectionTitle("Blender", nx()))
	add(dimText("Meshes sent with the Send to Studio add-on in Blender. They load from your PC - nothing is uploaded.", nx(), 10))
	add(toggle("Receive meshes from Blender", "blenderReceive", nx()))
	add(toggle("Add new Blender objects to the scene", "blenderInsert", nx()))
	add(toggle("Select a part when it arrives", "blenderSelect", nx()))
	add(toggle("Keep my Studio moves when Blender resends", "blenderKeepMoves", nx()))
	add(toggle("Build Bones + follow poses (rigged meshes)", "blenderBones", nx()))
	add(toggle("Meshes on one armature share one skeleton", "blenderShareBones", nx()))
	add(dimText("Separate parts (each with its own texture) bend with the same Bones, so the joints between them stay closed. The Bones go in one part and the parts are grouped in a model named after the armature. Off = every part gets its own copy.", nx(), 10))
	add(dimText("Off = every resend snaps the part back to where it is in Blender.", nx(), 10))
	add(toggle("Keep parts I send to Blender in sync", "blenderSync", nx()))
	add(toggle("Show the Import .obj button (Inserter)", "showObjImport", nx(), function()
		if refreshInserter then
			refreshInserter()
		end
	end))
	add(dimText("Select parts and click Send to Blender (toolbar). Moving, resizing or recolouring them here updates Blender, and editing them in Blender updates them here.", nx(), 10))

	add(sectionTitle("Collector", nx()))
	add(toggle("Live (follow what I click)", "live", nx(), rerenderAll))
	add(toggle("Download right away when sent", "autoStart", nx()))

	add(sectionTitle("Reset", nx()))
	local reset = add(button("Reset all settings to default", "secondary", nx()))
	reset.MouseButton1Click:Connect(function()
		for k, d in pairs(DEFAULTS) do
			save(k, d)
		end
		for _, b in ipairs(customBoxes) do
			b.Text = ""
		end
		applyUiScale()
		applyAppearance(true)
		syncControls(true)
		rerenderAll()
	end)
	add(dimText("Mesh Tools v" .. PLUGIN_VERSION, nx(), 10))
end

buildSettingsPage(col)
buildSettingsPage(ins)
end -- SETTINGS BLOCK

-- =================================================================
-- Wiring
-- =================================================================

collectorButton.Click:Connect(function()
	col.widget.Enabled = not col.widget.Enabled
end)
inserterButton.Click:Connect(function()
	ins.widget.Enabled = not ins.widget.Enabled
end)
openInserterButton.MouseButton1Click:Connect(function()
	ins.widget.Enabled = true
	switchTab(ins, "Library")
end)

col.onTab = function(name)
	if name == "Collector" then
		refresh()
	else
		closePop(col)
	end
end
ins.onTab = function(name)
	if name == "Library" then
		renderInserter()
	else
		closePop(ins)
	end
end

col.widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	collectorButton:SetActive(col.widget.Enabled)
	if col.widget.Enabled then
		refresh()
	end
end)
ins.widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	inserterButton:SetActive(ins.widget.Enabled)
	if ins.widget.Enabled then
		refreshInserter()
	end
end)

Studio.ThemeChanged:Connect(function()
	if S.theme == "studio" then
		applyAppearance(true)
		rerenderAll()
	end
end)

-- =================================================================
-- Blender: meshes sent with the "Send to Studio" add-on, and parts sent to Blender
-- =================================================================
;(function()
	local fromBlender -- (below) marks a part Blender just updated
	local function blenderParts(key)
		local list = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and d:GetAttribute("BlenderKey") == key then
				table.insert(list, d)
			end
		end
		return list
	end

	local function vec(t)
		if type(t) ~= "table" then
			return Vector3.zero
		end
		return Vector3.new(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0)
	end

	-- Bones from Blender (names / parents / positions in the part's space). Old ones are replaced.
	local boneCache = setmetatable({}, { __mode = "k" }) -- part -> { name -> Bone }
	local function buildBones(p, bones)
		for _, d in ipairs(p:GetChildren()) do
			if d:IsA("Bone") and d:GetAttribute("BlenderBone") then
				d:Destroy()
			end
		end
		boneCache[p] = nil
		if type(bones) ~= "table" or #bones == 0 then
			return
		end
		local made, pos, byName = {}, {}, {}
		for i, b in ipairs(bones) do
			local bone = Instance.new("Bone")
			bone.Name = tostring(b.n)
			bone:SetAttribute("BlenderBone", true)
			local here = Vector3.new(tonumber(b.x) or 0, tonumber(b.y) or 0, tonumber(b.z) or 0)
			local pi = (tonumber(b.p) or -1) + 1
			if pi >= 1 and made[pi] then
				bone.CFrame = CFrame.new(here - pos[pi])
				bone.Parent = made[pi]
			else
				bone.CFrame = CFrame.new(here)
				bone.Parent = p
			end
			made[i], pos[i] = bone, here
			byName[bone.Name] = bone
		end
		boneCache[p] = byName
	end

	local function bonesOf(p)
		local c = boneCache[p]
		if c then
			return c
		end
		c = {}
		for _, d in ipairs(p:GetDescendants()) do
			if d:IsA("Bone") then
				c[d.Name] = d
			end
		end
		boneCache[p] = c
		return c
	end

	-- One skeleton for all meshes on the same Blender armature: the Bones live in one part
	-- (the "host"), the other parts are skinned to them.
	local function rigHost(rig, except)
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and d ~= except and d:GetAttribute("BlenderRig") == rig and d:GetAttribute("BlenderRigHost") then
				return d
			end
		end
		return nil
	end
	local function rigBones(p, ev)
		local rig = ev.rig
		if not (S.blenderShareBones and type(rig) == "string" and type(ev.bones) == "table") then
			p:SetAttribute("BlenderRig", nil)
			p:SetAttribute("BlenderRigHost", nil)
			buildBones(p, ev.bones)
			return
		end
		p:SetAttribute("BlenderRig", rig)
		local host = p:GetAttribute("BlenderRigHost") and p or rigHost(rig, p)
		if host and host ~= p then
			p:SetAttribute("BlenderRigHost", nil)
			buildBones(p, nil) -- uses the host's Bones
			return
		end
		-- this part holds the skeleton. Bone positions come relative to this part's centre;
		-- every part sends the whole armature, so any of them can be the host.
		p:SetAttribute("BlenderRigHost", true)
		buildBones(p, ev.bones)
	end
	-- the folder a new part of a rig goes in: a model named after the armature
	local function rigParent(ev)
		if not (S.blenderShareBones and type(ev.rig) == "string") then
			return workspace
		end
		local other = rigHost(ev.rig)
		if not other then
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("BasePart") and d:GetAttribute("BlenderRig") == ev.rig then
					other = d
					break
				end
			end
		end
		if not other then
			local m = Instance.new("Model")
			m.Name = (ev.rigName and ev.rigName ~= "") and tostring(ev.rigName) or "Blender rig"
			m.Parent = workspace
			return m
		end
		if other.Parent == workspace then
			local m = Instance.new("Model")
			m.Name = (ev.rigName and ev.rigName ~= "") and tostring(ev.rigName) or "Blender rig"
			m.Parent = workspace
			other.Parent = m
		end
		return other.Parent
	end

	-- Live posing: Bone.Transform isn't saved with the place, so this never needs undo
	local function applyPose(ev)
		if type(ev.t) ~= "table" then
			return
		end
		for _, p in ipairs(blenderParts(ev.key)) do
			local rig = p:GetAttribute("BlenderRig")
			local bones = bonesOf((rig and S.blenderShareBones and rigHost(rig)) or p)
			for name, t in pairs(ev.t) do
				local bone = bones[name]
				if bone and type(t) == "table" and #t == 12 then
					pcall(function()
						bone.Transform = CFrame.new(table.unpack(t))
					end)
				end
			end
		end
	end

	local function stamp(p, ev, center, size)
		p:SetAttribute("BlenderKey", ev.key)
		p:SetAttribute("BlenderObject", tostring(ev.name))
		p:SetAttribute("BlenderCenter", center)
		p:SetAttribute("BlenderSize", size)
		p:SetAttribute("BlenderMeshId", tostring(ev.id))
	end

	-- Puts the new mesh on a part that's already in the scene
	local function updatePart(p, ev, center, size)
		local fresh, err = createLocalMeshPart(ev.id, p, LOCAL_PART_OPTIONS)
		if not fresh then
			return nil, err
		end
		local cf = CFrame.new(center)
		local newSize = fresh.Size
		local oldCenter = p:GetAttribute("BlenderCenter")
		local oldSize = p:GetAttribute("BlenderSize")
		if S.blenderKeepMoves and not p:GetAttribute("BlenderLinked") and typeof(oldCenter) == "Vector3" then
			-- (linked parts send their moves to Blender, so Blender's copy already has them)
			-- follow the change from Blender, but keep wherever you moved / turned it in Studio
			cf = p.CFrame * CFrame.new(center - oldCenter)
			if typeof(oldSize) == "Vector3" then
				local function ratio(a, b)
					return (b > 1e-4) and (a / b) or 1
				end
				newSize = newSize * Vector3.new(ratio(p.Size.X, oldSize.X), ratio(p.Size.Y, oldSize.Y), ratio(p.Size.Z, oldSize.Z))
			end
		end
		-- 1) swap the mesh in place (keeps the same part, scripts, welds ...)
		local swapped = pcall(function()
			p:ApplyMesh(fresh)
		end)
		if swapped then
			fresh:Destroy()
			p.Size = newSize
			p.CFrame = cf
			applyLocalLook(p, ev)
			stamp(p, ev, center, size)
			rigBones(p, ev)
			return p
		end

		-- 2) otherwise replace the part, keeping its settings and children
		for _, prop in ipairs(COPY_PROPS) do
			if prop ~= "Size" and prop ~= "CFrame" and prop ~= "PivotOffset" and prop ~= "TextureID" then
				pcall(function()
					fresh[prop] = p[prop]
				end)
			end
		end
		pcall(function()
			fresh.TextureID = p.TextureID
		end)
		copyAttributesAndTags(p, fresh)
		fresh.Size = newSize
		fresh.CFrame = cf
		for _, child in ipairs(p:GetChildren()) do
			if child:IsA("SpecialMesh") or child:IsA("FileMesh") then
				child:Destroy() -- the part now is the mesh
			else
				pcall(function()
					child.Parent = fresh
				end)
			end
		end
		applyLocalLook(fresh, ev)
		stamp(fresh, ev, center, size)
		fresh.Parent = p.Parent
		rigBones(fresh, ev)
		local sel = Selection:Get()
		local wasSelected = false
		for i, v in ipairs(sel) do
			if v == p then
				sel[i] = fresh
				wasSelected = true
			end
		end
		p:Destroy()
		if wasSelected then
			Selection:Set(sel)
		end
		return fresh
	end

	-- ---------------------------------------------------------------
	-- Studio -> Blender: "Send to Blender" (toolbar). The part shows up in Blender and stays
	-- linked both ways: move / resize / recolour it here and Blender follows, edit it in
	-- Blender and this part updates.
	-- ---------------------------------------------------------------
	local quiet = setmetatable({}, { __mode = "k" }) -- part -> os.clock() until which changes are Blender's
	local lastSent = setmetatable({}, { __mode = "k" }) -- part -> what Blender was last told (JSON)
	local linked = setmetatable({}, { __mode = "k" }) -- part -> its connections
	local dirty = setmetatable({}, { __mode = "k" })

	local function meshHolder(p)
		if p:IsA("MeshPart") then
			return nil
		end
		for _, d in ipairs(p:GetChildren()) do
			if (d:IsA("SpecialMesh") and d.MeshType == Enum.MeshType.FileMesh) or d:IsA("FileMesh") then
				return d
			end
		end
		return nil
	end

	-- What Blender needs to rebuild the part (nil = not a mesh Blender can get)
	local function describe(p)
		local holder = meshHolder(p)
		local meshUri, tex, look, cf = "", "", "opaque", p.CFrame
		local ev = {
			key = p:GetAttribute("BlenderKey"),
			name = p.Name,
			color = { p.Color.R, p.Color.G, p.Color.B },
			transparency = p.Transparency,
		}
		if p:IsA("MeshPart") then
			meshUri = meshIdOf(p)
			tex = textureOf(p)
			ev.size = { p.Size.X, p.Size.Y, p.Size.Z }
			ev.centerMesh = true -- a MeshPart shows its mesh centred on the part
			for _, d in ipairs(p:GetChildren()) do
				if d:IsA("SurfaceAppearance") then
					local cm = ""
					pcall(function()
						cm = tostring(d.ColorMap)
					end)
					if cm == "" then
						cm = contentUri(d, "ColorMapContent")
					end
					if cm ~= "" then
						tex = cm
					end
					local okA, mode = pcall(function()
						return d.AlphaMode
					end)
					if okA and mode == Enum.AlphaMode.Overlay then
						look = "overlay"
					elseif okA and mode == Enum.AlphaMode.Transparency then
						look = "alpha"
					end
					break
				end
			end
			local file = p:GetAttribute("MeshToolsTextureFile")
			if type(file) == "string" then
				tex, look = file, "overlay" -- painted head: Blender gets the unpainted picture + colour
			end
		elseif holder then
			meshUri = holder.MeshId
			tex = holder.TextureId
			look = "overlay" -- SpecialMeshes show the part colour through see-through spots
			ev.scale = { holder.Scale.X, holder.Scale.Y, holder.Scale.Z }
			cf = p.CFrame * CFrame.new(holder.Offset)
		else
			return nil
		end
		ev.meshId = idFrom(meshUri)
		if not ev.meshId then
			return nil
		end
		local file = string.match(tex, "^[%w_%.%-]+%.%a+$") or string.match(tex, "meshtools/textures/([%w_%.%-]+%.%a+)$")
		if file then
			ev.texture = file
		elseif tex ~= "" then
			ev.textureId = idFrom(tex)
		end
		ev.look = look
		ev.cframe = { cf:GetComponents() }
		return ev
	end

	local function post(list, live)
		local ok, res = request("POST", "/toblender", HttpService:JSONEncode({ parts = list, live = live }))
		return ok and decodeBody(res) or nil
	end

	local function mark(p)
		if (quiet[p] or 0) < os.clock() then
			dirty[p] = true
		end
	end

	local function link(p)
		if linked[p] then
			return
		end
		local conns = {}
		local function watch(inst, props)
			for _, prop in ipairs(props) do
				pcall(function()
					table.insert(conns, inst:GetPropertyChangedSignal(prop):Connect(function()
						mark(p)
					end))
				end)
			end
		end
		watch(p, { "CFrame", "Size", "Color", "Transparency", "TextureID", "MeshId", "Name" })
		local holder = meshHolder(p)
		if holder then
			watch(holder, { "MeshId", "TextureId", "Scale", "Offset" })
		end
		table.insert(conns, p.ChildAdded:Connect(function()
			mark(p)
		end))
		table.insert(conns, p.ChildRemoved:Connect(function()
			mark(p)
		end))
		linked[p] = conns
	end

	-- a part Blender just updated: remember it as is, so it isn't sent straight back
	fromBlender = function(p)
		quiet[p] = os.clock() + 0.75
		if p:GetAttribute("BlenderLinked") then
			task.defer(function()
				link(p)
				local ev = describe(p)
				lastSent[p] = ev and HttpService:JSONEncode(ev) or nil
			end)
		end
	end

	local function sendSelection()
		local parts, seen = {}, {}
		local function consider(inst)
			if inst:IsA("SpecialMesh") or inst:IsA("FileMesh") then
				inst = inst.Parent
			end
			if inst and inst:IsA("BasePart") and not seen[inst] and describe(inst) then
				seen[inst] = true
				table.insert(parts, inst)
			end
		end
		for _, s in ipairs(Selection:Get()) do
			consider(s)
			for _, d in ipairs(s:GetDescendants()) do
				consider(d)
			end
		end
		if #parts == 0 then
			warn("[Mesh Tools] Send to Blender: select MeshParts (or parts with a SpecialMesh) first.")
			return
		end
		local finish = beginRecording("Send to Blender")
		local list = {}
		for _, p in ipairs(parts) do
			local key = p:GetAttribute("BlenderKey")
			if type(key) ~= "string" or not string.match(key, "^%x+$") or #key < 6 then
				p:SetAttribute("BlenderKey", string.lower((string.gsub(HttpService:GenerateGUID(false), "%W", ""))))
			end
			p:SetAttribute("BlenderLinked", true)
			local ev = describe(p)
			lastSent[p] = HttpService:JSONEncode(ev)
			table.insert(list, ev)
			link(p)
		end
		finish(true)
		local d = post(list, false)
		if not d then
			warn("[Mesh Tools] Send to Blender: open Mesh Downloader first.")
		elseif (d.ready or 0) + (d.waiting or 0) == 0 then
			warn("[Mesh Tools] Send to Blender: none of these meshes have a Roblox ID Mesh Downloader can get.")
		else
			local msg = string.format("[Mesh Tools] Sent %d part(s) to Blender", (d.ready or 0) + (d.waiting or 0))
			if (d.waiting or 0) > 0 then
				msg = msg .. string.format(" - %d downloading first%s", d.waiting, d.hasKey and "" or " (needs your API key in Mesh Downloader)")
			end
			print(msg .. ". Turn on 'Receive from Studio' in Blender's Roblox panel if nothing shows up.")
		end
	end

	-- "Send Rig to Blender": only the skeleton (Motor6D joints + Bones) of the selected
	-- model, as a Blender armature. Works when the meshes are gone - in Blender, put the
	-- shapes back with "Attach meshes to rig".
	local function rigOf(model)
		local bones, partBone, names = {}, {}, {}
		local function add(name, pos, parent, part)
			local rec = { n = name, p = parent or -1, pos = { pos.X, pos.Y, pos.Z } }
			if part then
				rec.part = part.Name
				rec.pcf = { part.CFrame:GetComponents() }
				rec.size = { part.Size.X, part.Size.Y, part.Size.Z }
			end
			table.insert(bones, rec)
			names[name] = #bones - 1
			return #bones - 1
		end
		local motors, parts = {}, {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Motor6D") and d.Part0 and d.Part1 then
				table.insert(motors, d)
			elseif d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		local isChild = {}
		for _, m in ipairs(motors) do
			isChild[m.Part1] = true
		end
		local root = (model:IsA("Model") and model.PrimaryPart) or model:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			root = nil
			for _, m in ipairs(motors) do
				if not isChild[m.Part0] then
					root = m.Part0
					break
				end
			end
		end
		root = root or parts[1]
		if not root then
			return nil
		end
		partBone[root] = add(root.Name, root.Position, -1, root)
		-- joints, parents first
		local left = #motors
		while left > 0 do
			local progress = false
			for _, m in ipairs(motors) do
				if partBone[m.Part0] and not partBone[m.Part1] then
					local joint = (m.Part0.CFrame * m.C0).Position
					partBone[m.Part1] = add(m.Part1.Name, joint, partBone[m.Part0], m.Part1)
					left = left - 1
					progress = true
				end
			end
			if not progress then
				break
			end
		end
		-- parts with no joint still get a bone (so their mesh has something to follow)
		for _, pt in ipairs(parts) do
			if not partBone[pt] and not names[pt.Name] then
				partBone[pt] = add(pt.Name, pt.Position, partBone[root], pt)
			end
		end
		-- Bones (skinned rigs). One named like a part is the same joint: skipped.
		local boneIndex = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Bone") and not names[d.Name] then
				local parent = d.Parent
				local pi = nil
				if parent and parent:IsA("Bone") then
					pi = boneIndex[parent]
				end
				if not pi then
					local host = d:FindFirstAncestorWhichIsA("BasePart")
					pi = (host and partBone[host]) or partBone[root]
				end
				boneIndex[d] = add(d.Name, d.WorldPosition, pi, nil)
			elseif d:IsA("Bone") then
				boneIndex[d] = names[d.Name]
			end
		end
		return bones
	end

	local rigButton = toolbar:CreateButton("Send Rig to Blender", "Send only the skeleton (joints + Bones) of the selected model to Blender - works even when its meshes are missing", "")
	rigButton.ClickableWhenViewportHidden = true
	rigButton.Click:Connect(function()
		rigButton:SetActive(false)
		local ok, err = pcall(function()
			local list = {}
			for _, sel in ipairs(Selection:Get()) do
				local model = sel:IsA("BasePart") and (sel:FindFirstAncestorWhichIsA("Model") or sel) or sel
				local bones = rigOf(model)
				if bones and #bones > 0 then
					local key = model:GetAttribute("BlenderRigKey")
					if type(key) ~= "string" then
						key = string.lower((string.gsub(HttpService:GenerateGUID(false), "%W", "")))
						model:SetAttribute("BlenderRigKey", key)
					end
					table.insert(list, { type = "rig", key = key, name = model.Name, bones = bones })
				end
			end
			if #list == 0 then
				warn("[Mesh Tools] Send Rig to Blender: select a rig (a model with Motor6Ds or Bones) first.")
				return
			end
			local d = post(list, false)
			if not d then
				warn("[Mesh Tools] Send Rig to Blender: open Mesh Downloader first.")
			else
				print(string.format("[Mesh Tools] Sent %d rig(s) to Blender (%d bones).", #list, #list[1].bones))
			end
		end)
		if not ok then
			warn("[Mesh Tools] Send Rig to Blender: " .. tostring(err))
		end
	end)

	local sendButton = toolbar:CreateButton("Send to Blender", "Send the selected mesh parts to Blender - they stay linked both ways", "")
	sendButton.ClickableWhenViewportHidden = true
	sendButton.Click:Connect(function()
		sendButton:SetActive(false)
		local ok, err = pcall(sendSelection)
		if not ok then
			warn("[Mesh Tools] Send to Blender: " .. tostring(err))
		end
	end)

	-- linked parts from before (place reopened) and copies: a Ctrl+D copy isn't linked
	local function found(d)
		if d:IsA("BasePart") and d:GetAttribute("BlenderLinked") then
			local key = d:GetAttribute("BlenderKey")
			for other in pairs(linked) do
				if other ~= d and other.Parent and other:GetAttribute("BlenderKey") == key then
					d:SetAttribute("BlenderLinked", nil)
					d:SetAttribute("BlenderKey", nil)
					return
				end
			end
			link(d)
			local ev = describe(d)
			lastSent[d] = ev and HttpService:JSONEncode(ev) or nil
		end
	end
	task.defer(function()
		for _, d in ipairs(workspace:GetDescendants()) do
			found(d)
		end
		workspace.DescendantAdded:Connect(function(d)
			task.defer(found, d)
		end)
	end)

	-- send what changed, a few times a second while you drag
	task.spawn(function()
		while alive do
			task.wait(0.15)
			if next(dirty) and S.blenderSync and not RunService:IsRunning() then
				local list, parts = {}, {}
				for p in pairs(dirty) do
					dirty[p] = nil
					if p.Parent and p:IsDescendantOf(workspace) and p:GetAttribute("BlenderLinked") then
						local ev = describe(p)
						local json = ev and HttpService:JSONEncode(ev)
						if json and json ~= lastSent[p] then
							table.insert(list, ev)
							table.insert(parts, { p, json })
						end
					end
				end
				if #list > 0 and post(list, true) then
					for _, pj in ipairs(parts) do
						lastSent[pj[1]] = pj[2]
					end
				end
			end
		end
	end)

	local function handleBlender(ev)
		if type(ev) ~= "table" or type(ev.key) ~= "string" then
			return
		end
		if ev.type == "pose" then
			if S.blenderBones then
				applyPose(ev)
			end
			return
		end
		if not S.blenderBones then
			ev.bones = nil -- the mesh still comes in, just without Bone objects
		end
		if not tostring(ev.id or ""):match("^%d+$") then
			return
		end
		ev.id = tostring(ev.id)
		local center, size = vec(ev.center), vec(ev.size)
		local existing = blenderParts(ev.key)
		if #existing == 0 and not S.blenderInsert then
			return
		end
		local finish = beginRecording("Blender: " .. tostring(ev.name))
		local done, firstErr = 0, nil
		if #existing > 0 then
			for _, p in ipairs(existing) do
				fromBlender(p)
				local ok, err = updatePart(p, ev, center, size)
				if ok then
					fromBlender(ok)
					done = done + 1
				else
					firstErr = firstErr or err
				end
			end
		else
			local p, err = createLocalMeshPart(ev.id, nil, LOCAL_PART_OPTIONS)
			if p then
				p.Name = tostring(ev.name)
				p.Anchored = true
				p.Material = Enum.Material.SmoothPlastic -- Roblox's Plastic has a faint pattern Blender doesn't
				p.CFrame = CFrame.new(center)
				applyLocalLook(p, ev)
				stamp(p, ev, center, size)
				p.Parent = rigParent(ev)
				rigBones(p, ev)
				fromBlender(p)
				done = 1
				if S.blenderSelect then
					Selection:Set({ p })
				end
				print(string.format("[Mesh Tools] Blender: added %s (local mesh, nothing uploaded)", p.Name))
				if ins and ins.widget.Enabled and refreshInserter then
					task.defer(refreshInserter)
				end
			else
				firstErr = err
			end
		end
		finish(done > 0)
		if firstErr then
			warn(string.format("[Mesh Tools] Blender: couldn't load %s - %s", tostring(ev.name), tostring(firstErr)))
		end
	end

	task.spawn(function()
		local fails = 0
		local activeUntil = 0 -- poll fast for a while after something arrives (live posing)
		while alive do
			local waitFor = 1
			if S.blenderReceive and not RunService:IsRunning() then
				local ok, res = request("GET", "/blender/next")
				if ok then
					fails = 0
					local d = decodeBody(res)
					if d and type(d.events) == "table" and #d.events > 0 then
						activeUntil = os.clock() + 8
					end
					if os.clock() < activeUntil then
						waitFor = 0.1
					end
					if d and type(d.events) == "table" then
						for _, ev in ipairs(d.events) do
							local okH, e = pcall(handleBlender, ev)
							if not okH then
								warn("[Mesh Tools] Blender: " .. tostring(e))
							end
						end
					end
				else
					fails = fails + 1
					waitFor = math.min(5, 1 + fails) -- app closed: check less often
				end
			else
				waitFor = 2
			end
			task.wait(waitFor)
		end
	end)
end)()

-- Downloader status + update check (only while a window is open)
task.spawn(function()
	while alive do
		if col.widget.Enabled or ins.widget.Enabled then
			local ok, res = request("GET", "/ping")
			setLink(ok)
			if ok then
				local d = decodeBody(res)
				if d and d.version then
					appVersion = tostring(d.version)
				end
			end
			if os.time() - lastUpdateCheck > 1800 then
				checkForUpdate()
			end
		end
		task.wait(3)
	end
end)

switchTab(col, "Collector", true)
switchTab(ins, "Library", true)
collectorButton:SetActive(col.widget.Enabled)
inserterButton:SetActive(ins.widget.Enabled)
refresh()
if ins.widget.Enabled then
	refreshInserter()
end
