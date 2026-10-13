--!strict
-- Runtime interaction overlays; never edits authored Stadium or marker parts.
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Gameplay.BattingModeConfig)
local Geometry = require(Shared.Pitching.LaneGeometry)
local Worlds = require(script.Parent.Worlds.WorldRegistry)
local PitchServer = require(script.Parent.PitchServer)
local Boxes = {}
local spawns: { [string]: CFrame } = {}
local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name, p.CFrame, p.Size, p.Transparency = name, cf, size, transparency
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Color, p.Material = Color3.fromRGB(241, 235, 216), Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end
function Boxes.spawn(worldId: string): CFrame?
	return spawns[worldId]
end
function Boxes.create(triggered: (Player, string, string) -> ())
	local generated = Worlds.initialize()
	local rookie = Instance.new("Model")
	rookie.Name, rookie.ModelStreamingMode = "RookieBattingInteractions", Enum.ModelStreamingMode.PersistentPerPlayer
	rookie.Parent = generated
	for _, laneId in PitchServer.getLaneIds() do
		local geo = assert(PitchServer.getGeometry(laneId))
		local world = assert(Worlds.worldForLane(laneId))
		local container = Instance.new("Folder")
		container.Name = `BattingBoxes_{laneId}`
		container.Parent = Worlds.model(world) or rookie
		if not spawns[world] then
			local p = geo.plateGround - geo.toPitcher * geo.units.toStuds(Config.SpawnBackMeters)
			local params = RaycastParams.new()
			params.FilterType, params.FilterDescendantsInstances =
				Enum.RaycastFilterType.Include, Worlds.collisionRoots(laneId)
			params.RespectCanCollide = true
			local ground = Workspace:Raycast(p + geo.up * 30, -geo.up * 60, params)
			if ground then
				p = ground.Position
			end
			spawns[world] = CFrame.lookAt(p, p + geo.toPitcher)
		end
		for _, side in { "Right", "Left" } do
			local point = Geometry.boxGround(geo, side :: "Right" | "Left")
			local frame = CFrame.lookAt(point, point + geo.toPitcher)
			local anchor = part(container, `{side}BatterBox`, frame + geo.up * 1.5, Vector3.one * 0.1, 1)
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name, prompt.ObjectText, prompt.ActionText = "EnterBatting", `{side}-handed batter`, "Start batting"
			prompt.KeyboardKeyCode, prompt.GamepadKeyCode = Enum.KeyCode.E, Enum.KeyCode.ButtonX
			prompt.MaxActivationDistance, prompt.HoldDuration = Config.PromptDistanceStuds, 0
			prompt.RequiresLineOfSight = false
			prompt:SetAttribute("BattingBox", true)
			prompt.Parent = anchor
			prompt.Triggered:Connect(function(player)
				triggered(player, laneId, side)
			end)
			-- Rookie already has authored outlines. Generated worlds get a bounded overlay.
			if world ~= "rookie" then
				local width, length =
					geo.units.toStuds(Config.BoxWidthMeters), geo.units.toStuds(Config.BoxLengthMeters)
				for _, sign in { -1, 1 } do
					part(
						container,
						"BoxLine",
						frame * CFrame.new(sign * width / 2, 0.18, 0),
						Vector3.new(0.07, 0.03, length),
						0
					)
					part(
						container,
						"BoxLine",
						frame * CFrame.new(0, 0.18, sign * length / 2),
						Vector3.new(width, 0.03, 0.07),
						0
					)
				end
			end
		end
	end
end
return Boxes
