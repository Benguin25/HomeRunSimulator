--!strict
-- The pitcher's delivery on the authoritative windup/release clock. Pure
-- cosmetics: it never changes a pitch, it only reads windupTime, releaseTime
-- and the replicated (jittered) release point.
--
-- PitcherKeyframes are evaluated as smooth tracks over the pitch's own windup
-- length, turned into a world pose (pelvis/chest/head + limb IK targets) and
-- solved on the AthleteRig. Release sync: the delivery is authored so its
-- hand lands near the default release point; the remaining difference to the
-- actual release point is measured once per pitch and blended in (body from
-- the leg lift, stride foot by foot strike, arm by release), so the ball held
-- in the hand is exactly at the release point at the release time and then
-- continues on the unchanged trajectory. PitchPlayback uses `sample(...).hand`
-- for the ball before release; the client rig renders the same solve.

local AthleteConfig = require(script.Parent.AthleteConfig)
local AthleteRig = require(script.Parent.AthleteRig)
local KeyTrack = require(script.Parent.KeyTrack)
local Keyframes = require(script.Parent.PitcherKeyframes)
local Geometry = require(script.Parent.Parent.Pitching.LaneGeometry)
local PitchConfig = require(script.Parent.Parent.Pitching.PitchConfig)

local Motion = {}

local cfg = AthleteConfig.Pitcher

export type Channels = { [string]: any }

export type Sample = {
	channels: Channels,
	pose: AthleteRig.Pose,
	solved: AthleteRig.Solved,
	hand: Vector3, -- the ball in the throwing hand (world studs)
	released: boolean,
	u: number, -- windup fraction, clamped 0..1
	since: number, -- seconds since release (negative before it)
}

local compiledByWindup: { [string]: KeyTrack.CompiledSet } = {}
local alignmentCache: { [any]: { [string]: Vector3 } } = setmetatable({}, { __mode = "k" }) :: any
local alignmentCount: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function compiled(windupSeconds: number): KeyTrack.CompiledSet
	local key = string.format("%.4f", windupSeconds)
	local set = compiledByWindup[key]
	if set == nil then
		set = KeyTrack.compileSet(Keyframes, windupSeconds)
		compiledByWindup[key] = set
	end
	return set
end

function Motion.throwSide(): "Right" | "Left"
	return if PitchConfig.Geometry.PitcherHand == "Left" then "Left" else "Right"
end

function Motion.skeleton(geo: Geometry.Geometry): AthleteRig.Skeleton
	return AthleteRig.skeleton(geo.units.metersPerStud, cfg.Scale)
end

-- Windup fraction at which the ball becomes visible in the throwing hand.
function Motion.ballAlpha(u: number): number
	return KeyTrack.smooth((u - cfg.BallRevealStart) / (cfg.BallRevealEnd - cfg.BallRevealStart))
end

function Motion.trailOn(u: number): boolean
	return u >= cfg.TrailStart
end

local function zeroShifts(ch: Channels): Channels
	ch.bodyShift, ch.armShift, ch.leadShift, ch.trailShift = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
	return ch
end

local function breathe(ch: Channels, weight: number, now: number): Channels
	if weight <= 0 then
		return ch
	end
	local wave = math.sin(now * 2 * math.pi / cfg.IdleBreathPeriodSeconds)
	ch.chestPitch += weight * cfg.IdleBreathDegrees * wave
	ch.pelvis += Vector3.new(0, weight * cfg.IdleBobMeters * wave, 0)
	return ch
end

-- The set position (no pitch on this lane), with idle breathing.
function Motion.idleChannels(now: number): Channels
	return breathe(zeroShifts(KeyTrack.evalSet(compiled(1), -1)), 1, now)
end

