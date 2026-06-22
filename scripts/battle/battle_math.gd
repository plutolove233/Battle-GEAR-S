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
	var origin_key := HexGrid.key(origin)
	var target_key := HexGrid.key(target)
	if origin_key == target_key:
		return false
	var traversable := {}
	for tile in map_tiles:
		traversable[HexGrid.key(tile)] = true
	if not traversable.has(origin_key) or not traversable.has(target_key):
		return false
	var frontier: Array[Dictionary] = [origin]
	var costs := {origin_key: 0}
	var index := 0
	while index < frontier.size():
		var current := frontier[index]
		index += 1
		var current_cost := int(costs[HexGrid.key(current)])
		if current_cost >= available_power:
			continue
		for neighbor in HexGrid.neighbors(current):
			var neighbor_key := HexGrid.key(neighbor)
			if not traversable.has(neighbor_key) or costs.has(neighbor_key):
				continue
			var next_cost := current_cost + 1
			if neighbor_key == target_key:
				return next_cost <= available_power
			costs[neighbor_key] = next_cost
			frontier.append(neighbor)
	return false

static func make_log(message: String, details: Dictionary = {}) -> Dictionary:
	return {"message": message, "details": details.duplicate(true)}
