--!strict
local CAS = game:GetService("ContextActionService")
local UIS = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Edge = require(Shared.Presentation.ActionInput)
local Binding = {}
local bound: { [string]: boolean } = {}
function Binding.bind(name: string, key: Enum.KeyCode, priority: number, relevant: () -> boolean, pressed: () -> ())
	if bound[name] then
		return
	end
	bound[name] = true
	local edge = Edge.new()
	local consumed = false
	local function input(down: boolean)
		if Edge.edge(edge, down, UIS:GetFocusedTextBox() ~= nil) and relevant() then
			consumed = true
			pressed()
		elseif not down then
			consumed = false
		end
	end
	CAS:BindActionAtPriority(name, function(_, state)
		local sink = UIS:GetFocusedTextBox() == nil and (consumed or relevant())
		if state == Enum.UserInputState.Begin then
			input(true)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			input(false)
		end
		return if sink then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, priority, key)
	-- Studio/CoreGui/PlayerModule processing is not a veto for these dedicated
	-- controls. Both delivery routes share one edge latch; typing remains exempt.
	UIS.InputBegan:Connect(function(event)
		if event.KeyCode == key then
			input(true)
		end
	end)
	UIS.InputEnded:Connect(function(event)
		if event.KeyCode == key then
			input(false)
		end
	end)
	UIS.WindowFocusReleased:Connect(function()
		Edge.release(edge)
		consumed = false
	end)
end
return Binding
