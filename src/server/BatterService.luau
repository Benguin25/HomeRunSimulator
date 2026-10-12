--!strict
-- Assigns players to batting lanes, places their character at the batter
-- marker, and starts/stops the lane's pitching as the batter spawns, dies or
-- leaves. Players beyond the number of lanes wait in a queue.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local PitchConfig = require(Pitching.PitchConfig)
local PitchNet = require(Pitching.PitchNet)

local BattedBallServer = require(script.Parent.BattedBallServer)
local PitchServer = require(script.Parent.PitchServer)
local GameplayServer = require(script.Parent.GameplayServer)

local BatterService = {}

local laneBatter: { [string]: Player } = {}
local waiting: { Player } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}

local function disconnectAll(list: { RBXScriptConnection }?)
	if list then
		for _, connection in list do
			connection:Disconnect()
		end
		table.clear(list)
	end
end

local function getLaneOf(player: Player): string?
	for laneId, batter in laneBatter do
		if batter == player then
			return laneId
		end
	end
	return nil
end

local function placeCharacter(laneId: string, character: Model)
	local geometry = PitchServer.getGeometry(laneId)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not geometry or not humanoid or not root or not root:IsA("BasePart") then
		return
	end

	-- R15: root center sits HipHeight + half the root's height above the ground.
	local rootHeight = if humanoid.RigType == Enum.HumanoidRigType.R15
		then humanoid.HipHeight + root.Size.Y / 2
		else PitchConfig.Batter.HeightAboveMarkerStuds
	character:PivotTo(geometry.batterCFrame + Vector3.new(0, rootHeight, 0))

	if PitchConfig.Batter.LockMovement then
		humanoid.WalkSpeed = 0
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
		root.Anchored = true
	end
end

local function onCharacterAdded(player: Player, character: Model)
	disconnectAll(characterConnections[player])
	local laneId = getLaneOf(player)
	if not laneId then
		return
	end

	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root or character.Parent == nil or player.Character ~= character then
		return
	end
	assert(humanoid:IsA("Humanoid"))

	-- Defer so the default spawn placement has finished before we move the character.
	task.defer(function()
		if player.Character ~= character or getLaneOf(player) ~= laneId then
			return
		end
		placeCharacter(laneId, character)
		GameplayServer.character(player, laneId, true)
		PitchServer.startLane(laneId)
	end)

	characterConnections[player] = {
		humanoid.Died:Connect(function()
			if getLaneOf(player) == laneId then
				GameplayServer.character(player, laneId, false)
				PitchServer.stopLane(laneId, "BatterDied")
			end
		end),
	}
end

local function assignLane(player: Player, laneId: string)
	laneBatter[laneId] = player
	player:SetAttribute(PitchNet.PlayerLaneAttribute, laneId)
	PitchServer.setBatter(laneId, player.UserId)
	GameplayServer.assign(player, laneId)
	local character = player.Character
	if character then
		task.spawn(onCharacterAdded, player, character)
	end
end

local function tryAssign(player: Player): boolean
	for _, laneId in PitchServer.getLaneIds() do
		if not laneBatter[laneId] then
			assignLane(player, laneId)
			return true
		end
	end
	return false
end

local function onPlayerAdded(player: Player)
	playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end),
		player.CharacterRemoving:Connect(function()
			disconnectAll(characterConnections[player])
			local laneId = getLaneOf(player)
			if laneId then
				GameplayServer.character(player, laneId, false)
				PitchServer.stopLane(laneId, "CharacterRemoved")
			end
		end),
	}
	if not tryAssign(player) then
		table.insert(waiting, player)
	end
end

local function onPlayerRemoving(player: Player)
	disconnectAll(playerConnections[player])
	disconnectAll(characterConnections[player])
	playerConnections[player] = nil
	characterConnections[player] = nil

	local index = table.find(waiting, player)
	if index then
		table.remove(waiting, index)
	end

	local laneId = getLaneOf(player)
	if laneId then
		laneBatter[laneId] = nil
		-- A ball in the air is abandoned with its batter. (A reset or death keeps
		-- it: the outcome is already determined, and the lane stays paused
		-- until it resolves, so the respawned batter never faces a pitch mid-flight.)
		BattedBallServer.cancelLane(laneId, "BatterLeft")
		PitchServer.stopLane(laneId, "BatterLeft")
		PitchServer.setBatter(laneId, nil)
		local nextPlayer = table.remove(waiting, 1)
		if nextPlayer then
			assignLane(nextPlayer, laneId)
		end
	end
end

function BatterService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return BatterService
