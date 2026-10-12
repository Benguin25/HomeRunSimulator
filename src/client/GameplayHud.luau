--!strict
-- Minimal session HUD, collapsible panel and restrained record notices. All
-- targets/ratios/records are server values; local interpolation is visual only.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Gameplay.GameplayConfig)
local Net = require(Shared.Gameplay.GameplayNet)
local Stats = require(Shared.Gameplay.SessionStats)
local Replica = require(Shared.Gameplay.SessionReplica)
local CameraMath = require(Shared.Presentation.CameraMath)
local Controller = require(script.Parent.GameplayController)
local BattingCamera = require(script.Parent.BattingCamera)
local PitchDebugView = require(script.Parent.PitchDebugView)
local Hud = {}
local COLORS = require(script.Parent.HudStyle).Colors
local gui: ScreenGui
local main: CanvasGroup
local details: CanvasGroup
local notice: CanvasGroup
local skip: TextButton
local best: TextLabel
local hits: TextLabel
local milestone: TextLabel
local fill: Frame
local noticeTitle: TextLabel
local noticeValue: TextLabel
local noticeMilestone: TextLabel
local noticeStroke: UIStroke
local scales: { UIScale } = {}
local rows: { [string]: TextLabel } = {}
local displayed: { [string]: number } = {}
local snapshot: Net.Snapshot? = nil
local open = false
local panelAlpha = 0
local noticeAt = -math.huge
local noticeDuration = 0
local noticeIntensity = 0
local notices = Replica.new()
local lastDebugAt = 0

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end
local function text(
	parent: Instance,
	caption: string,
	position: UDim2,
	size: UDim2,
	fontSize: number,
	color: Color3
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position, label.Size = position, size
	label.Font, label.TextSize = Enum.Font.GothamMedium, fontSize
	label.TextColor3, label.Text = color, caption
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end
local function panel(name: string, width: number, height: number, position: UDim2): CanvasGroup
	local group = Instance.new("CanvasGroup")
	group.Name, group.Size, group.Position = name, UDim2.fromOffset(width, height), position
	group.AnchorPoint = Vector2.new(1, 1)
	group.BackgroundColor3, group.BackgroundTransparency = COLORS.panel, 0.15
	group.BorderSizePixel = 0
	corner(group, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Transparency = COLORS.text, 0.87
	stroke.Parent = group
	local scale = Instance.new("UIScale")
	scale.Parent = group
	table.insert(scales, scale)
	group.Parent = gui
	return group
end
local function button(parent: Instance, caption: string, position: UDim2, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Text, b.Position, b.Size = caption, position, size
	b.Font, b.TextSize = Enum.Font.GothamBold, 12
	b.TextColor3, b.BackgroundColor3 = COLORS.text, COLORS.panel
	b.BackgroundTransparency, b.BorderSizePixel = 0.2, 0
	corner(b, 8)
	b.Parent = parent
	return b
end
local function feet(value: number): string
	return string.format("%.0f ft", value / 0.3048)
end
local function updated(value: Net.Snapshot)
	snapshot = value
	Replica.apply(notices, value)
	local award = value.stats.award
	local celebration = Replica.celebration(notices)
	if value.loop and value.loop.phase == "Returning" then
		noticeAt = -math.huge -- an approved skip dismisses presentation, never the record
		return
	end
	if not award or celebration == nil then
		return
	end
	noticeAt, noticeIntensity = os.clock(), award.intensity
	noticeDuration = if award.baseline then Config.Hud.BaselineNoticeSeconds else Config.Hud.NoticeSeconds
	noticeTitle.Text = if award.baseline
		then "SESSION BEST ESTABLISHED"
		elseif award.newRecord then "NEW PERSONAL BEST!"
		else "DISTANCE MILESTONE!"
	noticeValue.Text = feet(award.distanceMeters)
	noticeMilestone.Text = if #award.milestonesFeet > 0
		then `{award.milestonesFeet[#award.milestonesFeet]} FT MILESTONE`
		elseif award.newRecord and not award.baseline then `+{feet(award.improvementMeters)} improvement`
		else "Your first measured fair carry"
end

local function debug(loop: Net.Loop?, stats: Stats.Snapshot?, now: number)
	if now - lastDebugAt < 0.1 then
		return
	end
	lastDebugAt = now
	local state = if loop then loop.phase else "Waiting for lane"
	PitchDebugView.setSection(
		"Gameplay",
		string.format(
			"<b>GAMEPLAY</b> %s | camera ready %s (local %s) | pitch ready %s | hit #%d\n    session hits %d | best %s | stats version %d / sync %d | rejection %s",
			state,
			tostring(loop ~= nil and loop.cameraReady),
			tostring(BattingCamera.isReady()),
			tostring(loop ~= nil and loop.pitchReady),
			if loop then loop.hitId else 0,
			if stats then stats.contacts else 0,
			if stats then feet(stats.longestMeters) else "-",
			if stats then stats.version else -1,
			if snapshot then snapshot.version else -1,
			if snapshot and snapshot.rejection and snapshot.rejection ~= "" then snapshot.rejection else "none"
		)
	)
end
local function render(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local view = camera.ViewportSize
	local scale = math.clamp(math.min(view.X / 1280, view.Y / 720), Config.Hud.MinScale, Config.Hud.MaxScale)
	for _, item in scales do
		item.Scale = scale
	end
	local v = snapshot and snapshot.stats
	local loop = snapshot and snapshot.loop
	local batting = BattingCamera.isBattingView()
	if not batting then
		open = false
	end
	local hiddenForDebug = PitchDebugView.isVisible()
	main.Visible = not hiddenForDebug and (batting or view.X >= Config.Hud.CompactWidth)
	if v then
		for _, key in
			{
				"longestMeters",
				"contacts",
				"fairHits",
				"averageDistanceMeters",
				"swings",
				"contactPercent",
				"over200",
				"over300",
				"over400",
				"highestExitMph",
				"milestoneProgress",
			}
		do
			displayed[key] = CameraMath.damp(displayed[key] or 0, (v :: any)[key], Config.Hud.NumberSmoothSeconds, dt)
		end
		best.Text = feet(displayed.longestMeters)
		hits.Text = string.format("%d SUCCESSFUL HITS", math.floor(displayed.contacts + 0.5))
		milestone.Text = if v.nextMilestoneFeet
			then `NEXT: {v.nextMilestoneFeet} FT`
			else "ALL DISTANCE MILESTONES REACHED"
		fill.Size = UDim2.fromScale(displayed.milestoneProgress, 1)
		for key, label in rows do
			local n = displayed[key] or (v :: any)[key]
			label.Text = if key == "longestMeters" or key == "averageDistanceMeters"
				then feet(n)
				elseif key == "contactPercent" then string.format("%.1f%%", n)
				elseif key == "highestExitMph" then string.format("%.1f mph", n)
				else string.format("%.0f", n)
		end
	end
	details.Position = UDim2.new(1, -16, 1, -28 - 112 * scale)
	panelAlpha = CameraMath.damp(panelAlpha, if open then 1 else 0, 0.06, dt)
	details.Visible = not hiddenForDebug and panelAlpha > 0.01
	details.GroupTransparency = 1 - panelAlpha
	local elapsed = os.clock() - noticeAt
	local alpha = if elapsed < noticeDuration then math.min(elapsed / 0.15, (noticeDuration - elapsed) / 0.25, 1) else 0
	notice.Visible = not hiddenForDebug and not open and alpha > 0
	notice.GroupTransparency = 1 - math.clamp(alpha, 0, 1)
	noticeStroke.Transparency = 0.8 - 0.3 * noticeIntensity * math.exp(-math.max(0, elapsed) * 4)
	notice.Position = UDim2.new(1, -16, 0, 160 + 10 * (1 - math.clamp(alpha, 0, 1)))
	skip.Visible = Controller.canSkip() and not hiddenForDebug
	debug(loop, v, os.clock())
end
function Hud.start()
	gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder = "GameplayHud", false, true, 7
	main = panel("SessionSummary", 244, 112, UDim2.new(1, -16, 1, -16))
	text(main, "PERSONAL BEST", UDim2.fromOffset(14, 10), UDim2.fromOffset(145, 14), 11, COLORS.muted)
	best = text(main, "0 ft", UDim2.fromOffset(14, 26), UDim2.fromOffset(145, 32), 28, COLORS.gold)
	best.Font = Enum.Font.GothamBlack
	hits = text(main, "0 SUCCESSFUL HITS", UDim2.fromOffset(14, 61), UDim2.fromOffset(220, 16), 12, COLORS.text)
	milestone = text(main, "NEXT: 200 FT", UDim2.fromOffset(14, 80), UDim2.fromOffset(220, 13), 10, COLORS.muted)
	local track = Instance.new("Frame")
	track.Position, track.Size = UDim2.fromOffset(14, 98), UDim2.fromOffset(216, 4)
	track.BackgroundColor3, track.BorderSizePixel = COLORS.muted, 0
	track.BackgroundTransparency = 0.8
	corner(track, 2)
	track.Parent = main
	fill = Instance.new("Frame")
	fill.BackgroundColor3, fill.BorderSizePixel = COLORS.gold, 0
	fill.Size = UDim2.fromScale(0, 1)
	corner(fill, 2)
	fill.Parent = track
	local toggle = button(main, `STATS [{Config.Hud.StatsKey}]`, UDim2.new(1, -84, 0, 12), UDim2.fromOffset(70, 27))
	toggle.Activated:Connect(function()
		if BattingCamera.isBattingView() then
			open = not open
		end
	end)
	details = panel("SessionStatistics", 268, 326, UDim2.new(1, -16, 1, -150))
	details.Active = true
	text(details, "THIS SESSION", UDim2.fromOffset(14, 12), UDim2.fromOffset(200, 20), 14, COLORS.text).Font =
		Enum.Font.GothamBold
	button(details, "X", UDim2.new(1, -36, 0, 8), UDim2.fromOffset(26, 26)).Activated:Connect(function()
		open = false
	end)
	local definitions = {
		{ "longestMeters", "Longest fair carry" },
		{ "averageDistanceMeters", "Average fair carry" },
		{ "contacts", "Successful hits" },
		{ "fairHits", "Resolved fair impacts" },
		{ "swings", "Swings" },
		{ "contactPercent", "Contact" },
		{ "over200", "Over 200 ft" },
		{ "over300", "Over 300 ft" },
		{ "over400", "Over 400 ft" },
		{ "highestExitMph", "Highest exit velocity" },
	}
	for i, definition in definitions do
		local y = 42 + (i - 1) * 25
		text(details, definition[2], UDim2.fromOffset(14, y), UDim2.fromOffset(166, 20), 12, COLORS.muted)
		local label = text(details, "0", UDim2.new(1, -87, 0, y), UDim2.fromOffset(73, 20), 13, COLORS.text)
		label.TextXAlignment = Enum.TextXAlignment.Right
		rows[definition[1]] = label
	end
	text(
		details,
		"Carry: confirmed fair ground landings only",
		UDim2.fromOffset(14, 300),
		UDim2.fromOffset(240, 16),
		10,
		COLORS.muted
	)
	notice = panel("RecordNotice", 268, 112, UDim2.new(1, -16, 0, 160))
	noticeTitle = text(notice, "", UDim2.fromOffset(14, 12), UDim2.fromOffset(240, 20), 14, COLORS.gold)
	noticeTitle.Font = Enum.Font.GothamBold
	noticeValue = text(notice, "", UDim2.fromOffset(14, 36), UDim2.fromOffset(240, 38), 32, COLORS.text)
	noticeValue.Font = Enum.Font.GothamBlack
	noticeMilestone = text(notice, "", UDim2.fromOffset(14, 82), UDim2.fromOffset(240, 16), 11, COLORS.muted)
	noticeStroke = notice:FindFirstChildOfClass("UIStroke") :: UIStroke
	noticeStroke.Color = COLORS.gold
	skip = button(gui, `SKIP RESULT [{Config.Hud.SkipKey}]`, UDim2.new(0.5, -100, 1, -30), UDim2.fromOffset(200, 24))
	skip.Visible = false
	skip.Activated:Connect(Controller.skip)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	Controller.onSnapshot(updated)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == (Enum.KeyCode :: any)[Config.Hud.StatsKey] and BattingCamera.isBattingView() then
			open = not open
		elseif input.KeyCode == Enum.KeyCode.Escape then
			open = false
		end
	end)
	RunService:BindToRenderStep("GameplayHud", Enum.RenderPriority.Camera.Value + 7, render)
end
return Hud
