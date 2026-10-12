--!strict
-- One screen-space cyan diamond at the true contact-plane crossing. No text,
-- trajectory drawings, Instances in Workspace, remotes or published bindings.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = RS:WaitForChild("Shared")
local Config = require(Shared.Presentation.PitchPreviewConfig)
local Preview = require(Shared.Presentation.PitchPreview)
local Toggle = require(Shared.Presentation.DebugToggle)
local Edge = require(Shared.Presentation.ActionInput)
local Gameplay = require(Shared.Gameplay.GameplayConfig)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local PitchNet = require(Shared.Pitching.PitchNet)
local PitchVisual = require(script.Parent.PitchVisualController)
local Camera = require(script.Parent.BattingCamera)
local Binding = require(script.Parent.ActionBinding)
local View = {}
local started = false
function View.start()
	if started or not Preview.allowed(RunService:IsStudio(), Config.Enabled) then
		return
	end
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[Config.ToggleKey]
	end)
	if
		not ok
		or not Edge.distinct(
			Config.ToggleKey,
			{ PitchConfig.Debug.ToggleKey, Gameplay.Hud.SkipKey, Gameplay.Hud.StatsKey }
		)
	then
		warn("[PitchPreview] Invalid/conflicting preview key; preview disabled.")
		return
	end
	started = true
	local state = Preview.new(true)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder = "PitchPreviewHud", false, true, 11
	gui.Enabled = false
	local marker = Instance.new("Frame")
	marker.Name, marker.AnchorPoint = "ContactPlaneTarget", Vector2.new(0.5, 0.5)
	marker.Size, marker.Rotation = UDim2.fromOffset(Config.MarkerPixels, Config.MarkerPixels), 45
	marker.BackgroundTransparency, marker.BorderSizePixel = 0.2, 0
	marker.BackgroundColor3, marker.Visible = Color3.fromRGB(55, 230, 255), false
	local border = Instance.new("UIStroke")
	border.Color, border.Thickness, border.Parent = Color3.fromRGB(7, 32, 45), 2, marker
	marker.Parent, gui.Parent = gui, Players.LocalPlayer:WaitForChild("PlayerGui")
	local function lane()
		local value = Players.LocalPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
		Preview.setLane(state, if typeof(value) == "string" then value else nil)
		marker.Visible = false
		if state.laneId then
			local geometry = PitchVisual.getGeometry(state.laneId)
			local flight = PitchVisual.getActiveFlight(state.laneId)
			if geometry and flight then
				Preview.begin(state, geometry, flight)
			end
		end
	end
	Players.LocalPlayer:GetAttributeChangedSignal(PitchNet.PlayerLaneAttribute):Connect(lane)
	Players.LocalPlayer.CharacterRemoving:Connect(function()
		if state.target then
			Preview.finish(state, state.target.laneId, state.target.pitchId)
		end
		marker.Visible = false
	end)
	PitchVisual.onPitchStarted(function(geometry, flight)
		Preview.begin(state, geometry, flight)
	end)
	PitchVisual.onPitchResult(function(result)
		Preview.finish(state, result.laneId, result.pitchId)
	end)
	PitchVisual.onPitchAborted(function(laneId, pitchId, _, atTime)
		if atTime then
			Preview.cut(state, laneId, pitchId, atTime, true)
		else
			Preview.finish(state, laneId, pitchId)
		end
	end)
	PitchVisual.onPitchCut(function(laneId, pitchId, atTime)
		if atTime then
			Preview.cut(state, laneId, pitchId, atTime, false)
		else
			Preview.uncut(state, laneId, pitchId)
		end
	end)
	lane()
	Binding.bind("HomeRunPitchPreviewToggle", key, Config.InputPriority, function()
		return true
	end, function()
		Toggle.input(state.toggle, true, false)
		Toggle.release(state.toggle)
		gui.Enabled = state.toggle.visible
	end)
	RunService:BindToRenderStep("PitchPreview", Enum.RenderPriority.Camera.Value + 5, function()
		local camera = Workspace.CurrentCamera
		local position = Preview.position(state, Workspace:GetServerTimeNow(), Camera.isBattingView())
		marker.Visible = false
		if camera and position then
			local screen, visible = camera:WorldToViewportPoint(position)
			marker.Position = UDim2.fromOffset(screen.X, screen.Y)
			marker.Visible = visible and screen.Z > 0
		end
	end)
end
return View
