--!strict
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Actions = game:GetService("ContextActionService")
local Config = require(script.Parent.LoadingConfig)
local Screen = {}
local player = Players.LocalPlayer
local started = false
local gui: ScreenGui
local group: Frame
local reveal: Frame
local revealTween: Tween?
local art: ImageLabel
local canvas: Frame
local title: TextLabel
local subtitle: TextLabel
local location: TextLabel
local status: TextLabel
local percentage: TextLabel
local fill: Frame
local play: TextButton
local tutorial: TextButton
local ball: Frame
local spinner: Frame
local progressValue: NumberValue
local progressTarget = -1
local readyRequested = false
local titleScale: UIScale
local playScale: UIScale
local playCallback: (() -> ())?
local retryCallback: (() -> ())?
local assetsReady = false
local artworkLoaded = false
local mode = "Join"
local operation = 0
local motionTime = 0
local savedGuis: { [ScreenGui]: boolean } = {}
local pg: PlayerGui

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end
local navy, cream, gold, red =
	rgb(Config.Colors.Navy), rgb(Config.Colors.Cream), rgb(Config.Colors.Gold), rgb(Config.Colors.Red)
local function frame(parent: Instance, name: string, position: UDim2, size: UDim2, color: Color3): Frame
	local f = Instance.new("Frame")
	f.Name, f.Position, f.Size, f.BackgroundColor3, f.BorderSizePixel, f.Parent = name, position, size, color, 0, parent
	return f
