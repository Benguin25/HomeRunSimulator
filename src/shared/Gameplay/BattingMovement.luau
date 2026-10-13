--!strict
-- Capture exact character settings once per reservation; restore exactly once.
local Movement = {}
export type Saved = {
	root: BasePart,
	humanoid: Humanoid,
	anchored: boolean,
	speed: number,
	jumpPower: number,
	jumpHeight: number,
	useJumpPower: boolean,
	autoRotate: boolean,
}
function Movement.capture(humanoid: Humanoid, root: BasePart): Saved
	return {
		root = root,
		humanoid = humanoid,
		anchored = root.Anchored,
		speed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		useJumpPower = humanoid.UseJumpPower,
		autoRotate = humanoid.AutoRotate,
	}
end
function Movement.lock(saved: Saved)
	saved.humanoid.WalkSpeed, saved.humanoid.JumpPower, saved.humanoid.JumpHeight = 0, 0, 0
	saved.humanoid.AutoRotate, saved.root.Anchored = false, true
end
function Movement.restore(saved: Saved)
	if saved.root.Parent then
		saved.root.Anchored = saved.anchored
	end
	if saved.humanoid.Parent then
		saved.humanoid.WalkSpeed, saved.humanoid.JumpPower = saved.speed, saved.jumpPower
		saved.humanoid.JumpHeight, saved.humanoid.UseJumpPower = saved.jumpHeight, saved.useJumpPower
		saved.humanoid.AutoRotate = saved.autoRotate
	end
end
return Movement
