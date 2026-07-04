## MechState.gd — 机甲运行时状态
##
## 机甲是玩家的战斗主体，由框架定义、6个部件槽位、2个武器槽位、
## 备用区域、事件区域和机师区域组成。
class_name MechState
extends RefCounted

const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _MechFrameDef = preload("res://scripts/card_defs/MechFrameDef.gd")

## 机甲唯一 ID
var mech_id: StringName = &""

## 所属玩家 ID
var owner_player_id: StringName = &""

## 框架定义
var frame_def = null

## 基础武器数据（从框架继承，不作为卡牌存在）
## 结构: Array[Dictionary]，索引0对应weapon_1，索引1对应weapon_2
## 结构: {name: String, might: int, range_value: int, weapon_kind: StringName}
var base_weapons: Array[Dictionary] = []

## 当前生命值
var current_hp: int = 25

## 最大生命值
var max_hp: int = 25

## 当前动力
var power: int = 0

## 最大动力（回合开始回复到此值）
var max_power: int = 0

## 六边形网格坐标 {"q": int, "r": int}
var position: Dictionary = {"q": 0, "r": 0}

## 槽位状态字典：slot_id → MechSlotState
var slots: Dictionary = {}

## 状态效果列表（锁定/不能攻击/不能移动等）
var statuses: Array[Dictionary] = []

## 本回合已攻击次数
var attack_count_this_turn: int = 0

## 每回合最大攻击次数（由机师牌决定）
var max_attacks_per_turn: int = 1

## 是否已被摧毁
var destroyed: bool = false


## ── 查询方法 ──


## 获取总护甲 = 所有部件槽位 effective_armor 之和
func get_armor() -> int:
	var total: int = 0
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		if slots.has(slot_id):
			total += slots[slot_id].get_effective_armor()
	return total


## 获取总动力 = 所有部件槽位 effective_power 之和
func get_total_power() -> int:
	var total: int = 0
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		if slots.has(slot_id):
			total += slots[slot_id].get_effective_power()
	return total


## 获取武器槽位中的装备 instance_id 列表
## 如果槽位为空但有基础武器，返回基础武器虚拟 ID（带槽位索引）
func get_weapon_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for i: int in range(2):
		var slot_id: StringName = StringName("weapon_%d" % [i + 1])
		if slots.has(slot_id):
			var slot: MechSlotState = slots[slot_id]
			if slot.equipped_card:
				# 有装备牌，使用装备牌的 instance_id
				result.append(slot.equipped_card.instance_id)
			elif i < base_weapons.size() and not base_weapons[i].is_empty():
				# 槽位为空但有基础武器，使用虚拟 ID（包含槽位索引）
				result.append(StringName("frame_base_weapon_%d" % [i + 1]))
	return result


## 获取基础武器数据（用于攻击计算）
## slot_index: 0=weapon_1, 1=weapon_2
func get_base_weapon(slot_index: int = 0) -> Dictionary:
	if slot_index >= 0 and slot_index < base_weapons.size():
		return base_weapons[slot_index]
	return {}


## 获取所有基础武器数据
func get_all_base_weapons() -> Array[Dictionary]:
	return base_weapons


## 设置基础武器数据（单把武器）
func set_base_weapon(weapon_data: Dictionary) -> void:
	base_weapons = [weapon_data]


## 设置基础武器数据（多把武器）
func set_base_weapons(weapons: Array[Dictionary]) -> void:
	base_weapons = weapons


## 获取所有区域损伤标记总数
func get_damage_token_count() -> int:
	var total: int = 0
	for slot in slots.values():
		total += slot.region_damage_tokens
	return total


## 获取指定槽位的装备牌
func get_equipped_card_in_slot(slot_id: StringName):
	if slots.has(slot_id):
		return slots[slot_id].equipped_card
	return null


## 是否有指定状态
func has_status(status_type: StringName) -> bool:
	for s: Dictionary in statuses:
		if s.get("type", &"") == status_type:
			return true
	return false


## 添加状态
func add_status(status: Dictionary) -> void:
	statuses.append(status)


## 移除指定类型的状态
func remove_status(status_type: StringName) -> void:
	statuses = statuses.filter(func(s: Dictionary) -> bool:
		return s.get("type", &"") != status_type
	)


## 本回合是否还能攻击
func can_attack() -> bool:
	if destroyed:
		return false
	if has_status(&"cannot_attack"):
		return false
	return attack_count_this_turn < max_attacks_per_turn


## 本回合是否还能移动
func can_move() -> bool:
	if destroyed:
		return false
	if has_status(&"cannot_move"):
		return false
	return power > 0