end
local function corner(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius, c.Parent = UDim.new(0, radius), inst
end
local function label(
	parent: Instance,
	name: string,
	text: string,
	position: UDim2,
	size: UDim2,
	fontSize: number
): TextLabel
	local l = Instance.new("TextLabel")
	l.Name, l.Text, l.Position, l.Size = name, text, position, size
	l.BackgroundTransparency, l.TextColor3, l.TextSize, l.Font = 1, cream, fontSize, Enum.Font.GothamMedium
	l.Parent = parent
	return l
end
local function button(name: string, text: string, y: number, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name, b.Text, b.Position, b.Size = name, text, UDim2.fromOffset(462, y), UDim2.fromOffset(356, 66)
	b.BackgroundColor3, b.TextColor3, b.BorderSizePixel = color, navy, 0
	b.Font, b.TextSize, b.AutoButtonColor, b.Active, b.Selectable = Enum.Font.Oswald, 30, false, false, false
	b.FontFace = Font.new(Font.fromEnum(Enum.Font.Oswald).Family, Enum.FontWeight.Bold)
	corner(b, 30)
	b.Parent = canvas
	return b
end
local function conceal(inst: Instance)
	if inst:IsA("ScreenGui") and inst ~= gui and player:GetAttribute(Config.ActiveAttribute) == true then
		if savedGuis[inst] == nil then
			savedGuis[inst] = inst.Enabled
		end
		inst.Enabled = false
	end
end
local function covered(active: boolean)
	player:SetAttribute(Config.ActiveAttribute, active)
	if active then
		for _, child in pg:GetChildren() do
			conceal(child)
		end
		Actions:BindActionAtPriority(
			"HRSLoadingMovement",
			function()
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value + 100,
			Enum.KeyCode.W,
			Enum.KeyCode.A,
			Enum.KeyCode.S,
			Enum.KeyCode.D,
			Enum.KeyCode.Space,
			Enum.KeyCode.Up,
			Enum.KeyCode.Down,
			Enum.KeyCode.Left,
			Enum.KeyCode.Right,
			Enum.KeyCode.E,
			Enum.KeyCode.G
		)
	else
		Actions:UnbindAction("HRSLoadingMovement")
		for screen, enabled in savedGuis do
			if screen.Parent then
				screen.Enabled = enabled
			end
		end
		table.clear(savedGuis)
	end
end
function Screen.start()
	if started then
		return
	end
	started = true
	pg = player:WaitForChild("PlayerGui") :: PlayerGui
	if not Config.Enabled then
		assetsReady = true
		player:SetAttribute(Config.EnteredAttribute, true)
		return
	end
	gui = Instance.new("ScreenGui")
	gui.Name, gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = Config.GuiName, true, false, 10000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	group = Instance.new("Frame")
	group.Name, group.Size, group.BackgroundColor3, group.BorderSizePixel = "Cover", UDim2.fromScale(1, 1), navy, 0
	group.Active, group.Parent = true, gui
	art = Instance.new("ImageLabel")
	art.Name, art.Image, art.Size, art.Position =
		"ArcadePoster", Config.Artwork, UDim2.fromScale(1.06, 1.06), UDim2.fromScale(-0.03, -0.03)
	art.ScaleType, art.BackgroundTransparency, art.ImageTransparency, art.Parent = Enum.ScaleType.Crop, 1, 0, group
	local gradient = frame(group, "CinematicGradient", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), navy)
	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.04),
		NumberSequenceKeypoint.new(0.4, 0.16),
		NumberSequenceKeypoint.new(1, 0.76),
	})
	g.Parent = gradient
	local bottom = frame(group, "BottomShade", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), navy)
	local bg = Instance.new("UIGradient")
	bg.Rotation, bg.Transparency, bg.Parent =
		90, NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.55, 0.94),
			NumberSequenceKeypoint.new(1, 0.25),
		}), bottom
	canvas = frame(group, "Layout", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(1280, 720), navy)
	canvas.AnchorPoint, canvas.BackgroundTransparency = Vector2.new(0.5, 0.5), 1
	local scale = Instance.new("UIScale")
	scale.Parent = canvas
	label(canvas, "Monogram", "HRS", UDim2.fromOffset(40, 28), UDim2.fromOffset(65, 35), 28)
	local diamond = frame(canvas, "GoldDiamond", UDim2.fromOffset(109, 49), UDim2.fromOffset(8, 8), gold)
	diamond.Rotation = 45
	location = label(canvas, "Location", "ROOKIE PARK", UDim2.fromOffset(995, 36), UDim2.fromOffset(205, 24), 14)
	location.TextXAlignment = Enum.TextXAlignment.Right
	title = label(canvas, "Title", "HOME RUN", UDim2.fromOffset(250, 116), UDim2.fromOffset(780, 108), 92)
	title.Rotation = -3
	title.FontFace = Font.new(Font.fromEnum(Enum.Font.Oswald).Family, Enum.FontWeight.Bold)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Transparency, stroke.Parent = navy, 4, 0.15, title
	titleScale = Instance.new("UIScale")
	titleScale.Parent = title
	subtitle = label(canvas, "Subtitle", "SIMULATOR", UDim2.fromOffset(330, 216), UDim2.fromOffset(620, 64), 52)
	subtitle.Rotation = -3
	subtitle.FontFace = title.FontFace
	title.FontFace = Font.new(Font.fromEnum(Enum.Font.Oswald).Family, Enum.FontWeight.Bold)
	local ss = stroke:Clone()
	ss.Thickness, ss.Parent = 3, subtitle
	status = label(canvas, "Status", "Loading profile", UDim2.fromOffset(462, 334), UDim2.fromOffset(290, 28), 16)
	status.TextXAlignment = Enum.TextXAlignment.Left
	percentage = label(canvas, "Percentage", "0%", UDim2.fromOffset(752, 334), UDim2.fromOffset(66, 28), 16)
	percentage.TextColor3, percentage.TextXAlignment = gold, Enum.TextXAlignment.Right
	local track = frame(canvas, "ProgressTrack", UDim2.fromOffset(462, 374), UDim2.fromOffset(356, 5), cream)
	track.BackgroundTransparency = 0.83
	corner(track, 3)
	fill = frame(track, "Progress", UDim2.fromScale(0, 0), UDim2.fromScale(0, 1), gold)
	corner(fill, 3)
	progressValue = Instance.new("NumberValue")
	progressValue.Name, progressValue.Parent = "DisplayedProgress", gui
	progressValue.Changed:Connect(function(value)
		percentage.Text = `{math.floor(value + 0.001)}%`
		fill.Size = UDim2.fromScale(value / 100, 1)
	end)
	spinner = frame(canvas, "LoadingCircle", UDim2.fromOffset(439, 348), UDim2.fromOffset(30, 30), navy)
	spinner.AnchorPoint, spinner.BackgroundTransparency = Vector2.new(0.5, 0.5), 1
	for i = 0, 11 do
		local angle = i * math.pi / 6
		local dot = frame(
			spinner,
			"Segment",
			UDim2.fromOffset(15 + math.sin(angle) * 12, 15 - math.cos(angle) * 12),
			UDim2.fromOffset(4, 6),
			gold
		)
		dot.AnchorPoint, dot.Rotation, dot.BackgroundTransparency = Vector2.new(0.5, 0.5), i * 30, i / 14
		corner(dot, 3)
	end
	TweenService:Create(
		spinner,
		TweenInfo.new(Config.SpinnerSecondsPerTurn, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		{ Rotation = 360 }
	):Play()
	play = button("Play", "PLAY", 408, gold)
	play.TextTransparency, play.BackgroundTransparency = 0.55, 0.48
	playScale = Instance.new("UIScale")
	playScale.Parent = play
	tutorial = button("Tutorial", "TUTORIAL  —  COMING SOON", 493, navy)
	tutorial.Size, tutorial.TextSize, tutorial.TextColor3, tutorial.TextTransparency =
		UDim2.fromOffset(356, 48), 17, cream, 0.5
	tutorial.BackgroundTransparency = 0.25
	ball = frame(canvas, "LoadingBall", UDim2.fromOffset(610, 284), UDim2.fromOffset(60, 60), cream)
	corner(ball, 30)
	ball.Visible = false
	for _, side in { -1, 1 } do
		for i = 1, 7 do
			local y = (i - 1) * 7 + 7
			local x = 30 + side * (17 - 7 * math.sin((i - 1) / 6 * math.pi))
			local stitch = frame(ball, "Stitch", UDim2.fromOffset(x - 3, y), UDim2.fromOffset(7, 2), red)
			stitch.Rotation = side * (i - 4) * 12
		end
	end
	label(canvas, "Footer", string.upper(Config.Title), UDim2.fromOffset(40, 658), UDim2.fromOffset(300, 30), 12).TextXAlignment =
		Enum.TextXAlignment.Left
	reveal = frame(gui, "Reveal", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), navy)
	reveal.BackgroundTransparency, reveal.ZIndex = 1, 100
	gui.Parent = pg
	covered(true)
	player:SetAttribute("LoadingScreenStartedAt", os.clock())
	pg.ChildAdded:Connect(conceal)
	ReplicatedFirst:RemoveDefaultLoadingScreen()
	play.Activated:Connect(Screen.activate)
	for _, event in { "MouseEnter", "MouseLeave" } do
		(play :: any)[event]:Connect(function()
			if play.Active then
				TweenService
					:Create(playScale, TweenInfo.new(0.14), { Scale = if event == "MouseEnter" then 1.025 else 1 })
					:Play()
			end
		end)
	end
	local lastViewport = Vector2.zero
	RunService.RenderStepped:Connect(function(dt)
		local camera = workspace.CurrentCamera
		if camera and camera.ViewportSize ~= lastViewport then
			lastViewport = camera.ViewportSize
			scale.Scale = math.min(camera.ViewportSize.X / 1280, camera.ViewportSize.Y / 720)
		end
		if not gui.Enabled then
			return
		end
		motionTime += dt
		local displayed = progressValue.Value
		local step = Config.ProgressPointsPerSecond * math.min(dt, 0.1)
		if displayed ~= progressTarget and progressTarget >= 0 then
			progressValue.Value = if displayed < progressTarget
				then math.min(progressTarget, displayed + step)
				else math.max(progressTarget, displayed - step)
		end
		art.Position = UDim2.fromScale(-0.03 + math.sin(motionTime / 10) * 0.008, -0.03)
		ball.Rotation = (motionTime * 65) % 360
		if readyRequested and progressValue.Value >= 99.99 then
			readyRequested = false
			spinner.Visible = false
			if mode == "Join" then
				play.Active, play.Selectable, play.BackgroundTransparency, play.TextTransparency = true, true, 0, 0
			elseif playCallback then
				playCallback()
			end
		end
	end)
	task.spawn(function()
		local ok = pcall(function()
			ContentProvider:PreloadAsync({ art }, function(_id, statusCode)
				if statusCode == Enum.AssetFetchStatus.Success then
					artworkLoaded = true
				end
			end)
		end)
		artworkLoaded = artworkLoaded or (ok and art.IsLoaded)
		assetsReady = true
		if artworkLoaded then
			TweenService:Create(art, TweenInfo.new(0.6), { ImageTransparency = 0 }):Play()
		end
	end)
	task.delay(Config.ArtworkTimeoutSeconds, function()
		assetsReady = true
	end)
	task.delay(Config.TimeoutSeconds, function()
		if player:GetAttribute(Config.ClientReadyAttribute) ~= true and gui.Enabled then
			Screen.error("Connection is taking longer — please rejoin", nil)
		end
	end)
