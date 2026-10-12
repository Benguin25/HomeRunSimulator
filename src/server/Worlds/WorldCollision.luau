--!strict
local CollectionService = game:GetService("CollectionService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.BattedBall.BattedBallConfig)
local Registry = require(script.Parent.WorldRegistry)
local Collision = {}
function Collision.params(laneId: string): RaycastParams
	local include: { Instance } = {}
	for _, root in Registry.collisionRoots(laneId) do
		local parts = root:GetDescendants()
		table.insert(parts, root)
		for _, part in parts do
			if not part:IsA("BasePart") or not part.CanCollide then
				continue
			end
			local ignored = false
			local ancestor: Instance? = part
			while ancestor and ancestor ~= workspace do
				if CollectionService:HasTag(ancestor, Config.Collision.IgnoreTag) then
					ignored = true
					break
				end
				ancestor = ancestor.Parent
			end
			if not ignored then
				table.insert(include, part)
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Include, include
	params.RespectCanCollide = Config.Collision.RespectCanCollide
	return params
end
return Collision
