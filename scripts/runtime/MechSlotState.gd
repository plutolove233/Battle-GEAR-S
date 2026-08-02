## MechSlotState.gd — 机甲槽位运行时状态
##
## 每个机甲有多个槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位独立追踪装备牌和区域损伤。
class_name MechSlotState
extends RefCounted

const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")

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


## 获取实际护甲值
## 规则：有装备时只算装备的护甲，无装备时算框架基础护甲 + 修正 - 区域损伤
## effect_014（重甲左臂/右腿/左腿）：损伤不影响此牌所在区域提供的护甲（不减 region_damage_tokens）
## effect_089（重甲头部）：机甲部件总损伤<3 时免疫，≥3 时正常减（需传 mech 判总损伤）
## mech 参数：MechState.get_armor 传 self；UI/测试若不传，总损伤阈值类保守按正常扣减
func get_effective_armor(mech = null) -> int:
	var total: int = armor_modifier
	if _is_equipment_active() and equipped_card.def is _EquipmentCardDef:
		var eq_def = equipped_card.def
		if eq_def.equipment_kind == &"PART":
			total += eq_def.armor
	else:
		# 无装备时使用框架基础护甲
		total += base_armor
	# 损伤降低护甲（规则书：每损伤使区域护甲 -1）
	# effect_014 无条件免疫 / effect_089 重甲头部总损伤<3免疫：helper 返回应扣减量（0=免疫）
	total -= _GenEquipEffects.card_damage_immune_armor_amount(equipped_card, mech, region_damage_tokens)
	# effect_080 联邦的一角兽·头部全场光环：名称含联邦的装备额外+1护甲/来源
	if _is_equipment_active():
		total += _GenEquipEffects.get_global_faction_equipment_aura_bonus(equipped_card, "联邦")
	return total


## 获取实际动力值
## 规则：有装备时只算装备的动力，无装备时算框架基础动力 + 修正
func get_effective_power() -> int:
	var total: int = power_modifier
	if _is_equipment_active() and equipped_card.def is _EquipmentCardDef:
		var eq_def = equipped_card.def
		if eq_def.equipment_kind == &"PART":
			total += eq_def.power
	else:
		# 无装备时使用框架基础动力
		total += base_power
	# effect_086 帝国的神莺·头部全场光环：名称含帝国的装备额外+1动力/来源
	if _is_equipment_active():
		total += _GenEquipEffects.get_global_faction_equipment_aura_bonus(equipped_card, "帝国")
	return total


## 此槽位是否有装备牌
func has_equipment() -> bool:
	return equipped_card != null


## 获取装备牌的耐久值（无装备返回0）
## 备用区牌视为1耐久的白板装备（用户裁定：备用区牌仅持有者可见、无效果、1损伤即弃置），
## 故 RESERVE 槽位固定返回 1，忽略牌面 printed durability。
func get_equipment_durability() -> int:
	if not _is_equipment_active() or not equipped_card.def is _EquipmentCardDef:
		return 0
	if slot_kind == &"RESERVE":
		return 1
	return equipped_card.def.durability


## 装备是否已损坏（损伤 ≥ 耐久）
func is_equipment_broken() -> bool:
	if not _is_equipment_active():
		return false
	return equipped_card.damage_tokens >= get_equipment_durability()


func _is_equipment_active() -> bool:
	return equipped_card != null and not bool(equipped_card.counters.get("_pending_equipment_activation", false))
