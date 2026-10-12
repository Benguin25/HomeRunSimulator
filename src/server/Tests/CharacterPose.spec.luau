--!strict
-- The procedural batting pose on mock R15 and R6 characters (standard joint
-- offsets), driven by the same bat poses the game draws: hands stay on the
-- handle, the body visibly turns through contact, nothing snaps, and the
-- Transforms themselves (not just the solver's numbers) put the hands there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Batting = Shared:WaitForChild("Batting")
local BatStance = require(Batting.BatStance)
local BattingConfig = require(Batting.BattingConfig)
local CharacterPose = require(Batting.CharacterPose)
local LaneGeometry = require(Shared.Pitching.LaneGeometry)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local RigBinding = require(Batting.RigBinding)
local SwingModel = require(Batting.SwingModel)

local MockRig = require(script.Parent.MockRig) :: any
local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local EPOCH = 1000
local STEPS = 480
-- In-zone and just-off-zone aims (meters): where hands must stay on the bat.
local AIMS = { { 0, 0.5 }, { 0, 0.8 }, { 0.3, 0.8 }, { -0.4, 0.8 }, { 0, 1.05 }, { 0.2, 0.6 } }

local function rigFor(kind: string, geometry: LaneGeometry.Geometry): CharacterPose.Rig
	-- Both default rigs stand with the root 3 studs above the ground.
	local root = geometry.batterCFrame + Vector3.new(0, 3, 0)
	-- "R15AC": the same R15 with AnimationConstraint joints (Avatar Joint Upgrade).
	local model = if kind == "R6" then MockRig.r6(root) elseif kind == "R15AC" then MockRig.r15Constraints(root) else MockRig.r15(root)
	local result = RigBinding.bind(model)
	assert(result.ok, result.reason)
	return CharacterPose.read(result.binding :: RigBinding.Binding)
end

type Sample = { time: number, phase: string, pose: SwingModel.Pose, result: CharacterPose.Result }

-- Steady-state body fit for the aim, then the whole swing sampled at a fixed rate.
local function run(geometry: LaneGeometry.Geometry, rig: CharacterPose.Rig, aimX: number, aimY: number): { Sample }
	local x, y = units.toStuds(aimX), units.toStuds(aimY)
	local shift = CharacterPose.bodyFitTarget(geometry, rig, SwingModel.pivotFor(geometry, x, y))
	local ready = BatStance.readyPose(geometry, CharacterPose.anchor(geometry, rig, shift), x, y)
	local swing = SwingModel.new(geometry, x, y, EPOCH)
	local samples = {}
	for i = -20, STEPS do
		local time = EPOCH + (swing.timeline.total + 0.02) * i / STEPS
		local pose = BatStance.visualPoseAt(swing, time, ready, ready)
		local phase = if time < EPOCH then "Ready" else (SwingModel.phaseAt(swing, time))
		table.insert(samples, { time = time, phase = phase, pose = pose, result = CharacterPose.solve(geometry, rig, pose, shift) })
	end
	return samples
end

local function rotationAngle(a: CFrame, b: CFrame): number
	local worst = 0
	for _, pair in { { a.LookVector, b.LookVector }, { a.UpVector, b.UpVector }, { a.RightVector, b.RightVector } } do
		worst = math.max(worst, math.acos(math.clamp(pair[1]:Dot(pair[2]), -1, 1)))
	end
	return worst
end

-- Signed chest turn about world up from the stance (+ = toward the pitcher).
local function chestTurn(geometry: LaneGeometry.Geometry, rig: CharacterPose.Rig, result: CharacterPose.Result): number
	local look = CharacterPose.chestFor(rig, result.transforms).LookVector
	look = Vector3.new(look.X, 0, look.Z).Unit
	local forward = geometry.batterCFrame.LookVector
	return math.atan2(forward:Cross(look).Y, forward:Dot(look)) * CharacterPose.openSign(geometry)
end

return function(t)
	t.test("hands stay on the handle through the whole swing (R15 and R6)", function()
		-- Worst grip error allowed (cm) while the bat can hit, and anywhere in the swing.
		-- R6's rigid arms can't bend, so its hands are only approximately on the handle.
		local limits = { R15 = { active = 0.5, any = 5 }, R15AC = { active = 0.5, any = 5 }, R6 = { active = 6, any = 9 } }
		for _, kind in { "R15", "R15AC", "R6" } do
			for laneName, geometry in TestUtil.geometries() do
				local rig = rigFor(kind, geometry)
				for _, aim in AIMS do
					for _, sample in run(geometry, rig, aim[1], aim[2]) do
						local gap = units.toMeters(sample.result.gap) * 100
						local label = `{kind} {laneName} aim ({aim[1]}, {aim[2]}) {sample.phase}`
						if sample.phase == "Windup" or sample.phase == "Active" or sample.phase == "Ready" then
							TestUtil.assertTrue(gap <= limits[kind].active, `{label}: hand {gap} cm off the handle`)
						end
						TestUtil.assertTrue(gap <= limits[kind].any, `{label}: hand {gap} cm off the handle`)
					end
				end
			end
		end
	end)

	t.test("AnimationConstraint and Motor6D R15 rigs get identical Transforms all swing long", function()
		for laneName, geometry in TestUtil.geometries() do
			local classic = rigFor("R15", geometry)
			local upgraded = rigFor("R15AC", geometry)
			for _, aim in { { 0, 0.8 }, { -0.4, 0.6 } } do
				local a, b = run(geometry, classic, aim[1], aim[2]), run(geometry, upgraded, aim[1], aim[2])
				for i, sample in a do
					local other = b[i].result.transforms
					for role, transform in sample.result.transforms do
						local twin = other[role] :: CFrame?
						assert(twin, `{laneName}: {role} missing on the AnimationConstraint rig`)
						TestUtil.assertTrue(
							(twin.Position - transform.Position).Magnitude < 1e-5
								and (twin.LookVector - transform.LookVector).Magnitude < 1e-5
								and (twin.UpVector - transform.UpVector).Magnitude < 1e-5,
							`{laneName}: {role} differs between joint types at {sample.phase}`
						)
					end
				end
			end
		end
	end)

	t.test("the Transforms themselves put the hands where the solver says", function()
		for _, kind in { "R15", "R15AC", "R6" } do
			local geometry = TestUtil.geometries().rotated
			local rig = rigFor(kind, geometry)
			for _, sample in run(geometry, rig, 0.1, 0.75) do
				local hands = CharacterPose.handsFor(rig, sample.result.transforms)
				for i, hand in hands do
					TestUtil.assertTrue((hand - sample.result.hands[i]).Magnitude < 2e-3, `{kind}: forward kinematics disagree with the solve`)
				end
			end
		end
	end)

	t.test("the body visibly swings: arms move, the torso turns through contact and follows through", function()
		for _, kind in { "R15", "R15AC", "R6" } do
			for laneName, geometry in TestUtil.geometries() do
				local rig = rigFor(kind, geometry)
				local samples = run(geometry, rig, 0, 0.8)
				local x, y = 0, units.toStuds(0.8)
				local swing = SwingModel.new(geometry, x, y, EPOCH)
				local readyTurn, contactTurn, followTurn = nil, nil, -math.huge
				local readyArm, contactArm = nil, nil
				for _, sample in samples do
					local turn = chestTurn(geometry, rig, sample.result)
					if sample.phase == "Ready" and not readyTurn then
						readyTurn = turn
						readyArm = sample.result.transforms.leftShoulder
					end
					if not contactTurn and sample.time >= swing.squareTime then
						contactTurn = turn
						contactArm = sample.result.transforms.leftShoulder
					end
					if sample.phase == "FollowThrough" then
						followTurn = math.max(followTurn, turn)
					end
				end
				assert(readyTurn and contactTurn and readyArm and contactArm, "missing samples")
				local label = `{kind} {laneName}`
				TestUtil.assertTrue(math.abs(readyTurn) <= math.rad(BattingConfig.Stance.MaxTorsoCloseDegrees) + 1e-6, `{label}: stance turned {math.deg(readyTurn)} deg`)
				TestUtil.assertTrue(contactTurn - readyTurn > math.rad(25), `{label}: chest opened only {math.deg(contactTurn - readyTurn)} deg by contact`)
				TestUtil.assertTrue(followTurn > math.rad(70), `{label}: follow-through opened only {math.deg(followTurn)} deg`)
				TestUtil.assertTrue(rotationAngle(readyArm, contactArm) > math.rad(30), `{label}: the arm barely moved`)
			end
		end
	end)

	t.test("no joint snaps: every Transform changes smoothly at 240+ Hz", function()
		for _, kind in { "R15", "R6" } do
			local geometry = TestUtil.geometries().straight
			local rig = rigFor(kind, geometry)
			for _, aim in AIMS do
				local samples = run(geometry, rig, aim[1], aim[2])
				for i = 2, #samples do
					local before, after = samples[i - 1].result.transforms, samples[i].result.transforms
					for role, transform in after do
						local previous = before[role] :: CFrame?
						assert(previous, `{kind} {role} appeared mid-swing`)
						local turn = math.deg(rotationAngle(previous, transform))
						local move = units.toMeters((previous.Position - transform.Position).Magnitude) * 100
						local label = `{kind} aim ({aim[1]}, {aim[2]}) {role} at {samples[i].phase}`
						-- The bat itself turns ~5 deg per step here at its fastest.
						TestUtil.assertTrue(turn < 15, `{label}: jumps {turn} deg in one step`)
						TestUtil.assertTrue(move < 4, `{label}: jumps {move} cm in one step`)
					end
				end
			end
		end
	end)

	t.test("feet stay planted and the root is only nudged, never thrown around", function()
		for _, kind in { "R15", "R6" } do
			for _, geometry in TestUtil.geometries() do
				local rig = rigFor(kind, geometry)
				local standing = CharacterPose.feetFor(rig, {})
				local standingChest = CharacterPose.chestFor(rig, {}).Position.Y
				local lowest = standingChest - CharacterPose.maxCrouch(rig, geometry) - units.toStuds(0.12) -- crouch + lean
				for _, aim in AIMS do
					local x, y = units.toStuds(aim[1]), units.toStuds(aim[2])
					local shift = CharacterPose.bodyFitTarget(geometry, rig, SwingModel.pivotFor(geometry, x, y))
					local flatShift = Vector3.new(shift.X, 0, shift.Z)
					TestUtil.assertTrue(units.toMeters(flatShift.Magnitude) <= BattingConfig.Stance.BodyMaxShiftMeters + 1e-6, "body slides too far")
					local samples = run(geometry, rig, aim[1], aim[2])
					-- R6 spreads into a batting stance; measure its feet against that stance.
					local stance = CharacterPose.feetFor(rig, samples[1].result.transforms)
					for _, sample in samples do
						local feet = CharacterPose.feetFor(rig, sample.result.transforms)
						for i, foot in feet do
							-- Feet stay on the ground they stood on, never floating or sinking.
							local lift = units.toMeters(foot.Y - standing[i].Y)
							TestUtil.assertTrue(lift > -0.01 and lift < 0.01, `{kind}: foot lifted {lift} m`)
							local home = if kind == "R15" then standing[i] + flatShift else stance[i]
							local slide = units.toMeters(Vector3.new(foot.X - home.X, 0, foot.Z - home.Z).Magnitude)
							-- R15 feet are pinned. R6 has no waist: its hips turn and lean with the
							-- chest, so its feet pivot (up to ~0.45 m during contact and ~0.65 m in a
							-- full follow-through) -- the price of keeping rigid arms on the bat.
							local limit = if kind == "R15" then 0.005 elseif sample.phase == "Active" then 0.5 else 0.7
							TestUtil.assertTrue(slide < limit, `{kind}: foot slid {slide} m in {sample.phase}`)
						end
						-- The chest never drops more than the crouch limit plus the lean.
						local chest = CharacterPose.chestFor(rig, sample.result.transforms)
						TestUtil.assertTrue(chest.Position.Y >= lowest, `{kind}: chest dropped {units.toMeters(standingChest - chest.Position.Y)} m`)
					end
				end
			end
		end
	end)

	t.test("a left-handed batter swings mirrored and still holds the bat", function()
		local geometryConfig = PitchConfig.Geometry :: any
		local saved = geometryConfig.BatterSide
		geometryConfig.BatterSide = "Left"
		local ok, err = pcall(function()
			for _, kind in { "R15", "R6" } do
				for laneName, geometry in TestUtil.geometries() do
					local rig = rigFor(kind, geometry)
					local samples = run(geometry, rig, 0, 0.8)
					local swing = SwingModel.new(geometry, 0, units.toStuds(0.8), EPOCH)
					local contactTurn = nil
					for _, sample in samples do
						if sample.phase == "Active" then
							TestUtil.assertTrue(units.toMeters(sample.result.gap) < 0.04, `{kind} {laneName}: left-handed hands off the bat`)
						end
						if not contactTurn and sample.time >= swing.squareTime then
							contactTurn = chestTurn(geometry, rig, sample.result)
						end
					end
					TestUtil.assertTrue(contactTurn ~= nil and contactTurn > math.rad(10), `{kind} {laneName}: left-handed chest should open toward the pitcher`)
				end
			end
		end)
		geometryConfig.BatterSide = saved
		if not ok then
			error(err, 0)
		end
	end)

	t.test("torso turn is continuous, zero-ish in the stance and capped", function()
		local cfg = BattingConfig.Stance
		for _, kind in { "R15", "R6" } do
			local geometry = TestUtil.geometries().rotated
			local rig = rigFor(kind, geometry)
			for _, aim in AIMS do
				local last = nil
				for _, sample in run(geometry, rig, aim[1], aim[2]) do
					local yaw = sample.result.torsoYaw * CharacterPose.openSign(geometry)
					TestUtil.assertTrue(yaw <= math.rad(cfg.MaxTorsoOpenDegrees) + 1e-6, "turn above the open cap")
					TestUtil.assertTrue(yaw >= -math.rad(cfg.MaxTorsoCloseDegrees) - 1e-6, "turn above the close cap")
					if last then
						TestUtil.assertTrue(math.abs(yaw - last) < math.rad(12), `{kind}: torso turn jumps {math.deg(math.abs(yaw - last))} deg`)
					end
					last = yaw
				end
			end
		end
	end)

	t.test("with arms disabled the arms are left alone", function()
		BattingConfig.Stance.ArmIK = false
		local ok, err = pcall(function()
			for _, kind in { "R15", "R6" } do
				local geometry = TestUtil.geometries().straight
				local rig = rigFor(kind, geometry)
				local samples = run(geometry, rig, 0, 0.8)
				for _, sample in samples do
					TestUtil.assertTrue((sample.result.transforms.leftShoulder :: CFrame?) == nil, `{kind}: arm driven while disabled`)
					TestUtil.assertTrue(sample.result.lean == 0, `{kind}: leaned for disabled arms`)
				end
			end
		end)
		BattingConfig.Stance.ArmIK = true
		if not ok then
			error(err, 0)
		end
	end)
end
