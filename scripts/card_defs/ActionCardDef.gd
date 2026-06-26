## ActionCardDef.gd — 行动牌静态定义
##
## 行动牌分为三类：
##   攻击：发动攻击（如"进攻"、"强袭"）
##   迎击：响应攻击（如"回避"、"防御"、"反击"）
##   辅助：特殊效果（如"维修"、"聚能"、"推进"）
##
## 注意：不 extends CardDef，独立包含所有字段（避免 Godot 跨文件 extends 问题）。
class_name ActionCardDef
extends RefCounted

## ── CardDef 基类字段（手动包含）──
var card_id: StringName = &""
var display_name: String = ""
var card_kind: StringName = &"action"
var rarity: String = "N"
var tags: Array[StringName] = []
var effects: Array = []
var effect_text: String = ""
var count: int = 1

## 行动类型：&"攻击" / &"迎击" / &"辅助"
var action_type: StringName = &""


## 检查此卡牌是否是指定类型
func is_type(kind: StringName) -> bool:
	return card_kind == kind
