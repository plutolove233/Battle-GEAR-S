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
## 兼容保留：新数据读 timer_count/timer_mode，delay 作为旧字段别名（= timer_count）
var delay: int = 0

## 计时方式（决定怎么计时），枚举值见 GeneratedEventEffects.TIMER_MODE_*：
##   instant             -- 设置时即刻生效并结算（计时数 0）
##   every_turn_end      -- 从当前回合开始计时，每个回合结束后 -1（默认）
##   own_turn_end        -- 从当前回合开始计时，只在我方回合结束后 -1
##   next_own_turn_end   -- 从下一个我方回合开始计时，只在我方回合结束后 -1
##   next_own_turn_start -- 从下一个我方回合开始计时，我方回合开始时 -1
var timer_mode: StringName = &"instant"

## 计时数：归 0 时该牌生效结束，从区域中弃置
var timer_count: int = 0

## 收益倾向："正"（有利）/ "负"（不利）/ "中"（条件性）
var tone: String = ""

## 计时方式描述（如"从当前回合开始计时"）
var timing: String = ""

## 计时归零后是否弃置事件牌
var discard_when_timer_zero: bool = true


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
