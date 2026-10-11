--!strict
-- Visible-bat alignment: the bat that is drawn must be the bat that collides
-- (Active), must never snap between phases, must start in the batter's hands,
-- and the arm IK must put the hands where the bat is.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchConfig = require(Pitching.PitchConfig)
local Batting = Shared:WaitForChild("Batting")
local ArmIK = require(Batting.ArmIK)
local BatCollision = require(Batting.BatCollision)
local BatStance = require(Batting.BatStance)
local BodyFit = require(Batting.BodyFit)
local BattingConfig = require(Batting.BattingConfig)
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)

local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local CM = units.toStuds(0.01)
local EPOCH = 1.7e9
-- float32 positions at ~250 studs from the origin: well under a millimeter.
local EPS = 2e-3

local function makeFlight(geometry: LaneGeometry.Geometry, seed: number): Pitch.Flight
	local release = EPOCH + 1
	local data = Pitch.generate(geometry, TestUtil.rng(seed), { id = seed, laneId = "Test", windupTime = release - 1, releaseTime = release })
	return Pitch.buildFlight(geometry, data)
end

local function ballAimAt(geometry: LaneGeometry.Geometry, flight: Pitch.Flight): (number, number, number)
	local ideal = SwingResolver.idealContactTime(geometry, flight)
	assert(ideal, "no contact-plane crossing")
	local ball = flight.trajectory.positions[1]
	local PitchPhysics = require(Pitching.PitchPhysics)
	ball = PitchPhysics.sample(flight.trajectory, ideal - flight.data.releaseTime)
	local offset = ball - SwingModel.contactPlane(geometry).point
	return offset:Dot(geometry.right), offset:Dot(geometry.up), ideal
end

local function anchorFor(geometry: LaneGeometry.Geometry): Vector3
	return BatStance.fallbackAnchor(geometry)
end

local function poseGap(a: SwingModel.Pose, b: SwingModel.Pose): number
	return math.max((a.knob - b.knob).Magnitude, (a.tip - b.tip).Magnitude)
end

-- Synthetic R15-like arm: joints at the ends of limb segments hanging along -Y.
local function syntheticArm(side: number): ArmIK.ArmRig
	return {
		shoulderC0 = CFrame.new(side * 1.0, 0.6, 0),
		shoulderC1 = CFrame.new(0, 0.55, 0),
		elbowC0 = CFrame.new(0, -0.4, 0),
		elbowC1 = CFrame.new(0, 0.4, 0),
		wristC0 = CFrame.new(0, -0.5, 0),
		wristC1 = CFrame.new(0, 0.2, 0),
	}
end

