## CardDatabase.gd — 卡牌数据库统一访问入口
##
## 聚合 CardDatabaseLoader（卡牌定义）和 GeneratedEffects（效果定义），
## 提供按 ID、按类型查询的统一接口。
## 使用方式：先调用 load_all(registry) 加载数据，再通过 get_card / get_effect 查询。
class_name CardDatabase
extends RefCounted

## 卡牌定义索引：card_id → CardDef
var card_defs: Dictionary = {}

## 效果定义索引：effect_id → CardEffect
var effect_defs: Dictionary = {}


## 从 DataRegistry 加载所有卡牌定义和效果定义
func load_all(registry: DataRegistry) -> void:
	# 加载卡牌定义（JSON → CardDef）
	var loader := CardDatabaseLoader.new()
	card_defs = loader.load_from_registry(registry)

	# 加载效果定义（手写存根 → CardEffect）
	effect_defs = GeneratedEffects.build_all_effects()

	# 将效果绑定到对应卡牌
	_bind_effects_to_cards(loader.get_effect_id_map())


## 根据 card_id 获取 CardDef，找不到返回 null
## 注意：子类（EquipmentCardDef 等）因 Godot 跨文件 extends 限制直接 extends RefCounted，
## 不能用 as CardDef 类型转换（会返回 null），因此返回无类型。
func get_card(card_id: StringName):
	var def = card_defs.get(card_id, null)
	if def == null:
		return null
	return def


## 根据 effect_id 获取 CardEffect，找不到返回 null
func get_effect(effect_id: StringName) -> CardEffect:
	var effect = effect_defs.get(effect_id, null)
	if effect == null:
		return null
	return effect as CardEffect


## 按 card_kind 筛选卡牌，返回 Array[CardDef]
func list_cards_by_kind(kind: StringName) -> Array:
	var result: Array = []
	for def in card_defs.values():
		if def.card_kind == kind:
			result.append(def)
	return result


## ── 内部：将效果绑定到对应卡牌 ──
## 根据 effect_id_map 查找 CardEffect 并附加到 CardDef.effects。
## 如果效果 ID 在 effect_defs 中不存在（如 effect_unimplemented），跳过绑定。
func _bind_effects_to_cards(effect_id_map: Dictionary) -> void:
	for card_id in effect_id_map:
		var effect_id: StringName = effect_id_map[card_id]
		var effect: CardEffect = effect_defs.get(effect_id, null) as CardEffect
		if effect == null:
			# 效果尚未定义（如 effect_unimplemented），跳过
			continue
		var def = card_defs.get(card_id, null)
		if def == null:
			continue
		def.effects.append(effect)
