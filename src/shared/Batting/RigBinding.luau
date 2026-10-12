--!strict
-- Finds the joints the procedural batting pose drives, for R15 AND R6
-- characters, and says exactly why when it cannot.
--
-- Two joint implementations are supported behind one small adapter:
--   * Motor6D: Part1 = Part0 * C0 * Transform * C1:Inverse()
--   * AnimationConstraint (Roblox's Avatar Joint Upgrade, now the default
--     R15 joint): it keeps Attachment1 offset from Attachment0 by Transform,
--     i.e. Part1 = Part0 * Attachment0.CFrame * Transform * Attachment1.CFrame:Inverse(),
--     the same chain with C0/C1 taken from the attachments and Part0/Part1
--     from the attachments' parents.
-- Both expose a writable `Transform`, which is what the Animator drives and
-- what the batting pose writes. Phase 2.7 accepted only Motor6Ds, so an
-- upgraded R15 avatar was rejected ("is a AnimationConstraint, not a
-- Motor6D") and only the bat moved.
--
-- Why this exists (Phase 2.7): the previous binding looked only for R15 joint
-- names ("Root", "Waist", "LeftShoulder", "LeftElbow", "LeftWrist", ...). An
-- R6 character has "RootJoint", "Left Shoulder" (with a space), "Neck" and the
-- hips, and no waist, elbow or wrist joints at all, so binding could never
-- succeed and the character stayed in the bat-only fallback forever.
--
-- The rig type comes from Humanoid.RigType, but the joints decide: if the
-- Humanoid claims one rig and the joints are the other, the joints win (and
-- the mismatch is reported).
--
-- Only uses Name / ClassName / IsA / Parent / GetDescendants / IsDescendantOf
-- and the joint fields, so tests can pass plain tables shaped like Instances.

local RigBinding = {}

export type RigKind = "R15" | "R6"

-- The joint class behind a role.
export type JointType = "Motor6D" | "AnimationConstraint"

-- Uniform view of one joint this frame.
export type JointFrame = {
	part0: any,
	part1: any,
	c0: CFrame, -- Part0 side offset (Motor6D.C0 / Attachment0.CFrame)
	c1: CFrame, -- Part1 side offset (Motor6D.C1 / Attachment1.CFrame)
}

export type JointSpec = {
	role: string, -- name used by CharacterPose
	name: string, -- joint name on the rig (Motor6D or AnimationConstraint)
	required: boolean,
}

export type Binding = {
	kind: RigKind,
	reportedRigType: string, -- Humanoid.RigType.Name, or "unknown"
	character: any,
	humanoid: any,
	root: any, -- HumanoidRootPart
	joints: { [string]: any }, -- role -> Motor6D or AnimationConstraint
	jointTypes: { [string]: number }, -- "Motor6D" / "AnimationConstraint" -> count
	missingOptional: { string }, -- "LeftKnee: not found", ...
	note: string?, -- set when Humanoid.RigType disagreed with the joints
}

export type Result = {
	ok: boolean,
	binding: Binding?,
	reportedRigType: string,
	triedKind: RigKind?, -- the rig whose problems are listed when binding failed
	problems: { string }, -- required joints that are missing or unusable
	reason: string, -- one line for the overlay and Output
}

local function spec(role: string, name: string, required: boolean): JointSpec
	return { role = role, name = name, required = required }
end

RigBinding.Specs = {
	R15 = {
		spec("root", "Root", true),
		spec("waist", "Waist", true),
		spec("leftShoulder", "LeftShoulder", true),
		spec("leftElbow", "LeftElbow", true),
		spec("leftWrist", "LeftWrist", true),
		spec("rightShoulder", "RightShoulder", true),
		spec("rightElbow", "RightElbow", true),
		spec("rightWrist", "RightWrist", true),
		spec("leftHip", "LeftHip", false),
		spec("leftKnee", "LeftKnee", false),
		spec("leftAnkle", "LeftAnkle", false),
		spec("rightHip", "RightHip", false),
		spec("rightKnee", "RightKnee", false),
		spec("rightAnkle", "RightAnkle", false),
	},
	-- R6 has no waist, elbows or wrists: the torso, both shoulders and the hips
	-- are all there is.
	R6 = {
		spec("root", "RootJoint", true),
		spec("leftShoulder", "Left Shoulder", true),
		spec("rightShoulder", "Right Shoulder", true),
		spec("leftHip", "Left Hip", false),
		spec("rightHip", "Right Hip", false),
	},
} :: { [string]: { JointSpec } }

local function rigTypeName(humanoid: any): string
	local ok, value = pcall(function()
		return humanoid.RigType
	end)
	if not ok or value == nil then
		return "unknown"
	end
	local nameOk, name = pcall(function()
		return value.Name
	end)
	if nameOk and type(name) == "string" then
		return name
	end
	return tostring(value)
end

local function findChildOfClass(parent: any, className: string): any?
	for _, child in parent:GetChildren() do
		if child:IsA(className) then
			return child
		end
	end
	return nil
end

function RigBinding.jointType(joint: any): JointType?
	if joint:IsA("Motor6D") then
		return "Motor6D"
	elseif joint:IsA("AnimationConstraint") then
		return "AnimationConstraint"
	end
	return nil
end

-- Why `candidate` can't drive the pose, or nil if it can.
local function jointProblem(candidate: any): string?
	local jointType = RigBinding.jointType(candidate)
	if jointType == "Motor6D" then
		if candidate.Part0 == nil then
			return "Part0 not set (rig still assembling?)"
		end
		if candidate.Part1 == nil then
			return "Part1 not set (rig still assembling?)"
		end
	elseif jointType == "AnimationConstraint" then
		for _, key in { "Attachment0", "Attachment1" } do
			local attachment = candidate[key]
			if attachment == nil then
				return `{key} not set (rig still assembling?)`
			end
			local parent = attachment.Parent
			if parent == nil or not parent:IsA("BasePart") then
				return `{key} is not on a BasePart`
			end
		end
	else
		return `is a {candidate.ClassName}, not a Motor6D or AnimationConstraint`
	end
	if candidate.Enabled == false then
		return "disabled"
	end
	return nil
end

-- Offsets and parts of a bound joint, read now (both joint types).
function RigBinding.frame(joint: any): JointFrame
	if RigBinding.jointType(joint) == "AnimationConstraint" then
		local a0, a1 = joint.Attachment0, joint.Attachment1
		return { part0 = a0.Parent, part1 = a1.Parent, c0 = a0.CFrame, c1 = a1.CFrame }
	end
	return { part0 = joint.Part0, part1 = joint.Part1, c0 = joint.C0, c1 = joint.C1 }
end

-- name -> every descendant with that name, in tree order.
local function indexByName(character: any, wanted: { [string]: boolean }): { [string]: { any } }
	local found: { [string]: { any } } = {}
	for _, descendant in character:GetDescendants() do
		local name = descendant.Name
		if wanted[name] then
			local list = found[name]
			if not list then
				list = {}
				found[name] = list
			end
			table.insert(list, descendant)
		end
	end
	return found
end

type Attempt = {
	joints: { [string]: any },
	problems: { string },
	missingOptional: { string },
}

local function attempt(kind: string, found: { [string]: { any } }): Attempt
	local result: Attempt = { joints = {}, problems = {}, missingOptional = {} }
	for _, jointSpec in RigBinding.Specs[kind] do
		local candidates = found[jointSpec.name]
		local chosen = nil
		local problem = "not found"
		if candidates then
			-- Take the first usable joint. Otherwise explain the first candidate
			-- that IS a joint class (a disabled or unattached joint matters more
			-- than a same-named value or ragdoll socket), else the first one.
			local explainedJoint = false
			for index, candidate in candidates do
				local why = jointProblem(candidate)
				if why == nil then
					chosen = candidate
					break
				end
				local isJoint = RigBinding.jointType(candidate) ~= nil
				if index == 1 or (isJoint and not explainedJoint) then
					problem = why
					explainedJoint = explainedJoint or isJoint
				end
			end
		end
		if chosen then
			result.joints[jointSpec.role] = chosen
		elseif jointSpec.required then
			table.insert(result.problems, `{jointSpec.name}: {problem}`)
		else
			table.insert(result.missingOptional, `{jointSpec.name}: {problem}`)
		end
	end
	return result
end

local function failure(reported: string, reason: string, kind: RigKind?, problems: { string }?): Result
	return {
		ok = false,
		binding = nil,
		reportedRigType = reported,
		triedKind = kind,
		problems = problems or {},
		reason = reason,
	}
end

-- Binds `character`. Never yields and never throws for odd hierarchies.
function RigBinding.bind(character: any): Result
	if character == nil then
		return failure("unknown", "no character")
	end
	local humanoid = findChildOfClass(character, "Humanoid")
	if not humanoid then
		return failure("unknown", "no Humanoid in the character (still loading?)")
	end
	local reported = rigTypeName(humanoid)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return failure(reported, "no HumanoidRootPart in the character (still loading?)")
	end

	local wanted: { [string]: boolean } = {}
	for _, specs in RigBinding.Specs do
		for _, jointSpec in specs do
			wanted[jointSpec.name] = true
		end
	end
	local found = indexByName(character, wanted)

	-- Try the rig the Humanoid claims first, then the other one.
	local order: { RigKind } = if reported == "R6" then { "R6" :: RigKind, "R15" } else { "R15" :: RigKind, "R6" }
	local attempts: { [string]: Attempt } = {}
	for index, kind: RigKind in order do
		local tried = attempt(kind, found)
		attempts[kind] = tried
		if #tried.problems == 0 then
			local note = nil
			if index > 1 then
				note = `Humanoid.RigType is {reported} but the joints are {kind}; using {kind}`
			end
			local jointTypes: { [string]: number } = {}
			for _, joint in tried.joints do
				local jointType: string = RigBinding.jointType(joint) or "?"
				jointTypes[jointType] = (jointTypes[jointType] or 0) + 1
			end
			return {
				ok = true,
				binding = {
					kind = kind,
					jointTypes = jointTypes,
					reportedRigType = reported,
					character = character,
					humanoid = humanoid,
					root = root,
					joints = tried.joints,
					missingOptional = tried.missingOptional,
					note = note,
				},
				reportedRigType = reported,
				triedKind = kind,
				problems = {},
				reason = "bound",
			}
		end
	end

	-- Neither rig is complete: explain the one the Humanoid claims (or, if it
	-- claims neither, the closer one).
	local blamed: RigKind = order[1]
	if reported ~= "R6" and reported ~= "R15" and #attempts["R6"].problems < #attempts["R15"].problems then
		blamed = "R6"
	end
	local problems = attempts[blamed].problems
	return failure(
		reported,
		`{blamed} rig incomplete (Humanoid.RigType = {reported}): {table.concat(problems, "; ")}`,
		blamed,
		problems
	)
end

-- Why a binding no longer describes the live character (respawn, avatar
-- reload replacing body parts, death breaking joints), or nil if it is fine.
function RigBinding.staleReason(binding: Binding, character: any): string?
	if character ~= binding.character then
		return "the character changed"
	end
	if binding.root.Parent == nil or not binding.root:IsDescendantOf(character) then
		return "HumanoidRootPart was removed"
	end
	for role, joint in binding.joints do
		if joint.Parent == nil or not joint:IsDescendantOf(character) then
			return `joint {joint.Name} ({role}) was removed`
		end
		local problem = jointProblem(joint)
		if problem then
			return `joint {joint.Name} ({role}): {problem}`
		end
	end
	return nil
end

-- Every joint role that the binding drives.
function RigBinding.roles(binding: Binding): { string }
	local roles = {}
	for _, jointSpec in RigBinding.Specs[binding.kind] do
		if binding.joints[jointSpec.role] then
			table.insert(roles, jointSpec.role)
		end
	end
	return roles
end

return RigBinding
