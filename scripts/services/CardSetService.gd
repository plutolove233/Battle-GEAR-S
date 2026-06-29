## CardSetService.gd — 装备设置与出售服务
##
## 负责：
## - 装备设置到槽位（含替换已有装备）
## - 装备出售换取金币
class_name CardSetService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 设置装备到槽位
## 验证装备在手 → 验证槽位存在且类型匹配 → 处理替换 → 装备入槽 → 注册效果
func set_equipment(player_id: StringName, card_id: StringName, slot_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)

	# ── 验证玩家存在 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 验证装备在手牌中 ──
	if not player.equipment_hand.has(card_id):
		return {"ok": false, "message": "装备不在手牌中"}

	# ── 获取机甲 ──
	var mech: MechState = gs.get_mech_for_player(player_id)
	if mech == null:
		return {"ok": false, "message": "玩家没有机甲"}

	# ── 验证槽位存在 ──
	if not mech.slots.has(slot_id):
		return {"ok": false, "message": "槽位不存在: %s" % String(slot_id)}

	# ── 验证槽位类型与卡牌类型匹配 ──
	var slot: MechSlotState = mech.slots[slot_id]
	var card: CardInstance = gs.get_card(card_id)
	if card == null:
		return {"ok": false, "message": "卡牌实例不存在"}

	if not _is_slot_type_compatible(slot.slot_kind, card):
		return {"ok": false, "message": "装备类型与槽位不匹配"}

	# ── 处理已有装备的替换 ──
	if slot.equipped_card != null:
		var old_card: CardInstance = slot.equipped_card
		# 移除旧装备耐久度等值的区域损伤标记（与 EquipmentBreakService.replace_equipment 一致）
		var old_durability: int = slot.get_equipment_durability()
		var tokens_to_remove: int = mini(old_durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= tokens_to_remove
		# 取消注册旧装备效果
		if context.effect_registry:
			context.effect_registry.unregister_card(old_card)
		# 将旧装备放入弃牌堆
		context.deck_service.discard_card(old_card.instance_id, &"replaced")
		slot.equipped_card = null

	# ── 从装备手牌移除 ──
	player.equipment_hand.erase(card_id)

	# ── 将装备设置到槽位 ──
	card.zone = &"equipped"
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	slot.equipped_card = card

	# ── 重算动力上限并调整当前动力 ──
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	var power_delta: int = mech.max_power - old_max_power
	mech.power = maxi(0, mech.power + power_delta)

	# ── 注册装备效果 ──
	if context.effect_registry:
		context.effect_registry.register_card(card)

	# ── 触发装备设置钩子 ──
	_fire_hook(_EffectConst.HOOK_EQUIPMENT_SET, {
		"player_id": player_id,
		"mech_id": String(mech.mech_id),
		"card_id": String(card_id),
		"slot_id": String(slot_id),
	})

	gs.write_log(&"equipment_set", {
		"player_id": String(player_id),
		"card_id": String(card_id),
		"slot_id": String(slot_id),
	})
	return {"ok": true, "card_id": card_id, "slot_id": slot_id}


## 出售装备
## 验证装备在手牌中 → 获得金币 → 弃牌
func sell_equipment(player_id: StringName, card_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)

	# ── 验证玩家存在 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 验证装备在手牌中 ──
	if not player.equipment_hand.has(card_id):
		return {"ok": false, "message": "装备不在手牌中"}

	# ── 计算出售价格（默认1金币） ──
	var sell_price: int = 1
	var card: CardInstance = gs.get_card(card_id)
	if card and card.def:
		# 稀有度影响售价
		match card.def.rarity:
			"N":
				sell_price = 1
			"R":
				sell_price = 2
			"SR":
				sell_price = 3
			"SSR":
				sell_price = 5

	# ── 获得金币 ──
	if context.game_actions:
		context.game_actions.gain_gold(player_id, sell_price)
	else:
		player.gold += sell_price

	# ── 从手牌移除并弃牌 ──
	player.equipment_hand.erase(card_id)
	context.deck_service.discard_card(card_id, &"sold")

	gs.write_log(&"equipment_sold", {
		"player_id": String(player_id),
		"card_id": String(card_id),
		"gold": sell_price,
	})
	return {"ok": true, "card_id": card_id, "gold_earned": sell_price}


## ── 内部方法 ──


## 检查槽位类型与卡牌类型是否兼容
func _is_slot_type_compatible(slot_kind: StringName, card: CardInstance) -> bool:
	if card.def == null:
		return false

	var card_kind: StringName = card.def.card_kind
	match slot_kind:
		&"PART":
			return card_kind == &"equipment"
		&"WEAPON":
			return card_kind == &"equipment" and card.def.equipment_kind == &"WEAPON"
		&"RESERVE":
			return card_kind == &"equipment"
		&"EVENT":
			return card_kind == &"event"
		&"PILOT":
			return card_kind == &"pilot"
		_:
			return false


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
