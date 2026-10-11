--!strict
-- Makes the local R15 character swing the bat (client-side, cosmetic only).
--
-- Every frame, from the bat pose that BatStance already decided:
--   * the body slides toward the swing pivot and crouches when the pivot is low
--     (BodyFit), implemented as a Transform on the Root joint so the anchored
--     HumanoidRootPart is never touched
--   * the waist turns with the swing (BatStance.torsoYaw)
--   * both arms are solved with two-bone IK onto the handle (ArmIK)
--   * legs are solved onto their planted feet, so a crouch bends the knees
--
-- Why this is robust against the things that go wrong in Studio:
--   * It writes Motor6D.Transform every frame, so the default Animate script
--     and Animator are silenced while batting (Stance.SuppressAnimations);
--     otherwise they rewrite those Transforms and the arms never move.
--   * Torso and limb frames are computed from HumanoidRootPart plus the joint
--     C0/C1 values read this frame (not cached part CFrames), so avatar
--     scaling and a one-frame lag cannot misplace the hands.
--   * Binding retries until the rig is fully assembled, instead of giving up
--     the first time a part is missing.
-- Unsupported rigs (R6, missing joints) fall back to the bat-only stance.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local LaneGeometry = require(Shared:WaitForChild("Pitching"):WaitForChild("LaneGeometry"))
local ArmIK = require(Shared:WaitForChild("Batting"):WaitForChild("ArmIK"))
local BatStance = require(Shared.Batting.BatStance)
local BattingConfig = require(Shared.Batting.BattingConfig)
local BodyFit = require(Shared.Batting.BodyFit)
local SwingModel = require(Shared.Batting.SwingModel)

local CharacterGrip = {}

local UP = Vector3.new(0, 1, 0)
local RETRY_SECONDS = 0.4

type Limb = { first: Motor6D, second: Motor6D, third: Motor6D }

type Rig = {
	character: Model,
	root: BasePart,
	rootJoint: Motor6D,
	waist: Motor6D,
	arms: { Limb },
	legs: { Limb },
	animate: LocalScript?,
	animateWasEnabled: boolean,
	animatorConnection: RBXScriptConnection?,
}

local rig: Rig? = nil
local boundCharacter: Model? = nil
local lastTry = -math.huge
local bodyShift = Vector3.zero
local status = "no character"
local lastGap = 0
local lastCrouch = 0

local function findMotor(character: Model, name: string): Motor6D?
	local found = character:FindFirstChild(name, true)
	if found and found:IsA("Motor6D") and found.Part0 and found.Part1 then
		return found
	end
	return nil
end

local function findLimb(character: Model, side: string, names: { string }): Limb?
	local first = findMotor(character, side .. names[1])
	local second = findMotor(character, side .. names[2])
	local third = findMotor(character, side .. names[3])
	if first and second and third then
		return { first = first, second = second, third = third }
	end
	return nil
end

-- Joint offsets read fresh (avatar scale can change after the character loads).
local function readRig(limb: Limb): ArmIK.ArmRig
	return {
		shoulderC0 = limb.first.C0,
		shoulderC1 = limb.first.C1,
		elbowC0 = limb.second.C0,
		elbowC1 = limb.second.C1,
		wristC0 = limb.third.C0,
		wristC1 = limb.third.C1,
	}
end

local function suppressAnimations(state: Rig)
	local animate = state.character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		state.animate = animate
		state.animateWasEnabled = animate.Enabled
		animate.Enabled = false
	end
	local humanoid = state.character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
		state.animatorConnection = animator.AnimationPlayed:Connect(function(track)
			track:Stop(0)
		end)
	end
end

local function resetTransforms(state: Rig)
	state.rootJoint.Transform = CFrame.identity
	state.waist.Transform = CFrame.identity
	for _, limb in state.arms do
		limb.first.Transform = CFrame.identity
		limb.second.Transform = CFrame.identity
		limb.third.Transform = CFrame.identity
	end
	for _, limb in state.legs do
		limb.first.Transform = CFrame.identity
		limb.second.Transform = CFrame.identity
		limb.third.Transform = CFrame.identity
	end
end

-- Hands the character back to the animation system.
function CharacterGrip.release()
	local state = rig
	if not state then
		return
	end
	resetTransforms(state)
	if state.animatorConnection then
		state.animatorConnection:Disconnect()
		state.animatorConnection = nil
	end
	if state.animate then
		state.animate.Enabled = state.animateWasEnabled
		state.animate = nil
	end
	rig = nil
	bodyShift = Vector3.zero
