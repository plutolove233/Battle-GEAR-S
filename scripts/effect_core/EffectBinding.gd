## EffectBinding.gd — 把静态 CardEffect 绑定到运行时来源牌
##
## EffectBinding 是效果系统的核心连接件：
## 将静态的 CardEffect 定义与运行时的 CardInstance 实例关联。
## 通过 source_card 可以追溯效果的来源牌、拥有者、所属机甲等信息。
## 数据结构来源于规则表 Effect全牌表.xlsx "核心执行框架" 第2行。
extends RefCounted
class_name EffectBinding

## Preloaded references for cross-file custom types
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _CardEffect = preload("res://scripts/effect_core/CardEffect.gd")

## 来源牌实例（运行时）
var source_card

## 静态效果定义
var effect


func _init(p_source_card, p_effect) -> void:
	source_card = p_source_card
	effect = p_effect


## 获取来源牌的操控者玩家ID
func get_owner_player_id() -> StringName:
	if source_card == null:
		return &""
	return source_card.owner_player_id


## 获取来源牌的实例ID
func get_source_instance_id() -> StringName:
	if source_card == null:
		return &""
	return source_card.instance_id


## 获取来源牌所属机甲ID
func get_source_mech_id() -> StringName:
	if source_card == null:
		return &""
	return source_card.mech_id
