## CardDef.gd — 所有卡牌的基类静态定义
##
## CardDef 表示一张牌"长什么样"——牌面属性和效果列表。
## 同一张牌的所有复制品共用同一个 CardDef。
## 运行时通过 CardInstance 引用 CardDef。
##
## 注意：子类（EquipmentCardDef、ActionCardDef 等）不继承此类，
## 而是 extends RefCounted 并独立包含所有字段。
## 这是因为 Godot 4 的跨文件 extends 解析存在加载顺序问题。
class_name CardDef
extends RefCounted

## 卡牌唯一标识（对应 JSON 中的 id 字段）
var card_id: StringName = &""

## 显示名称
var display_name: String = ""

## 卡牌大类：equipment / action / event / pilot / mech_frame
var card_kind: StringName = &""

## 稀有度：N / R / SR / SSR
var rarity: String = "N"

## 标签列表（用于条件判断，如 &"远程武器"、&"攻击牌"、&"联邦"）
var tags: Array[StringName] = []

## 效果列表（卡牌上附带的所有 CardEffect）
var effects: Array = []  # Array[CardEffect] — 用 Array 避免循环引用问题

## 效果文本（规则原文描述）
var effect_text: String = ""

## 牌堆中的数量（同一 CardDef 有 count 张复制品）
var count: int = 1


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
