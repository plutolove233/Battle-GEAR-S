## EquipmentBreakService.gd — 装备损坏与替换服务
##
## 负责：
## - 检查装备是否因损伤标记超过耐久度而损坏
## - 替换损坏装备（移除损伤标记、弃掉旧装备、设置新装备）
class_name EquipmentBreakService
extends RefCounted

var context = null  # type: GameContext

const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")


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

	# 弃掉损坏装备（走 discard_card 动作发 DISCARD_AFTER 时点，近战右腿等离场效果按 reason=damage_durability 触发）
	# discard_card 动作的 move_to_tmp 步骤会注销装备的 permanent listener。
	context.deck_service.discard_card(broken_card.instance_id, &"damage_durability")

	# 清空槽位
	slot.equipped_card = null

	# ── 重算动力上限并调整当前动力 ──
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	var power_delta: int = mech.max_power - old_max_power
	mech.power = maxi(0, mech.power + power_delta)

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

	# ── 获取新装备的耐久值 ──
	var new_durability: int = 0
	var new_card: CardInstance = gs.get_card(new_card_id)
	if new_card and new_card.def is _EquipmentCardDef:
		new_durability = new_card.def.durability

	# ── 如果有旧装备，弃掉（走 discard_card 动作发 DISCARD_AFTER 时点，reason=equipment_replace） ──
	if old_card != null:
		# 注销旧装备的 permanent listener（discard_card 动作的 move_to_tmp 也会注销，此处显式调用确保替换流程内立即失效）
		if context.timing_engine != null:
			context.timing_engine.unregister_permanent_listeners_for_card(old_card.instance_id)
		context.deck_service.discard_card(old_card.instance_id, &"equipment_replace")

	# ── 从装备手牌移除新装备 ──
	player.equipment_hand.erase(new_card_id)

	# ── 设置新装备到槽位（走 set_equipment 动作注册装备效果到 TimingEngine） ──
	# 新装备无损伤：先确保区域损伤不超新耐久（动作的 _step_remove_damage 会按耐久移除）
	if new_durability > 0:
		var tokens_to_remove: int = mini(new_durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= tokens_to_remove

	if new_card and context.action_service != null:
		# 临时把新装备放回手牌，让 set_equipment 动作走标准设置流程（含效果注册）
		player.equipment_hand.append(new_card_id)
		context.action_service.execute(&"set_equipment", {
			"card_id": new_card_id,
			"mech_id": mech_id,
			"slot_id": slot_id,
			"source": {"player_id": player_id, "mech_id": mech_id, "card_instance_id": new_card_id},
		})
	elif new_card:
		# 退路：action_service 未就绪，同步设置（不发时点、不注册装备效果）
		new_card.zone = &"equipped"
		new_card.slot_id = slot_id
		new_card.mech_id = mech_id
		new_card.damage_tokens = 0
		slot.equipped_card = new_card

	# ── 重算动力上限并调整当前动力 ──
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	var power_delta: int = mech.max_power - old_max_power
	mech.power = maxi(0, mech.power + power_delta)

	gs.write_log(&"equipment_replaced", {
		"player_id": String(player_id),
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
		"new_card_id": String(new_card_id),
	})
	return {"ok": true, "slot_id": slot_id, "new_card_id": new_card_id}


## ── 内部方法 ──
