--!strict
-- Sole owner of batting/menu cursor and native interaction availability.
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Prompts = game:GetService("ProximityPromptService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Policy = require(Shared.Presentation.InputMode)
local Config = require(Shared.Gameplay.BattingModeConfig)
local LoadingConfig = require(Shared.Presentation.LoadingConfig)
local Coordinator = {}
local state = Policy.new()
local player = Players.LocalPlayer
local function refresh()
	state.batting = player:GetAttribute(Config.ModeAttribute) == "Batting"
	state.leaving = player:GetAttribute(Config.ExitAttribute) == true
	UIS.MouseIconEnabled = Policy.cursor(state)
	-- Free roam leaves Roblox's third-person drag/shift-lock behavior alone.
	if state.batting or Policy.blocked(state) then
		UIS.MouseBehavior = Enum.MouseBehavior.Default
	end
	Prompts.Enabled = not state.batting and not state.leaving and not Policy.blocked(state)
end
function Coordinator.menu(name: string, opened: boolean)
	Policy.menu(state, name, opened, os.clock())
	refresh()
end
function Coordinator.isMenuOpen(): boolean
	return Policy.blocked(state)
end
function Coordinator.canAim(): boolean
	return Policy.canSwing(state, os.clock(), UIS:GetFocusedTextBox() ~= nil)
end
function Coordinator.canSwing(): boolean
	if not Coordinator.canAim() then
		return false
	end
	-- Active HUD surfaces (including menu-opening buttons) consume clicks even
	-- when Roblox does not mark their InputBegan as processed.
	local mouse = UIS:GetMouseLocation()
	for _, object in player.PlayerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y) do
		if object:IsA("GuiButton") or object:IsA("TextBox") or object.Active then
			return false
		end
	end
	return true
end
function Coordinator.start()
	Coordinator.menu("Loading", player:GetAttribute(LoadingConfig.ActiveAttribute) == true)
	player:GetAttributeChangedSignal(LoadingConfig.ActiveAttribute):Connect(function()
		Coordinator.menu("Loading", player:GetAttribute(LoadingConfig.ActiveAttribute) == true)
	end)
	player:GetAttributeChangedSignal(Config.ModeAttribute):Connect(refresh)
	player:GetAttributeChangedSignal(Config.ExitAttribute):Connect(refresh)
	GuiService.MenuOpened:Connect(function()
		Coordinator.menu("Roblox", true)
	end)
	GuiService.MenuClosed:Connect(function()
		Coordinator.menu("Roblox", false)
	end)
	UIS.TextBoxFocused:Connect(function()
		Coordinator.menu("TextBox", true)
	end)
	UIS.TextBoxFocusReleased:Connect(function()
		Coordinator.menu("TextBox", false)
	end)
	-- Roblox's camera may reapply shift-lock while a custom menu is open.
	-- Apply the shared pointer policy after that camera update.
	game:GetService("RunService"):BindToRenderStep("HomeRunPointer", Enum.RenderPriority.Camera.Value + 2, function()
		UIS.MouseIconEnabled = Policy.cursor(state)
		if state.batting or Policy.blocked(state) then
			UIS.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)
	refresh()
end
return Coordinator
