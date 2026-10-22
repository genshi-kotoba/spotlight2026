extends Node
## Cross-module bridge. Map UI owns neither combat, rewards nor SeedService.
signal map_load_requested(snapshot: Dictionary, saved_state: Dictionary)
signal map_loaded(map_id: String, seed: String)
signal player_cell_entered(map_id: String, coordinate: Vector2i)
signal node_interaction_requested(request: Dictionary)
signal node_interaction_restored(request: Dictionary)
signal node_result_submitted(result: Dictionary)
signal node_interaction_resolved(request_id: String, node_id: String, status: String)
signal map_state_changed(map_id: String, saved_state: Dictionary)
signal boss_cleared(map_id: String, node_id: String)
