extends RefCounted
class_name BattleState

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")
const DataRegistry = preload("res://scripts/data/data_registry.gd")

var registry: DataRegistry
var config: Dictionary = {}
var map_tiles: Array[Dictionary] = []
var turn_number: int = 1
var active_side: String = "player"
var log: Array[Dictionary] = []
var units: Dictionary = {}

func start_tutorial(data_registry: DataRegistry) -> Dictionary:
	registry = data_registry
	config = registry.get_tutorial_battle()
	map_tiles = []
	turn_number = 1
	active_side = "player"
	log = []
	units = {}
	if config.is_empty():
		return {"ok": false, "message": "tutorial battle config is missing"}
	map_tiles = HexGrid.generate_radius(int(config.map.radius), config.map.get("blocked", []))
	units = {
		"player": _make_unit("player", config.player_frame_id, config.player_start),
		"enemy": _make_unit("enemy", config.enemy_frame_id, config.enemy_start),
	}
	_draw_starting_cards("player")
	_draw_starting_cards("enemy")
	log.append(BattleMath.make_log("战斗开始", {"battle": config.name}))
	return {"ok": true, "message": "started"}

func _make_unit(side: String, frame_id: String, position: Dictionary) -> Dictionary:
	var frame := registry.get_mech_frame(frame_id)
	var armor := 0
	var power := 0
	for slot in frame.get("base_slots", {}).values():
		armor += int(slot.get("armor", 0))
		power += int(slot.get("power", 0))
	return {
		"side": side,
		"frame_id": frame_id,
		"name": frame.get("name", side),
		"position": _copy_hex(position),
		"life": int(frame.get("life", 25)),
		"max_life": int(frame.get("life", 25)),
		"armor": armor,
		"power": power,
		"max_power": power,
		"gold": 20,
		"hand": [],
		"equipment_hand": config.get("starting_equipment_pool", []).duplicate(),
		"weapons": frame.get("base_weapons", []).duplicate(true),
		"damage_markers": {},
	}

func _draw_starting_cards(side: String) -> void:
	var deck: Array = config.get("starting_action_deck", []).duplicate()
	units[side].hand = deck.slice(0, mini(4, deck.size()))

func _copy_hex(hex: Dictionary) -> Dictionary:
	return {"q": int(hex.get("q", 0)), "r": int(hex.get("r", 0))}

func _validate_side(side: String) -> Dictionary:
	return _validate_labeled_side(side, "side")

func _validate_labeled_side(side: String, label: String) -> Dictionary:
	if units.is_empty():
		return {"ok": false, "message": "battle is not started"}
	if not units.has(side):
		return {"ok": false, "message": "%s is invalid: %s" % [label, side]}
	return {"ok": true, "message": "valid"}

func start_turn(side: String) -> Dictionary:
	var validation := _validate_side(side)
	if not validation.ok:
		return validation
	active_side = side
	units[side].power = units[side].max_power
	units[side].gold += 2
	log.append(BattleMath.make_log("%s 回合开始" % units[side].name, {"side": side, "turn": turn_number}))
	return {"ok": true, "message": "turn_started"}

func move_unit(side: String, target: Dictionary) -> Dictionary:
	var validation := _validate_side(side)
	if not validation.ok:
		return validation
	var unit: Dictionary = units[side]
	if not BattleMath.can_move(unit.position, target, int(unit.power), map_tiles):
		return {"ok": false, "message": "target is not reachable"}
	var cost := HexGrid.distance(unit.position, target)
	unit.position = _copy_hex(target)
	unit.power -= cost
	log.append(BattleMath.make_log("%s 移动" % unit.name, {"to": target, "cost": cost}))
	return {"ok": true, "message": "moved"}

func set_equipment(side: String, equipment_id: String) -> Dictionary:
	var validation := _validate_side(side)
	if not validation.ok:
		return validation
	var unit: Dictionary = units[side]
	if not unit.equipment_hand.has(equipment_id):
		return {"ok": false, "message": "equipment is not in hand"}
	var part := registry.get_equipment_part(equipment_id)
	var weapon := registry.get_weapon(equipment_id)
	if not part.is_empty():
		unit.armor += int(part.armor)
		unit.max_power += int(part.power)
		unit.power += int(part.power)
		unit.equipment_hand.erase(equipment_id)
		log.append(BattleMath.make_log("%s 设置装备 %s" % [unit.name, part.set_name], {"slot": part.slot}))
		return {"ok": true, "message": "part_set"}
	if not weapon.is_empty():
		unit.weapons.append({
			"name": weapon.name,
			"weapon_type": weapon.weapon_type,
			"damage": weapon.damage,
			"range": weapon.range,
		})
		unit.equipment_hand.erase(equipment_id)
		log.append(BattleMath.make_log("%s 设置武器 %s" % [unit.name, weapon.name]))
		return {"ok": true, "message": "weapon_set"}
	return {"ok": false, "message": "equipment data is missing"}

func sell_equipment(side: String, equipment_id: String) -> Dictionary:
	var validation := _validate_side(side)
	if not validation.ok:
		return validation
	var unit: Dictionary = units[side]
	if not unit.equipment_hand.has(equipment_id):
		return {"ok": false, "message": "equipment is not in hand"}
	var data := registry.get_equipment_part(equipment_id)
	if data.is_empty():
		data = registry.get_weapon(equipment_id)
	if data.is_empty():
		return {"ok": false, "message": "equipment data is missing"}
	unit.gold += int(data.get("cost", 0))
	unit.equipment_hand.erase(equipment_id)
	log.append(BattleMath.make_log("%s 卖出装备" % unit.name, {"equipment_id": equipment_id}))
	return {"ok": true, "message": "sold"}

