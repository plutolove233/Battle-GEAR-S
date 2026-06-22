extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")

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

func test_start_tutorial_sets_initial_units() -> bool:
	var battle := _new_battle()
	return battle.units.player.life == 25 and battle.units.enemy.position == {"q": 3, "r": 0}

func test_player_can_move_to_adjacent_hex() -> bool:
	var battle := _new_battle()
	var result := battle.move_unit("player", {"q": 1, "r": 0})
	return result.ok and battle.units.player.position == {"q": 1, "r": 0}

func test_player_attack_can_damage_enemy() -> bool:
	var battle := _new_battle()
	battle.move_unit("player", {"q": 1, "r": 0})
	var result := battle.attack("player", "enemy", 0)
	return result.ok and battle.units.enemy.life < 25

func test_enemy_turn_attacks_or_moves() -> bool:
	var battle := _new_battle()
	var before: Dictionary = battle.units.enemy.position.duplicate()
	var result := battle.run_enemy_turn()
	var after: Dictionary = battle.units.enemy.position
	return result.ok and (after != before or battle.units.player.life < 25)

func test_battle_result_reports_victory() -> bool:
	var battle := _new_battle()
	battle.units.enemy.life = 0
	return battle.get_result().state == "victory"
