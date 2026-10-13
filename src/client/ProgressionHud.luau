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
local Debug = require(script.Parent.PitchDebugView)
local Audio = require(script.Parent.GameAudio)
local Hud = {}
local C = Style.Colors
local gui: ScreenGui
local summary: CanvasGroup
local shop: CanvasGroup
local rebirth: CanvasGroup
local rebirthInfo: TextLabel
local rebirthProgress: Frame
local rebirthButton: TextButton
local rebirthMessage: TextLabel
local statusLabel: TextLabel
local confirm = false
local celebrated = -1
local rebirthMessageUntil = 0
local rebirthAt = -math.huge
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
	if celebrated >= 0 and snapshot.rebirths > celebrated then
		Audio.play("Rebirth")
		toast.Text = string.format("REBORN! PERMANENT POWER %.2fx", snapshot.permanentMultiplier)
		toastUntil = os.clock() + Config.Hud.RebirthNoticeSeconds
		rebirthAt = os.clock()
		purchaseAt = os.clock()
		confirm = false
	end
	celebrated = math.max(celebrated, snapshot.rebirths)
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
	if award and award.coins > 0 and os.clock() - purchaseAt > 0.1 then
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
		local rebirthElapsed = os.clock() - rebirthAt
		local rebirthPulse = if rebirthElapsed < 1
			then Config.Hud.RebirthPulseScale * math.exp(-rebirthElapsed * 7) * math.sin(rebirthElapsed * 18)
			else 0
		s.Scale = scale * (if i == 2 then 1 + punch elseif i == 3 then 1 + rebirthPulse else 1)
	end
	rebirth.BackgroundColor3 =
		C.panel:Lerp(C.gold, 0.22 * math.exp(-(os.clock() - rebirthAt) / Config.Hud.RebirthFlashSeconds))
	if Debug.isVisible() then
		Controller.setOpen(false)
	end
	local open = Controller.isOpen()
	alpha += ((if open then 1 else 0) - alpha) * (1 - math.exp(-dt / 0.07))
	local rebirthOpen = open and Controller.panel() == "Rebirth"
	shop.Visible, shop.GroupTransparency = alpha > 0.01 and not rebirthOpen, 1 - alpha
	rebirth.Visible, rebirth.GroupTransparency = rebirthOpen, 1 - alpha
	if not rebirthOpen then
		confirm = false
	end
	local shopY = math.min(16 + 94 * scale + 42, math.max(16, gui.AbsoluteSize.Y - 292 * scale - 16))
	shop.Position = UDim2.fromOffset(16, shopY + 8 * (1 - alpha))
	rebirth.Position = UDim2.fromOffset(16, math.min(shopY, math.max(16, gui.AbsoluteSize.Y - 360 * scale - 16)))
	summary.Visible = not Debug.isVisible()
	toast.Position = UDim2.fromOffset(30, 22 + 94 * scale)
	toast.Visible = summary.Visible and os.clock() < toastUntil
	message.Visible = os.clock() < messageUntil
	local v = value
	local ready = Players.LocalPlayer:GetAttribute("ProfileState") == "Ready"
	local afford = ready and v ~= nil and v.nextCost ~= nil and v.coins >= (v.nextCost or math.huge)
	upgrade.BackgroundColor3 = if afford then C.gold else Color3.fromRGB(56, 63, 80)
	upgrade.TextColor3 = if afford then C.panel else C.muted
	upgrade.Text = if Controller.isPending()
		then "PURCHASING..."
		elseif not v then "LOADING..."
		elseif not v.nextCost then "MAX LEVEL"
		elseif afford then "UPGRADE POWER"
		else `NEED {number((v.nextCost or 0) - v.coins)} MORE COINS`
	upgrade.Active = afford and not Controller.isPending()
	local state = Players.LocalPlayer:GetAttribute("ProfileState")
	statusLabel.Text = if state == "LoadFailed"
		then tostring(
			Players.LocalPlayer:GetAttribute("ProfileLoadMessage") or "Progress couldn't load. Please rejoin."
		)
		elseif state == "Lost" then "Progression paused: session ownership expired. Please rejoin."
		elseif state == "SaveDelayed" then "Temporary saving issue. Progression paused while reconnecting."
		elseif state ~= "Ready" then "Loading your progression..."
		elseif Players.LocalPlayer:GetAttribute("ProfileMock") then "STUDIO MOCK: development session only"
		else ""
	statusLabel.Visible = statusLabel.Text ~= ""
	statusLabel.Size = UDim2.fromOffset(math.max(200, math.min(600, view.X - 32)), 48)
	statusLabel.Position = UDim2.fromOffset(16, math.max(0, gui.AbsoluteSize.Y - 56))
	if v then
		local required = v.rebirthRequirement
		local eligible = ready and required ~= nil and v.powerLevel >= (required or math.huge)
		rebirthInfo.Text = string.format(
			"Rebirths  %d\nPermanent bonus  %.2fx\nNext bonus  %s\nPower  Level %d / %s",
			v.rebirths,
			v.permanentMultiplier,
			if v.nextRebirthMultiplier then string.format("%.2fx", v.nextRebirthMultiplier) else "MAX",
			v.powerLevel,
			if required then tostring(required) else "MAX"
		)
		rebirthProgress.Size = UDim2.fromScale(if required then math.clamp(v.powerLevel / required, 0, 1) else 1, 1)
		rebirthButton.Text = if Controller.isPending()
			then "REBIRTHING..."
			elseif not required then "MAX REBIRTHS"
			elseif not ready then "PROGRESSION UNAVAILABLE"
			elseif confirm then "CONFIRM: RESET COINS & POWER"
			elseif eligible then "REBIRTH"
			else `LOCKED - NEED LEVEL {required}`
		rebirthButton.Active = eligible and not Controller.isPending()
		rebirthButton.BackgroundColor3 = if eligible then C.gold else Color3.fromRGB(56, 63, 80)
		rebirthButton.TextColor3 = if eligible then C.panel else C.muted
	end
	rebirthMessage.Visible = os.clock() < rebirthMessageUntil
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
		if Controller.isOpen() and Controller.panel() == "Power" then
			Controller.setOpen(false)
		else
			Controller.openPanel("Power")
		end
	end)
	local openRebirth = button(summary, "REBIRTH", 154, 63, 118, 23)
	openRebirth.Name = "OpenRebirth"
	openRebirth.Activated:Connect(function()
		if Controller.isOpen() and Controller.panel() == "Rebirth" then
			Controller.setOpen(false)
		else
			Controller.openPanel("Rebirth")
		end
	end)
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
				Audio.play("Upgrade")
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
	toast.Size = UDim2.fromOffset(390, 28)
	toast.Visible, toast.Font = false, Enum.Font.GothamBold
	rebirth = panel("Rebirth", 340, 360, UDim2.fromOffset(16, 166))
	rebirth.Visible = false
	label(rebirth, "REBIRTH", 18, 16, 260, 28, 22, C.gold).Font = Enum.Font.GothamBlack
	local closeRebirth = button(rebirth, "X", 300, 16, 24, 24)
	closeRebirth.Activated:Connect(function()
		Controller.setOpen(false)
	end)
	rebirthInfo = label(rebirth, "Loading...", 18, 58, 304, 110, 16, C.text)
	rebirthInfo.TextYAlignment = Enum.TextYAlignment.Top
	local bar = Instance.new("Frame")
	bar.Position, bar.Size, bar.BackgroundColor3, bar.BorderSizePixel =
		UDim2.fromOffset(18, 176), UDim2.fromOffset(304, 8), C.muted, 0
	bar.Parent = rebirth
	Style.corner(bar, 4)
	rebirthProgress = Instance.new("Frame")
	rebirthProgress.Size, rebirthProgress.BackgroundColor3, rebirthProgress.BorderSizePixel, rebirthProgress.Parent =
		UDim2.fromScale(0, 1), C.gold, 0, bar
	Style.corner(rebirthProgress, 4)
	local explanation = label(
		rebirth,
		"Coins and purchased Power reset to 0.\nKeep permanent bonuses, worlds, records\nand lifetime milestones. Build strength again!",
		18,
		200,
		304,
		65,
		12,
		C.muted
	)
	explanation.TextWrapped = true
	rebirthButton = button(rebirth, "LOADING...", 18, 278, 304, 40)
	rebirthButton.Name = "ConfirmRebirth"
	rebirthMessage = label(rebirth, "", 18, 324, 304, 22, 11, C.gold)
	rebirthButton.Activated:Connect(function()
		local v = value
		if
			not rebirth.Visible
			or not v
			or not v.rebirthRequirement
			or v.powerLevel < v.rebirthRequirement
			or Controller.isPending()
		then
			return
		end
		if not confirm then
			confirm = true
			return
		end
		confirm = false
		Controller.rebirth(function(result)
			rebirthMessageUntil = os.clock() + 3
			rebirthMessage.Text = if result.ok
				then "Permanent bonus unlocked!"
				elseif result.reason == "FinishHitFirst" then "Wait for the current hit to finish."
				elseif result.reason == "StaleProgression" then "Progress changed. Review and confirm again."
				elseif result.reason == "DataUnavailable" then "Saving unavailable. Please wait."
				else "Rebirth unavailable. Review and try again."
		end)
	end)
	statusLabel = label(gui, "Loading your progression...", 16, 600, 600, 48, 13, C.gold)
	statusLabel.TextWrapped = true
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
