## CardSetService.gd — 装备设置与出售服务
##
## 负责：
## - 装备设置到槽位（含替换已有装备）
## - 装备出售换取金币
class_name CardSetService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")


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

	# ── 获取新装备的耐久值（在替换前获取，因为替换后 card 会被设置到槽位） ──
	var new_durability: int = 0
	if card.def is _EquipmentCardDef:
		new_durability = card.def.durability

	# ── 备用区特殊规则：设置新装备前先移除备用区的所有损伤 ──
	if slot.slot_kind == &"RESERVE":
		slot.region_damage_tokens = 0

	# ── 处理已有装备的替换 ──
	if slot.equipped_card != null:
		var old_card: CardInstance = slot.equipped_card
		# 取消注册旧装备效果
		if context.effect_registry:
			context.effect_registry.unregister_card(old_card)
		# 将旧装备放入弃牌堆，原因记为"因替换装备弃置"
		context.deck_service.discard_card(old_card.instance_id, &"replaced")
		slot.equipped_card = null

	# ── 移除新装备耐久值对应的区域损伤（规则：设置新装备后，移除该区域对应新装备耐久值的损伤） ──
	# 但备用区已经在上面清除了所有损伤
	if new_durability > 0 and slot.slot_kind != &"RESERVE":
		var tokens_to_remove: int = mini(new_durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= tokens_to_remove

	# ── 从装备手牌移除 ──
	player.equipment_hand.erase(card_id)

	# ── 将装备设置到槽位 ──
	card.zone = &"equipped"
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	slot.equipped_card = card

	# ── 备用区装备特殊处理：设置 face_down = true ──
	if slot.slot_kind == &"RESERVE":
		card.face_down = true

	# ── 检查装备是否因损伤立即损坏（仅当区域损伤 >= 装备耐久时） ──
	if slot.slot_kind != &"RESERVE" and new_durability > 0 and slot.region_damage_tokens >= new_durability:
		# 立即因损伤弃置该装备牌
		if context.effect_registry:
			context.effect_registry.unregister_card(card)
		context.deck_service.discard_card(card.instance_id, &"broken_by_damage")
		slot.equipped_card = null
		gs.write_log(&"equipment_broken_by_damage", {
			"player_id": String(player_id),
			"card_id": String(card_id),
			"slot_id": String(slot_id),
		})
		return {"ok": true, "card_id": card_id, "slot_id": slot_id, "broken": true}

	# ── 部件槽位才计算动力上限 ──
	if slot.slot_kind == &"PART":
		var old_max_power: int = mech.max_power
		mech.max_power = mech.get_total_power()
		var power_delta: int = mech.max_power - old_max_power
		mech.power = maxi(0, mech.power + power_delta)

	# ── 注册装备效果（备用区装备不注册效果） ──
	if context.effect_registry and slot.slot_kind != &"RESERVE":
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
## 验证装备在手牌中或在备用区 → 获得金币 → 弃牌
func sell_equipment(player_id: StringName, card_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)

	# ── 验证玩家存在 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 验证是否还有卖出机会 ──
	var remaining_sells = _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN - player.sell_equipment_count_this_turn
	if remaining_sells <= 0:
		return {"ok": false, "message": "本回合已用完卖出装备的机会"}

	# ── 检查装备是在手牌中还是在备用区 ──
	var card: CardInstance = gs.get_card(card_id)
	if card == null:
		return {"ok": false, "message": "卡牌实例不存在"}

	var in_equipment_hand: bool = player.equipment_hand.has(card_id)
	var in_reserve: bool = false
	var reserve_slot_id: StringName = &""

	# 检查是否在备用区
	if not in_equipment_hand:
		var mech: MechState = gs.get_mech_for_player(player_id)
		if mech != null:
			for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
				if mech.slots.has(rs_id) and mech.slots[rs_id].equipped_card != null:
					if mech.slots[rs_id].equipped_card.instance_id == card_id:
						in_reserve = true
						reserve_slot_id = rs_id
						break

	if not in_equipment_hand and not in_reserve:
		return {"ok": false, "message": "装备不在手牌中或备用区"}

	# ── 计算出售价格（使用装备牌的 cost 字段） ──
	var sell_price: int = 1
	if card.def and card.def is EquipmentCardDef:
		sell_price = card.def.cost

	# ── 增加卖出次数 ──
	player.sell_equipment_count_this_turn += 1

	# ── 获得金币 ──
	if context.game_actions:
		context.game_actions.gain_gold({"player_id": player_id, "amount": sell_price})
	else:
		player.gold += sell_price

	# ── 从手牌移除并弃牌 或 从备用区移除并弃牌 ──
	if in_equipment_hand:
		player.equipment_hand.erase(card_id)
		context.deck_service.discard_card(card_id, &"sold")
	elif in_reserve:
		# 从备用区移除
		var mech: MechState = gs.get_mech_for_player(player_id)
		if mech != null and reserve_slot_id != &"":
			var slot: MechSlotState = mech.slots[reserve_slot_id]
			slot.equipped_card = null
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