end

-- Finds the joints on the character. Returns false (and keeps retrying from
-- ensureBound) until the R15 rig is complete.
function CharacterGrip.bind(character: Model?): boolean
	CharacterGrip.release()
	boundCharacter = character
	lastTry = os.clock()
	if not character then
		status = "no character"
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local rootJoint = findMotor(character, "Root")
	local waist = findMotor(character, "Waist")
	local leftArm = findLimb(character, "Left", { "Shoulder", "Elbow", "Wrist" })
	local rightArm = findLimb(character, "Right", { "Shoulder", "Elbow", "Wrist" })
	if not (root and root:IsA("BasePart") and rootJoint and waist and leftArm and rightArm) then
		status = "waiting for an R15 rig (unsupported rigs keep the bat-only stance)"
		return false
	end
	local legs: { Limb } = {}
	if BattingConfig.Stance.Legs then
		local leftLeg = findLimb(character, "Left", { "Hip", "Knee", "Ankle" })
		local rightLeg = findLimb(character, "Right", { "Hip", "Knee", "Ankle" })
		if leftLeg and rightLeg then
			legs = { leftLeg, rightLeg }
		end
	end
	local state: Rig = {
		character = character,
		root = root,
		rootJoint = rootJoint,
		waist = waist,
		arms = { leftArm, rightArm },
		legs = legs,
		animate = nil,
		animateWasEnabled = true,
		animatorConnection = nil,
	}
	if BattingConfig.Stance.SuppressAnimations then
		suppressAnimations(state)
	end
	rig = state
	status = "bound"
	return true
end

-- Call every frame: rebinds when the character changes, and retries while the
-- rig is still being assembled.
function CharacterGrip.ensureBound(character: Model?)
	if character ~= boundCharacter or (rig == nil and character ~= nil and os.clock() - lastTry > RETRY_SECONDS) then
		CharacterGrip.bind(character)
	end
end

function CharacterGrip.isBound(): boolean
	return rig ~= nil
end

-- Body frames --------------------------------------------------------------

local function lowerTorsoFrame(state: Rig, shift: Vector3): CFrame
	local joint = state.root.CFrame * state.rootJoint.C0
	return joint * CFrame.new(joint:VectorToObjectSpace(shift)) * state.rootJoint.C1:Inverse()
end

-- Waist Transform that turns the upper body `yaw` radians about world up.
local function waistTransform(state: Rig, lower: CFrame, yaw: number): CFrame
	local joint = lower * state.waist.C0
	return CFrame.fromAxisAngle(joint:VectorToObjectSpace(UP), yaw)
end

local function upperTorsoFrame(state: Rig, lower: CFrame, waistT: CFrame): CFrame
	return lower * state.waist.C0 * waistT * state.waist.C1:Inverse()
end

local function shoulderMidpoint(state: Rig, upper: CFrame): Vector3
	local a = ArmIK.shoulderPosition(upper, readRig(state.arms[1]))
	local b = ArmIK.shoulderPosition(upper, readRig(state.arms[2]))
	return (a + b) / 2
end

local function armLength(state: Rig): number
	local total = 0
	for _, arm in state.arms do
		local upper, lower, hand = ArmIK.lengths(readRig(arm))
		total += upper + lower + hand
	end
	return total / #state.arms
end

-- Moves the body toward the position that lets the hands reach the swing pivot.
function CharacterGrip.step(geometry: LaneGeometry.Geometry, pivot: Vector3, dt: number)
	local state = rig
	if not state then
		return
	end
	local home = lowerTorsoFrame(state, Vector3.zero)
	local upper = upperTorsoFrame(state, home, CFrame.identity)
	local dims = SwingModel.dimensions(geometry)
	local gripRadius = dims.pivotRadius + geometry.units.toStuds(BattingConfig.Stance.GripTopMeters)
	local target = BodyFit.target(geometry, shoulderMidpoint(state, upper), pivot, armLength(state), gripRadius)
	local tau = BattingConfig.Stance.BodyFollowSeconds
	local alpha = if tau <= 0 then 1 else 1 - math.exp(-math.max(dt, 0) / tau)
	bodyShift = bodyShift:Lerp(target, alpha)
end