return function(t)
	t.test("while Active the drawn bat is exactly the collision pose", function()
		for laneName, geometry in TestUtil.geometries() do
			local swing = SwingModel.new(geometry, CM * 7, units.toStuds(0.85), EPOCH)
			local ready = BatStance.readyPose(geometry, anchorFor(geometry), swing.aimX, swing.aimY)
			for i = 0, 39 do -- strictly inside the window; its end is the follow-through boundary
				local time = swing.activeStart + (swing.activeEnd - swing.activeStart) * i / 40
				local visual = BatStance.visualPoseAt(swing, time, ready, ready)
				local collision = SwingModel.activePoseAt(swing, time)
				TestUtil.assertTrue(poseGap(visual, collision) < 1e-6, `{laneName}: drawn bat differs from collision pose at step {i}`)
				TestUtil.assertTrue((visual.planeNormal - collision.planeNormal).Magnitude < 1e-6, `{laneName}: bat roll differs at step {i}`)
			end
			-- At the square time the sweet spot is on the aim point.
			local square = BatStance.visualPoseAt(swing, swing.squareTime, ready, ready)
			local sweet = square.knob + square.direction * swing.dims.sweetSpot
			TestUtil.assertTrue((sweet - swing.aimPoint).Magnitude < 1e-3, `{laneName}: sweet spot is not on the aim point when square`)
		end
	end)

	t.test("the bat never snaps: every phase hand-off is continuous", function()
		for laneName, geometry in TestUtil.geometries() do
			for _, aim in { { 0, 0.8 }, { 0.4, 0.4 }, { -0.4, 1.2 } } do
				local swing = SwingModel.new(geometry, units.toStuds(aim[1]), units.toStuds(aim[2]), EPOCH)
				-- The resting pose when the click happened differs from the one at recovery end.
				local from = BatStance.readyPose(geometry, anchorFor(geometry), swing.aimX + CM * 9, swing.aimY - CM * 6)
				local ready = BatStance.readyPose(geometry, anchorFor(geometry), swing.aimX, swing.aimY)
				local tl = swing.timeline
				local boundaries = {
					EPOCH,
					EPOCH + tl.windup,
					EPOCH + tl.windup + tl.active,
					EPOCH + tl.windup + tl.active + tl.followThrough,
					EPOCH + tl.total,
				}
				-- At the click the controller starts the windup from the pose on screen.
				local atClick = BatStance.visualPoseAt(swing, EPOCH - 1e-6, ready, ready)
				TestUtil.assertTrue(poseGap(atClick, BatStance.visualPoseAt(swing, EPOCH + 1e-6, ready, ready)) < EPS, "bat jumps at the click")
				for index = 2, #boundaries do
					local boundary = boundaries[index]
					local before = BatStance.visualPoseAt(swing, boundary - 1e-6, from, ready)
					local after = BatStance.visualPoseAt(swing, boundary + 1e-6, from, ready)
					TestUtil.assertTrue(poseGap(before, after) < EPS, `{laneName}: bat jumps {poseGap(before, after)} studs at boundary {index}`)
				end
				-- Ends of the blends land exactly on their targets.
				TestUtil.assertTrue(poseGap(BatStance.visualPoseAt(swing, EPOCH, from, ready), from) < EPS, "windup should start at the on-screen pose")
				TestUtil.assertTrue(poseGap(BatStance.visualPoseAt(swing, EPOCH + tl.total + 1e-6, from, ready), ready) < EPS, "recovery should end at the resting pose")
				-- Along the whole swing the bat keeps its length and stays rigid.
				for i = 0, 200 do
					local time = EPOCH - 0.05 + (tl.total + 0.1) * i / 200
					local pose = BatStance.visualPoseAt(swing, time, from, ready)
					TestUtil.assertNear((pose.tip - pose.knob).Magnitude, swing.dims.length, 2e-3, "bat length")
					TestUtil.assertNear(pose.direction:Dot(pose.planeNormal), 0, 1e-4, "bat roll axis must stay perpendicular")
				end
			end
		end
	end)

	t.test("the windup moves toward the first collision pose without overshooting", function()
		local geometry = TestUtil.geometries().straight
		local swing = SwingModel.new(geometry, CM * -10, units.toStuds(0.55), EPOCH)
		local from = BatStance.readyPose(geometry, anchorFor(geometry), swing.aimX, swing.aimY)
		local target = SwingModel.activePoseAt(swing, swing.activeStart)
		local previous = math.huge
		for i = 0, 50 do
			local time = EPOCH + swing.timeline.windup * i / 50
			local distance = (BatStance.visualPoseAt(swing, time, from, from).knob - target.knob).Magnitude
			TestUtil.assertTrue(distance <= previous + 1e-6, "knob moved away from the swing during the windup")
			previous = distance
		end
		TestUtil.assertTrue(previous < EPS, "windup did not reach the first collision pose")
	end)

	t.test("the bat starts in the batter's hands, raised, and follows the aim only partially", function()
		for laneName, geometry in TestUtil.geometries() do
			local anchor = anchorFor(geometry)
			local preload = BattingConfig.Stance.PreloadFraction
			local farthest = 0
			for _, aimX in { -0.5, 0, 0.5 } do
				for _, aimY in { 0.3, 0.8, 1.3 } do
					local x, y = units.toStuds(aimX), units.toStuds(aimY)
					local pose = BatStance.readyPose(geometry, anchor, x, y)
					local fullyAimed = SwingModel.restPose(geometry, x, y)
					local expected = (fullyAimed.knob - anchor).Magnitude * preload
					TestUtil.assertNear((pose.knob - anchor).Magnitude, expected, 1e-3, `{laneName}: knob offset from the hands`)
					TestUtil.assertTrue(pose.direction.Y > 0.5, `{laneName}: resting bat should point up (y={pose.direction.Y})`)
					farthest = math.max(farthest, (pose.knob - anchor).Magnitude)
				end
			end
			-- Even for the extreme aims the hands stay within about a meter of home.
			TestUtil.assertTrue(units.toMeters(farthest) < 0.6, `{laneName}: resting bat strays {units.toMeters(farthest)} m from the hands`)
		end
	end)

	t.test("at registered contact the drawn barrel overlaps the drawn ball", function()
		local visualRadius = units.toStuds(PitchConfig.Ball.RadiusMeters) * PitchConfig.Ball.VisualScale
		for laneName, geometry in TestUtil.geometries() do
			for seed = 1, 6 do
				local flight = makeFlight(geometry, seed * 13)
				local x, y, ideal = ballAimAt(geometry, flight)
				for _, offsetMs in { 0, -25, 25 } do
					local swing = SwingModel.new(geometry, x, y, SwingModel.startTimeForSquareAt(ideal + offsetMs / 1000))
					local contact = SwingResolver.resolve(geometry, flight, swing).contact
					assert(contact, `{laneName} seed {seed} {offsetMs} ms: no contact`)
					local ready = BatStance.readyPose(geometry, anchorFor(geometry), x, y)
					local drawn = BatStance.visualPoseAt(swing, contact.contactTime, ready, ready)
					local gap = BatCollision.measure(drawn, swing.dims, contact.ballCenter, visualRadius).gap
					TestUtil.assertTrue(gap < -0.5 * CM, `{laneName} seed {seed}: drawn ball does not reach into the drawn bat (gap {gap})`)
					-- ...and not absurdly deep: the ball center stays outside the barrel.
					local centerGap = BatCollision.measure(drawn, swing.dims, contact.ballCenter, 0).gap
					TestUtil.assertTrue(centerGap > 0, `{laneName} seed {seed}: ball center inside the bat`)
				end
			end
		end
	end)

	t.test("the drawn pose is a pure function of server time (any frame rate)", function()
		local geometry = TestUtil.geometries().rotated
		local swing = SwingModel.new(geometry, CM * 3, units.toStuds(0.7), EPOCH)
		local from = BatStance.readyPose(geometry, anchorFor(geometry), 0, units.toStuds(0.9))
		local ready = BatStance.readyPose(geometry, anchorFor(geometry), swing.aimX, swing.aimY)
		local rng = TestUtil.rng(5)
		local reference: { [number]: SwingModel.Pose } = {}
		for i = 0, 100 do
			reference[i] = BatStance.visualPoseAt(swing, EPOCH + swing.timeline.total * i / 100, from, ready)
		end
		for _ = 1, 300 do
			local i = math.floor(rng:NextNumber(0, 100.999))
			local pose = BatStance.visualPoseAt(swing, EPOCH + swing.timeline.total * i / 100, from, ready)
			TestUtil.assertTrue(poseGap(pose, reference[i]) < 1e-9, "pose depends on query order")
		end
		-- The resting-bat smoothing is frame-rate independent too: 1 s of 30 fps vs 240 fps.
		local length = swing.dims.length
		local target = BatStance.readyPose(geometry, anchorFor(geometry), CM * 20, units.toStuds(1.1))
		local slow, fast = from, from
		for _ = 1, 30 do
			slow = BatStance.follow(slow, target, 1 / 30, length)
		end
		for _ = 1, 240 do
			fast = BatStance.follow(fast, target, 1 / 240, length)
		end
		TestUtil.assertTrue(poseGap(slow, fast) < 5e-3, "bat smoothing depends on frame rate")
	end)

	t.test("arm IK puts the hand on the grip point from any torso orientation", function()
		local rng = TestUtil.rng(21)
		local torsos = {
			CFrame.new(0, 3, 0),
			CFrame.new(250, 37.5, -120) * CFrame.Angles(0, math.rad(130), 0),
			CFrame.new(-40, 8, 17) * CFrame.Angles(math.rad(10), math.rad(-75), math.rad(6)),
		}
		for _, side in { -1, 1 } do
			local rig = syntheticArm(side)
			local upper, lower, hand = ArmIK.lengths(rig)
			TestUtil.assertNear(upper, 0.95, 1e-6, "upper arm length")
			TestUtil.assertNear(lower, 0.9, 1e-6, "forearm length")
			TestUtil.assertNear(hand, 0.2, 1e-6, "wrist-to-hand offset")
			for _, torso in torsos do
				local shoulder = ArmIK.shoulderPosition(torso, rig)
				for _ = 1, 60 do
					-- Random points the arm can reach (between 0.4 and 1.7 studs away).
					local direction = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 0.3), rng:NextNumber(-1, 1)).Unit
					local grip = shoulder + direction * rng:NextNumber(0.4, 1.7)
					local solution = ArmIK.solve(torso, rig, grip, Vector3.new(0, -1, 0.3))
					TestUtil.assertTrue(solution.reachable, "reachable grip reported unreachable")
					local elbow, wrist, handCenter = ArmIK.forward(torso, rig, solution)
					TestUtil.assertTrue((handCenter - grip).Magnitude < 2e-3, `hand misses the grip by {(handCenter - grip).Magnitude}`)
					TestUtil.assertNear((elbow - shoulder).Magnitude, upper, 2e-3, "upper arm stretched")
					TestUtil.assertNear((wrist - elbow).Magnitude, lower, 2e-3, "forearm stretched")
				end
			end
		end
	end)

	t.test("arm IK bends the elbow toward the hint and clamps out-of-reach targets", function()
		local rig = syntheticArm(1)
		local torso = CFrame.new(0, 3, 0)
		local shoulder = ArmIK.shoulderPosition(torso, rig)
		local upper, lower = ArmIK.lengths(rig)
		-- Hand held out in front: an elbow hint of "down" puts the elbow below the line.
		local grip = shoulder + Vector3.new(0, 0, 1.2)
		local down = ArmIK.solve(torso, rig, grip, Vector3.new(0, -1, 0))
		local up = ArmIK.solve(torso, rig, grip, Vector3.new(0, 1, 0))
		TestUtil.assertTrue(down.elbowPosition.Y < shoulder.Y - 0.1, "elbow should bend down")
		TestUtil.assertTrue(up.elbowPosition.Y > shoulder.Y + 0.1, "elbow should bend up")
		-- Far target: arm straight toward it, not stretched.
		local far = shoulder + Vector3.new(0.3, -0.5, 6)
		local clamped = ArmIK.solve(torso, rig, far, Vector3.new(0, -1, 0))
		TestUtil.assertTrue(not clamped.reachable, "out-of-reach grip reported reachable")
		local elbow, wrist = ArmIK.forward(torso, rig, clamped)
		TestUtil.assertNear((elbow - shoulder).Magnitude, upper, 2e-3, "upper arm length when clamped")
		TestUtil.assertNear((wrist - elbow).Magnitude, lower, 2e-3, "forearm length when clamped")
		local pointing = (wrist - shoulder).Unit:Dot((far - shoulder).Unit)
		TestUtil.assertTrue(pointing > 0.999, "clamped arm should point at the target")
		-- Degenerate hints (parallel to the reach direction) still solve.
		local degenerate = ArmIK.solve(torso, rig, grip, Vector3.new(0, 0, 1))
		TestUtil.assertTrue((select(3, ArmIK.forward(torso, rig, degenerate)) - grip).Magnitude < 2e-3, "degenerate hint broke the solve")
	end)

	t.test("the waist turns with the swing: zero at rest, monotonic, capped, never snapping", function()
		local rest = math.rad(BattingConfig.Swing.RestAngleDegrees)
		local sign = -SwingModel.batterSideSign()
		TestUtil.assertNear(BatStance.torsoYaw(rest), 0, 1e-9, "yaw at the resting angle")
		local previous = -math.huge
		for degrees = -100, 150, 5 do
			local yaw = BatStance.torsoYaw(math.rad(degrees)) * sign
			TestUtil.assertTrue(yaw >= previous - 1e-9, `yaw not monotonic at {degrees} deg`)
			TestUtil.assertTrue(math.abs(yaw) <= math.rad(BattingConfig.Stance.MaxTorsoYawDegrees) + 1e-9, "yaw above the cap")
			previous = yaw
		end
		TestUtil.assertTrue(BatStance.torsoYaw(math.rad(60)) * sign > math.rad(20), "contact should be visibly turned in")
		-- Continuous through the whole swing (the visual angle never jumps).
		local geometry = TestUtil.geometries().straight
		local swing = SwingModel.new(geometry, 0, units.toStuds(0.8), EPOCH)
		local ready = BatStance.readyPose(geometry, anchorFor(geometry), 0, units.toStuds(0.8))
		local last = BatStance.torsoYaw(ready.angle)
		for i = 0, 600 do
			local time = EPOCH + (swing.timeline.total + 0.02) * i / 600
			local yaw = BatStance.torsoYaw(BatStance.visualPoseAt(swing, time, ready, ready).angle)
			TestUtil.assertTrue(math.abs(yaw - last) < math.rad(4), `waist snaps by {math.deg(math.abs(yaw - last))} deg`)
			last = yaw
		end
	end)

	t.test("body fit puts the shoulders within arm's reach of the swing pivot", function()
		local geometry = TestUtil.geometries().rotated
		local home = geometry.batterCFrame.Position + geometry.up * 4.4 -- shoulder midpoint, studs
		local armLength = 2.7 -- shoulder to hand center, typical R15 (studs)
		local dims = SwingModel.dimensions(geometry)
		local gripRadius = dims.pivotRadius + units.toStuds(BattingConfig.Stance.GripTopMeters)
		local maxShift = units.toStuds(BattingConfig.Stance.BodyMaxShiftMeters)
		local maxCrouch = units.toStuds(BattingConfig.Stance.BodyMaxCrouchMeters)
		local atCap = 0
		for _, aimX in { -0.5, -0.25, 0, 0.25, 0.5 } do
			for _, aimY in { 0.3, 0.45, 0.6, 0.8, 1.05, 1.3 } do
				local pivot = SwingModel.pivotFor(geometry, units.toStuds(aimX), units.toStuds(aimY))
				local shift = BodyFit.target(geometry, home, pivot, armLength, gripRadius)
				local flat = Vector3.new(shift.X, 0, shift.Z)
				TestUtil.assertTrue(flat.Magnitude <= maxShift + 1e-6, "slides farther than allowed")
				TestUtil.assertTrue(-shift.Y >= -1e-9 and -shift.Y <= maxCrouch + 1e-6, "crouch outside its limits")
				-- Distance from the moved shoulders to the farthest grip on the pivot circle.
				local shoulder = home + shift
				local worst = 0
				for degrees = -100, 150, 10 do
					local direction = SwingModel.directionAt(SwingModel.new(geometry, units.toStuds(aimX), units.toStuds(aimY), EPOCH), math.rad(degrees))
					worst = math.max(worst, (pivot + direction * gripRadius - shoulder).Magnitude)
				end
				if aimY >= 0.45 then
					TestUtil.assertTrue(worst <= armLength, `aim ({aimX}, {aimY}): grips {worst} studs away, arms reach {armLength}`)
				elseif -shift.Y >= maxCrouch - 1e-6 then
					atCap += 1 -- very low pitches crouch as far as allowed
				end
			end
		end
		TestUtil.assertTrue(atCap > 0, "low pitches should use the full crouch")
	end)

	t.test("body fit is calm: dead zone, no jumps, and no change when disabled", function()
		local geometry = TestUtil.geometries().straight
		local home = geometry.batterCFrame.Position + geometry.up * 4.4
		local gripRadius = 1.7
		local pivotUnder = home - geometry.up * units.toStuds(0.8) -- right below the shoulders
		local still = BodyFit.target(geometry, home, pivotUnder + geometry.right * units.toStuds(0.05), 2.7, gripRadius)
		TestUtil.assertTrue(Vector3.new(still.X, 0, still.Z).Magnitude < 1e-6, "slides inside the dead zone")
		-- Small aim changes make small body changes.
		local previous = BodyFit.target(geometry, home, SwingModel.pivotFor(geometry, units.toStuds(-0.5), units.toStuds(0.8)), 2.7, gripRadius)
		for step = 1, 100 do
			local x = units.toStuds(-0.5 + step * 0.01)
			local shift = BodyFit.target(geometry, home, SwingModel.pivotFor(geometry, x, units.toStuds(0.8)), 2.7, gripRadius)
			TestUtil.assertTrue((shift - previous).Magnitude < units.toStuds(0.03), "body jumps for a 1 cm aim change")
			previous = shift
		end
		BattingConfig.Stance.BodyFit = false
		local off = BodyFit.target(geometry, home, pivotUnder + geometry.right * 5, 2.7, gripRadius)
		BattingConfig.Stance.BodyFit = true
		TestUtil.assertTrue(off.Magnitude == 0, "disabled body fit still moved the body")
	end)

	t.test("legs: the foot stays level and lands on its target while the knee bends", function()
		local rig = syntheticArm(1)
		local torso = CFrame.new(3, 6, -2) * CFrame.Angles(0, math.rad(40), 0)
		local desired = CFrame.Angles(0, math.rad(25), 0) -- the foot's neutral orientation
		-- Foot target, then the ankle-joint target the solver is aimed at.
		for _, drop in { 0, 0.3, 0.7 } do
			local footTarget = ArmIK.shoulderPosition(torso, rig) + Vector3.new(0.1, -1.4 + drop, 0.3)
			local ankleTarget = footTarget + desired.Rotation * rig.wristC1.Position
			local solverRig = table.clone(rig)
			solverRig.wristC1 = CFrame.identity
			local solution = ArmIK.solve(torso, solverRig, ankleTarget, Vector3.new(0, 0, 1))
			local transform = ArmIK.endTransform(torso, rig, solution, desired)
			local joint = ArmIK.endJointFrame(torso, rig, solution)
			local foot = joint * transform * rig.wristC1:Inverse()
			TestUtil.assertTrue((foot.Position - footTarget).Magnitude < 2e-3, `foot misses its target by {(foot.Position - footTarget).Magnitude}`)
			TestUtil.assertTrue((foot.LookVector - desired.LookVector).Magnitude < 1e-4 and (foot.UpVector - desired.UpVector).Magnitude < 1e-4, "foot is not level")
		end
	end)
end
