--!strict
-- Studio-only batting debug drawings and HUD, part of the pitch debug overlay
-- (same toggle key). Shows the live swing state and aim, and for the last
-- swing: the bat's collision capsules at contact (or closest approach), the
-- swept path of the sweet spot and tip over the Active window, the contact
-- point, timing error, quality factors and the server's validation result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching:WaitForChild("LaneGeometry"))
local PitchConfig = require(Pitching:WaitForChild("PitchConfig"))
local Batting = Shared:WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local BattingNet = require(Batting.BattingNet)
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)

local PitchDebugView = require(script.Parent.PitchDebugView)

local BattingDebugView = {}

local cfg = BattingConfig.Debug
local SECTION_LIVE = "Batting1"
local SECTION_RESULT = "Batting2"

local swingFolder: Folder? = nil
local lastLiveUpdate = 0

local function part(parent: Instance, shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number)
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Parent = parent
end

local function capsule(parent: Instance, a: Vector3, b: Vector3, radius: number, normal: Vector3, color: Color3)
	local dir = (b - a).Unit
	local frame = CFrame.fromMatrix((a + b) / 2, dir, normal)
	part(parent, Enum.PartType.Cylinder, Vector3.new((b - a).Magnitude, radius * 2, radius * 2), frame, color, 0.6)
	part(parent, Enum.PartType.Ball, Vector3.one * radius * 2, CFrame.new(a), color, 0.6)
	part(parent, Enum.PartType.Ball, Vector3.one * radius * 2, CFrame.new(b), color, 0.6)
end

local function drawBat(parent: Instance, pose: SwingModel.Pose, dims: SwingModel.BatDimensions)
	local split = pose.knob + pose.direction * dims.barrelStart
	capsule(parent, pose.knob, split, dims.handleRadius, pose.planeNormal, Color3.fromRGB(80, 160, 255))
	capsule(parent, split, pose.tip, dims.barrelRadius, pose.planeNormal, Color3.fromRGB(255, 170, 40))
	local sweet = pose.knob + pose.direction * dims.sweetSpot
	part(parent, Enum.PartType.Ball, Vector3.one * dims.barrelRadius * 0.9, CFrame.new(sweet), Color3.fromRGB(255, 255, 255), 0.2)
end

function BattingDebugView.isEnabled(): boolean
	return PitchDebugView.isEnabled()
end

-- Throttled per-frame line: swing state and current aim.
function BattingDebugView.updateLive(
	geometry: LaneGeometry.Geometry?,
	phase: string,
	aimX: number,
	aimY: number,
	clamped: boolean,
	gripStatus: string?
)
	if not PitchDebugView.isEnabled() then
		return
	end
	local now = os.clock()
	if now - lastLiveUpdate < 0.1 then
		return
	end
	lastLiveUpdate = now
	if not geometry then
		PitchDebugView.setSection(SECTION_LIVE, "<b>BAT</b>  no lane")
		return
	end
	local units = geometry.units
	PitchDebugView.setSection(
		SECTION_LIVE,
		string.format(
			"<b>BAT</b>  state %s | aim x=%+.2f m, h=%.2f m%s%s",
			phase,
			units.toMeters(aimX),
			units.toMeters(aimY),
			if clamped then " (clamped)" else "",
			if gripStatus then "\n    " .. gripStatus else ""
		)
	)
end

-- Draws the swing's collision geometry; called with the local prediction.
function BattingDebugView.drawSwing(geometry: LaneGeometry.Geometry, swing: SwingModel.Swing, resolution: SwingResolver.Resolution?)
	local root = PitchDebugView.getWorldFolder()
	if not root then
		return
	end
	if swingFolder then
		swingFolder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "BattingSwing"
	swingFolder = folder
	local dims = swing.dims

	if cfg.ShowSweptPath then
		local samples = math.max(2, cfg.SweptPathSamples)
		local dot = geometry.units.toStuds(0.015)
		for i = 0, samples do
			local t = swing.activeStart + (swing.activeEnd - swing.activeStart) * i / samples
			local pose = SwingModel.activePoseAt(swing, t)
			part(folder, Enum.PartType.Ball, Vector3.one * dot, CFrame.new(pose.tip), Color3.fromRGB(255, 170, 40), 0.3)
			part(folder, Enum.PartType.Ball, Vector3.one * dot, CFrame.new(pose.knob + pose.direction * dims.sweetSpot), Color3.fromRGB(255, 255, 255), 0.3)
		end
	end

	local contact = resolution and resolution.contact
	if cfg.ShowBatAtContact then
		-- At contact, or (for a miss) when the bat is square.
		local t = if contact then contact.contactTime else swing.squareTime
		drawBat(folder, SwingModel.activePoseAt(swing, t), dims)
	end
	if cfg.ShowContactPoint and contact then
		part(folder, Enum.PartType.Ball, Vector3.one * geometry.units.toStuds(0.03), CFrame.new(contact.contactPoint), Color3.fromRGB(255, 0, 255), 0)
		part(folder, Enum.PartType.Ball, Vector3.one * geometry.units.toStuds(PitchConfig.Ball.RadiusMeters * 2), CFrame.new(contact.ballCenter), Color3.fromRGB(255, 255, 255), 0.7)
	end
	folder.Parent = root
