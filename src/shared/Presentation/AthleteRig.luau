--!strict
-- Skeleton and pose solver for the procedural athletes (pitcher, catcher).
-- Pure: no Instances, so the whole body can be verified outside Roblox.
--
-- The rig uses the R15 part names and joint layout (LowerTorso root, Waist,
-- Neck, Shoulder/Elbow/Wrist, Hip/Knee/Ankle). Each joint is described the
-- way a Motor6D is: Part1 = Part0 * C0 * Transform * C1:Inverse(). Proportions
-- are athletic (human-like legs, ~1.88 m tall) instead of the default R15
-- avatar's short legs, which cannot make a real pitching stride.
--
-- A pose is: the pelvis (LowerTorso) world CFrame, chest and head world
-- rotations, and a world target + pole for each limb. Limbs are solved with
-- the existing two-bone ArmIK (shared with the batter), so hands and feet land
-- exactly where the animation puts them (feet stay planted, the throwing hand
-- reaches the authoritative release point).

local ArmIK = require(script.Parent.Parent.Batting.ArmIK)

local AthleteRig = {}

-- Authoring reference: numbers below are studs at 0.28 m/stud (converted to
-- meters once, then to the lane's studs at build time).
local REF = 0.28

export type PartDef = {
	name: string,
	size: Vector3, -- studs
	parent: string?,
	c0: CFrame, -- joint frame in the parent part
	c1: CFrame, -- joint frame in this part
}

export type Skeleton = {
	parts: { [string]: PartDef },
	order: { string }, -- parents before children
	gripDistance: number, -- wrist -> held ball / glove pocket along the hand, studs
	ankleHeight: number, -- ankle joint above the sole when the foot is flat, studs
	pelvisHeight: number, -- LowerTorso center above the ground standing straight, studs
	chestAbovePelvis: number, -- UpperTorso center above LowerTorso center, studs
	studsPerMeter: number,
}

type RefPart = { size: Vector3, parent: string?, c0: Vector3?, c1: Vector3? }

local REF_PARTS: { [string]: RefPart } = {
	LowerTorso = { size = Vector3.new(1.35, 0.7, 0.8) },
	UpperTorso = {
		size = Vector3.new(1.75, 1.75, 0.9),
		parent = "LowerTorso",
		c0 = Vector3.new(0, 0.35, 0),
		c1 = Vector3.new(0, -0.85, 0),
	},
	Head = { size = Vector3.new(0.95, 1, 0.95), parent = "UpperTorso", c0 = Vector3.new(0, 0.87, 0), c1 = Vector3.new(0, -0.58, 0) },
	RightUpperArm = {
		size = Vector3.new(0.52, 1.3, 0.52),
		parent = "UpperTorso",
		c0 = Vector3.new(1, 0.62, 0),
		c1 = Vector3.new(0, 0.48, 0),
	},
	RightLowerArm = {
		size = Vector3.new(0.46, 1.12, 0.46),
		parent = "RightUpperArm",
		c0 = Vector3.new(0, -0.62, 0),
		c1 = Vector3.new(0, 0.5, 0),
	},
	RightHand = {
		size = Vector3.new(0.44, 0.5, 0.26),
		parent = "RightLowerArm",
		c0 = Vector3.new(0, -0.46, 0),
		c1 = Vector3.new(0, 0.2, 0),
	},
	RightUpperLeg = {
		size = Vector3.new(0.68, 1.62, 0.68),
		parent = "LowerTorso",
		c0 = Vector3.new(0.34, -0.22, 0),
		c1 = Vector3.new(0, 0.72, 0),
	},
	RightLowerLeg = {
		size = Vector3.new(0.56, 1.72, 0.56),
		parent = "RightUpperLeg",
		c0 = Vector3.new(0, -0.72, 0),
		c1 = Vector3.new(0, 0.78, 0),
	},
	RightFoot = {
		size = Vector3.new(0.56, 0.32, 1.05),
		parent = "RightLowerLeg",
		c0 = Vector3.new(0, -0.8, 0),
		c1 = Vector3.new(0, 0.16, 0.24), -- ankle sits behind the foot's center (+Z is back)
	},
}
-- Left side mirrors the right.
for _, limb in { "UpperArm", "LowerArm", "Hand", "UpperLeg", "LowerLeg", "Foot" } do
	local right = REF_PARTS["Right" .. limb]
	local parent = right.parent :: string
	local c0 = right.c0 :: Vector3
	REF_PARTS["Left" .. limb] = {
		size = right.size,
		parent = if string.sub(parent, 1, 5) == "Right" then "Left" .. string.sub(parent, 6) else parent,
		c0 = Vector3.new(-c0.X, c0.Y, c0.Z),
		c1 = right.c1,
	}
end

local REF_GRIP = 0.36 -- wrist -> ball held in the fingers
local REF_ANKLE = 0.32

AthleteRig.PART_ORDER = {
	"LowerTorso",
	"UpperTorso",
	"Head",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
}

local cache: { [string]: Skeleton } = {}

-- The rig in studs for a lane's unit scale, times `scale` (1 = ~1.88 m tall).
function AthleteRig.skeleton(metersPerStud: number, scale: number): Skeleton
	local key = string.format("%.6f/%.4f", metersPerStud, scale)
	local existing = cache[key]
	if existing then
		return existing
	end
	local k = REF / metersPerStud * scale
	local parts: { [string]: PartDef } = {}
	for name, ref in REF_PARTS do
		parts[name] = {
			name = name,
			size = ref.size * k,
			parent = ref.parent,
			c0 = CFrame.new((ref.c0 or Vector3.zero) * k),
			c1 = CFrame.new((ref.c1 or Vector3.zero) * k),
		}
	end
	local legLength = (REF_PARTS.RightUpperLeg.c1 :: Vector3).Y
		- (REF_PARTS.RightLowerLeg.c0 :: Vector3).Y
		+ (REF_PARTS.RightLowerLeg.c1 :: Vector3).Y
		- (REF_PARTS.RightFoot.c0 :: Vector3).Y
	local skeleton: Skeleton = {
		parts = parts,
		order = AthleteRig.PART_ORDER,
		gripDistance = REF_GRIP * k,
		ankleHeight = REF_ANKLE * k,
		pelvisHeight = (REF_ANKLE + legLength - (REF_PARTS.RightUpperLeg.c0 :: Vector3).Y) * k,
		chestAbovePelvis = ((REF_PARTS.UpperTorso.c0 :: Vector3).Y - (REF_PARTS.UpperTorso.c1 :: Vector3).Y) * k,
		studsPerMeter = 1 / metersPerStud,
	}
	cache[key] = skeleton
	return skeleton
end

---------------------------------------------------------------------------
-- Orientation helper
---------------------------------------------------------------------------

export type Frame = {
	rotation: CFrame,
	facing: Vector3, -- body forward (LookVector)
	up: Vector3,
	arm: Vector3, -- toward the throwing-arm side (mirror-aware)
}

-- Turns a base frame by yaw (toward the arm side), then pitches forward
-- (top toward `facing`) and rolls toward the glove side. Degrees. Built from
-- vectors so a left-handed thrower (arm side = lane right) mirrors cleanly;
-- the resulting rotation is always proper (anatomical right = facing x up).
function AthleteRig.orient(facing: Vector3, arm: Vector3, up: Vector3, yaw: number, pitch: number, roll: number): Frame
	local y, p, r = math.rad(yaw), math.rad(pitch), math.rad(roll)
	local f0 = facing * math.cos(y) + arm * math.sin(y)
	local a0 = arm * math.cos(y) - facing * math.sin(y)
	local u1 = up * math.cos(p) + f0 * math.sin(p)
	local f1 = f0 * math.cos(p) - up * math.sin(p)
	local u2 = u1 * math.cos(r) - a0 * math.sin(r)
	local a2 = a0 * math.cos(r) + u1 * math.sin(r)
	local right = f1:Cross(u2)
	return {
		rotation = CFrame.fromMatrix(Vector3.zero, right, u2),
		facing = f1,
		up = u2,
		arm = a2,
	}
end

---------------------------------------------------------------------------
-- Solve
---------------------------------------------------------------------------

export type Limb = {
	target: Vector3, -- arms: grip point (gripDistance past the wrist); legs: ankle joint
	pole: Vector3, -- direction the elbow / knee bends toward
	rotation: CFrame?, -- optional end-part (hand/foot) world rotation
}

export type Pose = {
	pelvis: CFrame, -- LowerTorso world CFrame
	chest: CFrame, -- UpperTorso world rotation
	head: CFrame, -- Head world rotation
	rightArm: Limb,
	leftArm: Limb,
	rightLeg: Limb,
	leftLeg: Limb,
}

export type Solved = {
	cframes: { [string]: CFrame },
	grips: { Right: Vector3, Left: Vector3 },
	reached: { [string]: boolean },
}

local function ikRig(skeleton: Skeleton, side: string, upper: string, lower: string, finish: string, offset: number): ArmIK.ArmRig
	local p = skeleton.parts
	return {
		shoulderC0 = p[side .. upper].c0,
		shoulderC1 = p[side .. upper].c1,
		elbowC0 = p[side .. lower].c0,
		elbowC1 = p[side .. lower].c1,
		wristC0 = p[side .. finish].c0,
		-- ArmIK reaches the point `offset` past the last joint along the limb.
		wristC1 = CFrame.new(0, offset, 0),
	}
end

local function solveLimb(
	out: { [string]: CFrame },
	skeleton: Skeleton,
	root: CFrame,
	side: string,
	isArm: boolean,
	limb: Limb
): (Vector3, boolean)
	local upper, lower, finish = if isArm then "UpperArm" else "UpperLeg", if isArm then "LowerArm" else "LowerLeg", if isArm
		then "Hand"
		else "Foot"
	local offset = if isArm then skeleton.gripDistance else 0
	local rig = ikRig(skeleton, side, upper, lower, finish, offset)
	local solution = ArmIK.solve(root, rig, limb.target, limb.pole)
	local p = skeleton.parts
	local upperCF = root * rig.shoulderC0 * solution.shoulder * rig.shoulderC1:Inverse()
	local lowerCF = upperCF * rig.elbowC0 * solution.elbow * rig.elbowC1:Inverse()
	local joint = lowerCF * rig.wristC0
	local c1 = p[side .. finish].c1
	local endCF = if limb.rotation
		then CFrame.new(joint.Position) * limb.rotation * c1:Inverse()
		else joint * c1:Inverse()
	out[side .. upper] = upperCF
	out[side .. lower] = lowerCF
	out[side .. finish] = endCF
	local along = joint.Position - (upperCF * rig.elbowC0).Position
	local tip = joint.Position + (if along.Magnitude > 1e-6 then along.Unit else Vector3.yAxis) * offset
	return tip, solution.reachable
end

function AthleteRig.solve(skeleton: Skeleton, pose: Pose): Solved
	local p = skeleton.parts
	local out: { [string]: CFrame } = {}
	local pelvis = pose.pelvis
	out.LowerTorso = pelvis
	local waist = (pelvis * p.UpperTorso.c0).Position
	local chest = CFrame.new(waist) * pose.chest.Rotation * p.UpperTorso.c1:Inverse()
	out.UpperTorso = chest
	local neck = (chest * p.Head.c0).Position
	out.Head = CFrame.new(neck) * pose.head.Rotation * p.Head.c1:Inverse()

	local reached = {}
	local rightGrip, leftGrip
	rightGrip, reached.RightArm = solveLimb(out, skeleton, chest, "Right", true, pose.rightArm)
	leftGrip, reached.LeftArm = solveLimb(out, skeleton, chest, "Left", true, pose.leftArm)
	reached.RightLeg = select(2, solveLimb(out, skeleton, pelvis, "Right", false, pose.rightLeg))
	reached.LeftLeg = select(2, solveLimb(out, skeleton, pelvis, "Left", false, pose.leftLeg))
	return { cframes = out, grips = { Right = rightGrip, Left = leftGrip }, reached = reached }
end

-- Lowest point of a foot box relative to its ankle joint, along `up`, for a
-- given foot rotation (so a heel-up / toe-down foot is lifted onto its toe).
function AthleteRig.footClearance(skeleton: Skeleton, rotation: CFrame, up: Vector3): number
	local foot = skeleton.parts.RightFoot
	local frame = rotation * foot.c1:Inverse()
	local h = foot.size / 2
	local lowest = math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				lowest = math.min(lowest, (frame * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)):Dot(up))
			end
		end
	end
	return -lowest
end

return AthleteRig
