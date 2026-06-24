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

func test_set_equipment_applies_part_stats() -> bool:
	var battle := _new_battle()
	var before_armor: int = battle.units.player.armor
	var before_power: int = battle.units.player.max_power
	var result := battle.set_equipment("player", "part_002_量产装_躯干")
	return result.ok \
		and battle.units.player.armor == before_armor + 3 \
		and battle.units.player.max_power == before_power + 2 \
		and not battle.units.player.equipment_hand.has("part_002_量产装_躯干")

func test_sell_equipment_adds_gold_and_removes_card() -> bool:
	var battle := _new_battle()
	var before_gold: int = battle.units.player.gold
	var result := battle.sell_equipment("player", "weapon_001_光束军刀")
	return result.ok \
		and battle.units.player.gold == before_gold + 3 \
		and not battle.units.player.equipment_hand.has("weapon_001_光束军刀")

func test_end_player_turn_refreshes_next_player_turn() -> bool:
	var battle := _new_battle()
	battle.move_unit("player", {"q": 1, "r": 0})
	var before_gold: int = battle.units.player.gold
	var result := battle.end_player_turn()
	return result.ok \
		and battle.active_side == "player" \
		and battle.turn_number == 2 \
		and battle.units.player.power == battle.units.player.max_power \
		and battle.units.player.gold == before_gold + 2

func test_start_tutorial_resets_existing_state() -> bool:
	var registry := DataRegistry.new()
	registry.load_all()
	var battle := BattleState.new()
	battle.start_tutorial(registry)
	battle.units.enemy.life = 0
	battle.turn_number = 6
	battle.active_side = "enemy"
	battle.log.append({"message": "stale"})
	var result := battle.start_tutorial(registry)
	return result.ok \
		and battle.turn_number == 1 \
		and battle.active_side == "player" \
		and battle.units.enemy.life == 25 \
		and battle.log.size() == 1

func test_move_rejects_invalid_or_uninitialized_side() -> bool:
	var battle := BattleState.new()
	var unstarted_result := battle.move_unit("player", {"q": 1, "r": 0})
	battle = _new_battle()
	var invalid_result := battle.move_unit("ally", {"q": 1, "r": 0})
	return not unstarted_result.ok \
		and unstarted_result.message == "battle is not started" \
		and not invalid_result.ok \
		and invalid_result.message == "side is invalid: ally"

func test_attack_rejects_invalid_side() -> bool:
	var battle := _new_battle()
	var attacker_result := battle.attack("ally", "enemy", 0)
	var defender_result := battle.attack("player", "ally", 0)
	return not attacker_result.ok \
		and attacker_result.message == "attacker side is invalid: ally" \
		and not defender_result.ok \
		and defender_result.message == "defender side is invalid: ally"

func test_attack_rejects_out_of_range_target() -> bool:
	var battle := _new_battle()
	var result := battle.attack("player", "enemy", 0)
	return not result.ok and result.message == "target is out of range"

func test_enemy_uses_pathfinding_around_blocker() -> bool:
	var battle := _new_battle()
	battle.map_tiles = HexGrid.generate_radius(4, [{"q": 2, "r": 0}])
	battle.units.enemy.position = {"q": 3, "r": 0}
	battle.units.enemy.power = 0
	var result := battle.run_enemy_turn()
	return result.ok and battle.units.enemy.position == {"q": 3, "r": -1}
