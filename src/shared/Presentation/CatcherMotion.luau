--!strict
-- The catcher behind the plate: a receiving crouch, the mitt raised to a
-- neutral target during the windup, a late reach to where the ball really
-- ends, a "pop" recoil at the catch and a relaxed return. Pure cosmetics on
-- the same server clock as the pitch; it never touches collision or outcomes.
--
-- The mitt only moves toward the actual pitch after ReactFraction of the
-- flight (the ball itself is plainly visible by then), so the setup never
-- tips off a location before release.

local AthleteConfig = require(script.Parent.AthleteConfig)
local AthleteRig = require(script.Parent.AthleteRig)
local KeyTrack = require(script.Parent.KeyTrack)
local Geometry = require(script.Parent.Parent.Pitching.LaneGeometry)

local CatcherMotion = {}

local cfg = AthleteConfig.Catcher

export type PitchInfo = {
	windupTime: number,
	releaseTime: number,
	endTime: number, -- server time the ball reaches the end of its flight
	endPosition: Vector3,
	endVelocity: Vector3?,
	cutTime: number?, -- bat contact: the ball never arrives
}

export type Sample = {
	solved: AthleteRig.Solved,
	mitt: Vector3, -- where the mitt's pocket is aimed
	caught: boolean,
}

local smooth = KeyTrack.smooth

function CatcherMotion.skeleton(geo: Geometry.Geometry): AthleteRig.Skeleton
	return AthleteRig.skeleton(geo.units.metersPerStud, cfg.Scale)
end

-- Ground point the catcher squats over.
function CatcherMotion.origin(geo: Geometry.Geometry): Vector3
	return geo.plateGround - geo.toPitcher * geo.units.toStuds(cfg.BehindPlateMeters)
end

function CatcherMotion.sample(geo: Geometry.Geometry, pitch: PitchInfo?, now: number): Sample
	local skel = CatcherMotion.skeleton(geo)
	local s = geo.units.toStuds
	local facing, arm, up = geo.toPitcher, geo.right, geo.up
	local origin = CatcherMotion.origin(geo)
	local function local3(x: number, y: number, z: number): Vector3
		return arm * s(x) + up * s(y) + facing * s(z)
	end

	local rest = origin + local3(-0.2, 0.42, 0.3)
	local target = geo.plateGround + up * s(cfg.TargetHeightMeters) - geo.toPitcher * s(cfg.BehindPlateMeters - cfg.TargetForwardMeters)
	local mitt = rest
	local caught = false
	local bob = 0
	local breath = math.sin(now * 2 * math.pi / 3.1)
	if pitch then
		local windup = math.max(pitch.releaseTime - pitch.windupTime, 0.05)
		local raised = rest:Lerp(target, smooth((now - pitch.windupTime) / (windup * cfg.SetupFraction)))
		mitt = raised
		local flight = pitch.endTime - pitch.releaseTime
		local reactAt = pitch.releaseTime + flight * cfg.ReactFraction
		local cut = pitch.cutTime
		if cut and now >= cut then
			-- Contact: the ball is gone; relax the mitt.
			mitt = raised:Lerp(rest, smooth((now - cut) / cfg.RelaxSeconds))
		elseif now >= reactAt then
			local reach = smooth((now - reactAt) / math.max(pitch.endTime - reactAt, 1e-3))
			mitt = target:Lerp(pitch.endPosition, reach)
			if now >= pitch.endTime then
				caught = true
				local since = now - pitch.endTime
				local travel = pitch.endVelocity
				local back = if travel and travel.Magnitude > 1e-6 then travel.Unit else -geo.toPitcher
				local recoil = if since < cfg.RecoilSeconds
					then smooth(since / cfg.RecoilSeconds)
					else 1 - 0.6 * smooth((since - cfg.RecoilSeconds) / 0.25)
				local relax = smooth((since - cfg.HoldSeconds) / cfg.RelaxSeconds)
				mitt = (pitch.endPosition + back * s(cfg.RecoilMeters) * recoil):Lerp(rest, relax)
				bob = -0.025 * (1 - smooth(since / 0.3)) * smooth(since / 0.05)
			end
		end
	end

	local pelvisPos = origin + up * (skel.pelvisHeight + s(-0.5 + bob + 0.004 * breath)) + facing * s(0.02)
	local pelvisFrame = AthleteRig.orient(facing, arm, up, 0, 28, 0)
	local pelvisCF = CFrame.new(pelvisPos) * pelvisFrame.rotation
	local chestFrame = AthleteRig.orient(pelvisFrame.facing, pelvisFrame.arm, pelvisFrame.up, -4, -12 + 0.8 * breath, 0)
	local chestPart = skel.parts.UpperTorso
	local chestCenter = (pelvisCF * chestPart.c0).Position - chestFrame.rotation * chestPart.c1.Position
	local neck = (CFrame.new(chestCenter) * chestFrame.rotation * skel.parts.Head.c0).Position
	-- Eyes on the ball while it flies, on the pitcher otherwise.
	local lookAt = geo.pitcherGround + up * s(1.6)
	if pitch and now >= pitch.releaseTime and not caught and not (pitch.cutTime and now >= pitch.cutTime) then
		lookAt = pitch.endPosition:Lerp(lookAt, 0.3)
	elseif caught then
		lookAt = mitt
	end
	local head = CFrame.lookAt(Vector3.zero, (lookAt - neck).Unit, up)

	local function foot(side: number): (Vector3, AthleteRig.Frame)
		local frame = AthleteRig.orient(facing, arm, up, 28 * side, 0, 0)
		return origin + arm * s(0.3 * side) + facing * s(0.05) + up * skel.ankleHeight, frame
	end
	local rightAnkle, rightFrame = foot(1)
	local leftAnkle, leftFrame = foot(-1)
	local pose: AthleteRig.Pose = {
		pelvis = pelvisCF,
		chest = chestFrame.rotation,
		head = head,
		-- Bare hand tucked behind the back, mitt with its pocket to the pitcher.
		rightArm = {
			target = chestCenter + chestFrame.arm * s(0.24) - chestFrame.up * s(0.36) - chestFrame.facing * s(0.16),
			pole = chestFrame.arm - chestFrame.facing,
		},
		leftArm = {
			target = mitt,
			pole = -chestFrame.arm - chestFrame.up,
			rotation = CFrame.fromMatrix(Vector3.zero, -geo.right, -geo.up),
		},
		rightLeg = { target = rightAnkle, pole = rightFrame.facing + up * 0.6 + arm * 0.4, rotation = rightFrame.rotation },
		leftLeg = { target = leftAnkle, pole = leftFrame.facing + up * 0.6 - arm * 0.4, rotation = leftFrame.rotation },
	}
	return { solved = AthleteRig.solve(skel, pose), mitt = mitt, caught = caught }
end

return CatcherMotion
