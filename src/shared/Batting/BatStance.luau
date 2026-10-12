--!strict
-- The bat the player SEES, from the first frame of stance to the end of the
-- recovery. Pure functions of (swing, server time), so they are testable and
-- frame-rate independent.
--
-- The authoritative collision pose (SwingModel.activePoseAt) is the source of
-- truth. This module never changes it; it only decides where the bat is
-- while nothing can collide:
--
--   Ready         : in the batter's hands (the anchor), drifting a little
--                   toward the aimed swing so the hands visibly track the aim
--   Windup        : carried from wherever it was into the first collision pose
--   Active        : EXACTLY the collision pose
--   FollowThrough : the swing continuing about the same pivot (SwingModel.poseAt)
--   Recovery      : unwound back around the front of the body into the hands
--
-- Every hand-off is continuous, so the bat never snaps.

local LaneGeometry = require(script.Parent.Parent.Pitching.LaneGeometry)

local BattingConfig = require(script.Parent.BattingConfig)
local SwingModel = require(script.Parent.SwingModel)

local BatStance = {}

local function smoothstep(u: number): number
	return u * u * (3 - 2 * u)
end

-- Anchor used when the character rig is not available: roughly where a
-- batter's hands sit, relative to the batter marker.
function BatStance.fallbackAnchor(geometry: LaneGeometry.Geometry): Vector3
	local cfg = BattingConfig.Stance
	local units = geometry.units
	local frame = geometry.batterCFrame
	return frame.Position
		+ geometry.up * units.toStuds(cfg.FallbackHeightMeters)
		+ frame.LookVector * units.toStuds(cfg.FallbackForwardMeters)
		+ geometry.toPitcher * -units.toStuds(cfg.FallbackRearMeters)
end

-- Interpolates two poses (position and direction); the result is not
-- collidable. s = 0 gives `a`, s = 1 gives `b`.
function BatStance.blend(a: SwingModel.Pose, b: SwingModel.Pose, s: number, length: number): SwingModel.Pose
	local direction = a.direction:Lerp(b.direction, s)
	direction = if direction.Magnitude > 1e-4 then direction.Unit else a.direction
	local normal = a.planeNormal:Lerp(b.planeNormal, s)
	normal = normal - direction * normal:Dot(direction)
	if normal.Magnitude < 1e-4 then
		-- Degenerate: pick any perpendicular.
		normal = direction:Cross(Vector3.new(0, 1, 0))
		if normal.Magnitude < 1e-4 then
			normal = direction:Cross(Vector3.new(1, 0, 0))
		end
	end
	local knob = a.knob:Lerp(b.knob, s)
	return {
		knob = knob,
		tip = knob + direction * length,
		direction = direction,
		planeNormal = normal.Unit,
		angle = a.angle + (b.angle - a.angle) * s,
		collidable = false,
	}
end

-- The bat while waiting: in the hands, tilted back over the rear shoulder
-- (the swing model's rest direction), drifting toward the aimed swing by
-- Stance.PreloadFraction.
function BatStance.readyPose(geometry: LaneGeometry.Geometry, anchor: Vector3, aimX: number, aimY: number): SwingModel.Pose
	local base = SwingModel.restPose(geometry, aimX, aimY)
	local length = SwingModel.dimensions(geometry).length
	local knob = anchor:Lerp(base.knob, BattingConfig.Stance.PreloadFraction)
	return {
		knob = knob,
		tip = knob + base.direction * length,
		direction = base.direction,
		planeNormal = base.planeNormal,
		angle = base.angle,
		collidable = false,
	}
end

-- Moves `current` toward `target` with a time constant (frame-rate independent).
function BatStance.follow(current: SwingModel.Pose, target: SwingModel.Pose, dt: number, length: number): SwingModel.Pose
	local tau = BattingConfig.Stance.ReadyFollowSeconds
	local alpha = if tau <= 0 then 1 else 1 - math.exp(-math.max(dt, 0) / tau)
	return BatStance.blend(current, target, alpha, length)
end

-- The pose to draw at server time `t`.
--   fromPose  : the pose that was on screen when the click happened
--   readyPose : the resting pose right now (the Recovery target)
function BatStance.visualPoseAt(
	swing: SwingModel.Swing,
	t: number,
	fromPose: SwingModel.Pose,
	readyPose: SwingModel.Pose
): SwingModel.Pose
	local phase, phaseStart, phaseEnd = SwingModel.phaseAt(swing, t)
	local length = swing.dims.length
	if phase == "Ready" then
		return readyPose
	elseif phase == "Windup" then
		local u = math.clamp((t - phaseStart) / (phaseEnd - phaseStart), 0, 1)
		local eased = u ^ BattingConfig.Stance.WindupEasePower
		return BatStance.blend(fromPose, SwingModel.activePoseAt(swing, swing.activeStart), eased, length)
	elseif phase == "Active" then
		return SwingModel.activePoseAt(swing, t)
	elseif phase == "FollowThrough" then
		return SwingModel.poseAt(swing, t)
	end
	-- Recovery: unwind back around the FRONT of the body (the way the swing
	-- came) while blending into the hands' resting pose. A straight blend
	-- from the follow-through would cut the bat through the batter's body.
	local s = smoothstep(math.clamp((t - phaseStart) / (phaseEnd - phaseStart), 0, 1))
	local angle = swing.followEndAngle + (swing.startAngle - swing.followEndAngle) * s
	local raise = swing.followRaise + (swing.restRaise - swing.followRaise) * s
	return BatStance.blend(BatStance.poseAtAngle(swing, angle, raise), readyPose, s, length)
end

-- Non-collidable bat pose about the swing pivot at a swing-plane angle and a
-- raise out of the plane (same construction as SwingModel.poseAt). At the
-- follow-through's end angle and raise it equals the follow-through's last pose.
function BatStance.poseAtAngle(swing: SwingModel.Swing, angle: number, raise: number): SwingModel.Pose
	local flat = SwingModel.directionAt(swing, angle)
	local direction = if raise == 0 then flat else (flat * math.cos(raise) + swing.axis * math.sin(raise)).Unit
	local knob = swing.pivot + flat * swing.dims.pivotRadius
	return {
		knob = knob,
		tip = knob + direction * swing.dims.length,
		direction = direction,
		planeNormal = if raise == 0 then swing.axis else direction:Cross(swing.axis:Cross(direction)).Unit,
		angle = angle,
		collidable = false,
	}
end

-- World points where the two hands grip the handle for a bat pose.
function BatStance.gripPoints(geometry: LaneGeometry.Geometry, pose: SwingModel.Pose): (Vector3, Vector3)
	local cfg = BattingConfig.Stance
	local units = geometry.units
	return pose.knob + pose.direction * units.toStuds(cfg.GripBottomMeters),
		pose.knob + pose.direction * units.toStuds(cfg.GripTopMeters)
end

return BatStance
