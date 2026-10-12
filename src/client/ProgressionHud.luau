--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Input = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Progression.ProgressionConfig)
local Data = require(Shared.Progression.PlayerProgression)
local Replica = require(Shared.Progression.ProgressionReplica)
local Style = require(script.Parent.HudStyle)
local Controller = require(script.Parent.ProgressionController)
local Camera = require(script.Parent.BattingCamera)
local Debug = require(script.Parent.PitchDebugView)
local Hud = {}
local C = Style.Colors
local gui: ScreenGui
local summary: CanvasGroup
local shop: CanvasGroup
local balance: TextLabel
local level: TextLabel
local title: TextLabel
local strength: TextLabel
local nextPower: TextLabel
local cost: TextLabel
local shopBalance: TextLabel
local message: TextLabel
local toast: TextLabel
local upgrade: TextButton
local scales: { UIScale } = {}
local replica = Replica.new()
local value: Data.Snapshot? = nil
local toastUntil, messageUntil, purchaseAt = 0, 0, -math.huge
local alpha = 0
local function number(n: number): string
	local formatted = string.format("%.0f", n)
	local result = formatted:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return result
end
local function label(
	parent: Instance,
	caption: string,
	x: number,
	y: number,
	w: number,
	h: number,
	size: number,
	color: Color3
): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency, l.TextXAlignment = 1, Enum.TextXAlignment.Left
	l.Position, l.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
	l.Font, l.TextSize, l.TextColor3, l.Text = Enum.Font.GothamMedium, size, color, caption
	l.Parent = parent
	return l
end
local function panel(name: string, w: number, h: number, position: UDim2): CanvasGroup
	local p = Instance.new("CanvasGroup")
	p.Name, p.Size, p.Position = name, UDim2.fromOffset(w, h), position
	p.BackgroundColor3, p.BackgroundTransparency, p.BorderSizePixel = C.panel, 0.1, 0
	p.Active = true
	Style.corner(p, 14)
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Transparency, stroke.Parent = C.text, 0.87, p
	local scale = Instance.new("UIScale")
	scale.Parent = p
	table.insert(scales, scale)
	p.Parent = gui
	return p
end
local function button(parent: Instance, caption: string, x: number, y: number, w: number, h: number): TextButton
	local b = Instance.new("TextButton")
	b.Text, b.Font, b.TextSize = caption, Enum.Font.GothamBold, 13
	b.TextColor3, b.BackgroundColor3, b.BorderSizePixel = C.panel, C.gold, 0
	b.Position, b.Size, b.Parent = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h), parent
	b.AutoButtonColor = false
	Style.corner(b, 9)
	local scale = Instance.new("UIScale")
	scale.Parent = b
	local function animate(target: number)
		TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = target }):Play()
	end
	b.MouseEnter:Connect(function()
		animate(1.025)
	end)
	b.MouseLeave:Connect(function()
		animate(1)
	end)
	b.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			animate(0.96)
		end
	end)
	b.InputEnded:Connect(function()
		animate(1)
	end)
	return b
end
local function updated(snapshot: Data.Snapshot)
	value = snapshot
	Replica.apply(replica, snapshot)
	balance.Text = `{number(snapshot.coins)} COINS`
	level.Text = string.format("POWER LV. %d  /  %.2fx", snapshot.powerLevel, snapshot.multiplier)
	title.Text = `POWER — LEVEL {snapshot.powerLevel}`
	strength.Text = string.format("Current strength   %.2fx", snapshot.multiplier)
	nextPower.Text = if snapshot.nextMultiplier
		then string.format(
			"Next   %.2fx   (+%.0f%% launch speed)",
			snapshot.nextMultiplier,
			100 * (snapshot.nextMultiplier / snapshot.multiplier - 1)
		)
		else "Maximum tested power reached"
	cost.Text = if snapshot.nextCost then `{number(snapshot.nextCost)} COINS` else "MAX LEVEL"
	shopBalance.Text = `BALANCE  {number(snapshot.coins)} COINS`
	local award = Replica.award(replica)
	if award and award.coins > 0 then
		toast.Text = `+{number(award.coins)} COINS`
		toastUntil = os.clock() + Config.Hud.NoticeSeconds
	end
