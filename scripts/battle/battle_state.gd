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

func start_turn(side: String) -> Dictionary:
	active_side = side
	units[side].power = units[side].max_power
	units[side].gold += 2
	log.append(BattleMath.make_log("%s 回合开始" % units[side].name, {"side": side, "turn": turn_number}))
	return {"ok": true, "message": "turn_started"}

func move_unit(side: String, target: Dictionary) -> Dictionary:
	var unit: Dictionary = units[side]
	if not BattleMath.can_move(unit.position, target, int(unit.power), map_tiles):
		return {"ok": false, "message": "target is not reachable"}
	var cost := HexGrid.distance(unit.position, target)
	unit.position = _copy_hex(target)
	unit.power -= cost
	log.append(BattleMath.make_log("%s 移动" % unit.name, {"to": target, "cost": cost}))
	return {"ok": true, "message": "moved"}

func set_equipment(side: String, equipment_id: String) -> Dictionary:
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
	start_turn("enemy")
	var attack_result := attack("enemy", "player", 0)
	if attack_result.ok:
		_end_turn("enemy")
		return {"ok": true, "message": "enemy_attacked"}
	var enemy: Dictionary = units.enemy
	var player: Dictionary = units.player
	var best: Dictionary = enemy.position
	var best_distance := HexGrid.distance(enemy.position, player.position)
	for neighbor in HexGrid.neighbors(enemy.position):
		if not BattleMath.can_move(enemy.position, neighbor, int(enemy.power), map_tiles):
			continue
		var distance := HexGrid.distance(neighbor, player.position)
		if distance < best_distance:
			best = neighbor
			best_distance = distance
	if best != enemy.position:
		move_unit("enemy", best)
	_end_turn("enemy")
	return {"ok": true, "message": "enemy_moved_or_waited"}

func end_player_turn() -> Dictionary:
	_end_turn("player")
	if get_result().state == "active":
		return run_enemy_turn()
	return {"ok": true, "message": "player_turn_ended"}

func _end_turn(side: String) -> void:
	log.append(BattleMath.make_log("%s 回合结束" % units[side].name, {"side": side}))
	if side == "enemy":
		turn_number += 1
		active_side = "player"
	else:
		active_side = "enemy"

func get_result() -> Dictionary:
	if int(units.enemy.life) <= 0:
		return {"state": "victory", "reason": "敌方机甲毁灭"}
	if int(units.player.life) <= 0:
		return {"state": "defeat", "reason": "我方机甲毁灭"}
	if turn_number > int(config.get("turn_limit", 12)):
		return {"state": "defeat", "reason": "超过回合限制"}
	return {"state": "active", "reason": ""}
