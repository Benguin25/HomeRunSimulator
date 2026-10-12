--!strict
local Stats = require(script.Parent.SessionStats)
local Gate = require(script.Parent.ReturnGate)
local Net = {
	RuntimeFolder = "GameplayRuntime",
	Event = "Update",
	Request = "Request",
	GetSnapshot = "GetSnapshot",
}
export type Loop = {
	laneId: string,
	epoch: number,
	hitId: number,
	pitchId: number,
	phase: Gate.Phase,
	characterReady: boolean,
	cameraReady: boolean,
	pitchReady: boolean,
	notBefore: number,
	rejection: string,
}
export type Snapshot = { version: number, stats: Stats.Snapshot, loop: Loop?, rejection: string? }
return Net
