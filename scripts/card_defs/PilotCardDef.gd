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


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
