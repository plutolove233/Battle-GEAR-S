## MechFrameDef.gd — 机甲框架静态定义
##
## 机甲框架是玩家的主要面板，定义了生命值、阵营、基础槽位和武器。
##
## 注意：不 extends CardDef，独立包含所有字段（避免 Godot 跨文件 extends 问题）。
class_name MechFrameDef
extends RefCounted

## ── CardDef 基类字段（手动包含）──
var card_id: StringName = &""
var display_name: String = ""
var card_kind: StringName = &"mech_frame"
var rarity: String = "N"
var tags: Array[StringName] = []
var effects: Array = []
var effect_text: String = ""
var count: int = 1

## 所属阵营
var faction: String = ""

## 生命值上限
var life: int = 25

## 基础槽位定义：slot_name → { armor: int, power: int }
## key: "头部", "躯干", "右臂", "左臂", "右腿", "左腿"
var base_slots: Dictionary = {}

## 基础武器列表：[ { name: String, weapon_kind: StringName, might: int, range_value: int } ]
var base_weapons: Array[Dictionary] = []

## 备用区域定义：[ { slot_id: String, durability: int, can_sell: bool } ]
var reserve_slots: Array[Dictionary] = []


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
