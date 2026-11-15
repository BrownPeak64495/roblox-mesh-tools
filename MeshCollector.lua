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

local PLUGIN_VERSION = "4.0" -- keep in sync with version.json
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
	-- appearance
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
	hoverEnlarge = true,
	hoverDelay = 4, -- tenths of a second
	bigSize = 240,
	lighting = "follow", -- follow | flat
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
	-- colours are looked up by name so a missing one can't break the plugin
	local function g(name, hover)
		local ok, v = pcall(function()
			if hover then
				return th:GetColor(C[name], Enum.StudioStyleGuideModifier.Hover)
			end
			return th:GetColor(C[name])
		end)
		return ok and v or nil
	end
	local bg = g("MainBackground") or rgb(46, 46, 46)
	return {
		bg = bg, panel = bg, input = g("InputFieldBackground") or rgb(37, 37, 37), border = g("Border") or rgb(34, 34, 34),
		text = g("MainText") or rgb(220, 220, 220), dim = g("DimmedText") or rgb(140, 140, 140),
		button = g("Button") or rgb(60, 60, 60), buttonText = g("ButtonText") or rgb(220, 220, 220),
		card = g("InputFieldBackground") or rgb(37, 37, 37), cardHover = g("Button", true) or rgb(70, 70, 70),
		preview = g("ViewPortBackground") or rgb(30, 30, 30), header = g("Titlebar") or rgb(53, 53, 53),
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
		if S.partPivots then
			centerPartPivots(r)
		end
		setModelPivot(r, S.modelPivot)
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
		id = id, widget = widget, root = root, holder = holder, pages = {}, tabs = {},
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

-------------------------------------------------------------------
-- 3D previews: small spinning ones on every card + a pop-up that
-- smoothly grows out of the card you hover / click.
-------------------------------------------------------------------
local thumbLists = {} -- list -> { ctx, thumbs }
local loadingThumbs = 0
local MAX_LOADING = 2

local function registerThumbList(list, ctx)
	thumbLists[list] = { ctx = ctx, thumbs = {} }
end

local function resetThumbs(list)
	local e = thumbLists[list]
	if e then
		e.thumbs = {}
	end
end

local function stripScripts(inst)
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

local function orbitCamera(o)
	local fov = math.rad(o.cam.FieldOfView)
	local dist = (o.radius / math.sin(fov / 2)) * o.zoom
	local rot = CFrame.Angles(0, o.yaw, 0) * CFrame.Angles(-o.pitch, 0, 0)
	o.cam.CFrame = CFrame.lookAt(rot * Vector3.new(0, 0, dist), Vector3.zero)
	if S.lighting ~= "flat" then
		o.vp.LightDirection = o.cam.CFrame.LookVector -- light follows the view: the side you see is lit
	end
end

local function newViewport(props)
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

local function frameContent(o, holder)
	local ok, cf, size = pcall(function()
		return holder:GetBoundingBox()
	end)
	if ok and size and size.Magnitude > 0 then
		holder:TranslateBy(-cf.Position)
		o.radius = math.max(size.Magnitude / 2, 0.1)
	else
		o.radius = 2
	end
end

local function attachPop(ctx)
	local layer = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40 })
	layer.Parent = ctx.widget
	local box = new("Frame", { Visible = false, ZIndex = 41 }, { corner(1.5) })
	bind(box, "BackgroundColor3", "panel")
	local st = new("UIStroke", { Thickness = 2 })
	bind(st, "Color", "accent")
	st.Parent = box
	box.Parent = layer
	local vp, cam, world = newViewport({ Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -38), ZIndex = 42, Active = true })
	corner(1).Parent = vp
	vp.Parent = box
	local title = text({ Position = UDim2.new(0, 10, 1, -30), Size = UDim2.new(1, -130, 0, 26), ZIndex = 42, TextTruncate = Enum.TextTruncate.AtEnd }, 12, "bold", "text")
	title.Parent = box
	local hint = text({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 1, -30), Size = UDim2.new(0, 120, 0, 26), ZIndex = 42, TextXAlignment = Enum.TextXAlignment.Right }, 10, "regular", "dim")
	hint.Parent = box
	local pop = {
		ctx = ctx, layer = layer, box = box, stroke = st, vp = vp, cam = cam, world = world, title = title, hint = hint,
		open = false, pinned = false, src = nil, radius = 1, yaw = 0, pitch = 0.35, zoom = 1,
		dragging = false, moved = 0, last = nil, outside = 0,
	}
	local function renderHint()
		hint.Text = pop.pinned and "kept open - click to let go" or "click to keep open"
		tween(st, { Thickness = pop.pinned and 3 or 2 })
	end
	pop.renderHint = renderHint
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
			if pop.moved <= 4 then
				pop.pinned = not pop.pinned
				renderHint()
			end
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
	ctx.pop = pop
	return pop
