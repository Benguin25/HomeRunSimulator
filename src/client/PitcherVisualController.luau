--!strict
-- One small local procedural rig per lane, no asset IDs, physics or remotes.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Geometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local Motion = require(Shared.Presentation.PitcherMotion)
local PitchVisual = require(script.Parent.PitchVisualController)
local Audio = require(script.Parent.GameAudio)
local Controller = {}
type Rig = {
	model: Model,
	parts: { [string]: Part },
	geo: Geometry.Geometry,
	pitch: Pitch.PitchData?,
	sounded: boolean,
	worldId: string,
}
local rigs: { [string]: Rig } = {}
local folder: Folder
local function makePart(model: Model, name: string, color: Color3): Part
	local p = Instance.new("Part")
	p.Name, p.Color, p.Material = name, color, Enum.Material.SmoothPlastic
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.Size, p.Parent = Vector3.one * 0.5, model
	return p
end
local function segment(part: Part, a: Vector3, b: Vector3, width: number)
	local length = (b - a).Magnitude
	part.Size = Vector3.new(width, width, math.max(length, 0.01))
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
end
local function bend(a: Vector3, b: Vector3, pole: Vector3, amount: number): Vector3
	local delta = b - a
	local along = if delta.Magnitude > 0.001 then delta.Unit else Vector3.yAxis
	local perpendicular = pole - along * pole:Dot(along)
	return (a + b) / 2 + (if perpendicular.Magnitude > 0.001 then perpendicular.Unit else Vector3.yAxis) * amount
end
local function render(rig: Rig, now: number)
	local geo, data = rig.geo, rig.pitch
	local pose = Motion.sample(
		geo,
		if data then data.windupTime else now - 3,
		if data then data.releaseTime else now - 2,
		if data then data.releasePosition else geo.releasePoint,
		now
	)
	local s = geo.units.toStuds
	local parts = rig.parts
	segment(parts.Torso, pose.hip, pose.chest, s(0.42))
	parts.Head.Shape, parts.Head.Size, parts.Head.CFrame =
		Enum.PartType.Ball, Vector3.one * s(0.27), CFrame.new(pose.head)
	parts.Cap.Size, parts.Cap.CFrame =
		Vector3.new(s(0.31), s(0.08), s(0.35)),
		CFrame.lookAt(pose.head + geo.up * s(0.12), pose.head + geo.up * s(0.12) - geo.toPitcher)
	local elbow = bend(pose.throwShoulder, pose.hand, geo.armSide - geo.toPitcher, s(0.14 * (1 - pose.stride) + 0.03))
	segment(parts.ThrowUpper, pose.throwShoulder, elbow, s(0.13))
	segment(parts.ThrowLower, elbow, pose.hand, s(0.1))
	parts.Hand.CFrame, parts.Hand.Size = CFrame.new(pose.hand), Vector3.one * s(0.13)
	local gloveElbow = bend(pose.gloveShoulder, pose.glove, -geo.armSide, s(0.13))
	segment(parts.GloveUpper, pose.gloveShoulder, gloveElbow, s(0.13))
	segment(parts.GloveLower, gloveElbow, pose.glove, s(0.1))
	parts.Glove.CFrame, parts.Glove.Size = CFrame.new(pose.glove), Vector3.one * s(0.23)
	for _, leg in
		{ { prefix = "Lead", foot = pose.leadFoot, sign = -1 }, { prefix = "Trail", foot = pose.trailFoot, sign = 1 } }
	do
		local prefix, foot, sign = leg.prefix, leg.foot, leg.sign
		local hip = pose.hip + geo.armSide * s(0.12 * sign)
		local knee = bend(hip, foot, -geo.toPitcher, s(0.12 + pose.lift * 0.08))
		segment(parts[prefix .. "Upper"], hip, knee, s(0.17))
		segment(parts[prefix .. "Lower"], knee, foot, s(0.14))
		parts[prefix .. "Shoe"].Size = Vector3.new(s(0.17), s(0.1), s(0.3))
		parts[prefix .. "Shoe"].CFrame = CFrame.lookAt(foot, foot - geo.toPitcher)
	end
	if data and not rig.sounded and pose.released then
		rig.sounded = true
		if
			now - data.releaseTime < 0.2
			and data.laneId == game:GetService("Players").LocalPlayer:GetAttribute("PitchLaneId")
		then
			Audio.play("Pitch")
		end
	end
end
function Controller.start()
	folder = Instance.new("Folder")
	folder.Name, folder.Parent = "PitcherVisuals", workspace
	PitchVisual.onGeometry(function(id, geo)
		if rigs[id] then
			rigs[id].geo = geo
			return
		end
		local model = Instance.new("Model")
		model.Name, model.Parent = id, folder
		local parts: { [string]: Part } = {}
		for _, name in
			{
				"Torso",
				"Head",
				"Cap",
				"ThrowUpper",
				"ThrowLower",
				"Hand",
				"GloveUpper",
				"GloveLower",
				"Glove",
				"LeadUpper",
				"LeadLower",
				"LeadShoe",
				"TrailUpper",
				"TrailLower",
				"TrailShoe",
			}
		do
			parts[name] = makePart(
				model,
				name,
				if name == "Head"
						or name == "Hand"
						or name == "ThrowLower"
						or name == "GloveLower"
					then Color3.fromRGB(206, 164, 124)
					elseif name == "Glove" then Color3.fromRGB(104, 65, 36)
					elseif name == "Torso" or string.find(name, "Upper") then Color3.fromRGB(225, 231, 240)
					else Color3.fromRGB(38, 60, 96)
			)
		end
		local runtime = game:GetService("ReplicatedStorage").PitchingRuntime.Lanes:FindFirstChild(id)
		local worldId = runtime and runtime:GetAttribute("WorldId")
		rigs[id] = {
			model = model,
			parts = parts,
			geo = geo,
			pitch = nil,
			sounded = false,
			worldId = if typeof(worldId) == "string" then worldId else "rookie",
		}
		render(rigs[id], workspace:GetServerTimeNow())
	end)
	PitchVisual.onPitchStarted(function(_, flight)
		local rig = rigs[flight.data.laneId]
		if rig then
			rig.pitch, rig.sounded = flight.data, false
		end
	end)
	PitchVisual.onPitchAborted(function(id, _, _, atTime)
		if not atTime and rigs[id] then
			rigs[id].pitch = nil
		end -- contact keeps the follow-through
	end)
	game:GetService("RunService").RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()
		local current = game:GetService("Players").LocalPlayer:GetAttribute("CurrentWorld") or "rookie"
		for _, rig in rigs do
			local parent = if rig.worldId == current then folder else nil
			if rig.model.Parent ~= parent then
				rig.model.Parent = parent
			end
			if parent then
				render(rig, now)
			end
		end
	end)
end
return Controller
