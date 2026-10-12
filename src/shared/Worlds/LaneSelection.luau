--!strict
-- Selection is pure; caller reserves and releases without yielding.
local Selection = {}
function Selection.free<T>(
	ids: { string },
	occupied: { [string]: T },
	worldFor: (string) -> string?,
	worldId: string
): string?
	for _, id in ids do
		if occupied[id] == nil and worldFor(id) == worldId then
			return id
		end
	end
	return nil
end
return Selection
