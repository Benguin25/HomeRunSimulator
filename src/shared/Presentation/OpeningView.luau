--!strict
-- Conservative home-plate coverage, including distant silhouettes in the view.
local View = {}
function View.includes(frame: CFrame, cf: CFrame, size: Vector3, radius: number, halfAngle: number): boolean
	local delta = cf.Position - frame.Position
	local bound = size.Magnitude / 2
	if delta.Magnitude - bound <= radius then
		return true
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude <= bound then
		return true
	end
	local forward = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z).Unit
	local angle = math.acos(math.clamp(flat.Unit:Dot(forward), -1, 1))
	local extent = math.asin(math.clamp(bound / flat.Magnitude, 0, 1))
	return angle - extent <= math.rad(halfAngle)
end
return View