func attack(attacker_side: String, defender_side: String, weapon_index: int) -> Dictionary:
	var attacker_validation := _validate_labeled_side(attacker_side, "attacker side")
	if not attacker_validation.ok:
		return attacker_validation
	var defender_validation := _validate_labeled_side(defender_side, "defender side")
	if not defender_validation.ok:
		return defender_validation
	var attacker: Dictionary = units[attacker_side]
	var defender: Dictionary = units[defender_side]
	if weapon_index < 0 or weapon_index >= attacker.weapons.size():
		return {"ok": false, "message": "weapon index is invalid"}
	var weapon: Dictionary = attacker.weapons[weapon_index]
	if not BattleMath.is_in_range(attacker.position, defender.position, int(weapon.range)):
		return {"ok": false, "message": "target is out of range"}
	var result := BattleMath.calculate_attack(int(weapon.damage), int(defender.armor))
	defender.life = maxi(0, int(defender.life) - int(result.damage))
	_add_damage_markers(defender, "躯干", int(result.markers))
	log.append(BattleMath.make_log("%s 攻击 %s" % [attacker.name, defender.name], {
		"weapon": weapon.name,
		"damage": result.damage,
		"markers": result.markers,
	}))
	return {"ok": true, "message": "attacked", "damage": result.damage, "markers": result.markers}

func _add_damage_markers(unit: Dictionary, slot: String, amount: int) -> void:
	unit.damage_markers[slot] = int(unit.damage_markers.get(slot, 0)) + amount

func run_enemy_turn() -> Dictionary:
	var enemy_validation := _validate_labeled_side("enemy", "enemy side")
	if not enemy_validation.ok:
		return enemy_validation
	var player_validation := _validate_labeled_side("player", "player side")
	if not player_validation.ok:
		return player_validation
	var start_result := start_turn("enemy")
	if not start_result.ok:
		return start_result
	var attack_result := attack("enemy", "player", 0)
	if attack_result.ok:
		_end_turn("enemy")
		return {"ok": true, "message": "enemy_attacked"}
	var enemy: Dictionary = units.enemy
	var player: Dictionary = units.player
	var best := _find_first_step_toward(enemy.position, player.position, int(enemy.power))
	if best != enemy.position:
		move_unit("enemy", best)
	_end_turn("enemy")
	return {"ok": true, "message": "enemy_moved_or_waited"}

func _find_first_step_toward(origin: Dictionary, target: Dictionary, available_power: int) -> Dictionary:
	if available_power <= 0:
		return _copy_hex(origin)
	var origin_key := HexGrid.key(origin)
	var target_key := HexGrid.key(target)
	if origin_key == target_key:
		return _copy_hex(origin)
	var traversable := {}
	for tile in map_tiles:
		traversable[HexGrid.key(tile)] = _copy_hex(tile)
	if not traversable.has(origin_key) or not traversable.has(target_key):
		return _copy_hex(origin)
	var frontier: Array[Dictionary] = [_copy_hex(origin)]
	var came_from := {origin_key: ""}
	var index := 0
	while index < frontier.size():
		var current := frontier[index]
		index += 1
		var current_key := HexGrid.key(current)
		if current_key == target_key:
			break
		for neighbor in HexGrid.neighbors(current):
			var neighbor_key := HexGrid.key(neighbor)
			if not traversable.has(neighbor_key) or came_from.has(neighbor_key):
				continue
			came_from[neighbor_key] = current_key
			frontier.append(_copy_hex(neighbor))
	if not came_from.has(target_key):
		return _copy_hex(origin)
	var step_key := target_key
	var previous_key := String(came_from[step_key])
	while previous_key != origin_key:
		step_key = previous_key
		previous_key = String(came_from[step_key])
	return traversable.get(step_key, _copy_hex(origin)).duplicate()

func end_player_turn() -> Dictionary:
	var player_validation := _validate_labeled_side("player", "player side")
	if not player_validation.ok:
		return player_validation
	var enemy_validation := _validate_labeled_side("enemy", "enemy side")
	if not enemy_validation.ok:
		return enemy_validation
	_end_turn("player")
	if get_result().state == "active":
		var enemy_result := run_enemy_turn()
		if not enemy_result.ok:
			return enemy_result
		if get_result().state == "active":
			var player_start_result := start_turn("player")
			if not player_start_result.ok:
				return player_start_result
			return {"ok": true, "message": "player_turn_started"}
		return enemy_result
	return {"ok": true, "message": "player_turn_ended"}

func _end_turn(side: String) -> void:
	log.append(BattleMath.make_log("%s 回合结束" % units[side].name, {"side": side}))
	if side == "enemy":
		turn_number += 1
		active_side = "player"
	else:
		active_side = "enemy"

func get_result() -> Dictionary:
	if units.is_empty() or not units.has("player") or not units.has("enemy"):
		return {"state": "inactive", "reason": "battle is not started"}
	if int(units.enemy.life) <= 0:
		return {"state": "victory", "reason": "敌方机甲毁灭"}
	if int(units.player.life) <= 0:
		return {"state": "defeat", "reason": "我方机甲毁灭"}
	if turn_number > int(config.get("turn_limit", 12)):
		return {"state": "defeat", "reason": "超过回合限制"}
	return {"state": "active", "reason": ""}
