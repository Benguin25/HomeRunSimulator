--!strict
-- Puts the local character's hands on the bat (R15 only, client-side and
-- cosmetic). Reads the rig's Motor6D offsets, solves two-bone IK for both
-- arms (ArmIK) and writes the shoulder/elbow Transforms every frame, after
-- the animation step. The rest of the body keeps its normal idle animation.
--
-- It also reports where the hands should be at rest ("anchor"), so the bat
-- starts in the batter's hands. Without an R15 rig everything degrades to the
-- geometric fallback and the arms are simply left alone.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local LaneGeometry = require(Shared:WaitForChild("Pitching"):WaitForChild("LaneGeometry"))
local ArmIK = require(Shared:WaitForChild("Batting"):WaitForChild("ArmIK"))
local BatStance = require(Shared.Batting.BatStance)
local BattingConfig = require(Shared.Batting.BattingConfig)
local SwingModel = require(Shared.Batting.SwingModel)

local CharacterGrip = {}

type Arm = {
	torso: BasePart,
	shoulder: Motor6D,
	elbow: Motor6D,
	wrist: Motor6D,
	rig: ArmIK.ArmRig,
	armLength: number,
}

local arms: { Arm } = {}
local boundCharacter: Model? = nil

local function buildArm(character: Model, torso: BasePart, side: string): Arm?
	local shoulder = character:FindFirstChild(`{side}Shoulder`, true)
	local elbow = character:FindFirstChild(`{side}Elbow`, true)
	local wrist = character:FindFirstChild(`{side}Wrist`, true)
	if not (shoulder and shoulder:IsA("Motor6D") and elbow and elbow:IsA("Motor6D") and wrist and wrist:IsA("Motor6D")) then
		return nil
	end
	if shoulder.Part0 ~= torso then
		return nil
	end
	local rig: ArmIK.ArmRig = {
		shoulderC0 = shoulder.C0,
		shoulderC1 = shoulder.C1,
		elbowC0 = elbow.C0,
		elbowC1 = elbow.C1,
		wristC0 = wrist.C0,
		wristC1 = wrist.C1,
	}
	local upper, lower, hand = ArmIK.lengths(rig)
	return { torso = torso, shoulder = shoulder, elbow = elbow, wrist = wrist, rig = rig, armLength = upper + lower + hand }
end

-- Finds both arms on the character (call again when the character changes).
function CharacterGrip.bind(character: Model?)
	CharacterGrip.release()
	table.clear(arms)
	boundCharacter = character
	if not character then
		return
	end
	local torso = character:FindFirstChild("UpperTorso")
	if not (torso and torso:IsA("BasePart")) then
		return
	end
	for _, side in { "Left", "Right" } do
		local arm = buildArm(character, torso, side)
		if arm then
			table.insert(arms, arm)
		end
	end
	if #arms ~= 2 then
		table.clear(arms)
	end
end

function CharacterGrip.ensureBound(character: Model?)
	if character ~= boundCharacter then
		CharacterGrip.bind(character)
	end
end

function CharacterGrip.isBound(): boolean
	return #arms == 2
end

-- Where the hands rest: in front of the chest, a little toward the rear
-- shoulder. nil without a rig (the caller uses BatStance.fallbackAnchor).
function CharacterGrip.getAnchor(geometry: LaneGeometry.Geometry): Vector3?
	if #arms ~= 2 then
		return nil
	end
	local cfg = BattingConfig.Stance
	local middle = (ArmIK.shoulderPosition(arms[1].torso.CFrame, arms[1].rig) + ArmIK.shoulderPosition(arms[2].torso.CFrame, arms[2].rig)) / 2
	local reach = (arms[1].armLength + arms[2].armLength) / 2
	return middle
		- geometry.up * (cfg.AnchorDownFraction * reach)
		+ geometry.batterCFrame.LookVector * (cfg.AnchorForwardFraction * reach)
		- geometry.toPitcher * (cfg.AnchorRearFraction * reach)
end

-- Poses the arms so the bottom hand holds the handle near the knob and the
-- top hand a little higher. The rear arm (farther from the pitcher) is the
-- top hand, as for a real batter.
function CharacterGrip.apply(geometry: LaneGeometry.Geometry, pose: SwingModel.Pose)
	if #arms ~= 2 or not BattingConfig.Stance.ArmIK then
		return
	end
	local bottomGrip, topGrip = BatStance.gripPoints(geometry, pose)
	local middle = (ArmIK.shoulderPosition(arms[1].torso.CFrame, arms[1].rig) + ArmIK.shoulderPosition(arms[2].torso.CFrame, arms[2].rig)) / 2
	for _, arm in arms do
		local torso = arm.torso.CFrame
		local shoulder = ArmIK.shoulderPosition(torso, arm.rig)
		local isRear = (shoulder - middle):Dot(geometry.toPitcher) < 0
		-- Elbows hang down and a little away from the chest.
		local outward = shoulder - middle
		outward = outward - geometry.up * outward:Dot(geometry.up)
		local pole = -geometry.up + (if outward.Magnitude > 1e-4 then outward.Unit else Vector3.zero) * BattingConfig.Stance.ElbowOutward
		local solution = ArmIK.solve(torso, arm.rig, if isRear then topGrip else bottomGrip, pole)
		arm.shoulder.Transform = solution.shoulder
		arm.elbow.Transform = solution.elbow
		arm.wrist.Transform = CFrame.identity
	end
end

-- Hands the arms back to the animation system.
function CharacterGrip.release()
	for _, arm in arms do
		arm.shoulder.Transform = CFrame.identity
		arm.elbow.Transform = CFrame.identity
		arm.wrist.Transform = CFrame.identity
	end
end

return CharacterGrip
