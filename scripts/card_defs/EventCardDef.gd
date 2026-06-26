## EventCardDef.gd — 事件牌静态定义
##
## 事件牌具有计时机制：设置后按回合递减，归零时触发最终效果。
## 延时为 0 的事件牌设置时即刻生效并结算。
##
## 注意：不 extends CardDef，独立包含所有字段（避免 Godot 跨文件 extends 问题）。
class_name EventCardDef
extends RefCounted

## ── CardDef 基类字段（手动包含）──
var card_id: StringName = &""
var display_name: String = ""
var card_kind: StringName = &"event"
var rarity: String = "N"
var tags: Array[StringName] = []
var effects: Array = []
var effect_text: String = ""
var count: int = 1

## 延时（回合数）：0 = 即时生效，>0 = 持续效果
var delay: int = 0

## 收益倾向："正"（有利）/ "负"（不利）/ "中"（条件性）
var tone: String = ""

## 计时方式描述（如"从当前回合开始计时"）
var timing: String = ""

## 计时归零后是否弃置事件牌
var discard_when_timer_zero: bool = true


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