-- Turns channels into a world pose and solves the rig.
function Motion.build(geo: Geometry.Geometry, ch: Channels): (AthleteRig.Pose, AthleteRig.Solved, Vector3)
	local skel = Motion.skeleton(geo)
	local s = geo.units.toStuds
	local forward, arm, up = -geo.toPitcher, geo.armSide, geo.up
	local ground = geo.pitcherGround
	local throw = Motion.throwSide()
	local glove = if throw == "Right" then "Left" else "Right"

	local pelvisOffset = ch.pelvis :: Vector3
	local pelvisPos = ground
		+ arm * s(pelvisOffset.X)
		+ up * (skel.pelvisHeight + s(pelvisOffset.Y))
		+ forward * s(pelvisOffset.Z)
		+ ch.bodyShift
	local pelvisFrame = AthleteRig.orient(forward, arm, up, ch.pelvisYaw, ch.pelvisPitch, ch.pelvisRoll)
	local pelvisCF = CFrame.new(pelvisPos) * pelvisFrame.rotation
	local chestFrame =
		AthleteRig.orient(pelvisFrame.facing, pelvisFrame.arm, pelvisFrame.up, ch.chestYaw, ch.chestPitch, ch.chestRoll)
	local chestPart = skel.parts.UpperTorso
	local chestCenter = (pelvisCF * chestPart.c0).Position - chestFrame.rotation * chestPart.c1.Position
	local function chestPoint(v: Vector3): Vector3
		return chestCenter + chestFrame.arm * s(v.X) + chestFrame.up * s(v.Y) + chestFrame.facing * s(v.Z)
	end
	local function chestDir(v: Vector3): Vector3
		return chestFrame.arm * v.X + chestFrame.up * v.Y + chestFrame.facing * v.Z
	end

	-- Head: eyes on the catcher's target, within a natural neck turn.
	local neck = (CFrame.new(chestCenter) * chestFrame.rotation * skel.parts.Head.c0).Position
	local look = geo.plateGround + up * s(cfg.LookHeightMeters) - neck
	local head = chestFrame.rotation
	if look.Magnitude > 1e-3 then
		local wanted = CFrame.lookAt(Vector3.zero, look.Unit, up)
		local angle = math.deg(math.acos(math.clamp(chestFrame.facing:Dot(look.Unit), -1, 1)))
		local weight = (ch.look :: number) * math.min(1, cfg.MaxHeadTurnDegrees / math.max(angle, 1e-3))
		head = chestFrame.rotation:Lerp(wanted, math.clamp(weight, 0, 1))
	end

	local function foot(offset: Vector3, yaw: number, pitch: number, shift: Vector3): (Vector3, AthleteRig.Frame)
		local frame = AthleteRig.orient(forward, arm, up, yaw, pitch, 0)
		local lift = math.max(skel.ankleHeight + s(offset.Y), AthleteRig.footClearance(skel, frame.rotation, up))
		return ground + arm * s(offset.X) + forward * s(offset.Z) + up * lift + shift, frame
	end
	local leadAnkle, leadFrame = foot(ch.leadFoot, ch.leadYaw, ch.leadPitch, ch.leadShift)
	local trailAnkle, trailFrame = foot(ch.trailFoot, ch.trailYaw, ch.trailPitch, ch.trailShift)
	local function kneePole(frame: AthleteRig.Frame): Vector3
		return frame.facing + pelvisFrame.facing + up * 0.1
	end

	local limbs: { [string]: AthleteRig.Limb } = {
		[throw .. "Arm"] = { target = chestPoint(ch.throwHand) + ch.armShift, pole = chestDir(ch.throwPole) },
		[glove .. "Arm"] = { target = chestPoint(ch.gloveHand), pole = chestDir(ch.glovePole) },
		[throw .. "Leg"] = { target = trailAnkle, pole = kneePole(trailFrame), rotation = trailFrame.rotation },
		[glove .. "Leg"] = { target = leadAnkle, pole = kneePole(leadFrame), rotation = leadFrame.rotation },
	}
	local pose: AthleteRig.Pose = {
		pelvis = pelvisCF,
		chest = chestFrame.rotation,
		head = head,
		rightArm = limbs.RightArm,
		leftArm = limbs.LeftArm,
		rightLeg = limbs.RightLeg,
		leftLeg = limbs.LeftLeg,
	}
	local solved = AthleteRig.solve(skel, pose)
	return pose, solved, solved.grips[throw]
