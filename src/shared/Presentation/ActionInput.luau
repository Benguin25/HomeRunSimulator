--!strict
-- Shared key-edge policy for priority actions and processed-input fallbacks.
local Input = {}
export type State = { pressed: boolean }
function Input.new(): State
	return { pressed = false }
end
function Input.edge(state: State, down: boolean, typing: boolean): boolean
	local previous = state.pressed
	state.pressed = down
	return down and not previous and not typing
end
function Input.release(state: State)
	state.pressed = false
end
function Input.distinct(key: string, blocked: { string }): boolean
	if key == "None" or key == "Escape" then
		return false
	end
	for _, value in blocked do
		if key == value then
			return false
		end
	end
	return true
end
return Input
