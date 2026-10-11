--!strict
-- Two-bone arm IK for an R15 rig, expressed over Motor6D data so it can be
-- verified without Roblox instances (see ArmIK tests).
--
-- A Motor6D places its Part1 at   Part0 * C0 * Transform * C1:Inverse().
-- For shoulder -> elbow -> wrist only the rotation of each Transform is
-- driven. We pick the elbow position with the classic two-bone solution
-- (elbow on the side of a "pole" hint), then choose each joint's rotation as
-- the smallest rotation that points the limb at its next joint. That yields
-- the shoulder and elbow Transforms to assign to the Motor6Ds.
--
-- Out-of-reach targets clamp to a fully extended arm pointing at the target.

local ArmIK = {}

export type ArmRig = {
	shoulderC0: CFrame, -- Part0 (torso) side
	shoulderC1: CFrame, -- Part1 (upper arm) side
	elbowC0: CFrame,
	elbowC1: CFrame,
	wristC0: CFrame,
	wristC1: CFrame,
}

export type Solution = {
	shoulder: CFrame, -- Transform for the shoulder Motor6D (rotation only)
	elbow: CFrame, -- Transform for the elbow Motor6D (rotation only)
	shoulderPosition: Vector3,
	elbowPosition: Vector3,
	wristPosition: Vector3,
	reachable: boolean,
}

local function rotationBetween(from: Vector3, to: Vector3): CFrame
	local axis = from:Cross(to)
	local dot = math.clamp(from:Dot(to), -1, 1)
	if axis.Magnitude < 1e-6 then
		if dot > 0 then
			return CFrame.identity
		end
		-- Opposite directions: half turn about any perpendicular axis.
		local perpendicular = from:Cross(Vector3.new(0, 1, 0))
		if perpendicular.Magnitude < 1e-6 then
			perpendicular = from:Cross(Vector3.new(1, 0, 0))
		end
		return CFrame.fromAxisAngle(perpendicular.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

-- Joint-to-joint lengths and the wrist->hand-center distance.
function ArmIK.lengths(rig: ArmRig): (number, number, number)
	local upper = (rig.shoulderC1:Inverse() * rig.elbowC0).Position.Magnitude
	local lower = (rig.elbowC1:Inverse() * rig.wristC0).Position.Magnitude
	return upper, lower, rig.wristC1.Position.Magnitude
end

function ArmIK.shoulderPosition(torso: CFrame, rig: ArmRig): Vector3
	return (torso * rig.shoulderC0).Position
end

-- Solves the arm so the HAND CENTER is at `grip`. `pole` is a direction the
-- elbow should bend toward (any non-zero vector).
function ArmIK.solve(torso: CFrame, rig: ArmRig, grip: Vector3, pole: Vector3): Solution
	local neutralShoulder = torso * rig.shoulderC0
	local shoulder = neutralShoulder.Position
	local toElbow = (rig.shoulderC1:Inverse() * rig.elbowC0).Position -- in the shoulder joint frame
	local toWrist = (rig.elbowC1:Inverse() * rig.wristC0).Position -- in the elbow joint frame
	local upper, lower, handOffset = toElbow.Magnitude, toWrist.Magnitude, rig.wristC1.Position.Magnitude

	-- The hand center lies on the forearm line, `handOffset` beyond the wrist,
	-- so the arm is a two-bone chain whose forearm is lengthened by the hand
	-- offset and whose end is the hand center. Solving that directly gives the
	-- elbow with no iteration (which is unstable when the arm folds back).
	local reachLower = lower + handOffset
	local maxReach = (upper + reachLower) * 0.9995
	local minReach = math.abs(upper - reachLower) + 1e-3

	local delta = grip - shoulder
	local distance = delta.Magnitude
	local along = if distance > 1e-6 then delta / distance else Vector3.new(0, -1, 0)
	local reachable = distance <= maxReach
	distance = math.clamp(distance, minReach, maxReach)

	local a = (upper * upper - reachLower * reachLower + distance * distance) / (2 * distance)
	local h = math.sqrt(math.max(upper * upper - a * a, 0))
	local bend = pole - along * pole:Dot(along)
	if bend.Magnitude < 1e-4 then
		bend = along:Cross(Vector3.new(0, 1, 0))
		if bend.Magnitude < 1e-4 then
			bend = along:Cross(Vector3.new(1, 0, 0))
		end
	end
	local elbow = shoulder + along * a + bend.Unit * h
	local hand = shoulder + along * distance
	local wrist = elbow + (hand - elbow).Unit * lower

	local shoulderTransform = rotationBetween(toElbow.Unit, neutralShoulder:VectorToObjectSpace((elbow - shoulder).Unit))
	local upperArm = neutralShoulder * shoulderTransform * rig.shoulderC1:Inverse()
	local neutralElbow = upperArm * rig.elbowC0
	local elbowTransform = rotationBetween(toWrist.Unit, neutralElbow:VectorToObjectSpace((wrist - elbow).Unit))

	return {
		shoulder = shoulderTransform,
		elbow = elbowTransform,
		shoulderPosition = shoulder,
		elbowPosition = elbow,
		wristPosition = wrist,
		reachable = reachable,
	}
end

-- World frame of the last joint (wrist/ankle) with the solution applied and
-- an identity Transform on that joint.
function ArmIK.endJointFrame(torso: CFrame, rig: ArmRig, solution: Solution): CFrame
	local upperArm = torso * rig.shoulderC0 * solution.shoulder * rig.shoulderC1:Inverse()
	local lowerArm = upperArm * rig.elbowC0 * solution.elbow * rig.elbowC1:Inverse()
	return lowerArm * rig.wristC0
end

-- Rotation-only Transform for the last joint that gives the end part (hand /
-- foot) the world orientation of `desired`, whatever the limb above it did.
function ArmIK.endTransform(torso: CFrame, rig: ArmRig, solution: Solution, desired: CFrame): CFrame
	local joint = ArmIK.endJointFrame(torso, rig, solution)
	-- part = joint * T * C1:Inverse()  =>  T.R = joint.R^-1 * desired.R * C1.R
	return joint.Rotation:Inverse() * desired.Rotation * rig.wristC1.Rotation
end

-- Forward kinematics with the solved transforms (wrist Transform = identity).
-- Returns the elbow joint, wrist joint and hand center in world space.
function ArmIK.forward(torso: CFrame, rig: ArmRig, solution: Solution): (Vector3, Vector3, Vector3)
	local upperArm = torso * rig.shoulderC0 * solution.shoulder * rig.shoulderC1:Inverse()
	local elbowJoint = upperArm * rig.elbowC0 * solution.elbow
	local lowerArm = elbowJoint * rig.elbowC1:Inverse()
	local wristJoint = lowerArm * rig.wristC0
	local hand = wristJoint * rig.wristC1:Inverse()
	return elbowJoint.Position, wristJoint.Position, hand.Position
end

return ArmIK
