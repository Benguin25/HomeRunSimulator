--!strict
local Style = {}
Style.Colors = {
	panel = Color3.fromRGB(14, 18, 28),
	text = Color3.fromRGB(245, 247, 255),
	muted = Color3.fromRGB(170, 178, 196),
	gold = Color3.fromRGB(255, 205, 64),
}
function Style.corner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, radius), parent
end
return Style
