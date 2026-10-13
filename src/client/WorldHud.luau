--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Input = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local Data = require(Shared.Progression.PlayerProgression)
local ProgressionConfig = require(Shared.Progression.ProgressionConfig)
local Progression = require(script.Parent.ProgressionController)
local Controller = require(script.Parent.WorldController)
local Debug = require(script.Parent.PitchDebugView)
local Style = require(script.Parent.HudStyle)
local Hud = {}
local C = Style.Colors
local started = false
local function label(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	size: number,
	color: Color3
): TextLabel
	local l = Instance.new("TextLabel")
	l.Text, l.Font, l.TextSize, l.TextColor3 = text, Enum.Font.GothamMedium, size, color
	l.BackgroundTransparency, l.TextXAlignment = 1, Enum.TextXAlignment.Left
	l.Position, l.Size, l.Parent = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h), parent
	return l
end
local function frame(parent: Instance, x: number, y: number, w: number, h: number, color: Color3): Frame
	local f = Instance.new("Frame")
	f.Position, f.Size, f.BackgroundColor3, f.BorderSizePixel = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h), color, 0
	f.Parent = parent
	Style.corner(f, 12)
	return f
end
local function button(parent: Instance, text: string, x: number, y: number, w: number, h: number): TextButton
	local b = Instance.new("TextButton")
	b.Text, b.Font, b.TextSize, b.TextColor3 = text, Enum.Font.GothamBold, 12, C.panel
	b.Position, b.Size, b.BackgroundColor3, b.BorderSizePixel =
		UDim2.fromOffset(x, y), UDim2.fromOffset(w, h), C.gold, 0
	b.Parent = parent
	Style.corner(b, 9)
	local scale = Instance.new("UIScale")
	scale.Parent = b
	local function animate(n: number)
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = n }):Play()
	end
	b.MouseEnter:Connect(function()
		animate(1.025)
	end)
	b.MouseLeave:Connect(function()
		animate(1)
	end)
	b.InputBegan:Connect(function()
		animate(0.97)
	end)
	b.InputEnded:Connect(function()
		animate(1)
	end)
	return b
end
local function icon(parent: Instance, world: Config.Definition, accent: Color3)
	local preview = frame(parent, 12, 14, 80, 98, Color3.fromRGB(22, 34, 49))
	local grass = frame(preview, 15, 30, 50, 50, Color3.fromRGB(53, 126, 98))
	grass.Rotation = 45
	local diamond = frame(preview, 27, 46, 26, 26, Color3.fromRGB(190, 138, 93))
	diamond.Rotation = 45
	for i = 1, 3 do
		frame(preview, 7, 18 + i * 6, 8, 48 - i * 4, accent)
		frame(preview, 65, 18 + i * 6, 8, 48 - i * 4, accent)
	end
	label(
		preview,
		if world.theme == "sky" then "SKY" elseif world.theme == "power" then "ARENA" else "PARK",
		5,
		5,
		70,
		14,
		10,
		accent
	).TextXAlignment =
		Enum.TextXAlignment.Center
	if world.theme == "sky" then
		frame(preview, 2, 79, 26, 10, C.text)
		frame(preview, 51, 83, 27, 10, C.text)
	end