end
function Screen.activate()
	if not Config.Enabled or not play.Active then
		return
	end
	if retryCallback then
		retryCallback()
	elseif playCallback then
		playCallback()
	end
end
function Screen.assetsReady(): boolean
	return assetsReady
end
function Screen.artworkLoaded(): boolean
	return artworkLoaded
end
function Screen.show(kind: string, name: string)
	Screen.start()
	if not Config.Enabled then
		return
	end
	operation += 1
	mode = kind
	retryCallback = nil
	readyRequested = false
	progressValue.Value, progressTarget = 0, -1
	spinner.Visible = true
	spinner.Position = UDim2.fromOffset(439, if kind == "Join" then 348 else 404)
	if revealTween then
		revealTween:Cancel()
	end
	gui.Enabled, group.Visible, reveal.BackgroundTransparency = true, true, 1
	location.Text = string.upper(name)
	play.Text, play.Active, play.Selectable = "PLAY", false, false
	play.BackgroundTransparency, play.TextTransparency = 0.48, 0.55
	play.Visible, tutorial.Visible, subtitle.Visible = kind == "Join", kind == "Join", kind == "Join"
	ball.Visible = kind == "Travel"
	title.Text, title.TextSize, title.Rotation =
		if kind == "Join" then "HOME RUN" else string.upper(name),
		if kind == "Join" then 92 else 54,
		if kind == "Join" then -3 else 0
	title.Position = UDim2.fromOffset(250, if kind == "Join" then 116 else 197)
	status.Position, percentage.Position =
		UDim2.fromOffset(462, if kind == "Join" then 334 else 390),
		UDim2.fromOffset(752, if kind == "Join" then 334 else 390)
	local track = fill.Parent :: Frame
	track.Position = UDim2.fromOffset(462, if kind == "Join" then 374 else 436)
	titleScale.Scale = 0.94
	TweenService:Create(titleScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	covered(true)
	Screen.progress(0, "Loading")
end
function Screen.progress(percent: number, text: string)
	if not Config.Enabled then
		return
	end
	status.Text = text
	if progressTarget ~= percent then
		progressTarget = percent
	end
	if percent < 100 and not retryCallback then
		readyRequested, spinner.Visible = false, true
		play.Active, play.Selectable = false, false
		play.BackgroundTransparency, play.TextTransparency = 0.48, 0.55
	end
end
function Screen.ready(callback: () -> ())
	if not Config.Enabled then
		callback()
		return
	end
	retryCallback, playCallback = nil, callback
	Screen.progress(100, if mode == "Join" then "Ready to play" else "Ready")
	if not play.Active then
		readyRequested = true
	end
end
function Screen.error(message: string, retry: (() -> ())?)
	if not Config.Enabled then
		return
	end
	status.Text = message
	readyRequested = false
	retryCallback, playCallback = retry, nil
	if retry then
		play.Visible, play.Text, play.Active, play.Selectable = true, "RETRY", true, true
		play.BackgroundTransparency, play.TextTransparency = 0, 0
	else
		play.Active, play.Selectable = false, false
	end
end
function Screen.finish(callback: () -> ())
	if not Config.Enabled then
		callback()
		return
	end
	operation += 1
	local token = operation
	play.Active, play.Selectable = false, false
	retryCallback, playCallback = nil, nil
	revealTween = TweenService:Create(reveal, TweenInfo.new(Config.CoverSeconds), { BackgroundTransparency = 0 })
	local activeTween = revealTween :: Tween
	activeTween:Play()
	task.delay(Config.CoverSeconds, function()
		if token ~= operation then
			return
		end
		group.Visible = false
		revealTween = TweenService:Create(reveal, TweenInfo.new(Config.RevealSeconds), { BackgroundTransparency = 1 })
		local finishTween = revealTween :: Tween
		finishTween:Play()
		task.delay(Config.RevealSeconds, function()
			if token ~= operation then
				return
			end
			gui.Enabled = false
			covered(false)
			callback()
		end)
	end)
end
function Screen.cancel()
	Screen.finish(function() end)
end
return Screen
