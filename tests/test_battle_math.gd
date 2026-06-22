extends RefCounted

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")

func test_hex_distance_uses_axial_coordinates() -> bool:
	return HexGrid.distance({"q": 0, "r": 0}, {"q": 2, "r": -1}) == 2

func test_neighbors_returns_six_adjacent_hexes() -> bool:
	var neighbors := HexGrid.neighbors({"q": 0, "r": 0})
	return neighbors.size() == 6 and neighbors.has({"q": 1, "r": 0}) and neighbors.has({"q": 0, "r": -1})

func test_generate_radius_skips_blocked_tiles() -> bool:
	var tiles := HexGrid.generate_radius(1, [{"q": 1, "r": 0}])
	return tiles.size() == 6 and not tiles.has({"q": 1, "r": 0})

func test_damage_minimum_zero_after_armor() -> bool:
	var result := BattleMath.calculate_attack(10, 14)
	return result.damage == 0 and result.markers == 2

func test_damage_markers_round_down_by_five_power() -> bool:
	var result := BattleMath.calculate_attack(12, 3)
	return result.damage == 9 and result.markers == 2