end

local function openPop(ctx, t, pin)
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
	pop.pinned = pin and true or false
	pop.renderHint()
	local lp, ls = pop.layer.AbsolutePosition, pop.layer.AbsoluteSize
	local sp, ss = t.vp.AbsolutePosition - lp, t.vp.AbsoluteSize
	local big = math.max(120, math.min(S.bigSize, ls.X - 16, ls.Y - 54))
	local bw, bh = big, big + 32
	local tx = math.clamp(sp.X + ss.X / 2 - bw / 2, 8, math.max(8, ls.X - bw - 8))
	local ty = math.clamp(sp.Y + ss.Y / 2 - bh / 2, 8, math.max(8, ls.Y - bh - 8))
	if not pop.open then
		pop.box.Position = UDim2.fromOffset(sp.X, sp.Y)
		pop.box.Size = UDim2.fromOffset(ss.X, ss.Y)
	end
	pop.box.Visible = true
	pop.open = true
	pop.outside = 0
	setupLighting(pop.vp, pop.cam)
	orbitCamera(pop)
	tween(pop.box, { Position = UDim2.fromOffset(tx, ty), Size = UDim2.fromOffset(bw, bh) }, 1.6)
end

local function closePop(ctx)
	local pop = ctx.pop
	if not pop or not pop.open then
		return
	end
	pop.open = false
	pop.pinned = false
	pop.dragging = false
	local t = pop.src
	local function hide()
		if not pop.open then
			pop.box.Visible = false
			pop.world:ClearAllChildren()
		end
	end
	if t and t.vp.Parent and t.vp.AbsoluteSize.X > 0 and animTime() > 0 then
		local sp = t.vp.AbsolutePosition - pop.layer.AbsolutePosition
		local tw = tween(pop.box, {
			Position = UDim2.fromOffset(sp.X, sp.Y),
			Size = UDim2.fromOffset(t.vp.AbsoluteSize.X, t.vp.AbsoluteSize.Y),
		}, 1.3)
		if tw then
			tw.Completed:Connect(hide)
		else
			hide()
		end
	else
		hide()
	end
end

