## MechSlotState.gd — 机甲槽位运行时状态
##
## 每个机甲有多个槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位独立追踪装备牌和区域损伤。
class_name MechSlotState
extends RefCounted

const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

## 槽位标识（&"头部"/&"躯干"/&"右臂"/&"左臂"/&"右腿"/&"左腿"
##          /&"weapon_1"/&"weapon_2"/&"reserve_1"/&"reserve_2"
##          /&"event_1"/&"pilot_1"）
var slot_id: StringName = &""

## 槽位大类：&"PART" / &"WEAPON" / &"RESERVE" / &"EVENT" / &"PILOT"
var slot_kind: StringName = &"PART"

## 当前装备的牌（null = 空槽位）
var equipped_card = null

## 框架基础护甲
var base_armor: int = 0

## 框架基础动力
var base_power: int = 0

## 备用区域基础耐久
var base_durability: int = 0

## 区域上的损伤标记（装备弃置后仍然保留）
var region_damage_tokens: int = 0

## 护甲修正（来自效果）
var armor_modifier: int = 0

## 动力修正（来自效果）
var power_modifier: int = 0


## 获取实际护甲值 = 基础 + 装备牌护甲 + 修正 - 区域损伤
func get_effective_armor() -> int:
	var total: int = base_armor + armor_modifier
	if equipped_card and equipped_card.def is _EquipmentCardDef:
		var eq_def = equipped_card.def
		if eq_def.equipment_kind == &"PART":
			total += eq_def.armor
	# 损伤降低护甲（规则书：每损伤使区域护甲 -1）
	total -= region_damage_tokens
	return total


## 获取实际动力值 = 基础 + 装备牌动力 + 修正
func get_effective_power() -> int:
	var total: int = base_power + power_modifier
	if equipped_card and equipped_card.def is _EquipmentCardDef:
		var eq_def = equipped_card.def
		if eq_def.equipment_kind == &"PART":
			total += eq_def.power
	return total


## 此槽位是否有装备牌
func has_equipment() -> bool:
	return equipped_card != null


## 获取装备牌的耐久值（无装备返回0）
func get_equipment_durability() -> int:
	if not equipped_card or not equipped_card.def is _EquipmentCardDef:
		return 0
	return equipped_card.def.durability


## 装备是否已损坏（损伤 ≥ 耐久）
func is_equipment_broken() -> bool:
	if not equipped_card:
		return false
	return equipped_card.damage_tokens >= get_equipment_durability()
