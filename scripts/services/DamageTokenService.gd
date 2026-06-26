## DamageTokenService.gd — 损伤标记服务
##
## 负责：
## - 放置损伤标记到机甲槽位
## - 优先放置到已装备的槽位
## - 检查装备是否因标记数超过耐久度而损坏
class_name DamageTokenService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 放置损伤标记
## params 包含: mech_id, count, source_attack_id
## 流程：逐个放置 → 选择槽位（优先已装备） → 添加标记 → 检查装备损坏
func place_damage_tokens(params: Dictionary) -> void:
	var gs: GameState = context.game_state
	var mech_id: StringName = params.get("mech_id", &"")
	var count: int = int(params.get("count", 0))

	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null or count <= 0:
		return

	for i: int in range(count):
		# ── 触发放置前钩子 ──
		_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
			"event": &"before_damage_token_placed",
			"mech_id": String(mech_id),
			"token_index": i,
		})

		# ── 选择目标槽位（优先已装备槽位） ──
		var target_slot_id: StringName = _choose_slot_for_token(mech)
		if target_slot_id == &"":
			break  # 没有可用槽位

		var slot: MechSlotState = mech.slots[target_slot_id]

		# ── 添加区域损伤标记 ──
		slot.region_damage_tokens += 1

		# ── 如果槽位有装备，也添加装备损伤标记 ──
		if slot.equipped_card != null:
			slot.equipped_card.damage_tokens += 1

		# ── 触发放置后钩子 ──
		_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
			"event": &"after_damage_token_placed",
			"mech_id": String(mech_id),
			"slot_id": String(target_slot_id),
		})

		# ── 检查装备是否损坏 ──
		if slot.equipped_card != null:
			context.equipment_break_service.check_equipment_broken(mech_id, target_slot_id)

	gs.write_log(&"damage_tokens_placed", {
		"mech_id": String(mech_id),
		"count": count,
	})


## ── 内部方法 ──


## 为损伤标记选择目标槽位
## 优先选择已装备的部件槽位，其次是武器槽位，最后是空槽位
func _choose_slot_for_token(mech: MechState) -> StringName:
	# 优先级：已装备部件 > 已装备武器 > 空部件 > 空武器 > 其他
	var equipped_parts: Array[StringName] = []
	var equipped_weapons: Array[StringName] = []
	var empty_parts: Array[StringName] = []
	var empty_weapons: Array[StringName] = []
	var other_slots: Array[StringName] = []

	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		match slot.slot_kind:
			&"PART":
				if slot.equipped_card != null:
					equipped_parts.append(slot_id)
				else:
					empty_parts.append(slot_id)
			&"WEAPON":
				if slot.equipped_card != null:
					equipped_weapons.append(slot_id)
				else:
					empty_weapons.append(slot_id)
			_:
				other_slots.append(slot_id)

	# 按优先级返回第一个可用槽位
	if not equipped_parts.is_empty():
		return equipped_parts[randi() % equipped_parts.size()]
	if not equipped_weapons.is_empty():
		return equipped_weapons[randi() % equipped_weapons.size()]
	if not empty_parts.is_empty():
		return empty_parts[randi() % empty_parts.size()]
	if not empty_weapons.is_empty():
		return empty_weapons[randi() % empty_weapons.size()]
	if not other_slots.is_empty():
		return other_slots[randi() % other_slots.size()]

	return &""


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
