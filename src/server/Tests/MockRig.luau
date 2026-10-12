--!nocheck
-- Instance-shaped tables for R6 and R15 characters (standard joint offsets),
-- so rig binding and posing can be tested without Roblox. Only the members
-- RigBinding and CharacterPose use are implemented.

local MockRig = {}

local IS_A = {
	Part = { Part = true, BasePart = true, Instance = true },
	MeshPart = { MeshPart = true, BasePart = true, Instance = true },
	AnimationConstraint = { AnimationConstraint = true, Constraint = true, Instance = true },
	BallSocketConstraint = { BallSocketConstraint = true, Constraint = true, Instance = true },
}

local Node = {}
Node.__index = Node

function MockRig.node(className: string, name: string, props: { [string]: any }?)
	local self = setmetatable({ ClassName = className, Name = name, Parent = nil, _children = {} }, Node)
	for key, value in props or {} do
		self[key] = value
	end
	return self
end

function Node:IsA(className: string): boolean
	local table_ = IS_A[self.ClassName]
	if table_ then
		return table_[className] == true
	end
	return self.ClassName == className or className == "Instance"
end

function Node:Add(child)
	child.Parent = self
	table.insert(self._children, child)
	return child
end

function Node:Remove()
	local parent = self.Parent
	if parent then
		local index = table.find(parent._children, self)
		if index then
			table.remove(parent._children, index)
		end
	end
	self.Parent = nil
end

function Node:GetChildren()
	return table.clone(self._children)
end

function Node:GetDescendants()
	local list = {}
	local function walk(node)
		for _, child in node._children do
			table.insert(list, child)
			walk(child)
		end
	end
	walk(self)
	return list
end

function Node:FindFirstChild(name: string)
	for _, child in self._children do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function Node:IsDescendantOf(ancestor): boolean
	local node = self.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = node.Parent
	end
	return false
end

local function part(model, name: string, size: Vector3)
	return model:Add(MockRig.node("Part", name, { Size = size, CFrame = CFrame.identity }))
end

-- Joint class used by the R15 builder: "Motor6D" (classic rigs) or
-- "AnimationConstraint" (Avatar Joint Upgrade).
local jointClass = "Motor6D"

-- A joint parented to Part1 (like Roblox's default rigs). AnimationConstraints
-- connect two rig attachments whose CFrames play the role of C0 / C1, and
-- start force-driven (IsKinematic = false) as the joint upgrade creates them.
local function motor(name: string, part0, part1, c0: CFrame, c1: CFrame)
	if jointClass == "AnimationConstraint" then
		local a0 = part0:Add(MockRig.node("Attachment", name .. "RigAttachment", { CFrame = c0 }))
		local a1 = part1:Add(MockRig.node("Attachment", name .. "RigAttachment", { CFrame = c1 }))
		return part1:Add(MockRig.node("AnimationConstraint", name, {
			Attachment0 = a0,
			Attachment1 = a1,
			Transform = CFrame.identity,
			IsKinematic = false,
			Enabled = true,
		}))
	end
	return part1:Add(MockRig.node("Motor6D", name, { Part0 = part0, Part1 = part1, C0 = c0, C1 = c1, Transform = CFrame.identity }))
end

local function humanoid(model, rigType: string)
	return model:Add(MockRig.node("Humanoid", "Humanoid", { RigType = { Name = rigType } }))
end

-- Standard R6 (blocky) character. `rootCFrame` is the HumanoidRootPart.
function MockRig.r6(rootCFrame: CFrame, rigType: string?)
	local model = MockRig.node("Model", "R6Dummy")
	humanoid(model, rigType or "R6")
	local root = part(model, "HumanoidRootPart", Vector3.new(2, 2, 1))
	root.CFrame = rootCFrame
	local torso = part(model, "Torso", Vector3.new(2, 2, 1))
	local head = part(model, "Head", Vector3.new(2, 1, 1))
	local leftArm = part(model, "Left Arm", Vector3.new(1, 2, 1))
	local rightArm = part(model, "Right Arm", Vector3.new(1, 2, 1))
	local leftLeg = part(model, "Left Leg", Vector3.new(1, 2, 1))
	local rightLeg = part(model, "Right Leg", Vector3.new(1, 2, 1))
	-- R6 joints live in HumanoidRootPart (RootJoint) and Torso (everything else).
	local function r6Motor(parent, name, part0, part1, c0, c1)
		return parent:Add(MockRig.node("Motor6D", name, { Part0 = part0, Part1 = part1, C0 = c0, C1 = c1, Transform = CFrame.identity }))
	end
	local rootRot = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0)
	r6Motor(root, "RootJoint", root, torso, rootRot, rootRot)
	r6Motor(torso, "Neck", torso, head, CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0), CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0))
	r6Motor(torso, "Right Shoulder", torso, rightArm, CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0))
	r6Motor(torso, "Left Shoulder", torso, leftArm, CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))
	r6Motor(torso, "Right Hip", torso, rightLeg, CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0))
	r6Motor(torso, "Left Hip", torso, leftLeg, CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))
	-- Attachments and an accessory weld, as on a real character.
	torso:Add(MockRig.node("Attachment", "LeftCollarAttachment"))
	local hat = model:Add(MockRig.node("Accessory", "Hat"))
	local handle = hat:Add(MockRig.node("Part", "Handle", { Size = Vector3.one, CFrame = CFrame.identity }))
	handle:Add(MockRig.node("Weld", "AccessoryWeld", { Part0 = handle, Part1 = head }))
	model:Add(MockRig.node("LocalScript", "Animate"))
	return model
