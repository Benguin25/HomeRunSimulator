--!strict
-- The batter's body pose for R15 and R6 rigs, as Motor6D Transforms.
--
-- Pure math over joint offsets (C0/C1), part sizes and the root's CFrame, so
-- both rigs are testable without Roblox (see CharacterPose.spec).
-- CharacterGrip reads a bound rig with `read`, calls `solve` each frame and
-- writes the Transforms back.
--
-- Both rigs follow the same bat pose (BatStance / SwingModel), which follows
-- the authoritative collision swing. Nothing here feeds back into the swing.
--
-- Shared by both rigs: the chest turns to face the hands as they circle the
-- body (torsoYaw), and the upper body leans toward the grips when the arms
-- would fall short (solveLean). Roblox arms are short relative to the bat's
-- circle, so without both the hands cannot stay on the handle.
--
--   R15: root offset (body fit + crouch), hips and waist share the turn, the
--        waist leans, two-bone arms with the wrists curled around the
--        handle, legs planted with bent knees.
--   R6 : no waist, elbows or wrists. The whole torso turns and leans about
--        the hips through RootJoint, each rigid arm is pointed at its grip
--        from the shoulder, and the legs splay into a batting stance that
--        keeps the feet on the ground.
--
-- A Motor6D places Part1 at Part0 * C0 * Transform * C1:Inverse().

local LaneGeometry = require(script.Parent.Parent.Pitching.LaneGeometry)

local ArmIK = require(script.Parent.ArmIK)
local BatStance = require(script.Parent.BatStance)
local BattingConfig = require(script.Parent.BattingConfig)
local BodyFit = require(script.Parent.BodyFit)
local RigBinding = require(script.Parent.RigBinding)
local SwingModel = require(script.Parent.SwingModel)

local CharacterPose = {}

local UP = Vector3.new(0, 1, 0)

export type Offsets = { c0: CFrame, c1: CFrame }

export type R15Rig = {
	kind: "R15",
	root: CFrame, -- HumanoidRootPart
	rootJoint: Offsets,
	waist: Offsets,
	arms: { ArmIK.ArmRig }, -- [1] left, [2] right
	legs: { ArmIK.ArmRig }, -- hip/knee/ankle, [1] left, [2] right; empty = legs untouched
}

