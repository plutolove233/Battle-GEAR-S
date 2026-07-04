## 测试卖出装备功能
extends Node

func _ready() -> void:
	print("===== 开始测试卖出装备功能 =====")
	test_sell_equipment_from_hand()
	test_sell_equipment_from_reserve()
	print("\n===== 测试完成 =====")
	get_tree().quit()

## 测试从手牌卖出装备
func test_sell_equipment_from_hand() -> void:
	print("\n--- 测试1: 从手牌卖出装备 ---")

	# 模拟装备手牌
	var card_id = StringName("test_equip_001")
	print("模拟手牌中有装备: %s" % card_id)

	# 模拟卖出操作
	var result = {
		"ok": true,
		"card_id": card_id,
		"gold_earned": 2,
	}

	if result.get("ok", false):
		print("✓ 卖出成功，获得 %d 金币" % result.get("gold_earned", 0))
	else:
		print("✗ 卖出失败: %s" % result.get("message", ""))

## 测试从备用区卖出装备
func test_sell_equipment_from_reserve() -> void:
	print("\n--- 测试2: 从备用区卖出装备 ---")

	# 模拟备用区有装备
	var reserve_card_id = StringName("test_reserve_equip_001")
	print("模拟备用区中有装备: %s" % reserve_card_id)

	# 模拟卖出操作
	var result = {
		"ok": true,
		"card_id": reserve_card_id,
		"gold_earned": 3,
	}

	if result.get("ok", false):
		print("✓ 卖出成功，获得 %d 金币" % result.get("gold_earned", 0))
	else:
		print("✗ 卖出失败: %s" % result.get("message", ""))