end

-- Standard blocky R15 character (scale 1).
function MockRig.r15(rootCFrame: CFrame, rigType: string?)
	local model = MockRig.node("Model", "R15Dummy")
	humanoid(model, rigType or "R15")
	-- A non-joint that shares a joint's name (and comes first) must not confuse the binder.
	model:Add(MockRig.node("StringValue", "Waist"))
	local root = part(model, "HumanoidRootPart", Vector3.new(2, 2, 1))
	root.CFrame = rootCFrame
	local lowerTorso = part(model, "LowerTorso", Vector3.new(2, 0.4, 1))
	local upperTorso = part(model, "UpperTorso", Vector3.new(2, 1.6, 1))
	local head = part(model, "Head", Vector3.new(1.2, 1.2, 1.2))
	motor("Root", root, lowerTorso, CFrame.new(0, -1, 0), CFrame.new(0, -0.2, 0))
	motor("Waist", lowerTorso, upperTorso, CFrame.new(0, 0.2, 0), CFrame.new(0, -0.8, 0))
	motor("Neck", upperTorso, head, CFrame.new(0, 0.8, 0), CFrame.new(0, -0.5, 0))
	for _, side in { "Left", "Right" } do
		local x = if side == "Left" then -1 else 1
		local upperArm = part(model, side .. "UpperArm", Vector3.new(1, 1.17, 1))
		local lowerArm = part(model, side .. "LowerArm", Vector3.new(1, 1.05, 1))
		local hand = part(model, side .. "Hand", Vector3.new(1, 0.3, 1))
		motor(side .. "Shoulder", upperTorso, upperArm, CFrame.new(x, 0.563, 0), CFrame.new(-x * 0.5, 0.392, 0))
		motor(side .. "Elbow", upperArm, lowerArm, CFrame.new(0, -0.334, 0), CFrame.new(0, 0.26, 0))
		motor(side .. "Wrist", lowerArm, hand, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.125, 0))
		hand:Add(MockRig.node("Attachment", side .. "WristRigAttachment"))
		local upperLeg = part(model, side .. "UpperLeg", Vector3.new(1, 1.2, 1))
		local lowerLeg = part(model, side .. "LowerLeg", Vector3.new(1, 1.2, 1))
		local foot = part(model, side .. "Foot", Vector3.new(1, 0.2, 1))
		motor(side .. "Hip", lowerTorso, upperLeg, CFrame.new(x * 0.5, -0.2, 0), CFrame.new(0, 0.45, 0))
		motor(side .. "Knee", upperLeg, lowerLeg, CFrame.new(0, -0.45, 0), CFrame.new(0, 0.45, 0))
		motor(side .. "Ankle", lowerLeg, foot, CFrame.new(0, -0.45, 0), CFrame.new(0, 0.1, 0))
	end
	model:Add(MockRig.node("LocalScript", "Animate"))
	return model
end

-- The same R15 character with AnimationConstraint joints (Avatar Joint
-- Upgrade) instead of Motor6Ds; identical geometry.
function MockRig.r15Constraints(rootCFrame: CFrame, rigType: string?)
	jointClass = "AnimationConstraint"
	local ok, model = pcall(MockRig.r15, rootCFrame, rigType)
	jointClass = "Motor6D"
	assert(ok, model)
	return model
end

-- Finds the first descendant with this name and class (any class if nil).
function MockRig.findOfClass(model, name: string, className: string)
	for _, descendant in model:GetDescendants() do
		if descendant.Name == name and descendant.ClassName == className then
			return descendant
		end
	end
	return nil
end

-- Finds the first descendant with this name.
function MockRig.find(model, name: string)
	for _, descendant in model:GetDescendants() do
		if descendant.Name == name then
			return descendant
		end
	end
	return nil
end

return MockRig
