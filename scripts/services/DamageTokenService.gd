## DamageTokenService.gd — 损伤标记服务
##
## 负责：
## - 放置损伤标记到机甲槽位
## - 优先放置到已装备的槽位（AI自动放置模式）
## - 支持玩家指定槽位放置（place_one_token_at_slot）
## - 检查装备是否因标记数超过耐久度而损坏
class_name DamageTokenService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 放置1个损伤标记到指定槽位（玩家选择模式）
## 流程：添加标记 → 检查装备损坏
func place_one_token_at_slot(mech_id: StringName, slot_id: StringName) -> void:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return
	if not mech.slots.has(slot_id):
		return

	var slot: MechSlotState = mech.slots[slot_id]

	# ── 触发放置前钩子 ──
	_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
		"event": &"before_damage_token_placed",
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
	})

	# ── 区域 + 装备损伤 + 重算动力 + 放置日志（统一走 GameState.place_one_damage_token）──
	# 与 place_damage_tokens_on_slot / GameActions.place_damage_tokens 一致汇聚到同一函数，
	# 保证 effect_101/119 的 damage_placement_log 在所有放置路径下都被填充。
	gs.place_one_damage_token(mech_id, slot_id)

	# ── 触发放置后钩子 ──
	_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
		"event": &"after_damage_token_placed",
		"mech_id": String(mech_id),
		"slot_id": String(slot_id),
	})

	# ── 检查装备是否损坏 ──
	if slot.equipped_card != null:
		context.equipment_break_service.check_equipment_broken(mech_id, slot_id)


## 放置多个损伤标记（AI自动放置模式）
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

		# ── 区域 + 装备损伤 + 重算动力 + 放置日志（统一走 GameState.place_one_damage_token）──
		gs.place_one_damage_token(mech_id, target_slot_id)

		# ── 触发放置后钩子 ──
		_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
			"event": &"after_damage_token_placed",
			"mech_id": String(mech_id),
			"slot_id": String(target_slot_id),
		})

		# ── 检查装备是否损坏 ──
		if slot.equipped_card != null:
			context.equipment_break_service.check_equipment_broken(mech_id, target_slot_id)

	# 损伤变化后重算动力上限（effect_016/021/048 派生动力随损伤变，max_power 需同步）
	mech.recalc_power_limits()
	gs.write_log(&"damage_tokens_placed", {
		"mech_id": String(mech_id),
		"count": count,
	})


## ── P2-4: 查询和执行API ──


## 返回可选槽位列表（给UI层使用）
## 有装备槽位存在时，空槽位不可放置
## 备用区有装备牌时也属"有装备的区域"（规则书：所有损伤需优先设置在有装备牌的区域上），
## 备用区牌视为1耐久白板装备，可承受损伤（1损伤即弃置）。
func get_valid_damage_slots(target_id: StringName) -> Array[StringName]:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(target_id)
	if mech == null:
		return []

	var equipped_parts: Array[StringName] = []
	var equipped_weapons: Array[StringName] = []
	var equipped_reserve: Array[StringName] = []
	var empty_parts: Array[StringName] = []
	var empty_weapons: Array[StringName] = []

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
			&"RESERVE":
				# 仅有装备牌的备用区可放置损伤（空备用区不参与，损伤打到空备用区无意义）
				if slot.equipped_card != null:
					equipped_reserve.append(slot_id)

	# 规则：有装备槽位存在时，空槽位不可放置
	var has_equipped: bool = not equipped_parts.is_empty() or not equipped_weapons.is_empty() or not equipped_reserve.is_empty()
	if has_equipped:
		var result: Array[StringName] = []
		result.append_array(equipped_parts)
		result.append_array(equipped_weapons)
		result.append_array(equipped_reserve)
		return result
	else:
		var result: Array[StringName] = []
		result.append_array(empty_parts)
		result.append_array(empty_weapons)
		return result


## 在指定槽位放1枚损伤标记（玩家逐枚放置模式）
func place_one_damage_token(target_id: StringName, slot_id: StringName) -> void:
	place_one_token_at_slot(target_id, slot_id)


## 检查并处理装备损坏
func check_and_handle_equipment_break(target_id: StringName, slot_id: StringName) -> bool:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(target_id)
	if mech == null:
		return false
	var slot: MechSlotState = mech.slots.get(slot_id)
	if slot == null or slot.equipped_card == null:
		return false

	var card = slot.equipped_card
	if card.def == null or card.def.card_kind != &"equipment":
		return false

	if card.damage_tokens < slot.get_equipment_durability():
		return false

	# 装备损坏
	context.equipment_break_service.check_equipment_broken(target_id, slot_id)
	return true


## ── 内部方法 ──


## 为损伤标记选择目标槽位（AI自动放置）
## 优先选择已装备的部件槽位，其次是武器槽位，再次是备用区（有牌），最后是空槽位
## 优先级：已装备部件 > 已装备武器 > 已装备备用区 > 空部件 > 空武器 > 其他
func _choose_slot_for_token(mech: MechState) -> StringName:
	var equipped_parts: Array[StringName] = []
	var equipped_weapons: Array[StringName] = []
	var equipped_reserve: Array[StringName] = []
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
			&"RESERVE":
				# 有牌备用区属"有装备的区域"（1耐久白板）；空备用区归入其他（最低优先）
				if slot.equipped_card != null:
					equipped_reserve.append(slot_id)
				else:
					other_slots.append(slot_id)
			_:
				other_slots.append(slot_id)

	# 按优先级返回第一个可用槽位（走 context.rng 同步随机，锁步双端一致）
	var _r = context.rng if context != null and context.rng != null else null
	if not equipped_parts.is_empty():
		return equipped_parts[(_r.randi() if _r != null else randi()) % equipped_parts.size()]
	if not equipped_weapons.is_empty():
		return equipped_weapons[(_r.randi() if _r != null else randi()) % equipped_weapons.size()]
	if not equipped_reserve.is_empty():
		return equipped_reserve[(_r.randi() if _r != null else randi()) % equipped_reserve.size()]
	if not empty_parts.is_empty():
		return empty_parts[(_r.randi() if _r != null else randi()) % empty_parts.size()]
	if not empty_weapons.is_empty():
		return empty_weapons[(_r.randi() if _r != null else randi()) % empty_weapons.size()]
	if not other_slots.is_empty():
		return other_slots[(_r.randi() if _r != null else randi()) % other_slots.size()]

	return &""


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
