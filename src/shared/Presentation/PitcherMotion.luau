--!strict
-- A procedural pose on the authoritative windup/release clock. Pure cosmetics.
local Geometry = require(script.Parent.Parent.Pitching.LaneGeometry)
local Config = require(script.Parent.Parent.Gameplay.BattingModeConfig)
local Motion = {}
export type Pose = {
	hip: Vector3,
	chest: Vector3,
	head: Vector3,
	hand: Vector3,
	glove: Vector3,
	throwShoulder: Vector3,
	gloveShoulder: Vector3,
	leadFoot: Vector3,
	trailFoot: Vector3,
	lift: number,
	stride: number,
	released: boolean,
}
local function smooth(value: number): number
	local u = math.clamp(value, 0, 1)
	return u * u * (3 - 2 * u)
end
function Motion.sample(geo: Geometry.Geometry, windup: number, release: number, point: Vector3, now: number): Pose
	local u = math.clamp((now - windup) / math.max(release - windup, 0.001), 0, 1)
	local follow = smooth((now - release) / Config.PitcherFollowSeconds)
	local recover = smooth((now - release - Config.PitcherFollowSeconds) / Config.PitcherRecoverySeconds)
	local stride = smooth((u - 0.4) / 0.55) * (1 - recover)
	local lift = math.sin(math.pi * math.clamp(u / 0.72, 0, 1)) * (1 - stride)
	local s = geo.units.toStuds
	local forward, side, up = -geo.toPitcher, geo.armSide, geo.up
	local ground = geo.pitcherGround
	local hip = ground + up * s(0.85) + forward * s(0.9 * stride)
	local chest = hip + up * s(0.52 - 0.14 * follow * (1 - recover)) + forward * s(0.25 * stride)
	local set = ground + up * s(1.25) + forward * s(0.25)
	local cocked = chest + side * s(0.55) - forward * s(0.35) + up * s(0.48)
	local hand: Vector3
	if u < 0.72 then
		hand = set:Lerp(cocked, smooth((u - 0.35) / 0.37))
	else
		hand = cocked:Lerp(point, ((u - 0.72) / 0.28) ^ 2)
	end
	if now >= release then
		local finish = hip - side * s(0.25) + forward * s(0.65) - up * s(0.12)
		hand = point:Lerp(finish, follow):Lerp(set, recover)
	end
	return {
		hip = hip,
		chest = chest,
		head = chest + up * s(0.34),
		hand = hand,
		glove = set:Lerp(chest - side * s(0.24) - up * s(0.2), stride),
		throwShoulder = chest + side * s(0.23),
		gloveShoulder = chest - side * s(0.23),
		leadFoot = ground - side * s(0.18) + forward * s(1.25 * stride) + up * s(0.6 * lift + 0.06),
		trailFoot = ground + side * s(0.18) + up * s(0.06),
		lift = lift,
		stride = stride,
		released = now >= release,
	}
end
return Motion