-- A rigid R6 limb: its joint and the point (in the limb part's space) that
-- should land on the target (hand or foot).
export type R6Limb = { joint: Offsets, tip: Vector3 }

export type R6Rig = {
	kind: "R6",
	root: CFrame,
	rootJoint: Offsets,
	hipDrop: number, -- torso center down to the hip line (studs)
	arms: { R6Limb }, -- [1] left, [2] right
	legs: { R6Limb }, -- [1] left, [2] right; empty = legs untouched
}

export type Rig = R15Rig | R6Rig

export type Result = {
	transforms: { [string]: CFrame }, -- by RigBinding role
	hands: { Vector3 }, -- solved hand points (same order as the arms)
	grips: { Vector3 }, -- the grip each hand was sent to
	gap: number, -- largest hand-to-grip distance (studs)
	torsoYaw: number, -- radians, + = open for a right-handed batter's view (see torsoYaw)
	lean: number, -- radians
}

local ARM_ROLES = {
	R15 = { { "leftShoulder", "leftElbow", "leftWrist" }, { "rightShoulder", "rightElbow", "rightWrist" } },
	R6 = { { "leftShoulder" }, { "rightShoulder" } },
}
local LEG_ROLES = {
	R15 = { { "leftHip", "leftKnee", "leftAnkle" }, { "rightHip", "rightKnee", "rightAnkle" } },
	R6 = { { "leftHip" }, { "rightHip" } },
}

-- Reading a bound rig ---------------------------------------------------------

-- Joint offsets go through RigBinding.frame, so Motor6D and
-- AnimationConstraint joints read the same way.
local function offsets(joint: any): Offsets
	local frame = RigBinding.frame(joint)
	return { c0 = frame.c0, c1 = frame.c1 }
end

local function chain(joints: { [string]: any }, roles: { string }): ArmIK.ArmRig?
	local a, b, c = joints[roles[1]], joints[roles[2]], joints[roles[3]]
	if not (a and b and c) then
		return nil
	end
	local fa, fb, fc = RigBinding.frame(a), RigBinding.frame(b), RigBinding.frame(c)
	return { shoulderC0 = fa.c0, shoulderC1 = fa.c1, elbowC0 = fb.c0, elbowC1 = fb.c1, wristC0 = fc.c0, wristC1 = fc.c1 }
end

-- Snapshot of a bound rig's offsets this frame (avatar scale may change).
function CharacterPose.read(binding: RigBinding.Binding): Rig
	local joints = binding.joints
	local cfg = BattingConfig.Stance
	if binding.kind == "R15" then
		local arms = {}
		for _, roles in ARM_ROLES.R15 do
			table.insert(arms, (chain(joints, roles) :: ArmIK.ArmRig))
		end
		local legs = {}
		if cfg.Legs then
			local left, right = chain(joints, LEG_ROLES.R15[1]), chain(joints, LEG_ROLES.R15[2])
			if left and right then
				legs = { left, right }
			end
		end
		return {
			kind = "R15",
			root = binding.root.CFrame,
			rootJoint = offsets(joints.root),
			waist = offsets(joints.waist),
			arms = arms,
			legs = legs,
		}
	end
	local torso = RigBinding.frame(joints.root).part1
	local arms = {}
	for _, roles in ARM_ROLES.R6 do
		local motor = joints[roles[1]]
		local arm = RigBinding.frame(motor).part1
		table.insert(arms, { joint = offsets(motor), tip = Vector3.new(0, -arm.Size.Y / 2 * cfg.R6HandDepth, 0) })
	end
	local legs = {}
	if cfg.Legs and joints.leftHip and joints.rightHip then
		for _, roles in LEG_ROLES.R6 do
			local motor = joints[roles[1]]
			table.insert(legs, { joint = offsets(motor), tip = Vector3.new(0, -RigBinding.frame(motor).part1.Size.Y / 2, 0) })
		end
	end
	return {
		kind = "R6",
		root = binding.root.CFrame,
		rootJoint = offsets(joints.root),
		hipDrop = torso.Size.Y / 2,
		arms = arms,
		legs = legs,
	}
end

-- Body frames -----------------------------------------------------------------

-- Rotation about a world point.
local function about(point: Vector3, rotation: CFrame): CFrame
	return CFrame.new(point) * rotation * CFrame.new(-point)
end

local function leanRotation(lean: Vector3): CFrame
	return if lean.Magnitude > 1e-6 then CFrame.fromAxisAngle(lean.Unit, lean.Magnitude) else CFrame.identity
end

-- R15 lower torso: shifted, then the hips turned `hipYaw` about world up.
local function r15Lower(rig: R15Rig, shift: Vector3, hipYaw: number): CFrame
	local joint = rig.root * rig.rootJoint.c0
	local home = joint * CFrame.new(joint:VectorToObjectSpace(shift)) * rig.rootJoint.c1:Inverse()
	return about(home.Position, CFrame.fromAxisAngle(UP, hipYaw)) * home
end

-- R15 upper torso: the waist turned `waistYaw` and leaned by the rotation
-- vector `lean`, both about the waist joint.
local function r15Upper(rig: R15Rig, lower: CFrame, waistYaw: number, lean: Vector3): CFrame
	local joint = lower * rig.waist.c0
	return about(joint.Position, leanRotation(lean) * CFrame.fromAxisAngle(UP, waistYaw)) * joint * rig.waist.c1:Inverse()
end

local function r6Home(rig: R6Rig): CFrame
	return rig.root * rig.rootJoint.c0 * rig.rootJoint.c1:Inverse()
end

-- R6 torso: turned `yaw` about world up and leaned by `lean`, both about the
-- middle of the hips, then shifted.
local function r6Torso(rig: R6Rig, shift: Vector3, yaw: number, lean: Vector3): CFrame
	local home = r6Home(rig)
	local hips = home * Vector3.new(0, -rig.hipDrop, 0)
	return CFrame.new(shift) * about(hips, leanRotation(lean) * CFrame.fromAxisAngle(UP, yaw)) * home
end

-- The frame the arms hang from (R15 upper torso, R6 torso) for a body state.
local function chest(rig: Rig, shift: Vector3, yaw: number, lean: Vector3): CFrame
	if rig.kind == "R15" then
		local hipYaw = yaw * BattingConfig.Stance.HipTurnFraction
		return r15Upper(rig, r15Lower(rig, shift, hipYaw), yaw - hipYaw, lean)
	end
	return r6Torso(rig, shift, yaw, lean)
end

-- The point the upper body leans about (R15 waist joint, R6 middle of the hips).
local function leanPivot(rig: Rig, shift: Vector3, yaw: number): Vector3
	if rig.kind == "R15" then
		return (r15Lower(rig, shift, yaw * BattingConfig.Stance.HipTurnFraction) * rig.waist.c0).Position
	end
	return r6Home(rig) * Vector3.new(0, -rig.hipDrop, 0) + shift
end

local function shouldersOf(rig: Rig, chestFrame: CFrame): { Vector3 }
	local list = {}
	if rig.kind == "R15" then
		for _, arm in rig.arms do
			table.insert(list, ArmIK.shoulderPosition(chestFrame, arm))
		end
	else
		for _, arm in rig.arms do
			table.insert(list, (chestFrame * arm.joint.c0).Position)
		end
	end
	return list
end

-- Midpoint of the shoulders with the body standing (no turn or lean), shifted.
function CharacterPose.shoulderMid(rig: Rig, shift: Vector3): Vector3
	local list = shouldersOf(rig, chest(rig, shift, 0, Vector3.zero))
	return (list[1] + list[2]) / 2
end

-- Shoulder to hand point, arm fully extended (studs), averaged over both arms.
function CharacterPose.armLength(rig: Rig): number
	local total = 0
	if rig.kind == "R15" then
		for _, arm in rig.arms do
			local upper, lower, hand = ArmIK.lengths(arm)
			total += upper + lower + hand
		end
	else
		for _, arm in rig.arms do
			total += (arm.joint.c1:Inverse() * arm.tip).Magnitude
		end
	end
	return total / #rig.arms
end

function CharacterPose.maxCrouch(rig: Rig, geometry: LaneGeometry.Geometry): number
	local cfg = BattingConfig.Stance
	return geometry.units.toStuds(if rig.kind == "R6" then cfg.R6MaxCrouchMeters else cfg.BodyMaxCrouchMeters)
end

-- Where the body should be shifted for a swing pivot (see BodyFit).
function CharacterPose.bodyFitTarget(geometry: LaneGeometry.Geometry, rig: Rig, pivot: Vector3): Vector3
	local dims = SwingModel.dimensions(geometry)
	local gripRadius = dims.pivotRadius + geometry.units.toStuds(BattingConfig.Stance.GripTopMeters)
	return BodyFit.target(
		geometry,
		CharacterPose.shoulderMid(rig, Vector3.zero),
		pivot,
		CharacterPose.armLength(rig),
		gripRadius,
		CharacterPose.maxCrouch(rig, geometry)
	)
end

-- Where the hands rest: in front of the chest, a little toward the rear
-- shoulder, for the body as it currently stands.
function CharacterPose.anchor(geometry: LaneGeometry.Geometry, rig: Rig, shift: Vector3): Vector3
	local cfg = BattingConfig.Stance
	local reach = CharacterPose.armLength(rig)
	-- Rigid R6 arms can't bend to hands held high by the rear shoulder.
	local down = if rig.kind == "R6" then cfg.R6AnchorDownFraction else cfg.AnchorDownFraction
	return CharacterPose.shoulderMid(rig, shift)
		- geometry.up * (down * reach)
		+ geometry.batterCFrame.LookVector * (cfg.AnchorForwardFraction * reach)
		- geometry.toPitcher * (cfg.AnchorRearFraction * reach)
end

-- The rear arm (farther from the pitcher) is the top hand, as for a real
-- batter. Decided with the body standing, so it never flips mid-swing.
local function gripsFor(geometry: LaneGeometry.Geometry, rig: Rig, shift: Vector3, pose: SwingModel.Pose): { Vector3 }
	local bottom, top = BatStance.gripPoints(geometry, pose)
	local list = shouldersOf(rig, chest(rig, shift, 0, Vector3.zero))
	local middle = (list[1] + list[2]) / 2
	local grips = {}
	for i, shoulder in list do
		grips[i] = if (shoulder - middle):Dot(geometry.toPitcher) < 0 then top else bottom
	end
	return grips
end

-- Sign that makes a turn toward the pitcher ("opening") positive, for either
-- batting side.
function CharacterPose.openSign(geometry: LaneGeometry.Geometry): number
	local forward = geometry.batterCFrame.LookVector
	return if forward:Cross(geometry.toPitcher).Y >= 0 then 1 else -1
end

-- Torso turn (radians about world up) that keeps the chest facing the hands
-- as they circle the body. 0 = chest facing the plate. Fades out when the
-- hands pass close to the body axis (their direction is meaningless there),
-- so it is continuous for any bat path.
function CharacterPose.torsoYaw(geometry: LaneGeometry.Geometry, rig: Rig, shift: Vector3, grips: { Vector3 }): number
	local cfg = BattingConfig.Stance
	local toHands = (grips[1] + grips[2]) / 2 - CharacterPose.shoulderMid(rig, shift)
	toHands = Vector3.new(toHands.X, 0, toHands.Z)
	local fade = math.clamp(toHands.Magnitude / geometry.units.toStuds(0.15), 0, 1)
	if fade <= 0 then
		return 0
	end
	fade = fade * fade * (3 - 2 * fade)
	local forward = geometry.batterCFrame.LookVector
	forward = Vector3.new(forward.X, 0, forward.Z).Unit
	local openSign = CharacterPose.openSign(geometry)
	local angle = math.atan2(forward:Cross(toHands).Y, forward:Dot(toHands)) * openSign
	-- The follow-through carries the hands past 180 deg on the open side;
	-- wrap behind the back on the closed side instead, where hands never go.
	if angle < -math.rad(135) then
		angle += 2 * math.pi
	end
	local opened = math.clamp(
		angle * cfg.TorsoFollowHands,
		-math.rad(cfg.MaxTorsoCloseDegrees),
		math.rad(cfg.MaxTorsoOpenDegrees)
	)
	return opened * openSign * fade
end

-- Lean (a rotation vector about the lean pivot) that brings each shoulder
-- within `reach` of its grip. A few linearized steps; continuous in the bat
-- pose, so the body never snaps. Never leans away from grips that are close.
-- With `bowAxis`, the part of the lean NOT about that axis (a sideways lean)
-- is capped at `maxSide` radians (R6: bowing about the hip line leaves the
-- hip joints and legs in place; leaning sideways lifts one hip).
local function solveLean(
	rig: Rig,
	shift: Vector3,
	yaw: number,
	grips: { Vector3 },
	reach: number,
	maxLean: number,
	bowAxis: Vector3?,
	maxSide: number?
): Vector3
	local pivot = leanPivot(rig, shift, yaw)
	local lean = Vector3.zero
	for _ = 1, 4 do
		local list = shouldersOf(rig, chest(rig, shift, yaw, lean))
		local move = Vector3.zero
		local middle = Vector3.zero
		for i, shoulder in list do
			middle += shoulder / #list
			local toGrip = grips[i] - shoulder
			local distance = toGrip.Magnitude
			if distance > 1e-4 then
				move += toGrip * (math.max(distance - reach, 0) / distance) / #list
			end
		end
		local lever = middle - pivot
		local leverSq = lever:Dot(lever)
		if leverSq < 1e-6 then
			break
		end
		-- Small rotation w with w x lever = the part of `move` a lean can produce.
		local perpendicular = move - lever * (move:Dot(lever) / leverSq)
		lean += lever:Cross(perpendicular) / leverSq
		if bowAxis then
			local bow = bowAxis * lean:Dot(bowAxis)
			local side = lean - bow
			local limit = maxSide or 0
			if side.Magnitude > limit then
				side = if limit > 0 then side.Unit * limit else Vector3.zero
			end
			lean = bow + side
		end
		if lean.Magnitude > maxLean then
			lean = lean.Unit * maxLean
		end
	end
	return lean
end

-- R15 -------------------------------------------------------------------------

-- Two-bone arm with the wrist curled around the handle; the hand center still
-- lands on `grip`. Returns shoulder/elbow/wrist Transforms and the hand center.
local function solveR15Arm(upper: CFrame, arm: ArmIK.ArmRig, grip: Vector3, pole: Vector3, batDirection: Vector3)
	local cfg = BattingConfig.Stance
	local straight = ArmIK.solve(upper, arm, grip, pole)
	local offset = arm.wristC1.Position -- wrist joint, in hand space
	if cfg.WristWrap <= 0 or offset.Magnitude < 1e-4 then
		local _, _, hand = ArmIK.forward(upper, arm, straight)
		return straight.shoulder, straight.elbow, CFrame.identity, hand
	end
	-- Hand orientation with a straight wrist, then bent so the hand wraps the bat.
	local neutral = ArmIK.endJointFrame(upper, arm, straight) * arm.wristC1:Inverse()
	local along = neutral:VectorToWorldSpace(-offset).Unit -- wrist -> hand center
	local wrapped = along - batDirection * (along:Dot(batDirection) * cfg.WristWrap)
	local bend = if wrapped.Magnitude > 1e-3
		then ArmIK.rotationBetween(along, wrapped.Unit, math.rad(cfg.MaxWristBendDegrees))
		else CFrame.identity
	local handRotation = bend * neutral.Rotation
	-- Solve the arm to the wrist joint that puts the bent hand's center on the grip.
	local wristTarget = grip + handRotation:VectorToWorldSpace(offset)
	local toWrist = table.clone(arm)
	toWrist.wristC1 = CFrame.identity
	local solution = ArmIK.solve(upper, toWrist, wristTarget, pole)
	local wristT = ArmIK.endTransform(upper, arm, solution, handRotation)
	local hand = (ArmIK.endJointFrame(upper, arm, solution) * wristT * arm.wristC1:Inverse()).Position
	return solution.shoulder, solution.elbow, wristT, hand
end

local function solveR15(geometry: LaneGeometry.Geometry, rig: R15Rig, pose: SwingModel.Pose, shift: Vector3): Result
	local cfg = BattingConfig.Stance
	local transforms: { [string]: CFrame } = {}
	local grips = gripsFor(geometry, rig, shift, pose)

	-- Body: hips and waist share the turn; the waist leans toward the grips.
	local yaw = CharacterPose.torsoYaw(geometry, rig, shift, grips)
	local reach = CharacterPose.armLength(rig) * cfg.LeanReachFraction
	local lean = if cfg.ArmIK then solveLean(rig, shift, yaw, grips, reach, math.rad(cfg.MaxLeanDegrees)) else Vector3.zero
	local hipYaw = yaw * cfg.HipTurnFraction
	local lower = r15Lower(rig, shift, hipYaw)
	local upper = r15Upper(rig, lower, yaw - hipYaw, lean)
	-- part = Part0 * C0 * T * C1:Inverse()  =>  T = (Part0 * C0):Inverse() * part * C1
	transforms.root = (rig.root * rig.rootJoint.c0):Inverse() * lower * rig.rootJoint.c1
	transforms.waist = (lower * rig.waist.c0):Inverse() * upper * rig.waist.c1

	-- Legs: feet stay level where the body's horizontal position puts them;
	-- the crouch bends the knees and the hip turn twists the legs.
	if #rig.legs == 2 then
		local home = r15Lower(rig, Vector3.zero, 0)
		local forward = geometry.batterCFrame.LookVector
		for i, leg in rig.legs do
			local foot = home * leg.shoulderC0 * leg.shoulderC1:Inverse() * leg.elbowC0 * leg.elbowC1:Inverse() * leg.wristC0 * leg.wristC1:Inverse()
			local footTarget = foot.Position + Vector3.new(shift.X, 0, shift.Z)
			-- Aim the solver at the ankle joint, so the level foot lands on the target.
			local ankleTarget = footTarget + foot.Rotation * leg.wristC1.Position
			local solverRig = table.clone(leg)
			solverRig.wristC1 = CFrame.identity
			local solution = ArmIK.solve(lower, solverRig, ankleTarget, forward)
			local roles = LEG_ROLES.R15[i]
			transforms[roles[1]] = solution.shoulder
			transforms[roles[2]] = solution.elbow
			transforms[roles[3]] = ArmIK.endTransform(lower, leg, solution, foot)
		end
	end

	-- Arms: both hands on the handle.
	local hands = {}
	local gap = 0
	if cfg.ArmIK then
		local chestForward = upper.LookVector
		local middle = (ArmIK.shoulderPosition(upper, rig.arms[1]) + ArmIK.shoulderPosition(upper, rig.arms[2])) / 2
		for i, arm in rig.arms do
			local shoulder = ArmIK.shoulderPosition(upper, arm)
			-- Elbows hang down and a little away from the chest.
			local outward = shoulder - middle
			outward = outward - UP * outward:Dot(UP)
			local pole = -UP + (if outward.Magnitude > 1e-4 then outward.Unit else Vector3.zero) * cfg.ElbowOutward - chestForward * 0.2
			local shoulderT, elbowT, wristT, hand = solveR15Arm(upper, arm, grips[i], pole, pose.direction)
			local roles = ARM_ROLES.R15[i]
			transforms[roles[1]] = shoulderT
			transforms[roles[2]] = elbowT
			transforms[roles[3]] = wristT
			hands[i] = hand
			gap = math.max(gap, (hand - grips[i]).Magnitude)
		end
	end
	return { transforms = transforms, hands = hands, grips = grips, gap = gap, torsoYaw = yaw, lean = lean.Magnitude }
end

-- R6 --------------------------------------------------------------------------

local function solveR6(geometry: LaneGeometry.Geometry, rig: R6Rig, pose: SwingModel.Pose, shift: Vector3): Result
	local cfg = BattingConfig.Stance
	local transforms: { [string]: CFrame } = {}
	local grips = gripsFor(geometry, rig, shift, pose)

	-- Torso: turn to the hands and lean toward the grips, all through RootJoint.
	local openSign = CharacterPose.openSign(geometry)
	local yaw = math.min(CharacterPose.torsoYaw(geometry, rig, shift, grips) * openSign, math.rad(cfg.R6MaxTorsoOpenDegrees)) * openSign
	local reach = CharacterPose.armLength(rig) * cfg.LeanReachFraction
	-- Bowing about the hip line keeps both hip joints (and the rigid legs) in
	-- place; a sideways lean lifts one hip, so it is limited.
	local hipLine = CFrame.fromAxisAngle(UP, yaw):VectorToWorldSpace(r6Home(rig).RightVector)
	local lean = if cfg.ArmIK
		then solveLean(
			rig,
			shift,
			yaw,
			grips,
			reach,
			math.rad(cfg.R6MaxLeanDegrees),
			hipLine.Unit,
			math.rad(cfg.R6MaxSideLeanDegrees)
		)
		else Vector3.zero
	local torso = r6Torso(rig, shift, yaw, lean)
	-- A sideways lean lifts one hip; if that puts it beyond leg length, sink
	-- the body just enough to keep that foot on the ground.
	local float = 0
	for _, leg in rig.legs do
		local homeFoot = (r6Home(rig) * leg.joint.c0 * leg.joint.c1:Inverse()) * leg.tip
		local hip = (torso * leg.joint.c0).Position
		float = math.max(float, hip.Y - homeFoot.Y - (leg.joint.c1:Inverse() * leg.tip).Magnitude)
	end
	if float > 0 then
		torso = CFrame.new(0, -float, 0) * torso
	end
	transforms.root = (rig.root * rig.rootJoint.c0):Inverse() * torso * rig.rootJoint.c1

	-- Legs: a batting stance. Each rigid leg keeps its standing orientation
	-- (undoing the torso's turn and lean), then is aimed at a foot point ON
	-- the ground, exactly a leg's length from the hip, in the direction of its
	-- planted spot (splayed out along the stride line, moved with the body's
	-- slide). The feet never float or sink, and when the hips turn the foot
	-- pivots near its spot instead of travelling with the hip.
	if #rig.legs == 2 then
		local home = r6Home(rig)
		local slide = Vector3.new(shift.X, 0, shift.Z)
		for i, leg in rig.legs do
			local homeJoint = home * leg.joint.c0
			local ground = ((homeJoint * leg.joint.c1:Inverse()) * leg.tip).Y
			local length = (leg.joint.c1:Inverse() * leg.tip).Magnitude
			local outward = homeJoint.Position - home.Position
			outward = Vector3.new(outward.X, 0, outward.Z)
			outward = if outward.Magnitude > 1e-4 then outward.Unit else Vector3.zero
			local standHeight = homeJoint.Position.Y - ground
			local planted = Vector3.new(homeJoint.Position.X, ground, homeJoint.Position.Z)
				+ slide
				+ outward * math.sqrt(math.max(length * length - standHeight * standHeight, 0))
			local jointFrame = torso * leg.joint.c0
			local hip = jointFrame.Position
			local hipGround = Vector3.new(hip.X, ground, hip.Z)
			local height = hip.Y - ground
			local reachFlat = math.sqrt(math.max(length * length - height * height, 0))
			-- The outward bias keeps the direction defined (turning hips only move inward).
			local toPlanted = planted - hipGround + outward * 0.25
			local foot = hipGround + (if toPlanted.Magnitude > 1e-4 then toPlanted.Unit else outward) * reachFlat
			local standing = jointFrame.Rotation:Inverse() * homeJoint.Rotation
			local transform = ArmIK.aimRigid(jointFrame, leg.joint.c1, leg.tip, standing, foot)
			transforms[LEG_ROLES.R6[i][1]] = transform
		end
	end

	-- Arms: point each rigid arm's hand at its grip. A rigid arm can't
	-- shorten, so when the grip is closer than the arm is long the handle
	-- crosses the forearm instead of the hand; the error is therefore the
	-- grip's distance from the hand end of the arm (R6HandRegion of it).
	local hands = {}
	local gap = 0
	if cfg.ArmIK then
		for i, arm in rig.arms do
			local jointFrame = torso * arm.joint.c0
			-- A grip closer than the straight arm slides down the handle toward
			-- the knob (never past it) to where the arm fits. The handle meets
			-- the arm's reach at s1 (knob side) and s2; the slide fades out as
			-- the grip nears s2 so it is continuous at both ends.
			local shoulderPoint = jointFrame.Position
			local length = (arm.joint.c1:Inverse() * arm.tip).Magnitude
			if (grips[i] - shoulderPoint).Magnitude < length then
				local fromKnob = pose.knob - shoulderPoint
				local along = (grips[i] - pose.knob):Dot(pose.direction)
				local b = fromKnob:Dot(pose.direction)
				local root = math.sqrt(math.max(b * b - (fromKnob:Dot(fromKnob) - length * length), 0))
				local s1, s2 = -b - root, -b + root
				local weight = if s2 - s1 > 1e-6 then math.clamp(2 * (s2 - along) / (s2 - s1), 0, 1) else 0
				local slid = math.max(along + (s1 - along) * weight, 0)
				grips[i] = pose.knob + pose.direction * math.min(slid, along)
			end
			-- Aim from a reference pointing forward-down from the chest, not from
			-- the hanging arm: the least rotation from "hanging" flips when the
			-- hands pass overhead in the follow-through; from forward-down it
			-- only flips behind the back, where the hands never go.
			local toTip = arm.joint.c1:Inverse() * arm.tip
			local reference = jointFrame:VectorToObjectSpace((torso.LookVector - torso.UpVector).Unit)
			local base = ArmIK.rotationBetween(toTip.Unit, reference)
			local transform, hand = ArmIK.aimRigid(jointFrame, arm.joint.c1, arm.tip, base, grips[i])
			transforms[ARM_ROLES.R6[i][1]] = transform
			hands[i] = hand
			local shoulder = jointFrame.Position
			local regionStart = hand:Lerp(shoulder, cfg.R6HandRegion)
			local along = hand - regionStart
			local u = if along.Magnitude > 1e-6 then math.clamp((grips[i] - regionStart):Dot(along) / along:Dot(along), 0, 1) else 1
			gap = math.max(gap, (regionStart + along * u - grips[i]).Magnitude)
		end
	end
	return { transforms = transforms, hands = hands, grips = grips, gap = gap, torsoYaw = yaw, lean = lean.Magnitude }
end

-- The whole body for one bat pose. `shift` is the (smoothed) body offset.
function CharacterPose.solve(geometry: LaneGeometry.Geometry, rig: Rig, pose: SwingModel.Pose, shift: Vector3): Result
	if rig.kind == "R15" then
		return solveR15(geometry, rig, pose, shift)
	end
	return solveR6(geometry, rig, pose, shift)
end

-- Forward kinematics -----------------------------------------------------------

local function r15TorsoFor(rig: R15Rig, transforms: { [string]: CFrame }): (CFrame, CFrame)
	local lower = rig.root * rig.rootJoint.c0 * (transforms.root or CFrame.identity) * rig.rootJoint.c1:Inverse()
	return lower, lower * rig.waist.c0 * (transforms.waist or CFrame.identity) * rig.waist.c1:Inverse()
end

local function r6TorsoFor(rig: R6Rig, transforms: { [string]: CFrame }): CFrame
	return rig.root * rig.rootJoint.c0 * (transforms.root or CFrame.identity) * rig.rootJoint.c1:Inverse()
end

-- World positions of the hand points for a set of Transforms (tests use it to
-- check the Transforms themselves, not just the solver's own numbers).
function CharacterPose.handsFor(rig: Rig, transforms: { [string]: CFrame }): { Vector3 }
	local hands = {}
	if rig.kind == "R15" then
		local _, upper = r15TorsoFor(rig, transforms)
		for i, arm in rig.arms do
			local roles = ARM_ROLES.R15[i]
			local upperArm = upper * arm.shoulderC0 * (transforms[roles[1]] or CFrame.identity) * arm.shoulderC1:Inverse()
			local lowerArm = upperArm * arm.elbowC0 * (transforms[roles[2]] or CFrame.identity) * arm.elbowC1:Inverse()
			hands[i] = (lowerArm * arm.wristC0 * (transforms[roles[3]] or CFrame.identity) * arm.wristC1:Inverse()).Position
		end
	else
		local torso = r6TorsoFor(rig, transforms)
		for i, arm in rig.arms do
			local part = torso * arm.joint.c0 * (transforms[ARM_ROLES.R6[i][1]] or CFrame.identity) * arm.joint.c1:Inverse()
			hands[i] = part * arm.tip
		end
	end
	return hands
end

-- World position of each foot point (R15: foot part center) for a set of Transforms.
function CharacterPose.feetFor(rig: Rig, transforms: { [string]: CFrame }): { Vector3 }
	local feet = {}
	if rig.kind == "R15" then
		local lower = r15TorsoFor(rig, transforms)
		for i, leg in rig.legs do
			local roles = LEG_ROLES.R15[i]
			local upperLeg = lower * leg.shoulderC0 * (transforms[roles[1]] or CFrame.identity) * leg.shoulderC1:Inverse()
			local lowerLeg = upperLeg * leg.elbowC0 * (transforms[roles[2]] or CFrame.identity) * leg.elbowC1:Inverse()
			feet[i] = (lowerLeg * leg.wristC0 * (transforms[roles[3]] or CFrame.identity) * leg.wristC1:Inverse()).Position
		end
	else
		local torso = r6TorsoFor(rig, transforms)
		for i, leg in rig.legs do
			local part = torso * leg.joint.c0 * (transforms[LEG_ROLES.R6[i][1]] or CFrame.identity) * leg.joint.c1:Inverse()
			feet[i] = part * leg.tip
		end
	end
	return feet
end

-- Chest frame (R15 upper torso, R6 torso) for a set of Transforms.
function CharacterPose.chestFor(rig: Rig, transforms: { [string]: CFrame }): CFrame
	if rig.kind == "R15" then
		local _, upper = r15TorsoFor(rig, transforms)
		return upper
	end
	return r6TorsoFor(rig, transforms)
end

return CharacterPose
