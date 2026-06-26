## EquipmentCardDef.gd — 装备牌静态定义（部件 + 武器）
##
## 装备牌分为两大类：
##   PART（部件）：设置在头部/躯干/双臂/双腿区域，提供护甲和动力
##   WEAPON（武器）：设置在武器区域，提供威力和范围
##
## 注意：不 extends CardDef，独立包含所有字段（避免 Godot 跨文件 extends 问题）。
class_name EquipmentCardDef
extends RefCounted

## ── CardDef 基类字段（手动包含）──
var card_id: StringName = &""
var display_name: String = ""
var card_kind: StringName = &"equipment"
var rarity: String = "N"
var tags: Array[StringName] = []
var effects: Array = []
var effect_text: String = ""
var count: int = 1

## ── 装备大类：&"PART" 或 &"WEAPON" ──
var equipment_kind: StringName = &"PART"

## 部件槽位（仅 PART）：&"头部"/&"躯干"/&"右臂"/&"左臂"/&"右腿"/&"左腿"
var slot: StringName = &""

## 套装名称（如"量产装"、"联邦普装"）
var set_name: String = ""

## ── 部件属性 ──
var armor: int = 0       ## 提供的护甲值
var power: int = 0       ## 提供的动力值

## ── 武器属性 ──
var might: int = 0       ## 武器威力（JSON 中为 damage，加载时映射为 might）
var range_value: int = 0 ## 武器范围（JSON 中为 range，加载时映射为 range_value）
var weapon_kind: StringName = &""  ## &"近战" 或 &"远程"

## ── 通用属性 ──
var durability: int = 0  ## 耐久（损伤 ≥ 耐久时装备弃置）
var cost: int = 0        ## 金币价值（购买/卖出参考）


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
