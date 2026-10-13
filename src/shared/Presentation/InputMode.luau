--!strict
-- Shared, pure cursor/input policy. A named set lets unrelated menus coordinate.
local Input = {}
local Config = require(script.Parent.Parent.Gameplay.BattingModeConfig)
export type State = { batting: boolean, leaving: boolean, menus: { [string]: boolean? }, resumeAt: number }
function Input.new(): State
	return { batting = false, leaving = false, menus = {}, resumeAt = 0 }
end
function Input.menu(state: State, name: string, opened: boolean, now: number)
	if (state.menus[name] == true) == opened then
		return
	end
	state.menus[name] = if opened then true else nil
	-- A menu-closing click cannot become a swing in a later input callback.
	state.resumeAt = math.max(state.resumeAt, now + Config.MenuResumeSeconds)
end
function Input.blocked(state: State): boolean
	return next(state.menus) ~= nil
end
function Input.canSwing(state: State, now: number, textFocused: boolean): boolean
	return state.batting
		and not state.leaving
		and not Input.blocked(state)
		and not textFocused
		and now >= state.resumeAt
end
function Input.cursor(state: State): boolean
	return not state.batting or state.leaving or Input.blocked(state)
end
return Input
