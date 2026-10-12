--!strict
-- Studio-only batted-ball debug: HUD sections and world drawings inside the
-- pitch debug overlay (same F7 toggle, hidden together with it).
--
-- HUD: exit velocity, launch / spray angle, backspin / sidespin, apex,
-- flight time, live distance and height, the plate-level landing projection,
-- the server's measured outcome and the flight state. For the swinging
-- client's own predicted hits it also shows the impact model's internals.
-- World: the predicted trajectory (dots), apex, projected landing, the
-- server's first impact, and the foul lines.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattedBallFolder = Shared:WaitForChild("BattedBall")
local BattedBall = require(BattedBallFolder.BattedBall)
local BattedBallConfig = require(BattedBallFolder.BattedBallConfig)
local FieldFrame = require(BattedBallFolder.FieldFrame)
local ImpactModel = require(BattedBallFolder.ImpactModel)
local LandingDetector = require(BattedBallFolder.LandingDetector)

local PitchDebugView = require(script.Parent.PitchDebugView)

local BattedBallDebugView = {}

export type DebugFlight = {
	laneId: string,
	hitId: number?,
	predicted: boolean,
	flight: BattedBall.Flight,
	endTime: number?,
	outcome: LandingDetector.OutcomePayload?,
	impact: ImpactModel.Result?,
	contactType: ImpactModel.ContactType?,
}

local cfg = BattedBallConfig.Debug
local SECTION_LIVE = "BattedBall1"
local SECTION_LAUNCH = "BattedBall2"
local SECTION_OUTCOME = "BattedBall3"

local flightFolders: { Folder } = {}
local lastLive = 0

local function dot(parent: Instance, position: Vector3, size: number, color: Color3, transparency: number?)
	local part = Instance.new("Part")
	part.Name = "Dot"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
end

local function bar(parent: Instance, a: Vector3, b: Vector3, thickness: number, color: Color3)
	local part = Instance.new("Part")
	part.Name = "Line"
	part.Size = Vector3.new(thickness, thickness, (b - a).Magnitude)
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = 0.4
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
end

local function distanceText(meters: number): string
	return string.format("%.1f m / %s", meters, BattedBall.formatDistance(meters, "Feet"))
end

local function side(flight: BattedBall.Flight): string
	local spray = flight.sprayAngleDegrees
	local field = if math.abs(spray) < 15 then "CF" elseif spray > 0 then "RF side" else "LF side"
	local pull = if math.abs(flight.pullAngleDegrees) < 1 then "straight" elseif flight.pullAngleDegrees > 0 then "pull" else "oppo"
	return `{field}, {pull}`
end

-- Draws the lane's foul lines once (and again if the geometry changes).
function BattedBallDebugView.drawField(laneId: string, frame: FieldFrame.Frame)
	local root = PitchDebugView.getWorldFolder()
	if not root or not cfg.ShowFoulLines then
		return
	end
	local name = `FoulLines_{laneId}`
	local existing = root:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	local length = cfg.FoulLineLengthMeters * frame.studsPerMeter
	local lift = frame.up * 0.05
	for _, direction in { FieldFrame.foulLineDirection(frame, "Left"), FieldFrame.foulLineDirection(frame, "Right") } do
		bar(folder, frame.origin + lift, frame.origin + lift + direction * length, 0.08, Color3.fromRGB(255, 255, 255))
	end
	folder.Parent = root
end