end
function Hud.start()
	if started then
		return
	end
	started = true
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "WorldHud", false, 12
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	local open = button(gui, "WORLDS", 16, 155, 126, 28)
	open.Name = "OpenWorlds"
	local current = label(gui, "ROOKIE PARK", 0, 0, 250, 22, 12, C.muted)
	current.AnchorPoint, current.Position, current.TextXAlignment =
		Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 10), Enum.TextXAlignment.Center
	local panel = frame(gui, 0, 0, 500, 520, C.panel)
	panel.Name, panel.AnchorPoint, panel.Position, panel.Visible, panel.Active =
		"WorldSelection", Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), false, true
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	local heading = label(panel, "CHOOSE YOUR STADIUM", 22, 16, 430, 26, 21, C.text)
	heading.Font = Enum.Font.GothamBlack
	local best = label(panel, "CONFIRMED BEST  0 FT", 22, 46, 440, 22, 12, C.gold)
	local close = button(panel, "X", 456, 18, 26, 26)
	close.Activated:Connect(function()
		Controller.setOpen(false)
	end)
	local status =
		label(panel, "Travel is free. Coins, Power and records stay with you.", 22, 486, 456, 22, 11, C.muted)
	local rows: {
		{
			world: Config.Definition,
			row: Frame,
			nameLabel: TextLabel,
			description: TextLabel,
			track: Frame,
			action: TextButton,
			detail: TextLabel,
			fill: Frame,
			accent: Color3,
		}
	} =
		{}
	for index, world in Config.Worlds do
		local accent = Color3.fromRGB(world.accent[1], world.accent[2], world.accent[3])
		local row = frame(panel, 16, 78 + (index - 1) * 134, 468, 126, Color3.fromRGB(25, 32, 47))
		icon(row, world, accent)
		local nameLabel = label(row, world.name, 107, 13, 245, 25, 19, C.text)
		nameLabel.Font = Enum.Font.GothamBold
		local description = label(row, world.description, 107, 40, 346, 18, 11, C.muted)
		local detail = label(row, "", 107, 66, 240, 18, 11, accent)
		local track = frame(row, 107, 96, 230, 7, Color3.fromRGB(47, 55, 72))
		local fill = frame(track, 0, 0, 230, 7, accent)
		local action = button(row, "LOCKED", 350, 83, 102, 30)
		action.Name = `Travel_{world.id}`
		action.Activated:Connect(function()
			if not Controller.isOpen() or not action.Active then
				return
			end
			Controller.go(world.id, function(ok, reason)
				status.Text = if ok
					then "Welcome to your new stadium!"
					elseif reason == "FinishHitFirst" then "Finish your hit and camera return before traveling."
					elseif reason == "WorldFull" then "All lanes are occupied. Try again shortly."
					elseif reason == "RateLimited" then "Give travel a moment, then try again."
					elseif reason == "CharacterNotReady" then "Wait for your character to respawn."
					else "Travel unavailable. Refresh and try again."
			end)
		end)
		table.insert(rows, {
			world = world,
			row = row,
			nameLabel = nameLabel,
			description = description,
			track = track,
			action = action,
			detail = detail,
			fill = fill,
			accent = accent,
		})
	end
	local banner = label(gui, "", 0, 0, 450, 48, 19, C.gold)
	banner.Name, banner.AnchorPoint, banner.TextXAlignment, banner.Font =
		"WorldUnlock", Vector2.new(0.5, 0), Enum.TextXAlignment.Center, Enum.Font.GothamBlack
	local noticeUntil, noticeAt, unlockedHit = 0, 0, 0
	local value: Data.Snapshot?
	local initialized = false
	Progression.onSnapshot(function(snapshot)
		value = snapshot
		local world = Config.get(snapshot.worlds.currentWorld)
		current.Text = if world then string.upper(world.name) else "STADIUM"
		best.Text = string.format("ALL-TIME CONFIRMED BEST  %.0f FT", snapshot.worlds.qualifyingBestMeters / 0.3048)
		local notice = snapshot.worldUnlock
		if notice and notice.hitId > unlockedHit then
			unlockedHit = notice.hitId
			if initialized then
				local names = {}
				for _, id in notice.ids do
					local definition = Config.get(id)
					if definition then
						table.insert(names, string.upper(definition.name))
					end
				end
				banner.Text = table.concat(names, " + ") .. " UNLOCKED!"
				noticeAt, noticeUntil = os.clock(), os.clock() + 4.5
			end
		end
		initialized = true
	end)
	open.Activated:Connect(function()
		Controller.setOpen(not Controller.isOpen())
	end)
	Input.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and Input:GetFocusedTextBox() == nil then
			Controller.setOpen(false)
		end
	end)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	RunService:BindToRenderStep("WorldHud", Enum.RenderPriority.Camera.Value + 9, function()
		local size = gui.AbsoluteSize
		local short = size.Y < 420 and size.X > size.Y
		local width, height = if short then 780 else 500, if short then 300 else 520
		panel.Size = UDim2.fromOffset(width, height)
		scale.Scale = math.min(1, math.max(0.2, (size.X - 32) / width), math.max(0.2, (size.Y - 32) / height))
		local zoom = scale.Scale
		local compact = size.X < 700 or short
		heading.Text = if compact then "WORLDS" else "CHOOSE YOUR STADIUM"
		heading.TextSize = if compact then 21 / zoom else 21
		best.TextSize = if compact then 12 / zoom else 12
		heading.Size = UDim2.fromOffset(width - 110, 30 / zoom)
		best.Size = UDim2.fromOffset(width - 110, 22 / zoom)
		local closeSize = if compact then 44 / zoom else 26
		close.Size, close.Position =
			UDim2.fromOffset(closeSize, closeSize), UDim2.fromOffset(width - closeSize - 18, 14)
		status.Position, status.Size = UDim2.fromOffset(22, height - 34), UDim2.fromOffset(width - 44, 22 / zoom)
		status.TextSize = if compact then 11 / zoom else 11
		open.Size = UDim2.fromOffset(126, if compact then 44 else 28)
		local hudScale = math.clamp(
			math.min(size.X / 1280, size.Y / 720),
			ProgressionConfig.Hud.MinScale,
			ProgressionConfig.Hud.MaxScale
		)
		-- This GUI uses DeviceSafeInsets; progression respects the CoreGui inset.
		local topInset = GuiService:GetGuiInset().Y
		open.Position = UDim2.fromOffset(16, topInset + 22 + 94 * hudScale + 34)
		if Debug.isVisible() or Progression.isOpen() then
			Controller.setOpen(false)
		end
		panel.Visible = Controller.isOpen()
		open.Visible = not Debug.isVisible() and not Progression.isOpen() and not panel.Visible
		current.AnchorPoint = if size.X < 700 then Vector2.zero else Vector2.new(0.5, 0)
		current.Position = if size.X < 700
			then UDim2.fromOffset(152, topInset + 26 + 94 * hudScale + 34)
			else UDim2.new(0.5, 0, 0, 10)
		current.Size = UDim2.fromOffset(if size.X < 700 then math.max(100, size.X - 166) else 250, 22)
		current.TextSize = if size.X < 700 then 10 else 12
		current.Visible = not Debug.isVisible() and (size.X >= 700 or (not Progression.isOpen() and not panel.Visible))
		banner.Visible = not Debug.isVisible() and os.clock() < noticeUntil
		banner.Size = UDim2.fromOffset(math.min(450, size.X - 32), 48)
		banner.TextSize = if size.X < 600 then 14 else 19
		banner.Position =
			UDim2.new(0.5, 0, 0, (if size.X < 700 then 180 else 42) + 8 * math.exp(-(os.clock() - noticeAt) * 7))
		banner.TextTransparency = math.clamp((os.clock() - noticeUntil + 0.5) / 0.5, 0, 1)
		for index, row in rows do
			if short then
				row.row.Position, row.row.Size =
					UDim2.fromOffset(16 + (index - 1) * 250, 78), UDim2.fromOffset(240, 190)
				row.nameLabel.Position, row.nameLabel.Size = UDim2.fromOffset(16, 113), UDim2.fromOffset(210, 26 / zoom)
				row.detail.Position, row.detail.Size = UDim2.fromOffset(16, 147), UDim2.fromOffset(212, 22 / zoom)
				row.track.Position, row.track.Size = UDim2.fromOffset(16, 174), UDim2.fromOffset(208, 7)
				row.action.Position = UDim2.fromOffset(124, 28)
			else
				row.row.Position, row.row.Size =
					UDim2.fromOffset(16, 78 + (index - 1) * 134), UDim2.fromOffset(468, 126)
				row.nameLabel.Position, row.nameLabel.Size = UDim2.fromOffset(107, 13), UDim2.fromOffset(245, 26 / zoom)
				row.detail.Position, row.detail.Size = UDim2.fromOffset(107, 66), UDim2.fromOffset(240, 22 / zoom)
				row.track.Position, row.track.Size = UDim2.fromOffset(107, 96), UDim2.fromOffset(230, 7)
				row.action.Position = UDim2.fromOffset(350, if compact then 126 - 44 / zoom - 12 else 83)
			end
			row.description.Visible = not short
			row.description.TextSize = if compact then 11 / zoom else 11
			row.nameLabel.TextSize = if compact then 18 / zoom else 19
			row.detail.TextSize = if compact then 11 / zoom else 11
			row.action.Size = UDim2.fromOffset(102, if compact then 44 / zoom else 30)
			row.action.TextSize = if compact then 12 / zoom else 12
			local state = value and value.worlds
			local here = state ~= nil and state.currentWorld == row.world.id
			local available = state ~= nil and state.unlockedWorlds[row.world.id] == true
			row.action.Active = available and not here and not Controller.isPending()
			row.action.BackgroundColor3 = if available then row.accent else Color3.fromRGB(55, 63, 79)
			row.action.TextColor3 = if available then C.panel else C.muted
			row.action.Text = if here
				then "CURRENT"
				elseif not available then "LOCKED"
				elseif Controller.isPending() then "WAIT..."
				else "TRAVEL"
			local feet = if state then state.qualifyingBestMeters / 0.3048 else 0
			local fraction = if row.world.requiredFeet == 0 then 1 else math.clamp(feet / row.world.requiredFeet, 0, 1)
			row.fill.Size = UDim2.fromScale(fraction, 1)
			row.detail.Text = if available
				then (if here then "YOUR CURRENT STADIUM" else "UNLOCKED  /  FREE TRAVEL")
				else string.format(
					"%.0f / %d FT  (%d%%)",
					feet,
					row.world.requiredFeet,
					math.floor(fraction * 100)
				)
		end
	end)
end
return Hud
