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

local ProgressionServer = require(script.Parent.ProgressionServer)
local Worlds = require(script.Parent.Worlds.WorldRegistry)
local Selection = require(ReplicatedStorage.Shared.Worlds.LaneSelection)
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
	if
		not humanoid
		or not root
		or character.Parent == nil
		or player.Character ~= character
		or getLaneOf(player) ~= laneId
	then
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
	local laneId =
		Selection.free(PitchServer.getLaneIds(), laneBatter, Worlds.worldForLane, ProgressionServer.world(player))
	if not laneId then
		return false
	end
	assignLane(player, laneId)
	return true
end

local function drainWaiting()
	local index = 1
	while index <= #waiting do
		local player = waiting[index]
		if not player.Parent or tryAssign(player) then
			table.remove(waiting, index)
		else
			index += 1
		end
	end
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
	player:SetAttribute("CurrentWorld", ProgressionServer.world(player))
	Worlds.visibility(player, nil, ProgressionServer.world(player))
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
		GameplayServer.release(player, laneId)
		drainWaiting()
	end
end

-- Non-yielding transaction: select destination first; never abandon a hit.
function BatterService.travel(player: Player, target: any, sequence: any, expectedWorld: any)
	local oldLane = getLaneOf(player)
	local destination: string? = nil
	if typeof(target) == "string" then
		destination = Selection.free(PitchServer.getLaneIds(), laneBatter, Worlds.worldForLane, target)
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local previous = ProgressionServer.world(player)
	local result = ProgressionServer.travel(player, target, sequence, expectedWorld, {
		characterReady = character ~= nil
			and character.Parent ~= nil
			and humanoid ~= nil
			and humanoid.Health > 0
			and character:FindFirstChild("HumanoidRootPart") ~= nil,
		hitBusy = oldLane ~= nil and BattedBallServer.getActiveHit(oldLane) ~= nil,
		returnReady = oldLane == nil or GameplayServer.travelReady(player, oldLane),
		laneAvailable = destination ~= nil,
	})
	if result.ok then
		assert(destination, "travel reserved a destination")
		disconnectAll(characterConnections[player])
		if oldLane then
			PitchServer.stopLane(oldLane, "WorldTravel")
			PitchServer.setBatter(oldLane, nil)
			GameplayServer.release(player, oldLane)
			laneBatter[oldLane] = nil
		end
		local index = table.find(waiting, player)
		if index then
			table.remove(waiting, index)
		end
		Worlds.visibility(player, previous, target)
		player:SetAttribute("CurrentWorld", target)
		assignLane(player, destination)
		-- Place synchronously; character readiness/start is deferred and lane-guarded.
		if character then
			placeCharacter(destination, character)
		end
		ProgressionServer.publish(player)
		drainWaiting()
	end
	return ProgressionServer.snapshot(player), result
end
function BatterService.start()
	local runtime = Instance.new("Folder")
	runtime.Name = "WorldRuntime"
	local travel = Instance.new("RemoteFunction")
	travel.Name, travel.Parent = "Travel", runtime
	travel.OnServerInvoke = BatterService.travel
	runtime.Parent = ReplicatedStorage
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return BatterService
