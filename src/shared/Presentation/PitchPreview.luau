--!strict
local Pitching = script.Parent.Parent.Pitching
local Geometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local Physics = require(Pitching.PitchPhysics)
local Swing = require(script.Parent.Parent.Batting.SwingModel)
local Toggle = require(script.Parent.DebugToggle)
local Preview = {}
export type Target = {
	laneId: string,
	pitchId: number,
	position: Vector3,
	crossTime: number,
	expiresAt: number,
	predictedCut: number?,
	confirmedCut: number?,
}
export type State = { toggle: Toggle.State, laneId: string?, lastPitch: number, target: Target? }
function Preview.allowed(isStudio: boolean, enabled: boolean): boolean
	return isStudio and enabled -- no published-player opt-in exists for pitch assistance
end
function Preview.new(enabled: boolean): State
	return { toggle = Toggle.new(enabled), laneId = nil, lastPitch = 0, target = nil }
end
function Preview.setLane(state: State, laneId: string?)
	if state.laneId ~= laneId then
		state.target, state.lastPitch = nil, 0
	end
	state.laneId = laneId
end
function Preview.begin(state: State, geometry: Geometry.Geometry, flight: Pitch.Flight): boolean
	local data = flight.data
	if not state.toggle.enabled or data.laneId ~= state.laneId or data.id <= state.lastPitch then
		return false
	end
	state.lastPitch, state.target = data.id, nil
	local crossing = Physics.findPlaneCrossing(flight.trajectory, Swing.contactPlane(geometry))
	if crossing then
		state.target = {
			laneId = data.laneId,
			pitchId = data.id,
			position = crossing.position,
			crossTime = data.releaseTime + crossing.time,
			expiresAt = data.releaseTime + flight.endTime,
		}
	end
	return true
end
function Preview.cut(state: State, laneId: string, pitchId: number, atTime: number, confirmed: boolean)
	local target = state.target
	if confirmed and laneId == state.laneId and pitchId > state.lastPitch then
		-- A terminal event can beat the asynchronously delivered start listener.
		state.lastPitch, state.target = pitchId, nil
		return
	end
	if target and target.laneId == laneId and target.pitchId == pitchId then
		if confirmed then
			target.confirmedCut = atTime
		else
			target.predictedCut = atTime
		end
	end
end
function Preview.uncut(state: State, laneId: string, pitchId: number)
	local target = state.target
	if target and target.laneId == laneId and target.pitchId == pitchId then
		target.predictedCut = nil
	end
end
function Preview.finish(state: State, laneId: string, pitchId: number)
	if state.laneId == laneId and pitchId >= state.lastPitch then
		state.lastPitch, state.target = pitchId, nil
	end
end
function Preview.position(state: State, now: number, batting: boolean): Vector3?
	local target = state.target
	if not target then
		return nil
	end
	if now >= target.expiresAt or (target.confirmedCut and now >= target.confirmedCut) then
		state.target = nil
		return nil
	end
	if not state.toggle.visible or not batting or (target.predictedCut and now >= target.predictedCut) then
		return nil
	end
	return target.position
end
return Preview
