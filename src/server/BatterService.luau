--!strict
-- Explicit lane reservation; free roam never consumes batting capacity.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchConfig = require(Shared.Pitching.PitchConfig)
local PitchNet = require(Shared.Pitching.PitchNet)
local Geometry = require(Shared.Pitching.LaneGeometry)
local Config = require(Shared.Gameplay.BattingModeConfig)
local Rules = require(Shared.Gameplay.BattingModeRules)
local BattedBallServer = require(script.Parent.BattedBallServer)
local PitchServer = require(script.Parent.PitchServer)
local GameplayServer = require(script.Parent.GameplayServer)
local ProgressionServer = require(script.Parent.ProgressionServer)
local Worlds = require(script.Parent.Worlds.WorldRegistry)
local Boxes = require(script.Parent.BatterBoxes)
local Movement = require(Shared.Gameplay.BattingMovement)
local Service = {}
type State = {
	lane: string?,
	epoch: number,
	leaving: boolean,
	guard: Rules.Guard,
	promptAt: number,
	movement: Movement.Saved?,
	connections: { RBXScriptConnection },
	characterConnections: { RBXScriptConnection },
}
local states: { [Player]: State } = {}
local owners: { [string]: Player? } = {}
local epoch = 0
local notice: RemoteEvent

local function disconnect(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end
local function living(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if
		not character
		or not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not root
		or not root:IsA("BasePart")
	then
		return nil, nil, nil
	end
	return character, humanoid, root
end
local function notify(player: Player, reason: string)
	notice:FireClient(player, reason)
end
local function restore(state: State)
	local m = state.movement
	state.movement = nil
	if not m then
		return
	end
	Movement.restore(m)
end
local function groundCFrame(player: Player, cf: CFrame)
	local character, humanoid, root = living(player)
	if not character or not humanoid or not root then
		return
	end
	local height = if humanoid.RigType == Enum.HumanoidRigType.R15
		then humanoid.HipHeight + root.Size.Y / 2
		else PitchConfig.Batter.HeightAboveMarkerStuds
	character:PivotTo(cf + Vector3.new(0, height, 0))
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
end
local function spawnRoam(player: Player)
	if not ProgressionServer.ready(player) then
		return
	end
	local world = ProgressionServer.world(player)
	local cf = Boxes.spawn(world)
	if cf then
		groundCFrame(player, cf)
	end
end
local function finishExit(player: Player, state: State, moveOutside: boolean)
	local lane = state.lane
	if not lane then
		return
	end
	-- Never release an authoritative hit through an entry/exit/travel request.
	assert(Rules.canRelease(BattedBallServer.getActiveHit(lane) ~= nil))
	PitchServer.stopLane(lane, "LeftBatting")
	PitchServer.setBatter(lane, nil)
	GameplayServer.release(player, lane)
	owners[lane], state.lane, state.leaving = nil, nil, false
	restore(state)
	player:SetAttribute(Config.ModeAttribute, "FreeRoam")
	player:SetAttribute(Config.ExitAttribute, false)
	player:SetAttribute(PitchNet.PlayerLaneAttribute, nil)
	if moveOutside then
		local geo = PitchServer.getGeometry(lane)
		if geo then
			local p = geo.batterCFrame.Position - geo.toPitcher * geo.units.toStuds(Config.ExitBackMeters)
			groundCFrame(player, CFrame.lookAt(p, p + geo.toPitcher))
		end
	end
	GameplayServer.publish(player)
end

function Service.enter(player: Player, laneId: any, side: any): (boolean, string)
	local state = states[player]
	if not state then
		return false, "UnknownPlayer"
	end
	local now = Workspace:GetServerTimeNow()
	local elapsed = now - state.promptAt
	state.promptAt = now
	if elapsed < Config.RequestGapSeconds then
		return false, "RateLimited"
	end
	local character, humanoid, root = living(player)
	local geo = if typeof(laneId) == "string" then PitchServer.getGeometry(laneId) else nil
	if not geo then
		return false, "UnknownLane"
	end
	local validSide = side == "Right" or side == "Left"
	local point = if validSide then Geometry.boxGround(geo, side) else geo.plateGround
	local reason = Rules.entry({
		profileReady = ProgressionServer.ready(player),
		characterReady = character ~= nil,
		assigned = state.lane ~= nil,
		sameWorld = Worlds.worldForLane(laneId) == ProgressionServer.world(player),
		laneAvailable = owners[laneId] == nil and BattedBallServer.getActiveHit(laneId) == nil,
		distance = if root then (root.Position - point).Magnitude else math.huge,
		side = side,
	})
	if reason then
		return false, reason
	end
	assert(character and humanoid and root, "entry validated character")
	-- No yields from validation to reservation/readiness initialization.
	epoch += 1
	state.epoch, state.lane, owners[laneId] = epoch, laneId, player
	local movement = Movement.capture(humanoid, root)
	state.movement = movement
	PitchServer.selectBox(laneId, side)
	geo = assert(PitchServer.getGeometry(laneId))
	groundCFrame(player, geo.batterCFrame)
	Movement.lock(movement)
	player:SetAttribute(Config.EpochAttribute, epoch)
	player:SetAttribute(Config.ExitAttribute, false)
	player:SetAttribute(Config.ModeAttribute, "Batting")
	player:SetAttribute(PitchNet.PlayerLaneAttribute, laneId)
	PitchServer.setBatter(laneId, player.UserId)
	GameplayServer.assign(player, laneId)
	GameplayServer.character(player, laneId, true)
	PitchServer.startLane(laneId) -- canStartPitch still requires validated camera readiness
	return true, "Entered"
end

function Service.exit(player: Player, sequence: any, expectedLane: any, expectedEpoch: any): (boolean, string)
	local state = states[player]
	if not state then
		return false, "UnknownPlayer"
	end
	local rejection = Rules.request(state.guard, Workspace:GetServerTimeNow(), sequence)
		or Rules.exit(
			state.lane ~= nil and state.lane == expectedLane and owners[state.lane :: string] == player,
			expectedEpoch,
			state.epoch,
			state.leaving
		)
	if rejection then
		return false, rejection
	end
	local lane = assert(state.lane, "exit validated assignment")
	state.leaving = true
	player:SetAttribute(Config.ExitAttribute, true)
	PitchServer.stopLane(lane, "ExitRequested")
	if Rules.canRelease(BattedBallServer.getActiveHit(lane) ~= nil) then
		finishExit(player, state, true)
		return true, "Exited"
	end
	return true, "FinishingHit"
end

local function characterAdded(player: Player, character: Model)
	local state = states[player]
	if not state then
		return
	end
	disconnect(state.characterConnections)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if player.Character ~= character or not character.Parent or not humanoid or not root then
		return
	end
	assert(humanoid:IsA("Humanoid"))
	task.defer(function()
		if player.Character ~= character or not states[player] then
			return
		end
		player:SetAttribute(Config.ModeAttribute, "FreeRoam")
		spawnRoam(player)
		if state.lane then
			-- Death/reset retains only the pending result reservation, never the stance.
			state.leaving = true
			player:SetAttribute(Config.ExitAttribute, true)
			GameplayServer.character(player, state.lane, true)
		end
	end)
	state.characterConnections = {
		humanoid.Died:Connect(function()
			if state.lane then
				state.leaving = true
				player:SetAttribute(Config.ExitAttribute, true)
				player:SetAttribute(Config.ModeAttribute, "FreeRoam")
				PitchServer.stopLane(state.lane, "BatterDied")
				GameplayServer.character(player, state.lane, false)
				restore(state)
				if Rules.canRelease(BattedBallServer.getActiveHit(state.lane) ~= nil) then
					finishExit(player, state, false)
				end
			end
		end),
	}
end
local function added(player: Player)
	local state: State = {
		lane = nil,
		epoch = 0,
		leaving = false,
		guard = Rules.new(),
		promptAt = -math.huge,
		movement = nil,
		connections = {},
		characterConnections = {},
	}
	states[player] = state
	player:SetAttribute(Config.ModeAttribute, "FreeRoam")
	player:SetAttribute(Config.ExitAttribute, false)
	player:SetAttribute(PitchNet.PlayerLaneAttribute, nil)
	local function profileReady()
		if ProgressionServer.ready(player) and not state.lane then
			local previous = player:GetAttribute("CurrentWorld")
			local world = ProgressionServer.world(player)
			Worlds.visibility(player, if typeof(previous) == "string" then previous else nil, world)
			player:SetAttribute("CurrentWorld", world)
			spawnRoam(player)
		end
	end
	state.connections = {
		player:GetAttributeChangedSignal("ProfileState"):Connect(profileReady),
		player.CharacterAdded:Connect(function(character)
			characterAdded(player, character)
		end),
		player.CharacterRemoving:Connect(function()
			disconnect(state.characterConnections)
			if state.lane then
				state.leaving = true
				player:SetAttribute(Config.ExitAttribute, true)
				player:SetAttribute(Config.ModeAttribute, "FreeRoam")
				PitchServer.stopLane(state.lane, "CharacterRemoved")
				GameplayServer.character(player, state.lane, false)
				restore(state)
				if Rules.canRelease(BattedBallServer.getActiveHit(state.lane) ~= nil) then
					finishExit(player, state, false)
				end
			end
		end),
	}
	profileReady()
	if player.Character then
		task.spawn(characterAdded, player, player.Character)
	end
end
local function removing(player: Player)
	local state = states[player]
	if not state then
		return
	end
	disconnect(state.connections)
	disconnect(state.characterConnections)
	restore(state)
	local lane = state.lane
	if lane then
		-- Disconnect retains the existing abandoned-hit policy.
		BattedBallServer.cancelLane(lane, "BatterLeft")
		PitchServer.stopLane(lane, "BatterLeft")
		PitchServer.setBatter(lane, nil)
		GameplayServer.release(player, lane)
		owners[lane] = nil
	end
	states[player] = nil
end

function Service.travel(player: Player, target: any, sequence: any, expectedWorld: any)
	local state = states[player]
	local lane = state and state.lane
	local character = living(player)
	local previous = ProgressionServer.world(player)
	local result = ProgressionServer.travel(player, target, sequence, expectedWorld, {
		characterReady = character ~= nil,
		hitBusy = lane ~= nil and BattedBallServer.getActiveHit(lane) ~= nil,
		returnReady = lane == nil or GameplayServer.travelReady(player, lane),
		-- Free roam has no batting capacity requirement, even if all boxes are occupied.
		laneAvailable = typeof(target) == "string" and Boxes.spawn(target) ~= nil,
	})
	if result.ok then
		if state and lane then
			finishExit(player, state, false)
		end
		Worlds.visibility(player, previous, target)
		player:SetAttribute("CurrentWorld", target)
		player:SetAttribute(Config.ModeAttribute, "FreeRoam")
		spawnRoam(player)
		ProgressionServer.publish(player)
	end
	return ProgressionServer.snapshot(player), result
end
function Service.start()
	local runtime = Instance.new("Folder")
	runtime.Name = "WorldRuntime"
	local travel = Instance.new("RemoteFunction")
	travel.Name, travel.Parent = "Travel", runtime
	travel.OnServerInvoke = Service.travel
	local exit = Instance.new("RemoteFunction")
	exit.Name, exit.Parent = "ExitBatting", runtime
	exit.OnServerInvoke = Service.exit
	notice = Instance.new("RemoteEvent")
	notice.Name, notice.Parent = "BattingNotice", runtime
	runtime.Parent = ReplicatedStorage
	Boxes.create(function(player, lane, side)
		local _, reason = Service.enter(player, lane, side)
		notify(player, reason)
	end)
	Players.PlayerAdded:Connect(added)
	Players.PlayerRemoving:Connect(removing)
	for _, player in Players:GetPlayers() do
		task.spawn(added, player)
	end
	RunService.Heartbeat:Connect(function()
		for player, state in states do
			local lane = state.lane
			if lane and state.leaving and Rules.canRelease(BattedBallServer.getActiveHit(lane) ~= nil) then
				finishExit(player, state, player:GetAttribute(Config.ModeAttribute) == "Batting")
			end
		end
	end)
end
return Service