-- Draws a flight's predicted trajectory (replacing older ones beyond the keep count).
function BattedBallDebugView.showFlight(entry: DebugFlight)
	local root = PitchDebugView.getWorldFolder()
	if not root then
		return
	end
	local flight = entry.flight
	local frame = flight.frame
	local s = frame.studsPerMeter

	PitchDebugView.setSection(
		SECTION_LAUNCH,
		string.format(
			"    EV %.1f mph | launch %+.1f deg | spray %+.1f deg (%s) | backspin %+.0f rpm, sidespin %+.0f rpm (total %.0f)"
				.. "\n    apex %.1f m at %.2f s | plate-level projection %s%s%s",
			flight.exitSpeedMph,
			flight.launchAngleDegrees,
			flight.sprayAngleDegrees,
			side(flight),
			flight.backspinRpm,
			flight.sidespinRpm,
			flight.spinRpm,
			flight.apexHeightMeters,
			flight.apexTime,
			if flight.fieldLanding then distanceText(flight.fieldLanding.distance) else "none",
			if flight.fieldLanding
				then string.format(" at %.2f s, %s", flight.fieldLanding.time, FieldFrame.territory(frame, flight.fieldLanding.x, flight.fieldLanding.z))
				else "",
			if entry.impact
				then string.format(
					"\n    impact model: %s | e %.3f, M_eff %.3f kg, q %.3f | approach %.1f m/s | J_n %.2f N s, J_t %.2f N s%s%s",
					entry.contactType or "?",
					entry.impact.restitution,
					entry.impact.effectiveBatMass,
					entry.impact.collisionEfficiency,
					entry.impact.approachSpeed,
					entry.impact.normalImpulse,
					entry.impact.tangentialImpulse,
					if entry.impact.sliding then " (sliding)" else " (rolling)",
					if entry.impact.energyCapped then " ENERGY CAPPED" else ""
				)
				else ""
		)
	)
	local endTime = entry.endTime
	if endTime then
		local ix, iy, iz = FieldFrame.toField(frame, BattedBall.positionAt(flight, endTime))
		PitchDebugView.setSection(
			SECTION_OUTCOME,
			string.format(
				"    server outcome: pending | predicted first impact at %.2f s: %s from home, %.1f m high (x %.1f, z %+.1f m)",
				endTime,
				distanceText(math.sqrt(ix * ix + iz * iz)),
				iy,
				ix,
				iz
			)
		)
	else
		PitchDebugView.setSection(SECTION_OUTCOME, "    server outcome: awaiting server launch (prediction flies to the end of the free flight)")
	end

	if not cfg.ShowTrajectory then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = `BattedBall_{entry.laneId}_{entry.hitId or "predicted"}`
	local traj = flight.trajectory
	local lastTime = math.min(entry.endTime or traj.duration, traj.duration)
	local lastIndex = math.min(traj.count, math.floor(lastTime / traj.dt) + 1)
	local every = math.max(1, cfg.TrajectoryDotEverySteps)
	local size = 0.06 * s
	local color = if entry.predicted and entry.hitId == nil then Color3.fromRGB(255, 160, 255) else Color3.fromRGB(0, 220, 255)
	for i = 1, lastIndex, every do
		dot(folder, FieldFrame.toWorld(frame, traj.px[i], traj.py[i], traj.pz[i]), size, color, 0.25)
	end
	dot(folder, BattedBall.positionAt(flight, flight.apexTime), size * 3, Color3.fromRGB(255, 255, 0), 0.2)
	local landing = flight.fieldLanding
	if landing then
		dot(folder, FieldFrame.toWorld(frame, landing.x, 0, landing.z), size * 4, Color3.fromRGB(255, 255, 255), 0.5)
	end
	if endTime then
		dot(folder, BattedBall.positionAt(flight, endTime), size * 4, Color3.fromRGB(255, 140, 0), 0.15)
	end
	folder.Parent = root

	-- A confirmed prediction replaces its own predicted drawing.
	for i = #flightFolders, 1, -1 do
		local old = flightFolders[i]
		if old.Name == `BattedBall_{entry.laneId}_predicted` or old.Name == folder.Name then
			old:Destroy()
			table.remove(flightFolders, i)
		end
	end
	table.insert(flightFolders, folder)
	while #flightFolders > math.max(1, cfg.KeepTrajectories) do
		local old = table.remove(flightFolders, 1)
		if old then
			old:Destroy()
		end
	end
end

function BattedBallDebugView.showOutcome(entry: DebugFlight)
	local root = PitchDebugView.getWorldFolder()
	local outcome = entry.outcome
	if not root or not outcome then
		return
	end
	local flight = entry.flight
	local fx, fy, fz = FieldFrame.toField(flight.frame, BattedBall.positionAt(flight, outcome.endTime))
	local lines = {
		`    server outcome: <b>{LandingDetector.describe(outcome)}</b>`,
		string.format(
			"    first impact: %s%s at %.2f s | client flight at that time: %s from home, %.2f m high",
			outcome.surface or "none",
			if outcome.impactName then ` ({outcome.impactName})` else "",
			outcome.endTime,
			distanceText(math.sqrt(fx * fx + fz * fz)),
			fy
		),
		string.format(
			"    projected carry (no obstacles) %s | measured carry %s",
			if outcome.projectedCarryMeters then distanceText(outcome.projectedCarryMeters) else "n/a",
			if outcome.carryMeters then distanceText(outcome.carryMeters) else "n/a (" .. outcome.kind .. ")"
		),
	}
	PitchDebugView.setSection(SECTION_OUTCOME, table.concat(lines, "\n"))

	local point = outcome.impactPoint
	if point then
		local folder = flightFolders[#flightFolders]
		local color = if outcome.kind == "Landed" then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 60, 60)
		dot(folder or root, point, 0.35 * flight.frame.studsPerMeter, color, 0.1)
	end
end

-- Throttled live line for the flight that matters most (the local lane's).
function BattedBallDebugView.updateLive(entry: DebugFlight?, serverNow: number)
	if not PitchDebugView.isEnabled() then
		return
	end
	local clock = os.clock()
	if clock - lastLive < 0.1 then
		return
	end
	lastLive = clock
	if entry == nil then
		PitchDebugView.setSection(SECTION_LIVE, "<b>HIT</b>  no ball in flight")
		return
	end
	local flight = entry.flight
	local t = serverNow - flight.launch.launchTime
	local endTime = entry.endTime
	local state: string
	if t < 0 then
		state = "waiting for contact"
	elseif endTime == nil then
		state = "flying (unconfirmed prediction)"
	elseif t <= endTime then
		state = "flying"
	else
		state = if entry.outcome then "resolved" else "waiting for server outcome"
	end
	local shown = math.clamp(t, 0, endTime or flight.trajectory.duration)
	local fx, fy, fz = FieldFrame.toField(flight.frame, BattedBall.positionAt(flight, shown))
	PitchDebugView.setSection(
		SECTION_LIVE,
		string.format(
			"<b>HIT</b> #%s %s | state %s | t %.2f / %s s | distance %s | height %.1f m | sim %d steps (%s)",
			if entry.hitId then tostring(entry.hitId) else "?",
			if entry.predicted then (if entry.hitId then "predicted+confirmed" else "predicted") else "server",
			state,
			shown,
			if endTime then string.format("%.2f", endTime) else "?",
			distanceText(math.sqrt(fx * fx + fz * fz)),
			fy,
			flight.trajectory.count - 1,
			flight.trajectory.endReason
		)
	)
end

return BattedBallDebugView
