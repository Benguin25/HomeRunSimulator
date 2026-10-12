--!strict
-- Distinct source-built arenas; four independent home diamonds per world.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local Build = require(script.Parent.Construction)
local Builder = {}
local white = Color3.fromRGB(233, 241, 249)
local function diamond(parent: Instance, frame: CFrame, markers: Instance, accent: Color3)
	local base = 27.432 / PitchConfig.Units.MetersPerStud / math.sqrt(2)
	Build.part(
		parent,
		"Infield",
		Vector3.new(base * 2, 0.1, base * 2),
		frame * CFrame.new(0, 0.06, -base) * CFrame.Angles(0, math.pi / 4, 0),
		Color3.fromRGB(173, 116, 74),
		false,
		Enum.Material.Sand
	)
	for _, p in
		{ Vector3.zero, Vector3.new(base, 0, -base), Vector3.new(0, 0, -base * 2), Vector3.new(-base, 0, -base) }
	do
		Build.part(
			parent,
			"Base",
			Vector3.new(2, 0.12, 2),
			frame * CFrame.new(p + Vector3.new(0, 0.15, 0)),
			white,
			false
		)
	end
	for _, sign in { -1, 1 } do
		Build.line(parent, frame, Vector3.new(0, 0.16, 0), Vector3.new(sign * 380, 0.16, -380), 0.65, white)
		Build.part(
			parent,
			"FoulPole",
			Vector3.new(1.5, 70, 1.5),
			frame * CFrame.new(sign * 380, 35, -380),
			accent,
			false,
			Enum.Material.Neon
		)
		Build.marker(
			markers,
			if sign == -1 then "LeftFoulPole" else "RightFoulPole",
			frame:PointToWorldSpace(Vector3.new(sign * 380, 0, -380))
		)
	end
	local pitcher = Vector3.new(0, 0, -PitchConfig.Geometry.MoundToPlateMeters / PitchConfig.Units.MetersPerStud)
	Build.part(
		parent,
		"Mound",
		Vector3.new(16, 0.18, 16),
		frame * CFrame.new(pitcher + Vector3.new(0, 0.12, 0)),
		Color3.fromRGB(173, 116, 74),
		false
	)
	Build.part(
		parent,
		"PitchingRubber",
		Vector3.new(3, 0.1, 0.5),
		frame * CFrame.new(pitcher + Vector3.new(0, 0.25, 0)),
		white,
		false
	)
	Build.marker(markers, "HomePlate", frame.Position)
	Build.marker(markers, "PitcherMarker", frame:PointToWorldSpace(pitcher))
	-- Explicit batter marker uses the same shared handedness/offset convention.
	local batterSide = if PitchConfig.Geometry.BatterSide == "Left" then 1 else -1
	Build.marker(
		markers,
		"BatterMarker",
		frame:PointToWorldSpace(
			Vector3.new(
				batterSide * PitchConfig.Geometry.BatterOffsetFromPlateMeters / PitchConfig.Units.MetersPerStud,
				0,
				0
			)
		)
	)
	-- Release remains derived by LaneGeometry.
	Build.marker(markers, "FirstBase", frame:PointToWorldSpace(Vector3.new(base, 0, -base)))
	Build.marker(markers, "ThirdBase", frame:PointToWorldSpace(Vector3.new(-base, 0, -base)))
end
local function powerArena(parent: Instance, frame: CFrame, accent: Color3)
	local dark = Color3.fromRGB(65, 78, 98)
	-- Stepped rectangular grandstands and cantilever canopies outside foul territory.
	for _, side in { -1, 1 } do
		for tier = 1, 7 do
			Build.part(
				parent,
				"GrandstandTier",
				Vector3.new(20, 5, 470),
				frame * CFrame.new(side * (465 + tier * 18), tier * 6, -150),
				if tier % 2 == 0 then dark else Color3.fromRGB(104, 126, 155),
				true
			)
		end
		Build.part(parent, "Canopy", Vector3.new(190, 6, 500), frame * CFrame.new(side * 570, 92, -150), dark, true)
		Build.part(
			parent,
			"CanopyLight",
			Vector3.new(185, 1, 3),
			frame * CFrame.new(side * 570, 90, 99),
			accent,
			false,
			Enum.Material.Neon
		)
		for _, z in { 40, -380 } do
			Build.part(parent, "LightMast", Vector3.new(5, 120, 5), frame * CFrame.new(side * 430, 60, z), dark, true)
			local lamp = Build.part(
				parent,
				"Floodlights",
				Vector3.new(45, 12, 4),
				frame * CFrame.new(side * 430, 120, z),
				white,
				false,
				Enum.Material.Neon
			)
			local light = Instance.new("SurfaceLight")
			light.Face, light.Range, light.Brightness, light.Angle, light.Parent =
				Enum.NormalId.Bottom, 60, 2, 120, lamp
		end
	end
	for _, x in { -88, 88 } do
		Build.part(parent, "ScoreboardSupport", Vector3.new(5, 75, 5), frame * CFrame.new(x, 37.5, -530), dark, true)
	end
	Build.sign(parent, frame, Vector3.new(0, 75, -530), "POWER ARENA", accent, 190)
	Build.sign(parent, frame, Vector3.new(0, 43, -530), "GO BIG  /  HIT FAR", white, 120)
	for _, z in { 550, 1100, 2200, 4400 } do
		Build.line(parent, frame, Vector3.new(-420, 0.2, -z), Vector3.new(420, 0.2, -z), 1, accent)
		Build.sign(
			parent,
			frame,
			Vector3.new(480, 18, -z),
			`{math.floor(z * PitchConfig.Units.MetersPerStud / 0.3048)} FT`,
			accent,
			60
		)
	end
