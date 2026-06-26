## EquipmentBreakService.gd — 装备损坏与替换服务
##
## 负责：
## - 检查装备是否因损伤标记超过耐久度而损坏
## - 替换损坏装备（移除损伤标记、弃掉旧装备、设置新装备）
class_name EquipmentBreakService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 检查装备是否损坏
## 如果损伤标记 >= 耐久度，触发损坏流程
func check_equipment_broken(mech_id: StringName, slot_id: StringName) -> void:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return

	if not mech.slots.has(slot_id):
		return

	var slot: MechSlotState = mech.slots[slot_id]
	if not slot.is_equipment_broken():
		return

	# ── 装备已损坏，执行损坏流程 ──
	var broken_card: CardInstance = slot.equipped_card
	if broken_card == null:
		return

	# 触发装备摧毁钩子
	_fire_hook(_EffectConst.HOOK_EQUIPMENT_BROKEN, {
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
		"card_id": String(broken_card.instance_id),
	})

	# 取消注册效果
	if context.effect_registry:
		context.effect_registry.unregister_card(broken_card)

	# 弃掉损坏装备
	context.deck_service.discard_card(broken_card.instance_id, &"broken")

	# 清空槽位
	slot.equipped_card = null

	gs.write_log(&"equipment_broken", {
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
		"card_id": String(broken_card.instance_id),
	})


## 替换装备
## 移除旧装备耐久度等值的区域损伤标记 → 弃掉旧装备 → 设置新装备
func replace_equipment(player_id: StringName, mech_id: StringName, new_card_id: StringName, slot_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	var mech: MechState = gs.mechs.get(mech_id)

	# ── 验证 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在"}
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	if not mech.slots.has(slot_id):
		return {"ok": false, "message": "槽位不存在"}
	if not player.equipment_hand.has(new_card_id):
		return {"ok": false, "message": "新装备不在手牌中"}

	var slot: MechSlotState = mech.slots[slot_id]
	var old_card: CardInstance = slot.equipped_card

	# ── 如果有旧装备，移除等量区域损伤标记并弃掉 ──
	if old_card != null:
		var old_durability: int = slot.get_equipment_durability()
		# 移除旧装备耐久度等值的区域损伤标记
		var tokens_to_remove: int = mini(old_durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= tokens_to_remove

		# 取消注册旧装备效果
		if context.effect_registry:
			context.effect_registry.unregister_card(old_card)

		# 弃掉旧装备
		context.deck_service.discard_card(old_card.instance_id, &"replaced")

	# ── 从装备手牌移除新装备 ──
	player.equipment_hand.erase(new_card_id)

	# ── 设置新装备到槽位 ──
	var new_card: CardInstance = gs.get_card(new_card_id)
	if new_card:
		new_card.zone = &"equipped"
		new_card.slot_id = slot_id
		new_card.mech_id = mech_id
		new_card.damage_tokens = 0  # 新装备无损伤
		slot.equipped_card = new_card

		# 注册新装备效果
		if context.effect_registry:
			context.effect_registry.register_card(new_card)

	# ── 触发装备设置钩子 ──
	_fire_hook(_EffectConst.HOOK_EQUIPMENT_SET, {
		"player_id": player_id,
		"mech_id": String(mech_id),
		"card_id": String(new_card_id),
		"slot_id": String(slot_id),
		"replaced": old_card != null,
	})

	gs.write_log(&"equipment_replaced", {
		"player_id": String(player_id),
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
		"new_card_id": String(new_card_id),
	})
	return {"ok": true, "slot_id": slot_id, "new_card_id": new_card_id}


## ── 内部方法 ──


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
