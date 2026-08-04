## CardSetService.gd — 装备设置与出售服务
##
## 负责：
## - 装备设置到槽位（含替换已有装备）
## - 装备出售换取金币
class_name CardSetService
extends RefCounted

var context = null  # type: GameContext

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

	# 转发到 set_equipment 动作（走 Action Engine + TimingEngine，装备效果由
	# set_equipment_action._register_equipment_effects 注册为 permanent listener，
	# 替换/弃置发 DISCARD_* 时点）。slot_id 已由调用方指定，动作不等待输入。
	# 兼容旧调用方：动作在后台执行，此处仍同步返回 ok。
	if context.action_service != null:
		var src: Dictionary = {
			"player_id": player_id,
			"mech_id": mech.mech_id,
			"card_instance_id": card_id,
		}
		context.action_service.execute(&"set_equipment", {
			"card_id": card_id,
			"mech_id": mech.mech_id,
			"slot_id": slot_id,
			"source": src,
		})
		gs.write_log(&"equipment_set", {
			"player_id": String(player_id),
			"card_id": String(card_id),
			"slot_id": String(slot_id),
		})
		return {"ok": true, "card_id": card_id, "slot_id": slot_id}

	# 退路：action_service 未就绪（初始化/测试），走 legacy 同步设置（不发时点、不注册装备效果）
	return _set_equipment_legacy(player_id, mech, slot, card_id, slot_id)


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
	var in_set_slot: bool = false  # 已设置到部件区域（量产装 effect_001 可卖出）
	var set_slot_id: StringName = &""
	var set_mech_id: StringName = &""

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
			# 检查是否已设置到部件区域（仅 effect_001 量产装可卖出已设置装备）
			if not in_reserve and card.def != null:
				var effect_ids_map: Dictionary = {}
				if context.get("card_database") != null:
					var cdb = context.card_database
					if cdb.get("loader") != null:
						effect_ids_map = cdb.loader.get_effect_ids_map()
					elif cdb.has_method("get_effect_ids_map"):
						effect_ids_map = cdb.get_effect_ids_map()
				var eids: Array = effect_ids_map.get(card.def.card_id, [])
				if eids.has(&"equipment_effect_001"):
					for sid: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
						if not mech.slots.has(sid):
							continue
						var slot = mech.slots[sid]
						if slot != null and slot.equipped_card != null and slot.equipped_card.instance_id == card_id:
							in_set_slot = true
							set_slot_id = sid
							set_mech_id = mech.mech_id
							break

	if not in_equipment_hand and not in_reserve and not in_set_slot:
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
	# reason: 手牌卖出=sell, 备用区卖出=sell_set_equipment, 已设置区域卖出=sell_set_equipment
	if in_equipment_hand:
		player.equipment_hand.erase(card_id)
		context.deck_service.discard_card(card_id, &"sell")
	elif in_reserve:
		# 从备用区移除
		var mech: MechState = gs.get_mech_for_player(player_id)
		if mech != null and reserve_slot_id != &"":
			var slot: MechSlotState = mech.slots[reserve_slot_id]
			slot.equipped_card = null
		context.deck_service.discard_card(card_id, &"sell_set_equipment")
	elif in_set_slot:
		# 从已设置部件区域移除（卖出后区域变空），注销装备效果 + 重算动力
		if context.timing_engine != null:
			context.timing_engine.unregister_permanent_listeners_for_card(card_id)
		if set_mech_id != &"" and set_slot_id != &"":
			var mech: MechState = gs.mechs.get(set_mech_id)
			if mech != null and mech.slots.has(set_slot_id):
				mech.slots[set_slot_id].equipped_card = null
				# 部件槽重算动力上限
				var old_max_power: int = mech.max_power
				mech.max_power = mech.get_total_power()
				mech.sync_own_power_after_max_change(old_max_power)
		context.deck_service.discard_card(card_id, &"sell_set_equipment")

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


## Legacy 同步设置装备（action_service 未就绪时退路，不发时点、不注册装备效果到 TimingEngine）
## 保留原同步行为：替换旧装备（reason=equipment_replace）、移除耐久对应损伤、备用区 face_down、
## 设置后立即因损伤损坏（reason=damage_durability）、部件槽重算动力上限。
func _set_equipment_legacy(player_id: StringName, mech: MechState, slot: MechSlotState, card_id: StringName, slot_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	var card: CardInstance = gs.get_card(card_id)

	var new_durability: int = 0
	if card.def is _EquipmentCardDef:
		new_durability = card.def.durability

	if slot.slot_kind == &"RESERVE":
		slot.region_damage_tokens = 0

	if slot.equipped_card != null:
		var old_card: CardInstance = slot.equipped_card
		if context.effect_registry:
			context.effect_registry.unregister_card(old_card)
		context.deck_service.discard_card(old_card.instance_id, &"equipment_replace")
		slot.equipped_card = null

	if new_durability > 0 and slot.slot_kind != &"RESERVE":
		var tokens_to_remove: int = mini(new_durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= tokens_to_remove

	player.equipment_hand.erase(card_id)

	card.zone = &"equipped"
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	slot.equipped_card = card

	if slot.slot_kind == &"RESERVE":
		card.face_down = true

	if slot.slot_kind != &"RESERVE" and new_durability > 0 and slot.region_damage_tokens >= new_durability:
		if context.effect_registry:
			context.effect_registry.unregister_card(card)
		context.deck_service.discard_card(card.instance_id, &"damage_durability")
		slot.equipped_card = null
		gs.write_log(&"equipment_broken_by_damage", {
			"player_id": String(player_id),
			"card_id": String(card_id),
			"slot_id": String(slot_id),
		})
		return {"ok": true, "card_id": card_id, "slot_id": slot_id, "broken": true}

	if slot.slot_kind == &"PART":
		var old_max_power: int = mech.max_power
		mech.max_power = mech.get_total_power()
		mech.sync_own_power_after_max_change(old_max_power)

	if context.effect_registry and slot.slot_kind != &"RESERVE":
		context.effect_registry.register_card(card)

	gs.write_log(&"equipment_set", {
		"player_id": String(player_id),
		"card_id": String(card_id),
		"slot_id": String(slot_id),
	})
	return {"ok": true, "card_id": card_id, "slot_id": slot_id}
