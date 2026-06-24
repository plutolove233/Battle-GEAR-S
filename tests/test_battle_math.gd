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

func test_is_in_range_allows_exact_range() -> bool:
	return BattleMath.is_in_range({"q": 0, "r": 0}, {"q": 2, "r": -1}, 2)

func test_is_in_range_rejects_out_of_range() -> bool:
	return not BattleMath.is_in_range({"q": 0, "r": 0}, {"q": 2, "r": -1}, 1)

func test_can_move_rejects_insufficient_power() -> bool:
	var tiles := HexGrid.generate_radius(2, [])
	return not BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -1}, 1, tiles)

func test_can_move_rejects_zero_distance() -> bool:
	var tiles := HexGrid.generate_radius(1, [])
	return not BattleMath.can_move({"q": 0, "r": 0}, {"q": 0, "r": 0}, 1, tiles)

func test_can_move_rejects_missing_destination() -> bool:
	var tiles := HexGrid.generate_radius(1, [{"q": 1, "r": 0}])
	return not BattleMath.can_move({"q": 0, "r": 0}, {"q": 1, "r": 0}, 1, tiles)

func test_can_move_rejects_missing_origin() -> bool:
	var tiles := HexGrid.generate_radius(1, [{"q": 0, "r": 0}])
	return not BattleMath.can_move({"q": 0, "r": 0}, {"q": 1, "r": 0}, 1, tiles)

func test_can_move_rejects_blocked_direct_route() -> bool:
	var tiles := HexGrid.generate_radius(3, [{"q": 1, "r": -1}])
	return not BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -2}, 2, tiles)

func test_can_move_allows_route_around_blocker_with_enough_power() -> bool:
	var tiles := HexGrid.generate_radius(3, [{"q": 1, "r": -1}])
	return BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -2}, 3, tiles)

func test_make_log_snapshots_details() -> bool:
	var details := {"target": {"armor": 4}}
	var log := BattleMath.make_log("hit", details)
	details.target.armor = 9
	return log.details.target.armor == 4