end

-- Difference between the authoritative release point and the authored hand
-- at release (world studs), measured once per pitch.
function Motion.alignment(geo: Geometry.Geometry, windupSeconds: number, releasePoint: Vector3): Vector3
	local perGeo = alignmentCache[geo]
	if perGeo == nil or (alignmentCount[geo] or 0) >= 32 then
		-- Bounded: only the current and recent pitches of a lane are needed.
		perGeo = {}
		alignmentCache[geo] = perGeo
		alignmentCount[geo] = 0
	end
	local key = string.format("%.4f|%.4f|%.4f|%.4f", windupSeconds, releasePoint.X, releasePoint.Y, releasePoint.Z)
	local cached = perGeo[key]
	if cached then
		return cached
	end
	local ch = zeroShifts(KeyTrack.evalSet(compiled(windupSeconds), windupSeconds))
	local _, _, grip = Motion.build(geo, ch)
	local delta = releasePoint - grip
	perGeo[key] = delta
	alignmentCount[geo] = (alignmentCount[geo] or 0) + 1
	return delta
end

-- Channels of a pitch's delivery at server time `now`.
function Motion.pitchChannels(
	geo: Geometry.Geometry,
	windupTime: number,
	releaseTime: number,
	releasePoint: Vector3,
	now: number
): Channels
	local windup = math.max(releaseTime - windupTime, 0.05)
	local t = now - windupTime
	local ch = KeyTrack.evalSet(compiled(windup), t)
	local a = cfg.Alignment
	local u = t / windup
	local since = t - windup
	local fade = 1 - KeyTrack.smooth((since - a.FadeStartSeconds) / (a.FadeEndSeconds - a.FadeStartSeconds))
	local body = KeyTrack.smooth((u - a.StartFraction) / (1 - a.StartFraction)) * fade
	local lead = KeyTrack.smooth((u - a.StartFraction) / (a.FootPlantFraction - a.StartFraction)) * fade
	local trail = KeyTrack.smooth((u - a.TrailDragFraction) / (1 - a.TrailDragFraction)) * fade
	if body > 0 or lead > 0 or trail > 0 then
		local delta = Motion.alignment(geo, windup, releasePoint)
		local up = geo.up
		local vertical = delta:Dot(up)
		local horizontal = delta - up * vertical
		local maxBody = geo.units.toStuds(a.MaxBodyVerticalMeters)
		local bodyVertical = math.clamp(vertical, -maxBody, maxBody)
		ch.bodyShift = (horizontal + up * bodyVertical) * body
		ch.armShift = up * (vertical - bodyVertical) * body
		ch.leadShift = horizontal * lead
		ch.trailShift = horizontal * trail
	else
		zeroShifts(ch)
	end
	-- Idle breathing fades out as the windup starts and back in after the walk back.
	local breath = if t < 0
		then 1
		elseif t < 0.2 then 1 - KeyTrack.smooth(t / 0.2)
		else KeyTrack.smooth((since - cfg.RecoverySeconds) / 0.5)
	return breathe(ch, breath, now)
end

-- Full pose of a pitch's delivery. `hand` is where the ball is held; at and
-- after `releaseTime` the ball follows the trajectory instead.
function Motion.sample(
	geo: Geometry.Geometry,
	windupTime: number,
	releaseTime: number,
	releasePoint: Vector3,
	now: number
): Sample
	local ch = Motion.pitchChannels(geo, windupTime, releaseTime, releasePoint, now)
	local pose, solved, grip = Motion.build(geo, ch)
	local windup = math.max(releaseTime - windupTime, 0.05)
	return {
		channels = ch,
		pose = pose,
		solved = solved,
		hand = grip,
		released = now >= releaseTime,
		u = math.clamp((now - windupTime) / windup, 0, 1),
		since = now - releaseTime,
	}
end

return Motion
