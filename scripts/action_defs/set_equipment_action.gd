## set_equipment_action.gd — 设置装备牌动作
##
## 按新规则文档定义：
##   ① 提取装备牌信息
##   ② 提示玩家选择设置区域
##   ③ 弃置该区域的旧装备牌
##   ④ 移除区域内损伤 → 发出 SET_EQUIP_BEFORE
##   ⑤ 将装备牌设置在区域上 → 发出 SET_EQUIP_AT
##   ⑥ 正式设置（数值参与计算） → 发出 SET_EQUIP_AFTER
##   ⑦ 设置装备牌结算 → 发出 SET_EQUIP_SETTLE
extends Action
class_name SetEquipmentAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedEquipmentEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")


func _init() -> void:
	action_type = &"set_equipment"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",    timing_point = &"",                          handler = _step_extract_info},
		{step_name = &"select_slot",    timing_point = &"",                          handler = _step_select_slot},
		{step_name = &"discard_old",    timing_point = &"",                          handler = _step_discard_old},
		{step_name = &"remove_damage",  timing_point = _TimingConst.SET_EQUIP_BEFORE, handler = _step_remove_damage},
		{step_name = &"place_equip",    timing_point = _TimingConst.SET_EQUIP_AT,   handler = _step_place_equip},
		{step_name = &"activate_equip", timing_point = _TimingConst.SET_EQUIP_AFTER,  handler = _step_activate_equip},
		{step_name = &"settle",         timing_point = _TimingConst.SET_EQUIP_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "设置装备牌"


func _step_extract_info(action: Action) -> Dictionary:
	return {}


func _step_select_slot(action: Action) -> Dictionary:
	var slot_id: StringName = action.record.get("slot_id", &"")
	if slot_id != &"":
		return {"slot_id": slot_id}
	return {
		"need_input": true,
		"input_type": &"select_equipment_slot",
		"input_params": {
			"card_id": action.record.get("card_id", &""),
			"mech_id": action.record.get("mech_id", &""),
		},
	}


func _step_discard_old(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var slot_id: StringName = action.record.get("slot_id", &"")

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null or slot_id == &"":
		return result

	var slot = mech.slots.get(slot_id)
	if slot != null and slot.equipped_card != null:
		var old_card = slot.equipped_card
		# 旧装备必须作为本动作的子动作完整弃置；若离场效果暂停，设置装备也随之暂停。
		context.action_service.execute_sub_action({
			"type": &"EXECUTE_DISCARD",
			"params": {"card_ids": [old_card.instance_id], "count": 1, "executor": &"system_default", "reason": &"equipment_replace"},
		}, action.record.duplicate(), action)
		result["discarded_card_id"] = old_card.instance_id
		if not action.pending_effect_action_ids.is_empty():
			result["effect_action_created"] = true

	return result


func _step_remove_damage(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_id", &"")
	var card = context.game_state.get_card(card_id)
	if card != null and card.def != null:
		var durability: int = card.def.durability if "durability" in card.def else 0
		if durability > 0:
			var mech_id: StringName = action.record.get("mech_id", &"")
			var slot_id: StringName = action.record.get("slot_id", &"")
			var mech = context.game_state.mechs.get(mech_id)
			if mech != null:
				var slot = mech.slots.get(slot_id)
				if slot != null:
					# 弃置「新牌耐久数」的区域损伤（最多弃现有数）。新牌的损伤在 _step_place_equip
					# 继承区域剩余损伤（损伤在区域上=在牌上）。
					# 走 damage_change(decrease, direct_remove) 子动作：①正常路径直接从该区域移除
					# min(耐久, 现有区域损伤) 不弹面板；②pilot_008 安德洛美达 effect_03 可在
					# DAMAGE_CHANGE_BEFORE 逆转为「设置等量损伤」（移除取消，安德洛美达选位放置）。
					var tokens_to_remove: int = mini(durability, slot.region_damage_tokens)
					if tokens_to_remove > 0:
						context.action_service.execute_sub_action({
							"type": &"EXECUTE_DAMAGE_CHANGE",
							"params": {
								"mech_ids": [mech_id],
								"value": tokens_to_remove,
								"method": &"decrease",
								"target_mech_id": mech_id,
								"target_slot_id": slot_id,
								"direct_remove": true,
								"executor": &"system_default",
								"reason": &"set_equipment_replace",
							}
						}, action.record.duplicate(), action)
						if not action.pending_effect_action_ids.is_empty():
							result["effect_action_created"] = true
	return result


func _step_place_equip(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_id", &"")
	var mech_id: StringName = action.record.get("mech_id", &"")
	var slot_id: StringName = action.record.get("slot_id", &"")

	if card_id == &"" or mech_id == &"" or slot_id == &"":
		return result

	var card = context.game_state.get_card(card_id)
	if card == null:
		return result

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return result

	var slot = mech.slots.get(slot_id)
	if slot == null:
		return result

	# 将装备牌设置在区域上，但在 activate_equip 前不参与数值或效果。
	slot.equipped_card = card
	card.counters["_pending_equipment_activation"] = true
	card.slot_id = slot_id
	card.mech_id = mech_id
	card.zone = &"equipment_slot"

	# 备用区装备 face_down（白板：仅持有者可见、无效果、1耐久）；设置到部件/武器区时翻面为
	# face_up。从备用区重新设置到部件区时，牌此前 face_down=true 必须在此重置为 false，
	# 否则 _register_equipment_effects 见 face_down 跳过 -> "设置时"效果（如王牌装头部 effect_033
	# 抽行动牌）不注册 -> SET_EQUIP_AFTER 无监听器 -> 效果不触发。
	card.face_down = (slot.slot_kind == &"RESERVE")

	# 从装备手牌移除
	var player = context.game_state.get_player_for_mech(mech_id)
	if player != null:
		player.equipment_hand.erase(card_id)

	# 新牌继承区域剩余损伤（损伤在区域上=在牌上，二者保持一致；备用区白板不继承）。
	# 若继承后损伤≥耐久，立即损坏弃置（区域损伤保留），并跳过 activate 的效果注册。
	if slot.slot_kind != &"RESERVE":
		card.damage_tokens = slot.region_damage_tokens
		var new_durability: int = card.def.durability if (card.def != null and "durability" in card.def) else 0
		if new_durability > 0 and card.damage_tokens >= new_durability:
			card.counters.erase("_pending_equipment_activation")
			context.deck_service.discard_card(card.instance_id, &"damage_durability")
			slot.equipped_card = null
			# 槽位变空，重算动力上限并调整当前动力
			var old_max_power: int = mech.max_power
			mech.max_power = mech.get_total_power()
			mech.sync_own_power_after_max_change(old_max_power)
			action.record["equipment_broken_on_set"] = true
			context.game_state.write_log(&"equipment_broken_by_damage", {
				"card_id": String(card_id),
				"slot_id": String(slot_id),
			})
			return result

	return result


## 注册装备牌的效果到TimingEngine
## 装备牌设置到区域后调用：查 GeneratedEquipmentEffects 取该牌的 effect 列表，
## 对 LISTEN 模式效果注册 permanent listener（携带 binding_context=装备牌来源信息），
## 对 DIRECT 主动效果也注册到 permanent_listeners（供 skill_bar/equipment_panel 扫描）。
## 派生值型效果（联邦/帝国头部、重甲头部、重甲右臂/机动右腿）不注册监听器，实时重算。
func _register_equipment_effects(card, mech_id: StringName, slot_id: StringName = &"") -> void:
	if context == null or context.timing_engine == null:
		return
	if card == null or card.def == null:
		return

	# 备用区装备为白板（face_down）：不注册任何效果监听器（用户裁定：备用区装备
	# 仅持有者可见、无效果、不被检索；从备用区正式设置到部件区时才注册效果）。
	if card.get("face_down") == true:
		return

	# 武器装备牌效果现已落码（effect_093+），正常注册。武器仅在正面设置到 WEAPON 槽时注册
	# permanent listener；备用区不注册（上面 face_down 守卫已拦）。派生值型武器效果（120）
	# 由 _is_derived_effect 跳过监听器注册，实时重算。effect_138 质能全转换已改主动触发，正常注册。

	# 取该牌的 effect_id 列表
	var effect_ids: Array = _GeneratedEquipmentEffects.get_effects_for_card(card.def.card_id, context)
	if effect_ids.is_empty():
		return

	var all_effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()

	# 来源信息（注入 binding_context，供 condition/skill_bar 识别装备牌）
	var player_id: StringName = card.owner_player_id
	var binding_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mech_id,
		"player_id": player_id,
		"card_def_id": card.def.card_id,
		"slot_id": slot_id if slot_id != &"" else card.slot_id,
	}

	var registered_timings: Array[StringName] = []
	for effect_id: StringName in effect_ids:
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null:
			continue

		# 派生值型效果（占位 DIRECT + 无 actions + effect_id 在派生值集合）不注册监听器
		if _is_derived_effect(effect_id):
			continue

		# DIRECT 主动效果：若无 listen_timing，注册到一个虚拟时点供 skill_bar 扫描
		# （机动头部、狙击右臂）。也可被 equipment_panel 主动按钮直接触发。
		if effect.mode == _TimingConst.MODE_DIRECT and effect.listen_timing == &"":
			# 用 effect_id 本身作为虚拟时点名注册，equipment_panel/skill_bar 可扫描
			context.timing_engine.register_permanent_listener(effect_id, effect, binding_ctx)
			registered_timings.append(effect_id)
			continue

		# LISTEN 模式：注册到 effect.listen_timing
		if effect.mode == _TimingConst.MODE_LISTEN and effect.listen_timing != &"":
			context.timing_engine.register_permanent_listener(effect.listen_timing, effect, binding_ctx)
			registered_timings.append(effect.listen_timing)

		# AVAILABILITY 模式：注册到 effect.listen_timing（响应窗口可选牌，如装备牌「被攻击时可响应」）
		# 装备牌 AVAILABILITY 效果设置到机甲后即生效，被攻击时进响应窗口。
		if effect.mode == _TimingConst.MODE_AVAILABILITY and effect.listen_timing != &"":
			context.timing_engine.register_permanent_listener(effect.listen_timing, effect, binding_ctx)
			registered_timings.append(effect.listen_timing)

	# 记录已注册的时点列表到 card.counters，供注销时使用（虽然注销按 card_instance_id）
	if not registered_timings.is_empty():
		card.counters["registered_equipment_listeners"] = registered_timings


## 派生值型效果集合（不注册监听器，由 MechState/MechSlotState 实时重算）
func _is_derived_effect(effect_id: StringName) -> bool:
	return effect_id in [
		&"equipment_effect_002",  # 联邦头部·按联邦数+护甲
		&"equipment_effect_008",  # 帝国头部·按帝国数+动力
		&"equipment_effect_014",  # 重甲·损伤不影响护甲
		&"equipment_effect_016",  # 重甲右臂/机动右腿·损伤≥1+动力
		&"equipment_effect_021",  # 机动左腿·损伤≥2+动力
		&"equipment_effect_046",  # 超重甲头部·总损伤<4免疫
		&"equipment_effect_048",  # 超重甲右臂·损伤≥2动力+2
		&"equipment_effect_092",  # 轰雷右臂·损伤≥2动力+3
		&"equipment_effect_049",  # 超重甲臂/腿·此牌损伤<2免疫
		&"equipment_effect_066",  # 联邦圣牛头·每联邦装备护甲+1(含自身)
		&"equipment_effect_070",  # 帝国雄鹰头·每帝国装备动力+1(含自身)
		&"equipment_effect_074",  # 轰雷·此牌损伤<3免疫护甲
		&"equipment_effect_080",  # 一角兽头·全场联邦光环护甲+1
		&"equipment_effect_086",  # 神莺头·全场帝国光环动力+1
		&"equipment_effect_087",  # 神莺躯干·虚拟武器(权限型，由武器选择识别)
		&"equipment_effect_120",  # 武器 26/27·每1自损威力-2(派生值实时重算)
	]


## 注销装备牌的所有 permanent listener（装备弃置/替换时调用）
func _unregister_equipment_effects(card) -> void:
	if context == null or context.timing_engine == null:
		return
	if card == null:
		return
	context.timing_engine.unregister_permanent_listeners_for_card(card.instance_id)


func _step_activate_equip(action: Action) -> Dictionary:
	var card_id: StringName = action.record.get("card_id", &"")
	var mech_id: StringName = action.record.get("mech_id", &"")
	var card = context.game_state.get_card(card_id)
	var mech = context.game_state.mechs.get(mech_id)
	if card == null or mech == null:
		return {"error": "装备激活失败"}
	# 设牌时因损伤立即损坏 -> 已在 _step_place_equip 弃置，跳过效果注册/动力重算
	if action.record.get("equipment_broken_on_set", false):
		return {}
	card.counters.erase("_pending_equipment_activation")
	_register_equipment_effects(card, mech_id, action.record.get("slot_id", &""))
	var slot = mech.slots.get(action.record.get("slot_id", &""))
	if slot != null and slot.slot_kind == &"PART":
		var old_max_power: int = mech.max_power
		mech.max_power = mech.get_total_power()
		mech.sync_own_power_after_max_change(old_max_power)
	return {}


func _step_settle(action: Action) -> Dictionary:
	# 通知装备设置完成
	# 时点 SET_EQUIP_SETTLE 由步骤级 timing_point 自动 fire（翻转后 handler 先跑、再由
	# _execute_step 阶段3 fire），此处不再手动 fire，避免双重 fire。
	return {}
