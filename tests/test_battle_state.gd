extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const HexGrid = preload("res://scripts/battle/hex_grid.gd")

func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func test_player_can_move_to_adjacent_hex() -> bool:
	var battle: BattleState = _new_battle()
	# 玩家起始位置 q=2, r=2，移动到相邻格
	var result: Dictionary = battle.move_unit("player", {"q": 3, "r": 2})
	return result.get("ok", false) and battle.units.player.position == {"q": 3, "r": 2}
