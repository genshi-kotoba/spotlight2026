class_name MapTile
extends RefCounted

## 单格数据。纯数据，不持有节点，不引用场景。

var coord: Vector2i
var height: int = 1
var terrain: int = MapTerrain.Terrain.PLAIN


func _init(p_coord: Vector2i = Vector2i.ZERO, p_height: int = 1, p_terrain: int = MapTerrain.Terrain.PLAIN) -> void:
	coord = p_coord
	height = p_height
	terrain = p_terrain


func is_passable() -> bool:
	return MapTerrain.is_passable(terrain)
