--!strict
-- One visibility state for every debug section and drawing. Input may arrive
-- through both ContextActionService and UserInputService; latch the key edge
-- so handled-input fallback, repeats and duplicate callbacks toggle only once.
local Toggle = {}
export type State = { enabled: boolean, visible: boolean, pressed: boolean }

function Toggle.allowed(isStudio: boolean, enabled: boolean, enableInPublished: boolean): boolean
	return enabled and (isStudio or enableInPublished)
end

function Toggle.new(enabled: boolean): State
	return { enabled = enabled, visible = false, pressed = false }
end

function Toggle.input(state: State, down: boolean, typing: boolean): boolean
	local wasPressed = state.pressed
	state.pressed = down
	if not state.enabled or not down or wasPressed or typing then
		return false
	end
	state.visible = not state.visible
	return true
end

function Toggle.release(state: State)
	state.pressed = false -- key-up/cancel may be lost when Studio loses focus
end

return Toggle
