extends RefCounted

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")

func test_hex_distance_uses_oddq_coordinates() -> bool:
	# odd-q offset: (0,0) 与 (2,-1) 的距离仍为 2
	return HexGrid.distance({"q": 0, "r": 0}, {"q": 2, "r": -1}) == 2

func test_neighbors_returns_six_adjacent_hexes() -> bool:
	var neighbors := HexGrid.neighbors({"q": 0, "r": 0})
	# 偶数列(0)邻居含(0,-1)上 与(0,1)下，共6个
	return neighbors.size() == 6 and neighbors.has({"q": 0, "r": -1}) and neighbors.has({"q": 0, "r": 1})

func test_neighbors_odd_column_matches_screen() -> bool:
	# (17,-6) 为奇数列，屏幕邻居应含左下(16,-4)与右下(18,-5)
	var neighbors := HexGrid.neighbors({"q": 17, "r": -6})
	return neighbors.size() == 6 and neighbors.has({"q": 16, "r": -4}) and neighbors.has({"q": 18, "r": -5}) and not neighbors.has({"q": 16, "r": -6})

func test_distance_oddq_neighbor_is_one() -> bool:
	# (17,-6) 的屏幕邻居(16,-4)在 odd-q 下距离=1
	return HexGrid.distance({"q": 17, "r": -6}, {"q": 16, "r": -4}) == 1

func test_generate_radius_skips_blocked_tiles() -> bool:
	# odd-q 下 (1,-1) 是 (0,0) 的邻居，block 它后 radius1 圆剩6格
	var tiles := HexGrid.generate_radius(1, [{"q": 1, "r": -1}])
	return tiles.size() == 6 and not tiles.has({"q": 1, "r": -1})

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
	var result: Dictionary = BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -1}, 1, tiles)
	return not result.get("ok", false)

func test_can_move_rejects_zero_distance() -> bool:
	var tiles := HexGrid.generate_radius(1, [])
	var result: Dictionary = BattleMath.can_move({"q": 0, "r": 0}, {"q": 0, "r": 0}, 1, tiles)
	return not result.get("ok", false)

func test_can_move_rejects_missing_destination() -> bool:
	# (1,-1) 是 (0,0) 邻居但被 block，目标设为它则不可达
	var tiles := HexGrid.generate_radius(1, [{"q": 1, "r": -1}])
	var result: Dictionary = BattleMath.can_move({"q": 0, "r": 0}, {"q": 1, "r": -1}, 1, tiles)
	return not result.get("ok", false)

func test_can_move_rejects_blocked_direct_route() -> bool:
	# odd-q 下 (0,0)→(2,-2) 的直路邻居 (1,-2) 被 block，power=2 刚够直路→不可达
	var tiles := HexGrid.generate_radius(3, [{"q": 1, "r": -2}])
	var result: Dictionary = BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -2}, 2, tiles)
	return not result.get("ok", false)

func test_can_move_allows_route_around_blocker_with_enough_power() -> bool:
	# 同上，power=3 可绕路→可达
	var tiles := HexGrid.generate_radius(3, [{"q": 1, "r": -2}])
	var result: Dictionary = BattleMath.can_move({"q": 0, "r": 0}, {"q": 2, "r": -2}, 3, tiles)
	return result.get("ok", false)

func test_make_log_snapshots_details() -> bool:
	var details := {"target": {"armor": 4}}
	var log := BattleMath.make_log("hit", details)
	details.target.armor = 9
	return log.details.target.armor == 4  # 返回 bool
