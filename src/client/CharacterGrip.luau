--!strict
-- Makes the local character swing the bat (client-side, cosmetic only), for
-- R15 and R6 rigs whose joints are Motor6Ds or AnimationConstraints.
--
-- Every frame BattingController calls ensureBound -> step -> getAnchor ->
-- apply(pose). The pose maths lives in the shared, tested CharacterPose
-- module; this file binds the real character (RigBinding), feeds it the live
-- joint offsets, writes the joints' Transforms and reports what happened.
--
-- AnimationConstraint joints (Roblox's Avatar Joint Upgrade) are force- and
-- torque-limited by default (IsKinematic = false): a written Transform is
-- only a target the physics solver pulls toward, so limbs would lag the bat
-- and could be shoved by collisions. Roblox documents IsKinematic = true as
-- "the connected parts follow the Transform perfectly without participating
-- in physics simulation", so while batting the BOUND joints are switched to
-- kinematic (client-side, Stance.KinematicJointsWhileBatting) and switched
-- back on release. Nothing is replaced or destroyed.
--
-- Update ordering. Roblox's Animator writes the joints' Transform in the
-- animation step, which runs after the render step and before physics, and
-- parts only move to their Transforms when physics resolves the joints. A
-- Transform written only in the render step is therefore overwritten by any
-- animation still playing before it is ever shown. So:
--   * the default animations are suppressed while batting (Animate script
--     disabled, Animator tracks stopped) and restored on release, and
--   * the same Transforms are written again in RunService.PreSimulation
--     (after the Animator, before physics), so they win even if something
--     keeps animating. Overwrites seen there are counted and shown in F7.
--
-- Why Phase 2.6 never moved the body: binding only knew R15 joint names, so
-- an R6 avatar ("RootJoint", "Left Shoulder", no elbows/wrists/waist) could
-- never bind and the bat-only fallback ran forever. RigBinding now binds
-- both rigs and reports exactly which joint is missing when it can't.

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local LaneGeometry = require(Shared:WaitForChild("Pitching"):WaitForChild("LaneGeometry"))
local BattingConfig = require(Shared:WaitForChild("Batting"):WaitForChild("BattingConfig"))
local CharacterPose = require(Shared.Batting.CharacterPose)
local RigBinding = require(Shared.Batting.RigBinding)
local SwingModel = require(Shared.Batting.SwingModel)

local CharacterGrip = {}

local LOG = "[Batting]"
local debugLogging = RunService:IsStudio()
-- Hands farther than this from where the Transforms put them mean the pose
-- is not reaching the screen.
local RENDER_TOLERANCE_METERS = 0.03

type State = {
	binding: RigBinding.Binding,
	roles: { string },
	rig: CharacterPose.Rig, -- this frame's joint offsets
	animate: BaseScript?,
	animateWasEnabled: boolean,
	animatorConnection: RBXScriptConnection?,
	stepConnection: RBXScriptConnection?,
	applied: { [Instance]: CFrame }, -- last Transform written per joint (Motor6D or AnimationConstraint)
	kinematicRestore: { [Instance]: boolean }, -- AnimationConstraints made kinematic -> original IsKinematic
	expectedHands: { Vector3 }?, -- where last frame's Transforms put the hands
	result: CharacterPose.Result?,
	-- Diagnostics
	lastApply: number,
	renderedError: number?, -- studs, measured from the real hand parts
	renderedBadSince: number?,
	renderWarned: boolean,
	overwrites: number, -- joints the Animator overwrote, last second
	overwriteWindow: number,
	overwritesShown: number,
	overwriteWarned: boolean,
	handTravel: number, -- studs the rendered hands moved, current window
	handTravelWindow: number,
	handTravelShown: number, -- studs the rendered hands moved, last full second
	lastRenderedHands: { Vector3 }?,
}

local state: State? = nil
local boundCharacter: Model? = nil
local lastTry = -math.huge
local lastResult: RigBinding.Result? = nil
local lastLoggedReason: string? = nil
local status = "no character"
local bodyShift = Vector3.zero

local function differs(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude > 1e-4
		or (a.LookVector - b.LookVector).Magnitude > 1e-4
		or (a.UpVector - b.UpVector).Magnitude > 1e-4
end

local function suppressAnimations(s: State)
	local character = s.binding.character :: Model
	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("BaseScript") then
		s.animate = animate
		s.animateWasEnabled = animate.Enabled
		animate.Enabled = false
	end
	local humanoid = s.binding.humanoid :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
		s.animatorConnection = animator.AnimationPlayed:Connect(function(track)
			track:Stop(0)
		end)
	end
end

-- Re-asserts this frame's Transforms after the Animator has run.
local function onPreSimulation()
	local s = state
	if not s then
		return
	end
	local now = os.clock()
	if now - s.overwriteWindow >= 1 then
		s.overwritesShown = s.overwrites
		s.overwrites = 0
		s.overwriteWindow = now
	end
	for joint, transform in s.applied do
		local live = joint :: any
		if differs(live.Transform, transform) then
			s.overwrites += 1
			live.Transform = transform
		end
	end
	if debugLogging and s.overwrites > 0 and not s.overwriteWarned then
		s.overwriteWarned = true
		warn(`{LOG} Something (usually an Animator track) is overwriting the batting pose's Motor6D Transforms; re-applying them in PreSimulation.`)
	end
end

-- Hands the character back to the animation system.
function CharacterGrip.release()
	local s = state
	if not s then
		return
	end
	state = nil
	if s.stepConnection then
		s.stepConnection:Disconnect()
	end
	for _, role in s.roles do
		local joint = s.binding.joints[role]
		if joint.Parent then
			joint.Transform = CFrame.identity
		end
	end
	for joint, wasKinematic in s.kinematicRestore do
		if joint.Parent then
			(joint :: any).IsKinematic = wasKinematic
		end
	end
	if s.animatorConnection then
		s.animatorConnection:Disconnect()
	end
	if s.animate and s.animate.Parent then
		s.animate.Enabled = s.animateWasEnabled
	end
	bodyShift = Vector3.zero
end

-- Finds the joints on the character. Returns false (and keeps retrying from
-- ensureBound) while the rig is incomplete; the reason is logged and shown.
function CharacterGrip.bind(character: Model?): boolean
	CharacterGrip.release()
	boundCharacter = character
	lastTry = os.clock()
	local result = RigBinding.bind(character)
	lastResult = result
	local binding = result.binding
	if not binding then
		status = result.reason
		if result.reason ~= lastLoggedReason then
			lastLoggedReason = result.reason
			if character then
				warn(`{LOG} Character rig not bound yet (bat-only stance meanwhile): {result.reason}`)
			end
		end
		return false
	end
	local s: State = {
		binding = binding,
		roles = RigBinding.roles(binding),
		rig = CharacterPose.read(binding),
		animate = nil,
		animateWasEnabled = true,
		animatorConnection = nil,
		stepConnection = nil,
		applied = {},
		kinematicRestore = {},
		expectedHands = nil,
		result = nil,
		lastApply = -math.huge,
		renderedError = nil,
		renderedBadSince = nil,
		renderWarned = false,
		overwrites = 0,
		overwriteWindow = os.clock(),
		overwritesShown = 0,
		overwriteWarned = false,
		handTravel = 0,
		handTravelWindow = os.clock(),
		handTravelShown = 0,
		lastRenderedHands = nil,
	}
	if BattingConfig.Stance.SuppressAnimations then
		suppressAnimations(s)
	end
	if BattingConfig.Stance.KinematicJointsWhileBatting then
		for _, role in s.roles do
			local joint = binding.joints[role]
			if RigBinding.jointType(joint) == "AnimationConstraint" and not joint.IsKinematic then
				s.kinematicRestore[joint] = false
				joint.IsKinematic = true
			end
		end
	end
	s.stepConnection = RunService.PreSimulation:Connect(onPreSimulation)
	state = s
	status = "bound"
	lastLoggedReason = nil
	if debugLogging then
		local extras = {}
		if binding.note then
			table.insert(extras, binding.note)
		end
		if #binding.missingOptional > 0 then
			table.insert(extras, `optional joints missing: {table.concat(binding.missingOptional, ", ")}`)
		end
		print(
			`{LOG} Character rig bound: {binding.kind} (Humanoid.RigType = {binding.reportedRigType}), {CharacterGrip.jointSummary(binding)}{if next(s.kinematicRestore) then " (made kinematic while batting)" else ""}, driving {#s.roles} joints: {table.concat(s.roles, ", ")}`
				.. (if #extras > 0 then ` | {table.concat(extras, " | ")}` else "")
		)
	end
	return true
end

-- Call every frame: binds a new character, rebinds when the binding went
-- stale (respawn, avatar parts replaced, joints broken), and retries while
-- the rig is still being assembled.
function CharacterGrip.ensureBound(character: Model?)
	local s = state
	if s then
		local stale = RigBinding.staleReason(s.binding, character)
		if not stale then
			s.rig = CharacterPose.read(s.binding)
			return
		end
		if debugLogging then
			print(`{LOG} Character rig binding went stale ({stale}); rebinding`)
		end
		CharacterGrip.bind(character)
		return
	end
	if character ~= boundCharacter or (character ~= nil and os.clock() - lastTry > BattingConfig.Stance.BindRetrySeconds) then
		CharacterGrip.bind(character)
	end
end

function CharacterGrip.isBound(): boolean
	return state ~= nil
end

-- Moves the body toward the position that lets the hands reach the swing pivot.
function CharacterGrip.step(geometry: LaneGeometry.Geometry, pivot: Vector3, dt: number)
	local s = state
	if not s then
		return
	end
	local target = CharacterPose.bodyFitTarget(geometry, s.rig, pivot)
	local tau = BattingConfig.Stance.BodyFollowSeconds
	local alpha = if tau <= 0 then 1 else 1 - math.exp(-math.max(dt, 0) / tau)
	bodyShift = bodyShift:Lerp(target, alpha)
end

-- Where the hands rest for the body as it currently stands. nil without a rig.
function CharacterGrip.getAnchor(geometry: LaneGeometry.Geometry): Vector3?
	local s = state
	if not s then
		return nil
	end
	return CharacterPose.anchor(geometry, s.rig, bodyShift)
end

-- Hand points as the engine actually placed them (last frame's Transforms).
local function renderedHands(s: State): { Vector3 }?
	local joints = s.binding.joints
	local rig = s.rig
	if rig.kind == "R15" then
		local left, right = RigBinding.frame(joints.leftWrist).part1, RigBinding.frame(joints.rightWrist).part1
		if left and right then
			return { left.Position, right.Position }
		end
		return nil
	end
	local list = {}
	for i, role in { "leftShoulder", "rightShoulder" } do
		local arm = RigBinding.frame(joints[role]).part1
		if not arm then
			return nil
		end
		list[i] = arm.CFrame * rig.arms[i].tip
	end
	return list
end

local function measureRendered(s: State, geometry: LaneGeometry.Geometry)
	local expected = s.expectedHands
	local actual = renderedHands(s)
	-- Real on-screen motion: how far the hand parts actually travel.
	local now = os.clock()
	if now - s.handTravelWindow >= 1 then
		s.handTravelShown = s.handTravel
		s.handTravel = 0
		s.handTravelWindow = now
	end
	local previous = s.lastRenderedHands
	if actual and previous and #previous == #actual then
		for i, hand in actual do
			s.handTravel += (hand - previous[i]).Magnitude / #actual
		end
	end
	s.lastRenderedHands = actual
	if not expected or not actual or #expected ~= #actual then
		return
	end
	local worst = 0
	for i, hand in actual do
		worst = math.max(worst, (hand - expected[i]).Magnitude)
	end
	s.renderedError = worst
	if geometry.units.toMeters(worst) > RENDER_TOLERANCE_METERS then
		s.renderedBadSince = s.renderedBadSince or now
		if not s.renderWarned and now - (s.renderedBadSince :: number) > 1 then
			s.renderWarned = true
			warn(
				string.format(
					"%s The batting pose is not reaching the screen: the hands are %.0f cm from where the Transforms put them. Another script may be driving these joints, or force-driven (non-kinematic) AnimationConstraints cannot keep up.",
					LOG,
					geometry.units.toMeters(worst) * 100
				)
			)
		end
	else
		s.renderedBadSince = nil
	end
end

-- Poses the whole character for a bat pose.
function CharacterGrip.apply(geometry: LaneGeometry.Geometry, pose: SwingModel.Pose)
	local s = state
	if not s then
		return
	end
	measureRendered(s, geometry)
	local result = CharacterPose.solve(geometry, s.rig, pose, bodyShift)
	for role, transform in result.transforms do
		local joint = s.binding.joints[role]
		if joint then
			joint.Transform = transform
			s.applied[joint] = transform
		end
	end
	s.result = result
	s.expectedHands = if #result.hands > 0 then CharacterPose.handsFor(s.rig, result.transforms) else nil
	s.lastApply = os.clock()
end

local function animationState(s: State): string
	local parts = {}
	if s.animate then
		table.insert(parts, if s.animate.Enabled then "Animate script ON" else "Animate script off")
	else
		table.insert(parts, "no Animate script")
	end
	local humanoid = s.binding.humanoid :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		table.insert(parts, `{#animator:GetPlayingAnimationTracks()} tracks playing`)
	else
		table.insert(parts, "no Animator")
	end
	table.insert(parts, if s.animatorConnection or s.animate then "(suppressed while batting)" else "(NOT suppressed)")
	return table.concat(parts, ", ")
end

-- "14 AnimationConstraint" / "8 Motor6D + 6 AnimationConstraint".
function CharacterGrip.jointSummary(binding: RigBinding.Binding): string
	local parts = {}
	for _, jointType in { "Motor6D", "AnimationConstraint" } do
		local count = binding.jointTypes[jointType]
		if count then
			table.insert(parts, `{count} {jointType}`)
		end
	end
	return table.concat(parts, " + ")
end

-- Status lines for the F7 overlay.
function CharacterGrip.describe(geometry: LaneGeometry.Geometry): string
	local s = state
	if not s then
		local reported = if lastResult then lastResult.reportedRigType else "?"
		return string.format(
			"rig: NOT BOUND (Humanoid.RigType %s): %s\n    retrying every %.1f s; the bat uses the fallback stance until then",
			reported,
			status,
			BattingConfig.Stance.BindRetrySeconds
		)
	end
	local units = geometry.units
	local binding = s.binding
	local cm = function(studs: number?): string
		return if studs then string.format("%.1f cm", units.toMeters(studs) * 100) else "n/a"
	end
	local kinematicCount = 0
	for _ in s.kinematicRestore do
		kinematicCount += 1
	end
	local lines = {
		string.format(
			"rig: %s bound (Humanoid.RigType %s), %d joints: %s%s%s%s",
			binding.kind,
			binding.reportedRigType,
			#s.roles,
			CharacterGrip.jointSummary(binding),
			if kinematicCount > 0 then string.format(" (%d made kinematic while batting)", kinematicCount) else "",
			if #binding.missingOptional > 0 then " | missing " .. table.concat(binding.missingOptional, ", ") else "",
			if binding.note then " | " .. binding.note else ""
		),
	}
	local age = os.clock() - s.lastApply
	local visible = if s.renderedError == nil
		then "not measured yet"
		elseif units.toMeters(s.renderedError) <= RENDER_TOLERANCE_METERS then "VISIBLE (body parts follow the pose)"
		else "NOT VISIBLE (body parts are not where the joints were told to put them)"
	table.insert(
		lines,
		string.format(
			"anim: %s | transforms %s (%.0f ms ago) | Animator overwrites %d/s",
			animationState(s),
			if age < 0.25 then "applied" else "STALE",
			age * 1000,
			s.overwritesShown
		)
	)
	-- Success is judged from the real hand parts, not from binding.
	table.insert(
		lines,
		string.format(
			"motion: %s | rendered hands vs solved %s | rendered hand travel %s in the last second",
			visible,
			cm(s.renderedError),
			cm(s.handTravelShown)
		)
	)
	local result = s.result
	if result then
		table.insert(
			lines,
			string.format(
				"grip: hand-to-bat %s | torso turn %.0f deg, lean %.0f deg | body shift %s, crouch %s",
				cm(result.gap),
				math.deg(result.torsoYaw * CharacterPose.openSign(geometry)),
				math.deg(result.lean),
				cm(Vector3.new(bodyShift.X, 0, bodyShift.Z).Magnitude),
				cm(math.max(-bodyShift.Y, 0))
			)
		)
	end
	return table.concat(lines, "\n    ")
end

return CharacterGrip
