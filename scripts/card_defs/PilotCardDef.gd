## PilotCardDef.gd — 机师牌静态定义
##
## 机师牌决定：回合攻击数、行动牌上限、金币消耗，以及特殊技能。
##
## 注意：不 extends CardDef，独立包含所有字段（避免 Godot 跨文件 extends 问题）。
class_name PilotCardDef
extends RefCounted

## ── CardDef 基类字段（手动包含）──
var card_id: StringName = &""
var display_name: String = ""
var card_kind: StringName = &"pilot"
var rarity: String = "N"
var tags: Array[StringName] = []
var effects: Array = []
var effect_text: String = ""
var count: int = 1

## 每回合攻击次数上限
var attack_limit: int = 1

## 行动牌手牌上限
var action_card_limit: int = 5

## 所属阵营（"联邦"/"帝国"/"秩序"/"混乱"）
var faction: String = ""

## 设置机师时消耗的金币
var cost: int = 0

## 维修增强配置（通用机制 REPAIR_BOOST）：非空则本机师牌所在玩家使用的维修获得加成。
## 格式：{"extra_removal": int, "range": int} —— 维修额外移除 N 损伤 + 目标范围扩大为 range。
## 如坎得 pilot_023 {"extra_removal": 2, "range": 4}；琳 pilot_024 等后续机师可复用。
var repair_boost: Dictionary = {}

## 远程武器范围+1 通用机制（仿 REPAIR_BOOST）：>0 时本机师牌所在机甲的远程武器范围 +N。
## 由 GeneratedEquipmentEffects.get_passive_weapon_range_bonus 实时重算（不注册监听器），
## 机师牌换下/换人即时失效。如克劳德 pilot_029 =1（远程武器范围+1）；后续机师可复用。
var passive_weapon_range_bonus: int = 0


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
