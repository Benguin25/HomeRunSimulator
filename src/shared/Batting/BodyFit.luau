--!strict
-- Where the visible body should stand so its hands can hold the bat.
--
-- The swing model rotates the bat about a pivot that depends only on the aim
-- point, so wherever the batter marker is, the bat's circle of travel may be
-- far from the avatar's shoulders. This module returns a client-side offset
-- for the body (horizontal slide toward the pivot, plus a crouch when the
-- pivot is far below the shoulders). It only moves the visible character: the
-- collision geometry is untouched.

local LaneGeometry = require(script.Parent.Parent.Pitching.LaneGeometry)

local BattingConfig = require(script.Parent.BattingConfig)

local BodyFit = {}

local UP = Vector3.new(0, 1, 0)

-- shoulderMid : midpoint of the shoulders with the body at its home position
-- pivot       : the swing pivot (SwingModel.Swing.pivot)
-- armLength   : shoulder to hand center, fully extended (studs)
-- gripRadius  : farthest grip from the pivot (studs)
-- Returns the world-space offset to apply to the whole body.
function BodyFit.target(
	geometry: LaneGeometry.Geometry,
	shoulderMid: Vector3,
	pivot: Vector3,
	armLength: number,
	gripRadius: number
): Vector3
	local cfg = BattingConfig.Stance
	if not cfg.BodyFit then
		return Vector3.zero
	end
	local units = geometry.units

	-- Horizontal: put the shoulders over the pivot, ignoring a small dead zone.
	local flat = pivot - shoulderMid
	flat = Vector3.new(flat.X, 0, flat.Z)
	local distance = flat.Magnitude
	local dead = units.toStuds(cfg.BodyDeadZoneMeters)
	local shift = Vector3.zero
	if distance > dead then
		shift = flat * ((distance - dead) / distance)
		local limit = units.toStuds(cfg.BodyMaxShiftMeters)
		if shift.Magnitude > limit then
			shift = shift.Unit * limit
		end
	end

	-- Vertical: how far can the arms drop from the shoulders to the grips?
	local leftover = (flat - shift).Magnitude
	local horizontalReach = leftover + gripRadius
	local usable = armLength * cfg.BodyReachMargin
	local allowedDrop = math.sqrt(math.max(usable * usable - horizontalReach * horizontalReach, 0))
	local drop = shoulderMid.Y - pivot.Y
	local crouch = math.clamp(drop - allowedDrop, 0, units.toStuds(cfg.BodyMaxCrouchMeters))
	return shift - UP * crouch
end

return BodyFit
