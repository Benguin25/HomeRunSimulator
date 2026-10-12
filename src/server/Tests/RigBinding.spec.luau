--!strict
-- Rig binding against mock R6 and R15 hierarchies: both rigs bind, the
-- Humanoid's claim is checked against the joints, and every failure says
-- exactly which joint is wrong and why (Phase 2.7 regression: an R6 avatar
-- used to be reported only as "waiting for an R15 rig").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Batting = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Batting")
local CharacterPose = require(Batting.CharacterPose)
local RigBinding = require(Batting.RigBinding)

local MockRig = require(script.Parent.MockRig) :: any
local TestUtil = require(script.Parent.TestUtil)

local ROOT = CFrame.new(10, 3, -4)

local function contains(text: string, part: string): boolean
	return string.find(text, part, 1, true) ~= nil
end

return function(t)
	t.test("an R15 character binds as R15 with every joint", function()
		local model = MockRig.r15(ROOT)
		local result = RigBinding.bind(model)
		TestUtil.assertTrue(result.ok, `R15 failed to bind: {result.reason}`)
		local binding = result.binding :: RigBinding.Binding
		TestUtil.assertEqual(binding.kind, "R15", "rig kind")
		TestUtil.assertEqual(binding.reportedRigType, "R15", "reported rig type")
		TestUtil.assertTrue(binding.note == nil, "no mismatch note expected")
		for _, jointSpec in RigBinding.Specs.R15 do
			local joint = binding.joints[jointSpec.role]
			TestUtil.assertTrue(joint ~= nil, `missing {jointSpec.role}`)
			TestUtil.assertEqual(joint.Name, jointSpec.name, `{jointSpec.role} name`)
			TestUtil.assertTrue(joint:IsA("Motor6D"), `{jointSpec.role} is not a Motor6D`)
		end
		TestUtil.assertEqual(#binding.missingOptional, 0, "optional joints reported missing")
		TestUtil.assertEqual(binding.root.Name, "HumanoidRootPart", "root part")
	end)

	t.test("an R6 character binds as R6 without expecting elbows, wrists or a waist", function()
		local model = MockRig.r6(ROOT)
		local result = RigBinding.bind(model)
		TestUtil.assertTrue(result.ok, `R6 failed to bind: {result.reason}`)
		local binding = result.binding :: RigBinding.Binding
		TestUtil.assertEqual(binding.kind, "R6", "rig kind")
		TestUtil.assertEqual(binding.joints.root.Name, "RootJoint", "root joint")
		TestUtil.assertEqual(binding.joints.leftShoulder.Name, "Left Shoulder", "left shoulder")
		TestUtil.assertEqual(binding.joints.rightShoulder.Name, "Right Shoulder", "right shoulder")
		TestUtil.assertEqual(binding.joints.leftHip.Name, "Left Hip", "left hip")
		TestUtil.assertEqual(binding.joints.rightHip.Name, "Right Hip", "right hip")
		for _, role in { "waist", "leftElbow", "leftWrist", "rightElbow", "rightWrist" } do
			TestUtil.assertTrue(binding.joints[role] == nil, `R6 should not have {role}`)
		end
		TestUtil.assertEqual(#RigBinding.roles(binding), 5, "driven joint count")
		-- The rig reads into pose data with sizes from the real parts.
		local rig = CharacterPose.read(binding) :: any
		TestUtil.assertEqual(rig.kind, "R6", "pose rig kind")
		TestUtil.assertNear(rig.hipDrop, 1, 1e-6, "hip drop = half the torso height")
		TestUtil.assertEqual(#rig.legs, 2, "legs read")
	end)

	t.test("the joints win when Humanoid.RigType disagrees with them", function()
		local result = RigBinding.bind(MockRig.r6(ROOT, "R15"))
		TestUtil.assertTrue(result.ok, `mislabelled R6 failed to bind: {result.reason}`)
		local binding = result.binding :: RigBinding.Binding
		TestUtil.assertEqual(binding.kind, "R6", "rig kind")
		TestUtil.assertEqual(binding.reportedRigType, "R15", "reported rig type")
		TestUtil.assertTrue(binding.note ~= nil and contains(binding.note, "Humanoid.RigType is R15"), "mismatch not reported")
		local other = RigBinding.bind(MockRig.r15(ROOT, "R6"))
		TestUtil.assertTrue(other.ok and (other.binding :: RigBinding.Binding).kind == "R15", "mislabelled R15 should bind as R15")
	end)

	t.test("a missing R15 joint is named in the failure reason", function()
		local model = MockRig.r15(ROOT)
		MockRig.find(model, "LeftElbow"):Remove()
		local result = RigBinding.bind(model)
		TestUtil.assertTrue(not result.ok, "incomplete R15 rig bound")
		TestUtil.assertEqual(result.triedKind, "R15", "blamed rig")
		TestUtil.assertTrue(contains(result.reason, "LeftElbow: not found"), `reason: {result.reason}`)
		TestUtil.assertTrue(contains(result.reason, "Humanoid.RigType = R15"), `reason should show the rig type: {result.reason}`)
		TestUtil.assertEqual(#result.problems, 1, "only the missing joint is a problem")
	end)

	t.test("unassembled and wrong-class joints are explained", function()
		local unassembled = MockRig.r6(ROOT)
		MockRig.find(unassembled, "Left Shoulder").Part1 = nil
		local result = RigBinding.bind(unassembled)
		TestUtil.assertTrue(not result.ok, "rig with an unset Part1 bound")
		TestUtil.assertTrue(contains(result.reason, "Left Shoulder: Part1 not set"), `reason: {result.reason}`)

		local welded = MockRig.r6(ROOT)
		local motor = MockRig.find(welded, "Right Shoulder")
		motor.ClassName = "Weld"
		local weldResult = RigBinding.bind(welded)
		TestUtil.assertTrue(not weldResult.ok, "rig with a welded shoulder bound")
		TestUtil.assertTrue(contains(weldResult.reason, "Right Shoulder: is a Weld, not a Motor6D"), `reason: {weldResult.reason}`)
	end)

	t.test("loading characters give specific reasons", function()
		TestUtil.assertEqual(RigBinding.bind(nil).reason, "no character", "nil character")
		local noHumanoid = MockRig.r15(ROOT)
		MockRig.find(noHumanoid, "Humanoid"):Remove()
		TestUtil.assertTrue(contains(RigBinding.bind(noHumanoid).reason, "no Humanoid"), "missing Humanoid")
		local noRoot = MockRig.r6(ROOT)
		MockRig.find(noRoot, "HumanoidRootPart"):Remove()
		TestUtil.assertTrue(contains(RigBinding.bind(noRoot).reason, "no HumanoidRootPart"), "missing root part")
	end)

	t.test("an R15 avatar with AnimationConstraint joints binds (Avatar Joint Upgrade)", function()
		-- Phase 2.8 regression: these were rejected as "not a Motor6D".
		local model = MockRig.r15Constraints(ROOT)
		local result = RigBinding.bind(model)
		TestUtil.assertTrue(result.ok, `AnimationConstraint R15 failed to bind: {result.reason}`)
		local binding = result.binding :: RigBinding.Binding
		TestUtil.assertEqual(binding.kind, "R15", "rig kind")
		TestUtil.assertEqual(binding.jointTypes.AnimationConstraint, #RigBinding.Specs.R15, "every joint is an AnimationConstraint")
		TestUtil.assertTrue(binding.jointTypes.Motor6D == nil, "no Motor6Ds expected")
		for _, jointSpec in RigBinding.Specs.R15 do
			local joint = binding.joints[jointSpec.role]
			TestUtil.assertEqual(RigBinding.jointType(joint), "AnimationConstraint", `{jointSpec.role} joint type`)
		end
		-- The adapter reads the same offsets and parts a Motor6D rig would have.
		local classic = (RigBinding.bind(MockRig.r15(ROOT)).binding :: RigBinding.Binding)
		for _, jointSpec in RigBinding.Specs.R15 do
			local a = RigBinding.frame(binding.joints[jointSpec.role])
			local b = RigBinding.frame(classic.joints[jointSpec.role])
			TestUtil.assertTrue((a.c0.Position - b.c0.Position).Magnitude < 1e-6 and (a.c1.Position - b.c1.Position).Magnitude < 1e-6, `{jointSpec.role} offsets differ`)
			TestUtil.assertEqual(a.part0.Name, b.part0.Name, `{jointSpec.role} Part0`)
			TestUtil.assertEqual(a.part1.Name, b.part1.Name, `{jointSpec.role} Part1`)
		end
	end)

	t.test("unusable AnimationConstraints and other constraints are explained", function()
		local unattached = MockRig.r15Constraints(ROOT)
		MockRig.find(unattached, "LeftElbow").Attachment1 = nil
		local result = RigBinding.bind(unattached)
		TestUtil.assertTrue(not result.ok, "constraint without Attachment1 bound")
		TestUtil.assertTrue(contains(result.reason, "LeftElbow: Attachment1 not set"), `reason: {result.reason}`)

		local disabled = MockRig.r15Constraints(ROOT)
		MockRig.findOfClass(disabled, "Waist", "AnimationConstraint").Enabled = false
		local disabledResult = RigBinding.bind(disabled)
		TestUtil.assertTrue(contains(disabledResult.reason, "Waist: disabled"), `reason: {disabledResult.reason}`)

		local ballSocket = MockRig.r15Constraints(ROOT)
		MockRig.find(ballSocket, "RightShoulder").ClassName = "BallSocketConstraint"
		local socketResult = RigBinding.bind(ballSocket)
		TestUtil.assertTrue(
			contains(socketResult.reason, "RightShoulder: is a BallSocketConstraint, not a Motor6D or AnimationConstraint"),
			`reason: {socketResult.reason}`
		)
	end)

	t.test("a usable joint wins over a same-named non-joint (ragdoll sockets, values)", function()
		local model = MockRig.r15Constraints(ROOT)
		-- A ragdoll BallSocketConstraint with the joint's name, FIRST in the tree.
		local socket = MockRig.node("BallSocketConstraint", "LeftShoulder")
		socket.Parent = model
		table.insert(model._children, 1, socket)
		local result = RigBinding.bind(model)
		TestUtil.assertTrue(result.ok, `bind failed: {result.reason}`)
		local joint = (result.binding :: RigBinding.Binding).joints.leftShoulder
		TestUtil.assertEqual(joint.ClassName, "AnimationConstraint", "picked the wrong LeftShoulder")
	end)

	t.test("an AnimationConstraint binding goes stale when its attachment is removed", function()
		local model = MockRig.r15Constraints(ROOT)
		local binding = RigBinding.bind(model).binding :: RigBinding.Binding
		TestUtil.assertTrue(RigBinding.staleReason(binding, model) == nil, "fresh binding reported stale")
		MockRig.find(model, "RightElbow").Attachment0 = nil
		local reason = RigBinding.staleReason(binding, model)
		TestUtil.assertTrue(reason ~= nil and contains(reason, "Attachment0 not set"), `reason: {reason}`)
	end)

	t.test("a binding goes stale when the rig is rebuilt or the character changes", function()
		local model = MockRig.r15(ROOT)
		local binding = RigBinding.bind(model).binding :: RigBinding.Binding
		TestUtil.assertTrue(RigBinding.staleReason(binding, model) == nil, "fresh binding reported stale")
		TestUtil.assertTrue(RigBinding.staleReason(binding, MockRig.r15(ROOT)) == "the character changed", "new character not detected")
		-- Avatar loading replaces a body part (and its joint) after spawn.
		MockRig.find(model, "RightWrist"):Remove()
		local reason = RigBinding.staleReason(binding, model)
		TestUtil.assertTrue(reason ~= nil and contains(reason, "RightWrist"), `removed joint not detected: {reason}`)
		-- Death breaks joints.
		local r6 = MockRig.r6(ROOT)
		local r6Binding = RigBinding.bind(r6).binding :: RigBinding.Binding
		MockRig.find(r6, "RootJoint").Part0 = nil
		local broken = RigBinding.staleReason(r6Binding, r6)
		TestUtil.assertTrue(broken ~= nil and contains(broken, "Part0 not set"), `broken joint not detected: {broken}`)
	end)
end