end

local function ms(seconds: number?): string
	return if seconds then string.format("%+.1f ms", seconds * 1000) else "n/a"
end

-- Server result vs local prediction.
function BattingDebugView.showResult(
	geometry: LaneGeometry.Geometry?,
	payload: BattingNet.SwingResultPayload,
	predicted: SwingResolver.Resolution?
)
	if not PitchDebugView.isEnabled() then
		return
	end
	local lines = {}
	table.insert(
		lines,
		string.format(
			"<b>SWING</b> #%d  server: %s%s | rewind %s / allowed %s%s",
			payload.seq,
			if payload.accepted then "ACCEPTED" else "REJECTED",
			if payload.reason ~= "Ok" then ` ({payload.reason})` else "",
			if payload.rewind then string.format("%.0f ms", payload.rewind * 1000) else "n/a",
			if payload.allowedRewind then string.format("%.0f ms", payload.allowedRewind * 1000) else "n/a",
			if payload.clamped then " CLAMPED" else ""
		)
	)
	local contact = payload.contact
	if contact and geometry then
		local units = geometry.units
		local f = contact.factors
		table.insert(
			lines,
			string.format(
				"    %s  score %.2f  [timing %.2f  sweet %.2f  vertical %.2f  efficiency %.2f]",
				string.upper(contact.label),
				contact.score,
				f.timing,
				f.sweetSpot,
				f.vertical,
				f.efficiency
			)
		)
		table.insert(
			lines,
			string.format(
				"    timing %s | %s, %.1f cm from knob, sweet-spot offset %+.1f cm, vertical %+.1f cm | bat angle %+.1f deg",
				ms(contact.timingErrorSeconds),
				contact.segment,
				units.toMeters(contact.distanceFromKnob) * 100,
				units.toMeters(contact.sweetSpotOffset) * 100,
				units.toMeters(contact.verticalOffset) * 100,
				contact.batAngleDegrees
			)
		)
		table.insert(
			lines,
			string.format(
				"    bat %.1f mph | ball %.1f mph | closing %.1f mph | spray %+.0f deg | launch hint %+.0f deg",
				units.studsPerSecondToMph(contact.batVelocity.Magnitude),
				units.studsPerSecondToMph(contact.ballVelocity.Magnitude),
				units.studsPerSecondToMph(contact.closingSpeed),
				contact.sprayAngleDegrees,
				contact.launchAngleHintDegrees
			)
		)
	elseif payload.pitchId then
		table.insert(
			lines,
			string.format(
				"    MISS (%s%s) | timing %s | closest gap %s",
				payload.missReason or "?",
				if payload.missAmount and geometry
					then (if payload.missReason == "Early" or payload.missReason == "Late"
						then string.format(" %.0f ms", payload.missAmount * 1000)
						else string.format(" %.1f cm", geometry.units.toMeters(payload.missAmount) * 100))
					else "",
				ms(payload.timingErrorSeconds),
				if payload.minGap and geometry then string.format("%.1f cm", geometry.units.toMeters(payload.minGap) * 100) else "n/a"
			)
		)
	elseif payload.accepted then
		table.insert(lines, "    practice swing (no pitch in the Active window)")
	end
	if predicted then
		local predictedLabel = if predicted.contact then predicted.contact.label else "Miss"
		local serverLabel = if contact then contact.label else "Miss"
		table.insert(lines, `    client prediction: {predictedLabel} ({if predictedLabel == serverLabel then "matches" else "MISMATCH"})`)
	end
	PitchDebugView.setSection(SECTION_RESULT, table.concat(lines, "\n"))
end

return BattingDebugView
