--!strict
-- Finds the gameplay markers that define each batting lane and turns them
-- into LaneGeometry inputs. Never modifies or replaces stadium geometry; if a
-- required marker is missing it creates a clearly named, invisible fallback
-- part (under Workspace.GameplayMarkers.PitchingFallbackMarkers) and warns.
--
-- Lane layout:
--   * Multi-lane: children of GameplayMarkers that are Folders/Models named
--     "Lane..." (or with the attribute PitchingLane = true) are separate lanes.
--   * Otherwise GameplayMarkers itself is a single lane called "Lane1".
-- Marker names are matched case-insensitively (see PitchConfig.Markers):
-- exact names first, then substring hints. Markers may be BaseParts,
-- Attachments or Models. "Ground" positions use the bottom of a part/model.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local Units = require(Pitching.Units)

local MarkerResolver = {}

export type ResolvedLane = {
	id: string,
	inputs: LaneGeometry.Inputs,
	geometry: LaneGeometry.Geometry,
	sources: { [string]: string }, -- marker role -> full name of the instance used (or "fallback")
}

local markerConfig = PitchConfig.Markers

local function isMarkerInstance(inst: Instance): boolean
	return inst:IsA("BasePart") or inst:IsA("Attachment") or inst:IsA("Model")
end

local function findByNames(root: Instance, names: { string }): Instance?
	local wanted = {}
	for priority, name in names do
		wanted[string.lower(name)] = priority
	end
	local best: Instance? = nil
	local bestPriority = math.huge
	for _, inst in root:GetDescendants() do
		local priority = wanted[string.lower(inst.Name)]
		if priority and priority < bestPriority and isMarkerInstance(inst) then
			best, bestPriority = inst, priority
		end
	end
	return best
end

local function findByHints(root: Instance, hints: { string }): Instance?
	for _, hint in hints do
		for _, inst in root:GetDescendants() do
			if isMarkerInstance(inst) and string.find(string.lower(inst.Name), hint, 1, true) then
				return inst
			end
		end
	end
	return nil
end

local function findMarker(laneRoot: Instance?, stadium: Instance?, names: { string }, hints: { string }): Instance?
	if laneRoot then
		local found = findByNames(laneRoot, names) or findByHints(laneRoot, hints)
		if found then
			return found
		end
	end
	if stadium then
		return findByNames(stadium, names)
	end
	return nil
end

-- Bottom-center of a marker, i.e. the ground it stands on.
function MarkerResolver.groundPosition(inst: Instance): Vector3
	if inst:IsA("BasePart") then
		return inst.CFrame:PointToWorldSpace(Vector3.new(0, -inst.Size.Y / 2, 0))
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	elseif inst:IsA("Model") then
		local cframe, size = inst:GetBoundingBox()
		return cframe.Position - Vector3.new(0, size.Y / 2, 0)
	end
	error(`Unsupported marker type {inst.ClassName}`)
end

function MarkerResolver.centerPosition(inst: Instance): Vector3
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	error(`Unsupported marker type {inst.ClassName}`)
end

local function horizontalLook(inst: Instance): Vector3?
	local cframe: CFrame? = nil
	if inst:IsA("BasePart") then
		cframe = inst.CFrame
	elseif inst:IsA("Model") then
		cframe = inst:GetPivot()
	end
	if cframe then
		local look = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
		if look.Magnitude > 1e-3 then
			return look.Unit
		end
	end
	return nil
end

