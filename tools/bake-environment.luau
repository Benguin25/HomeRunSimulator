--!nocheck
-- Studio Edit Command Bar only, after connecting Rojo to the authored place.
-- Save a local place backup first. This tool never saves/publishes a place.
return require(game.ReplicatedStorage.Shared.Environment.EnvironmentBaker).bake()
-- Individual region: .bake("downtown") (stable RegionMap id).
-- Rollback: require(game.ReplicatedStorage.Shared.Environment.EnvironmentBaker).rollback()