end
local function render(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local view = camera.ViewportSize
	local scale = math.clamp(math.min(view.X / 1280, view.Y / 720), Config.Hud.MinScale, Config.Hud.MaxScale)
	local elapsed = os.clock() - purchaseAt
	local punch = if elapsed < 1 then 0.025 * math.exp(-elapsed * 7) * math.sin(elapsed * 18) else 0
	for i, s in scales do
		s.Scale = scale * (if i == 2 then 1 + punch else 1)
	end
	if not Camera.isBattingView() or Debug.isVisible() then
		Controller.setOpen(false)
	end
	local open = Controller.isOpen()
	alpha += ((if open then 1 else 0) - alpha) * (1 - math.exp(-dt / 0.07))
	shop.Visible, shop.GroupTransparency = alpha > 0.01, 1 - alpha
	local shopY = math.min(16 + 94 * scale + 42, math.max(16, gui.AbsoluteSize.Y - 292 * scale - 16))
	shop.Position = UDim2.fromOffset(16, shopY + 8 * (1 - alpha))
	summary.Visible = not Debug.isVisible() and (view.X >= Config.Hud.CompactWidth or Camera.isBattingView())
	toast.Position = UDim2.fromOffset(30, 22 + 94 * scale)
	toast.Visible = summary.Visible and os.clock() < toastUntil
	message.Visible = os.clock() < messageUntil
	local v = value
	local afford = v ~= nil and v.nextCost ~= nil and v.coins >= (v.nextCost or math.huge)
	upgrade.BackgroundColor3 = if afford then C.gold else Color3.fromRGB(56, 63, 80)
	upgrade.TextColor3 = if afford then C.panel else C.muted
	upgrade.Text = if Controller.isPending()
		then "PURCHASING..."
		elseif not v then "LOADING..."
		elseif not v.nextCost then "MAX LEVEL"
		elseif afford then "UPGRADE POWER"
		else `NEED {number((v.nextCost or 0) - v.coins)} MORE COINS`
	upgrade.Active = afford and not Controller.isPending()
end
function Hud.start()
	gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder = "ProgressionHud", false, false, 9
	summary = panel("ProgressionSummary", 286, 94, UDim2.fromOffset(16, 16))
	balance = label(summary, "LOADING COINS...", 14, 10, 258, 26, 22, C.gold)
	balance.Font = Enum.Font.GothamBlack
	level = label(summary, "POWER LV. 0", 14, 39, 258, 18, 12, C.text)
	local openButton = button(summary, "POWER SHOP", 14, 63, 126, 23)
	openButton.Name = "OpenShop"
	openButton.Activated:Connect(function()
		if Camera.isBattingView() then
			Controller.setOpen(not Controller.isOpen())
		end
	end)
	label(summary, "SESSION ONLY", 154, 65, 120, 18, 10, C.muted)
	shop = panel("PowerShop", 320, 292, UDim2.fromOffset(16, 166))
	shop.Visible, shop.GroupTransparency = false, 1
	title = label(shop, "POWER — LEVEL 0", 18, 16, 255, 24, 18, C.gold)
	title.Font = Enum.Font.GothamBold
	local closeButton = button(shop, "X", 280, 14, 24, 24)
	closeButton.Name = "CloseShop"
	closeButton.Activated:Connect(function()
		Controller.setOpen(false)
	end)
	label(shop, "MORE SPEED. MORE DISTANCE.", 18, 48, 284, 18, 10, C.muted)
	strength = label(shop, "", 18, 82, 284, 26, 18, C.text)
	nextPower = label(shop, "", 18, 112, 284, 24, 13, C.muted)
	shopBalance = label(shop, "", 18, 148, 284, 18, 11, C.muted)
	cost = label(shop, "", 18, 171, 284, 28, 22, C.gold)
	upgrade = button(shop, "LOADING...", 18, 209, 284, 40)
	upgrade.Name = "UpgradePower"
	message = label(shop, "", 18, 257, 284, 18, 11, C.gold)
	message.Visible = false
	upgrade.Activated:Connect(function()
		local v = value
		if not Controller.isOpen() or not v or not v.nextCost or v.coins < v.nextCost then
			return
		end
		Controller.buy(function(result)
			messageUntil = os.clock() + Config.Hud.NoticeSeconds
			if result.ok then
				purchaseAt = os.clock()
				message.Text = `POWER LEVEL {if value then value.powerLevel else 0} UNLOCKED!`
			else
				message.Text = if result.reason == "InsufficientCoins"
					then "Earn more coins to upgrade."
					elseif result.reason == "StaleLevel" then "Power updated. Try again."
					elseif result.reason == "RateLimited" then "Give it a moment, then try again."
					else "Purchase unavailable. Try again."
			end
		end)
	end)
	toast = label(gui, "", 30, 120, 280, 28, 18, C.gold)
	toast.Visible, toast.Font = false, Enum.Font.GothamBold
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	Controller.onSnapshot(updated)
	Input.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and Input:GetFocusedTextBox() == nil then
			Controller.setOpen(false)
		end
	end)
	RunService:BindToRenderStep("ProgressionHud", Enum.RenderPriority.Camera.Value + 8, render)
end
return Hud
