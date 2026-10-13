--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Gameplay.BattingModeConfig)
local Net = require(Shared.Pitching.PitchNet)
local Input = require(script.Parent.InputCoordinator)
local Debug = require(script.Parent.PitchDebugView)
local Controller = {}
local player = Players.LocalPlayer
local sequence, pending = 0, false
local exit: RemoteFunction
local hint: TextButton
local message = ""
local messageUntil = 0
local captions: { [string]: string } = {
	Entered = "",
	Exited = "",
	FinishingHit = "Leaving after this hit finishes...",
	LaneOccupied = "This lane is occupied. Try another box.",
	TooFarAway = "Move closer to the batter's box.",
	DataUnavailable = "Waiting for your profile...",
	RateLimited = "Please wait a moment.",
	CharacterNotReady = "Waiting for your character...",
	AlreadyBatting = "Already batting.",
}
local function show(reason: string)
	message = captions[reason] or reason
	messageUntil = os.clock() + 3
end
function Controller.leave()
	if pending or UIS:GetFocusedTextBox() then
		return
	end
	local lane, epoch = player:GetAttribute(Net.PlayerLaneAttribute), player:GetAttribute(Config.EpochAttribute)
	if typeof(lane) ~= "string" or player:GetAttribute(Config.ExitAttribute) == true then
		return
	end
	pending = true
	sequence += 1
	task.spawn(function()
		local ok, _, reason = pcall(function()
			return exit:InvokeServer(sequence, lane, epoch)
		end)
		pending = false
		show(if ok then reason else "ConnectionError")
	end)
end
function Controller.start()
	local runtime = ReplicatedStorage:WaitForChild("WorldRuntime")
	exit = runtime:WaitForChild("ExitBatting") :: RemoteFunction
	(runtime:WaitForChild("BattingNotice") :: RemoteEvent).OnClientEvent:Connect(show)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BattingModeHud", false, 8
	hint = Instance.new("TextButton")
	hint.Name, hint.AnchorPoint = "ModeHint", Vector2.new(0.5, 0)
	hint.Position, hint.Size = UDim2.new(0.5, 0, 0, 145), UDim2.new(0.6, 0, 0, 44)
	hint.BackgroundTransparency, hint.TextColor3 = 0.25, Color3.fromRGB(240, 241, 248)
	hint.BackgroundColor3, hint.Font, hint.TextSize = Color3.fromRGB(20, 26, 38), Enum.Font.GothamMedium, 14
	hint.TextWrapped = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, 10), hint
	hint.Parent, gui.Parent = gui, player:WaitForChild("PlayerGui")
	hint.Activated:Connect(Controller.leave)
	UIS.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.E then
			Controller.leave()
		end
	end)
	game:GetService("RunService").RenderStepped:Connect(function()
		local batting = player:GetAttribute(Config.ModeAttribute) == "Batting"
		local leaving = player:GetAttribute(Config.ExitAttribute) == true
		hint.Visible = not Debug.isVisible() and not Input.isMenuOpen()
		hint.Text = if leaving
			then "Leaving after the confirmed hit and camera return..."
			elseif os.clock() < messageUntil and message ~= "" then message
			elseif batting then "Aim with mouse  •  Click to swing  •  E to leave"
			else "Explore the stadium  •  Approach either batter's box and press E"
		hint.Active = batting and not leaving
	end)
end
return Controller
