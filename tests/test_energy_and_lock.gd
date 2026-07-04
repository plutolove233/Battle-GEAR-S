## 测试聚能和锁定状态
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const CardInstance = preload("res://scripts/runtime/CardInstance.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
		return null
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
		return null
	return battle


## 测试1：聚能效果是否正确添加到mech.statuses
func test_energy_buff_added_to_mech() -> bool:
	print("=== 测试1：聚能效果是否正确添加到mech.statuses ===")
	var battle = _new_battle()
	if battle == null:
		return "创建战斗失败"

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")

	# 先装备一个武器
	var weapon_def = battle.context.card_database.get_card(&"E_001")
	if weapon_def == null:
		return "找不到武器卡E_001"

	var weapon_id: StringName = gs.next_id("test_weapon")
	var weapon_card := CardInstance.new(weapon_id, weapon_def)
	weapon_card.owner_player_id = &"player"
	weapon_card.mech_id = player_mech.mech_id
	weapon_card.zone = &"weapon_slot"
	weapon_card.slot_id = &"weapon_1"
	gs.cards[weapon_id] = weapon_card
	player_mech.slots[&"weapon_1"].equipped_card = weapon_card

	# 模拟聚能效果：直接调用 apply_energy_to_weapon
	battle.context.game_actions.apply_energy_to_weapon({
		"source_mech_id": player_mech.mech_id,
		"selected_weapon_id": &"weapon_1",
		"delta": 4
	})

	# 检查mech是否添加了状态
	var has_status := false
	var status_count := 0
	for s in player_mech.statuses:
		if s.get("type", &"") == &"NEXT_ATTACK_POWER_BUFF":
			has_status = true
			status_count += 1
			print("  找到状态: type=%s, weapon_id=%s, delta=%d" % [s.get("type"), s.get("weapon_id"), s.get("delta")])

	if not has_status:
		return "聚能后mech.statuses中没有NEXT_ATTACK_POWER_BUFF状态"

	print("  测试通过: 找到 %d 个聚能状态" % status_count)
	return true


## 测试2：多次聚能效果叠加
func test_energy_buff叠加() -> bool:
	print("=== 测试2：多次聚能效果叠加 ===")
	var battle = _new_battle()
	if battle == null:
		return "创建战斗失败"

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")

	# 装备武器
	var weapon_def = battle.context.card_database.get_card(&"E_001")
	var weapon_id: StringName = gs.next_id("test_weapon")
	var weapon_card := CardInstance.new(weapon_id, weapon_def)
	weapon_card.owner_player_id = &"player"
	weapon_card.mech_id = player_mech.mech_id
	weapon_card.zone = &"weapon_slot"
	weapon_card.slot_id = &"weapon_1"
	gs.cards[weapon_id] = weapon_card
	player_mech.slots[&"weapon_1"].equipped_card = weapon_card

	# 连续使用3次聚能
	for i in range(3):
		battle.context.game_actions.apply_energy_to_weapon({
			"source_mech_id": player_mech.mech_id,
			"selected_weapon_id": &"weapon_1",
			"delta": 4
		})

	# 统计weapon_1上的聚能状态数量
	var energy_count := 0
	for s in player_mech.statuses:
		if s.get("type", &"") == &"NEXT_ATTACK_POWER_BUFF" and s.get("weapon_id", &"") == &"weapon_1":
			energy_count += 1
			print("  状态%d: delta=%d" % [energy_count, s.get("delta")])

	if energy_count != 3:
		return "预期3个聚能状态，实际%d个" % energy_count

	print("  测试通过: 叠加了 %d 个聚能状态" % energy_count)
	return true


## 测试3：锁定效果
func test_locked_effect() -> bool:
	print("=== 测试3：锁定效果 ===")
	var battle = _new_battle()
	if battle == null:
		return "创建战斗失败"

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 模拟锁定效果
	player_mech.add_status({
		"status_id": gs.next_id("status"),
		"type": &"LOCKED",
		"duration": &"THIS_TURN",
		"source_player_id": &"enemy"
	})

	# 检查锁定状态
	if not player_mech.has_status(&"LOCKED"):
		return "添加LOCKED状态后has_status返回false"

	if not player_mech.has_status(&"LOCKED"):
		return "锁定状态添加失败"

	# 测试get_status_count
	var lock_count := player_mech.get_status_count(&"LOCKED")
	if lock_count != 1:
		return "锁定状态数量应为1，实际为%d" % lock_count

	print("  测试通过: 锁定状态正确添加")
	return true


## 测试4：_get_weapon_energy_buff_count 方法
func test_get_weapon_energy_buff_count() -> bool:
	print("=== 测试4：_get_weapon_energy_buff_count 方法 ===")
	var battle = _new_battle()
	if battle == null:
		return "创建战斗失败"

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")

	# 装备武器
	var weapon_def = battle.context.card_database.get_card(&"E_001")
	var weapon_id: StringName = gs.next_id("test_weapon")
	var weapon_card := CardInstance.new(weapon_id, weapon_def)
	weapon_card.owner_player_id = &"player"
	weapon_card.mech_id = player_mech.mech_id
	weapon_card.zone = &"weapon_slot"
	weapon_card.slot_id = &"weapon_1"
	gs.cards[weapon_id] = weapon_card
	player_mech.slots[&"weapon_1"].equipped_card = weapon_card

	# 添加聚能状态
	battle.context.game_actions.apply_energy_to_weapon({
		"source_mech_id": player_mech.mech_id,
		"selected_weapon_id": &"weapon_1",
		"delta": 4
	})
	battle.context.game_actions.apply_energy_to_weapon({
		"source_mech_id": player_mech.mech_id,
		"selected_weapon_id": &"weapon_1",
		"delta": 4
	})

	# 手动测试_get_weapon_energy_buff_count的逻辑
	var count := 0
	for s in player_mech.statuses:
		if s.get("type", &"") == &"NEXT_ATTACK_POWER_BUFF":
			if s.get("weapon_id", &"") == &"weapon_1":
				count += 1

	print("  weapon_1上的聚能状态数量: %d" % count)

	if count != 2:
		return "预期2个聚能状态，实际%d个" % count

	print("  测试通过")
	return true


func run_all_tests() -> void:
	print("========== 运行聚能/锁定状态测试 ==========")

	var results := []

	results.append(["test_energy_buff_added_to_mech", test_energy_buff_added_to_mech()])
	results.append(["test_energy_buff叠加", test_energy_buff叠加()])
	results.append(["test_locked_effect", test_locked_effect()])
	results.append(["test_get_weapon_energy_buff_count", test_get_weapon_energy_buff_count()])

	print("\n========== 测试结果 ==========")
	var passed := 0
	var failed := 0
	for r in results:
		var name := r[0]
		var result = r[1]
		if result == true:
			print("[PASS] %s" % name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [name, result])
			failed += 1

	print("\n总计: %d 通过, %d 失败" % [passed, failed])