-- Where the hands rest: in front of the chest, a little toward the rear
-- shoulder, for the body as it currently stands. nil without a rig.
function CharacterGrip.getAnchor(geometry: LaneGeometry.Geometry): Vector3?
	local state = rig
	if not state then
		return nil
	end
	local cfg = BattingConfig.Stance
	local lower = lowerTorsoFrame(state, bodyShift)
	local upper = upperTorsoFrame(state, lower, CFrame.identity)
	local reach = armLength(state)
	return shoulderMidpoint(state, upper)
		- geometry.up * (cfg.AnchorDownFraction * reach)
		+ geometry.batterCFrame.LookVector * (cfg.AnchorForwardFraction * reach)
		- geometry.toPitcher * (cfg.AnchorRearFraction * reach)
end

-- Poses the whole character for a bat pose: body offset, waist, both arms on
-- the handle, legs planted. The rear arm (farther from the pitcher) is the
-- top hand, as for a real batter.
function CharacterGrip.apply(geometry: LaneGeometry.Geometry, pose: SwingModel.Pose)
	local state = rig
	if not state then
		return
	end
	local cfg = BattingConfig.Stance
	local forward = geometry.batterCFrame.LookVector

	-- Body: root offset and waist turn.
	local rootFrame = state.root.CFrame * state.rootJoint.C0
	state.rootJoint.Transform = CFrame.new(rootFrame:VectorToObjectSpace(bodyShift))
	local lower = lowerTorsoFrame(state, bodyShift)
	local waistT = waistTransform(state, lower, BatStance.torsoYaw(pose.angle))
	state.waist.Transform = waistT
	local upper = upperTorsoFrame(state, lower, waistT)
	lastCrouch = math.max(-bodyShift.Y, 0)

	-- Legs: feet stay where the body's horizontal position puts them; only the
	-- crouch bends the knees.
	if #state.legs == 2 then
		local home = lowerTorsoFrame(state, Vector3.zero)
		for _, leg in state.legs do
			local legRig = readRig(leg)
			local foot = home
				* legRig.shoulderC0
				* legRig.shoulderC1:Inverse()
				* legRig.elbowC0
				* legRig.elbowC1:Inverse()
				* legRig.wristC0
				* legRig.wristC1:Inverse()
			local footTarget = foot.Position + Vector3.new(bodyShift.X, 0, bodyShift.Z)
			-- Aim the solver at the ankle joint, so the level foot lands on the target.
			local ankleTarget = footTarget + foot.Rotation * legRig.wristC1.Position
			local solverRig = table.clone(legRig)
			solverRig.wristC1 = CFrame.identity
			local solution = ArmIK.solve(lower, solverRig, ankleTarget, forward)
			leg.first.Transform = solution.shoulder
			leg.second.Transform = solution.elbow
			leg.third.Transform = ArmIK.endTransform(lower, legRig, solution, foot)
		end
	end

	-- Arms: both hands on the handle.
	if not cfg.ArmIK then
		return
	end
	local bottomGrip, topGrip = BatStance.gripPoints(geometry, pose)
	local middle = shoulderMidpoint(state, upper)
	local worstGap = 0
	for _, arm in state.arms do
		local armRig = readRig(arm)
		local shoulder = ArmIK.shoulderPosition(upper, armRig)
		local isRear = (shoulder - middle):Dot(geometry.toPitcher) < 0
		local grip = if isRear then topGrip else bottomGrip
		-- Elbows hang down and a little away from the chest.
		local outward = shoulder - middle
		outward = outward - UP * outward:Dot(UP)
		local pole = -UP + (if outward.Magnitude > 1e-4 then outward.Unit else Vector3.zero) * cfg.ElbowOutward - forward * 0.2
		local solution = ArmIK.solve(upper, armRig, grip, pole)
		arm.first.Transform = solution.shoulder
		arm.second.Transform = solution.elbow
		arm.third.Transform = CFrame.identity
		local _, _, hand = ArmIK.forward(upper, armRig, solution)
		worstGap = math.max(worstGap, (hand - grip).Magnitude)
	end
	lastGap = worstGap
end

-- One-line status for the F7 overlay.
function CharacterGrip.describe(geometry: LaneGeometry.Geometry): string
	local state = rig
	if not state then
		return `grip: {status}`
	end
	local units = geometry.units
	return string.format(
		"grip: R15 bound | animations %s | body shift %.0f cm, crouch %.0f cm | hand-to-bat gap %.1f cm%s",
		if state.animate or state.animatorConnection then "suppressed" else "NOT suppressed",
		units.toMeters(Vector3.new(bodyShift.X, 0, bodyShift.Z).Magnitude) * 100,
		units.toMeters(lastCrouch) * 100,
		units.toMeters(lastGap) * 100,
		if #state.legs == 2 then "" else " | no legs"
	)
end

return CharacterGrip