local function getFallbackFolder(markersRoot: Instance): Folder
	local existing = markersRoot:FindFirstChild(markerConfig.FallbackFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = markerConfig.FallbackFolderName
	folder.Parent = markersRoot
	return folder
end

local function createFallback(markersRoot: Instance, laneId: string, role: string, ground: Vector3): BasePart
	local name = `Fallback_{laneId}_{role}`
	local folder = getFallbackFolder(markersRoot)
	local existing = folder:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(1, 0.2, 1)
	part.CFrame = CFrame.new(ground + Vector3.new(0, 0.1, 0))
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part:SetAttribute("PitchingFallback", true)
	part.Parent = folder
	return part
end

local function resolveLane(laneId: string, laneRoot: Instance, markersRoot: Instance, stadium: Instance?): ResolvedLane
	local units = Units.new(PitchConfig.Units.MetersPerStud)
	local geo = PitchConfig.Geometry
	local sources = {}

	local plate = findMarker(laneRoot, stadium, markerConfig.Plate, markerConfig.PlateHints)
	local pitcher = findMarker(laneRoot, stadium, markerConfig.Pitcher, markerConfig.PitcherHints)
	local batter = findMarker(laneRoot, stadium, markerConfig.Batter, markerConfig.BatterHints)
	local release = findMarker(laneRoot, nil, markerConfig.Release, markerConfig.ReleaseHints)
	-- Guard against one instance matching several roles via loose hints.
	if pitcher and pitcher == plate then
		pitcher = nil
	end
	if batter and (batter == plate or batter == pitcher) then
		batter = nil
	end
	if release and (release == plate or release == pitcher or release == batter) then
		release = nil
	end

	local moundDistance = units.toStuds(geo.MoundToPlateMeters)
	local plateGround: Vector3
	local pitcherGround: Vector3

	if plate then
		plateGround = MarkerResolver.groundPosition(plate)
		sources.Plate = plate:GetFullName()
	end
	if pitcher then
		pitcherGround = MarkerResolver.groundPosition(pitcher)
		sources.Pitcher = pitcher:GetFullName()
	end

	if not plate then
		if batter then
			-- The batter stands right beside the plate; close enough for a fallback.
			plateGround = MarkerResolver.groundPosition(batter)
		elseif pitcher then
			local look = horizontalLook(pitcher) or Vector3.new(0, 0, 1)
			plateGround = pitcherGround + look * moundDistance
		else
			plateGround = if stadium and stadium:IsA("PVInstance") then stadium:GetPivot().Position else Vector3.zero
		end
		local part = createFallback(markersRoot, laneId, "HomePlate", plateGround)
		sources.Plate = "fallback " .. part:GetFullName()
		warn(`[Pitching] Lane {laneId}: no home plate marker found; created fallback at {plateGround}.`)
	end

	if not pitcher then
		local look = (plate and horizontalLook(plate)) or Vector3.new(0, 0, -1)
		pitcherGround = plateGround + look * moundDistance
		local part = createFallback(markersRoot, laneId, "PitcherMarker", pitcherGround)
		sources.Pitcher = "fallback " .. part:GetFullName()
		warn(
			`[Pitching] Lane {laneId}: no pitcher marker found; created fallback {geo.MoundToPlateMeters} m along the plate marker's LookVector.`
		)
	end

	-- Optional field markers (no fallbacks: FieldFrame uses the rulebook layout).
	local fieldMarkers: { [string]: Vector3? } = {}
	for _, role in { "LeftFoulPole", "RightFoulPole", "FirstBase", "ThirdBase" } do
		local found = findMarker(laneRoot, stadium, (markerConfig :: any)[role], {})
		if found and found ~= plate and found ~= pitcher and found ~= batter then
			fieldMarkers[role] = MarkerResolver.groundPosition(found)
			sources[role] = found:GetFullName()
		end
	end

	local inputs: LaneGeometry.Inputs = {
		plateGround = plateGround,
		pitcherGround = pitcherGround,
		releasePoint = release and MarkerResolver.centerPosition(release),
		batterGround = batter and MarkerResolver.groundPosition(batter),
		leftFoulPole = fieldMarkers.LeftFoulPole,
		rightFoulPole = fieldMarkers.RightFoulPole,
		firstBase = fieldMarkers.FirstBase,
		thirdBase = fieldMarkers.ThirdBase,
	}
	sources.Release = if release then release:GetFullName() else "derived from pitcher marker"
	sources.Batter = if batter then batter:GetFullName() else "derived from plate marker"
	if not batter then
		warn(`[Pitching] Lane {laneId}: no batter marker found; batter is placed beside the plate.`)
	end

	local geometry = LaneGeometry.new(inputs)
	local measuredMeters = units.toMeters(geometry.moundToPlate)
	if math.abs(measuredMeters - geo.MoundToPlateMeters) > 3 then
		warn(
			string.format(
				"[Pitching] Lane %s: pitcher->plate distance is %.1f m (expected ~%.2f m at %.2f m/stud). "
					.. "Check the markers or PitchConfig.Units.MetersPerStud.",
				laneId,
				measuredMeters,
				geo.MoundToPlateMeters,
				PitchConfig.Units.MetersPerStud
			)
		)
	end

	return { id = laneId, inputs = inputs, geometry = geometry, sources = sources }
end

function MarkerResolver.resolveLanes(): { ResolvedLane }
	local stadium = Workspace:FindFirstChild(markerConfig.StadiumName)
	if not stadium then
		warn(`[Pitching] Workspace.{markerConfig.StadiumName} not found; relying on markers/fallbacks only.`)
	end

	local markersRoot = Workspace:FindFirstChild(markerConfig.FolderName)
	if not markersRoot then
		warn(`[Pitching] Workspace.{markerConfig.FolderName} not found; creating it for fallback markers.`)
		local folder = Instance.new("Folder")
		folder.Name = markerConfig.FolderName
		folder.Parent = Workspace
		markersRoot = folder
	end
	assert(markersRoot, "GameplayMarkers folder missing")

	local laneRoots: { Instance } = {}
	for _, child in markersRoot:GetChildren() do
		local isContainer = child:IsA("Folder") or child:IsA("Model")
		local named = string.sub(string.lower(child.Name), 1, 4) == "lane"
		if isContainer and (child:GetAttribute("PitchingLane") == true or named) then
			table.insert(laneRoots, child)
		end
	end
	table.sort(laneRoots, function(a, b)
		return a.Name < b.Name
	end)

	local lanes = {}
	if #laneRoots == 0 then
		table.insert(lanes, resolveLane("Lane1", markersRoot, markersRoot, stadium))
	else
		for _, root in laneRoots do
			table.insert(lanes, resolveLane(root.Name, root, markersRoot, stadium))
		end
	end
	return lanes
end

return MarkerResolver