end
local function skyArena(parent: Instance, frame: CFrame, accent: Color3)
	local purple = Color3.fromRGB(87, 76, 164)
	-- Floating terraces, spires and cloud clusters give a different silhouette.
	for _, side in { -1, 1 } do
		for tier = 1, 5 do
			Build.part(
				parent,
				"FloatingTerrace",
				Vector3.new(70, 8, 600),
				frame * CFrame.new(side * (520 + tier * 35), tier * 18, -220),
				if tier % 2 == 0 then white else purple,
				true
			)
			Build.part(
				parent,
				"TerraceGlow",
				Vector3.new(71, 2, 600),
				frame * CFrame.new(side * (520 + tier * 35), tier * 18 - 5, -220),
				accent,
				false,
				Enum.Material.Neon
			)
		end
		for _, z in { 80, -480, -1100 } do
			Build.part(
				parent,
				"SkySpire",
				Vector3.new(13, 185, 13),
				frame * CFrame.new(side * 650, 92, z) * CFrame.Angles(0, math.pi / 4, 0),
				purple,
				true
			)
			local beacon = Build.part(
				parent,
				"Beacon",
				Vector3.new(28, 28, 28),
				frame * CFrame.new(side * 650, 190, z),
				accent,
				false,
				Enum.Material.Neon
			)
			beacon.Shape = Enum.PartType.Ball
		end
		for cluster = 1, 7 do
			for puff = 1, 3 do
				local cloud = Build.part(
					parent,
					"Cloud",
					Vector3.new(140 + puff * 15, 60, 100),
					frame * CFrame.new(side * (840 + puff * 30), 95 + puff * 8, -cluster * 520),
					white,
					false
				)
				cloud.Shape, cloud.Transparency = Enum.PartType.Ball, 0.35
			end
		end
	end
	Build.sign(parent, frame, Vector3.new(0, 110, -730), "SKY STADIUM", accent, 260)
	for _, z in { 1000, 2000, 3000, 5000 } do
		Build.line(parent, frame, Vector3.new(-500, 0.2, -z), Vector3.new(500, 0.2, -z), 2, accent)
		Build.sign(
			parent,
			frame,
			Vector3.new(-550, 30, -z),
			`{math.floor(z * PitchConfig.Units.MetersPerStud / 0.3048)} FT`,
			accent,
			80
		)
	end
end
function Builder.create(world: Config.Definition): Model
	local root = Instance.new("Model")
	root.Name = world.id
	root:SetAttribute("WorldId", world.id)
	root:SetAttribute("GenerationVersion", Config.GenerationVersion)
	-- Bounded geometry remains visible during distant cinematic flights.
	root.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	local ground = Instance.new("Folder")
	ground.Name, ground.Parent = "Collision", root
	local frame = Config.frame(world)
	Build.ground(
		ground,
		frame,
		-Config.GroundWidthStuds / 2,
		Config.GroundWidthStuds / 2,
		-Config.GroundForwardStuds,
		Config.GroundBackStuds,
		0,
		if world.theme == "sky" then Color3.fromRGB(51, 119, 132) else Color3.fromRGB(43, 103, 81)
	)
	local markerRoot = Instance.new("Folder")
	markerRoot.Name, markerRoot.Parent = "GameplayMarkers", root
	local accent = Color3.fromRGB(world.accent[1], world.accent[2], world.accent[3])
	for index = 1, world.lanes do
		local lane = Instance.new("Model")
		lane.Name, lane.Parent = `Arena{index}`, root
		local laneFrame = frame * CFrame.new((index - (world.lanes + 1) / 2) * Config.LaneSpacingStuds, 0, 0)
		local markers = Instance.new("Folder")
		markers.Name, markers.Parent = `Lane{index}`, markerRoot
		diamond(lane, laneFrame, markers, accent)
		if world.theme == "sky" then
			skyArena(lane, laneFrame, accent)
		else
			powerArena(lane, laneFrame, accent)
		end
	end
	return root
end
return Builder