local function thumbSetContent(t, instances)
	t.world:ClearAllChildren()
	t.holder = nil
	if not instances or #instances == 0 then
		t.state = "empty"
		t.note.Text = "no preview"
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
	t.note.Visible = false
	orbitCamera(t)
	-- fade in
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
		vp = vp, cam = cam, world = world, note = note, loader = o.loader, title = o.title, ctx = entry.ctx,
		state = "idle", radius = 1, yaw = math.random() * math.pi * 2, pitch = 0.35, zoom = 1,
		hovering = false, dragging = false, hoverToken = 0, moved = 0, last = nil,
	}
	vp.MouseEnter:Connect(function()
		t.hovering = true
		t.hoverToken = t.hoverToken + 1
		local tok = t.hoverToken
		if S.hoverEnlarge then
			task.delay(S.hoverDelay / 10, function()
				if t.hovering and tok == t.hoverToken and t.holder then
					openPop(t.ctx, t, false)
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
				openPop(t.ctx, t, true)
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

-- Load previews for cards you can see, spin them, and manage the pop-ups
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
								local ok = pcall(t.loader, function(instances)
									if vp.Parent then
										thumbSetContent(t, instances)
									end
								end)
								if not ok and t.state == "loading" then
									t.state = "empty"
									t.note.Text = "no preview"
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
				closePop(ctx)
			else
				local m = ctx.widget:GetRelativeMousePosition()
				local bp = pop.box.AbsolutePosition - pop.layer.AbsolutePosition
				local bs = pop.box.AbsoluteSize
				local inside = m.X >= bp.X - 6 and m.X <= bp.X + bs.X + 6 and m.Y >= bp.Y - 6 and m.Y <= bp.Y + bs.Y + 6
				if inside or pop.pinned or pop.dragging then
					pop.outside = 0
				else
					pop.outside = pop.outside + dt
					if pop.outside > 0.2 then
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

local function cardContainer(list, order)
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
			local w = f.AbsoluteSize.X
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

-- o = { title, lines, selected, onClick, loader, badge, onBadge }
local function card(container, list, order, o)
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

	local t = makeThumb(list, { loader = o.loader, title = o.title })
	corner(0.75).Parent = t.vp
	t.vp.Parent = c

	local title = text({ Text = o.title or "", TextTruncate = Enum.TextTruncate.AtEnd }, 13, "bold", "text")
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
	c.MouseButton1Click:Connect(o.onClick)
	c.Parent = container
	return { frame = c, paint = paint, thumb = t }
end

-- Full-width header row (optionally with a turning arrow)
local function groupHeader(list, order, label_, onClick, open)
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

local function makeNote(parent, str, order)
	text({ Size = UDim2.new(1, 0, 0, 34), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Text = str, LayoutOrder = order }, 12, "regular", "dim").Parent = parent
end

local function clearRows(frame)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function scrollList(order)
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

-- =================================================================
-- MESH COLLECTOR
-- =================================================================
local col = makeWidget("MeshCollectorV2", "Mesh Collector  v" .. PLUGIN_VERSION, 380, 700, { "Collector", "Settings" })
attachPop(col)
local colPage = col.pages.Collector

local summary = dimText("Select a model or part in Explorer.", 1)
summary.Parent = colPage

local refresh -- forward
local refreshInserter -- forward
local rerenderAll -- forward

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

local collectButton = button("Collect current selection", "secondary", 4)
collectButton.Visible = not S.live
collectButton.Parent = colPage

local listHeader = text({ Text = "Meshes (0)", Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 5 }, 13, "bold", "text")
listHeader.Parent = colPage

local listFrame = scrollList(6)
listFrame.Parent = colPage
registerThumbList(listFrame, col)

local sendButton = button("Send to Downloader", "primary", 7)
sendButton.Parent = colPage
local buildButton = button("Build local copy (real MeshParts, local .mesh)", "secondary", 8)
buildButton.Parent = colPage
local saveModelButton = button("Save model", "secondary")
local pivotButton = button("Apply pivots", "secondary")
buttonRow(9, { saveModelButton, pivotButton }).Parent = colPage
local copyButton = button("Copy list", "secondary")
local openInserterButton = button("Open Inserter", "secondary")
buttonRow(10, { copyButton, openInserterButton }).Parent = colPage

local statusLine = dimText("", 11, 11)
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
local frozenSelection = {}
local currentEntries = {}
local suppressLiveUntil = 0
local colSelected = nil
local colCards = {} -- part -> card

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
		table.insert(entries, { id = id, name = meshBaseName(owner), folder = folderFor(owner), owner = owner, model = m })
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
	listHeader.Text = string.format("Meshes (%d)", #entries)

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
				lines = {
					e.id .. "  -  " .. e.owner.ClassName,
					partSizeText(e.owner) .. (e.folder and ("  ->  " .. e.folder .. "/") or ""),
				},
				selected = (colSelected == e.owner),
				onClick = function()
					selectInStudio(e.owner)
				end,
				loader = function(cb)
					local ok, c = pcall(function()
						return e.owner:Clone()
					end)
					cb((ok and c) and { c } or nil)
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
		table.insert(items, { id = e.id, name = e.name, folder = e.folder, noId = not S.addId })
	end
	setStatus("Sending...", nil)
	local ok = request("POST", "/queue", HttpService:JSONEncode({ autoStart = S.autoStart, items = items }))
	setLink(ok)
	if ok then
		local verb = S.autoStart and "Downloading" or "Queued"
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
	if S.modelPivot == "keep" and not S.partPivots then
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
-- =================================================================
-- MESH INSERTER
-- =================================================================
local ins = makeWidget("MeshInserterV3", "Mesh Inserter", 400, 720, { "Library", "Settings" })
attachPop(ins)
local insPage = ins.pages.Library

local searchHolder, searchBox = textInput("Search meshes and models...", 1)
local refreshLibButton = button("Refresh", "secondary")
local searchRow = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 1 }, { hlist(6) })
searchHolder.Size = UDim2.new(1, -86, 1, 0)
searchHolder.LayoutOrder = 1
searchHolder.Parent = searchRow
refreshLibButton.Size = UDim2.new(0, 80, 1, 0)
refreshLibButton.LayoutOrder = 2
refreshLibButton.Parent = searchRow
searchRow.Parent = insPage

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
buttonRow(2, { insertButton, revealButton }).Parent = infoBlock
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

local function applyInfoPos()
	infoBlock.LayoutOrder = (S.infoPos == "top") and 2 or 5
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
local lib = { meshes = {}, models = {}, loaded = false }
local sectionOpen = { models = true, meshes = true }
local expanded = {}
local modelCache = {}
local meshTemplates = {}
local selected = nil
local selectToken = 0
local insCards = {} -- item/part table -> card
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
end

local function selectModel(m)
	selectToken = selectToken + 1
	local token = selectToken
	selected = { kind = "model", item = m }
	showModelInfo(m, modelCache[m.key])
	updateInsHighlights()
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
end

local function matches(str, filter)
	if filter == "" then
		return true
	end
	return string.find(string.lower(tostring(str or "")), filter, 1, true) ~= nil
end

renderInserter = function()
	if not ins.widget.Enabled then
		return
	end
	closePop(ins)
	clearRows(insList)
	resetThumbs(insList)
	insCards = {}
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
			local cont = cardContainer(insList, nextOrder())
			for i, m in ipairs(models) do
				if i > S.maxItems then
					break
				end
				local cache = modelCache[m.key]
				local detail = "press + to see its meshes"
				if cache and cache.roots then
					detail = string.format("%d parts  -  %d meshes", cache.partCount or 0, #(cache.parts or {}))
				elseif cache and cache.err then
					detail = "can't preview (see details)"
				end
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
							cb(nil)
						end
					end,
					badge = expanded[m.key] and "-" or "+",
					onBadge = function()
						expanded[m.key] = not expanded[m.key]
						if expanded[m.key] then
							loadModel(m, function()
								renderInserter()
							end)
						end
						renderInserter()
					end,
				})
				insCards[m] = cd
			end
		end

		-- expanded models: their meshes
		for _, m in ipairs(models) do
			if expanded[m.key] then
				local cache = modelCache[m.key]
				local count = (cache and cache.parts) and #cache.parts or 0
				groupHeader(insList, nextOrder(), string.format("%s  -  meshes (%d)   [click to close]", m.name, count), function()
					expanded[m.key] = nil
					renderInserter()
				end)
				if not cache or cache.loading then
					makeNote(insList, "Loading...", nextOrder())
				elseif cache.err then
					makeNote(insList, cache.err, nextOrder())
				elseif #cache.parts == 0 then
					makeNote(insList, "No meshes in this model.", nextOrder())
				else
					local cont = cardContainer(insList, nextOrder())
					local shown = 0
					for _, p in ipairs(cache.parts) do
						if filter == "" or matches(m.name, filter) or matches(p.name, filter) or matches(p.id, filter) then
							shown = shown + 1
							if shown > S.maxItems then
								break
							end
							local cd = card(cont, insList, shown, {
								title = p.name,
								lines = { p.id .. "  -  " .. p.inst.ClassName, p.path },
								selected = selected and selected.kind == "part" and selected.part == p,
								onClick = function()
									selectPart(m, p)
								end,
								loader = function(cb)
									cb(cloneAll({ p.inst }))
								end,
							})
							insCards[p] = cd
						end
					end
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
				local cd = card(cont, insList, i, {
					title = m.name,
					lines = {
						m.id .. "  -  " .. tostring(m.tris or "?") .. " tris" .. (bones ~= 0 and "  -  skinned" or ""),
						fmtSize(m.size) .. " studs  -  " .. fmtBytes(m.bytes),
					},
					selected = selected and selected.kind == "mesh" and selected.item == m,
					onClick = function()
						selectMesh(m)
					end,
					loader = function(cb)
						local tpl = getMeshTemplate(m.id)
						cb(tpl and { tpl:Clone() } or nil)
					end,
				})
				insCards[m] = cd
			end
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
		setInsStatus("Pick a mesh or model first (click its name).", RED)
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
		local clones = cloneAll({ p.inst })
		if #clones == 0 then
			setInsStatus("Couldn't copy that part.", RED)
			return
		end
		insertInstances(clones, p.name)
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
		local clones = cloneAll(entry.roots)
		insertInstances(clones, m.name)
		setInsStatus(string.format("Inserted %s (%d object(s), folders and models kept).", m.name, #clones), GREEN)
	end
end)

revealButton.MouseButton1Click:Connect(function()
	if not selected then
		setInsStatus("Pick a mesh or model first (click its name).", RED)
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
-- SETTINGS TAB (same settings in both windows)
-- =================================================================
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
	add(stepper("Text size", "textScale", nx(), 80, 130, 5, function(v)
		return v .. "%"
	end, appearance))
	add(stepper("Corner roundness", "corner", nx(), 0, 16, 2, px, appearance))
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
	add(stepper("Card / preview size", "cardSize", nx(), 64, 200, 8, px, rerenderAll))
	add(stepper("Space between cards", "gap", nx(), 2, 24, 2, px, rerenderAll))
	add(toggle("Show details on cards", "showDetails", nx(), rerenderAll))
	add(stepper("Max items shown", "maxItems", nx(), 50, 2000, 50, tostring, rerenderAll))
	add(dimText("Inserter details panel", nx(), 11))
	add(segmented(nx(), {
		{ key = "top", text = "Above the list" },
		{ key = "bottom", text = "Below the list" },
	}, "infoPos", applyInfoPos))

	add(sectionTitle("3D previews", nx()))
	add(toggle("Spin previews", "spin", nx()))
	add(stepper("Spin speed", "spinSpeed", nx(), 2, 30, 2, function(v)
		return string.format("%.1fx", v / 10)
	end))
	add(toggle("Grow into a big preview on hover", "hoverEnlarge", nx()))
	add(stepper("Hover delay", "hoverDelay", nx(), 0, 15, 1, function(v)
		return string.format("%.1f s", v / 10)
	end))
	add(stepper("Big preview size", "bigSize", nx(), 140, 480, 20, px))
	add(dimText("Lighting", nx(), 11))
	add(segmented(nx(), {
		{ key = "follow", text = "Follows view" },
		{ key = "flat", text = "Flat (no shading)" },
	}, "lighting", rerenderAll))

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

	add(sectionTitle("Pivots", nx()))
	add(dimText("Model pivot (used by Build, Save, Insert and Apply pivots)", nx(), 11))
	add(segmented(nx(), {
		{ key = "keep", text = "Keep" },
		{ key = "middle", text = "Middle" },
		{ key = "average", text = "Average" },
	}, "modelPivot"))
	add(dimText("Middle = centre of the box around the whole model (halfway between its farthest edges). Average = average position of all its parts, so it leans toward where most parts are.", nx(), 11))
	add(toggle("Center each part's pivot on itself", "partPivots", nx()))

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
		applyAppearance(true)
		syncControls(true)
		rerenderAll()
	end)
	add(dimText("Mesh Tools v" .. PLUGIN_VERSION, nx(), 10))
end

buildSettingsPage(col)
buildSettingsPage(ins)

-- =================================================================
-- Wiring
-- =================================================================
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
