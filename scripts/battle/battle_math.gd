extends RefCounted
class_name BattleMath

const HexGrid = preload("res://scripts/battle/hex_grid.gd")

static func calculate_attack(attack_power: int, target_armor: int) -> Dictionary:
	var damage = max(0, attack_power - target_armor)
	var markers = int(floor(float(attack_power) / 5.0))
	return {"damage": damage, "markers": markers}

static func is_in_range(origin: Dictionary, target: Dictionary, weapon_range: int) -> bool:
	return HexGrid.distance(origin, target) <= weapon_range

static func can_move(origin: Dictionary, target: Dictionary, available_power: int, map_tiles: Array) -> bool:
	if not HexGrid.contains_hex(map_tiles, target):
		return false
	var cost := HexGrid.distance(origin, target)
	return cost > 0 and cost <= available_power

static func make_log(message: String, details: Dictionary = {}) -> Dictionary:
	return {"message": message, "details": details}
