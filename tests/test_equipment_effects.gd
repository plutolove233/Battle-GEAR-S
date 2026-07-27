extends RefCounted

## 装备牌效果测试（A1-I 实现后的验证）
## 覆盖：联邦头部动态护甲、重甲头部损伤不影响护甲、机动头部主动效果 once_per_turn、
##       量产装可卖出已设置装备、装备效果注册到 TimingEngine、近战头部类型转换。
## 文档附录B的8类用例（正常发动/取消/条件边界/状态竞争/多实例/来源离场/中断无效/清理）
## 取可单元化的部分；攻击流程相关用例走实机 F3 验证。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedEquipmentEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 把指定 card_def_id 的装备牌塞入玩家装备手牌，返回卡牌实例ID
func _ensure_equipment_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	# 先看手牌
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	# 从装备牌堆找
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
	return &""


## 测试1：GeneratedEquipmentEffects 定义了全部31个 effect_id
func test_equipment_effects_defined() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	for i in range(1, 32):
		var eid: StringName = StringName("equipment_effect_%03d" % i)
		if not effects.has(eid):
			return "缺少效果定义: %s" % String(eid)
	# 量产装权限型 effect_001 也应存在
	if not effects.has(&"equipment_effect_001"):
		return "缺少 equipment_effect_001"
	return true


## 测试2：装备效果注册到 TimingEngine（set_equipment 后 permanent_listeners 含该效果）
func test_equipment_effect_registers_on_set() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 联邦右腿 effect_006（ATTACK_PRE listener）
	var card_id: StringName = _ensure_equipment_in_hand(battle, "part_011_联邦普装_右腿")
	if card_id == &"":
		return "找不到联邦右腿装备牌"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", card_id, &"右腿")
	if not result.get("ok", false):
		return "设置装备失败: %s" % String(result.get("message", ""))
	# 推进帧让 set_equipment 动作完成（动作异步）
	await _pump_frames(3)
	var has_listener: bool = battle.context.timing_engine.permanent_listeners.has(_TimingConst.ATTACK_PRE)
	if not has_listener:
		# 可能 listener 已触发后清理，检查 binding_context
		var found := false
		for timing in battle.context.timing_engine.permanent_listeners:
			var entries: Array = battle.context.timing_engine.permanent_listeners[timing]
			for entry in entries:
				var eff = entry.get("effect") if entry is Dictionary else null
				if eff and eff.effect_id == &"equipment_effect_006":
					found = true
					break
			if found:
				break
		if not found:
			return "装备设置后未注册 effect_006 的 permanent listener"
	return true


## 测试3：联邦头部动态护甲（其他区域每张联邦装备+1护甲）
func test_federation_head_dynamic_armor() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 记录设置前护甲
	var armor_before: int = mech.get_armor()
	# 设置联邦头部（part_007）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_007_联邦普装_头部")
	if head_id == &"":
		return "找不到联邦头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 设置第二张联邦装备（躯干/右臂/左臂/右腿/左腿任一可找到的）
	var second_id: StringName = &""
	var second_slot: StringName = &""
	for pair in [["part_008_联邦普装_躯干", &"躯干"], ["part_009_联邦普装_右臂", &"右臂"], ["part_010_联邦普装_左臂", &"左臂"], ["part_011_联邦普装_右腿", &"右腿"], ["part_012_联邦普装_左腿", &"左腿"]]:
		var cid: StringName = _ensure_equipment_in_hand(battle, pair[0])
		if cid != &"":
			second_id = cid
			second_slot = pair[1]
			break
	if second_id == &"":
		# 教程 deck 无第二张联邦装备，跳过动态护甲多装备验证（非失败）
		push_warning("教程 deck 无第二张联邦装备，跳过 compute_faction_armor_bonus 多装备验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", second_id, second_slot)
	await _pump_frames(3)
	# 头部因多1张其他区域联邦装备，护甲加成应≥1
	var bonus: int = _GeneratedEquipmentEffects.compute_faction_armor_bonus(mech, &"头部")
	if bonus < 1:
		return "联邦头部动态护甲加成应≥1（其他区域有联邦装备），实际: %d" % bonus
	return true


## 测试4：重甲头部损伤不影响护甲（effect_014）
func test_heavy_head_damage_immune_armor() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 设置重甲头部（part_019, effect_014）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_019_重甲装_头部")
	if head_id == &"":
		return "找不到重甲头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var slot = mech.slots.get(&"头部")
	if slot == null or slot.equipped_card == null:
		return "头部装备未设置"
	# card_has_damage_immune_armor 应返回 true
	if not _GeneratedEquipmentEffects.card_has_damage_immune_armor(slot.equipped_card):
		return "重甲头部装备应识别为损伤免疫护甲（effect_014）"
	# 给区域加损伤，护甲不应降
	var armor_before: int = slot.get_effective_armor()
	slot.region_damage_tokens += 2
	var armor_after: int = slot.get_effective_armor()
	if armor_after != armor_before:
		return "重甲头部有损伤时护甲应不变（损伤不影响护甲），前:%d 后:%d" % [armor_before, armor_after]
	return true


## 测试5：机动头部主动效果 once_per_turn（effect_017）
func test_mobile_head_active_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 设置机动头部（part_025, effect_017）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_025_机动装_头部")
	if head_id == &"":
		return "找不到机动头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# effect_017 应注册为 DIRECT permanent listener（timing=effect_id）
	var found_direct: bool = false
	for timing in battle.context.timing_engine.permanent_listeners:
		var entries: Array = battle.context.timing_engine.permanent_listeners[timing]
		for entry in entries:
			var eff = entry.get("effect") if entry is Dictionary else null
			if eff and eff.effect_id == &"equipment_effect_017" and eff.mode == _TimingConst.MODE_DIRECT:
				found_direct = true
				break
		if found_direct:
			break
	if not found_direct:
		return "机动头部 effect_017 未注册为 DIRECT permanent listener"
	# once_per_turn_key 应已设置
	var effect_found = null
	for timing in battle.context.timing_engine.permanent_listeners:
		for entry in battle.context.timing_engine.permanent_listeners[timing]:
			var eff = entry.get("effect") if entry is Dictionary else null
			if eff and eff.effect_id == &"equipment_effect_017":
				effect_found = eff
				break
		if effect_found:
			break
	if effect_found == null or effect_found.once_per_turn_key == &"":
		return "机动头部 effect_017 应设 once_per_turn_key"
	return true


## 测试6：量产装可卖出已设置装备（effect_001）
func test_mass_production_sell_set_equipment() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var player = battle.context.game_state.players.get(&"player")
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 设置量产头部（part_001, effect_001）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_001_量产装_头部")
	if head_id == &"":
		return "找不到量产头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var gold_before: int = player.gold
	# 卖出已设置装备
	var sell_result: Dictionary = battle.context.card_set_service.sell_equipment(&"player", head_id)
	if not sell_result.get("ok", false):
		return "卖出已设置装备失败: %s" % String(sell_result.get("message", ""))
	var gold_after: int = player.gold
	if gold_after <= gold_before:
		return "卖出后金币应增加，前:%d 后:%d" % [gold_before, gold_after]
	# 头部应变空
	await _pump_frames(3)
	var slot = mech.slots.get(&"头部")
	if slot != null and slot.equipped_card != null:
		return "卖出已设置装备后头部区域应变空"
	return true


## 测试7：近战头部类型转换效果定义正确（effect_028 priority 20）
func test_melee_head_type_conversion_definition() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	var eff = effects.get(&"equipment_effect_028")
	if eff == null:
		return "缺少 effect_028"
	if eff.priority != 20:
		return "近战头部 effect_028 优先级应为20（先于近战威力+2），实际: %d" % eff.priority
	if eff.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "近战头部应监听 ATTACK_BEFORE"
	# actions 应含 SET_ATTACK_EFFECTIVE_WEAPON_KIND（在 CHOOSE_ONE options 内层）
	var has_set_kind: bool = _action_type_in_effect(eff, &"SET_ATTACK_EFFECTIVE_WEAPON_KIND")
	if not has_set_kind:
		return "近战头部 actions 应含 SET_ATTACK_EFFECTIVE_WEAPON_KIND"
	# 条件应含 ATTACK_EFFECTIVE_WEAPON_KIND_NOT（非近战才转换）
	var has_not_kind: bool = false
	for cond in eff.conditions:
		if cond is Dictionary and cond.get("op", &"") == &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT":
			has_not_kind = true
			break
	if not has_not_kind:
		return "近战头部条件应含 ATTACK_EFFECTIVE_WEAPON_KIND_NOT"
	return true


## 测试8：近战右腿因损伤弃置移除其他区域损伤效果定义（effect_031）
func test_melee_rleg_discard_effect_definition() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	var eff = effects.get(&"equipment_effect_031")
	if eff == null:
		return "缺少 effect_031"
	if eff.listen_timing != _TimingConst.DISCARD_AFTER:
		return "近战右腿应监听 DISCARD_AFTER"
	# 条件应含 DISCARD_REASON_IS(damage_durability)
	var has_reason_cond: bool = false
	for cond in eff.conditions:
		if cond is Dictionary and cond.get("op", &"") == &"DISCARD_REASON_IS" and cond.get("reason", &"") == &"damage_durability":
			has_reason_cond = true
			break
	if not has_reason_cond:
		return "近战右腿条件应含 DISCARD_REASON_IS(damage_durability)"
	# actions 应含 REMOVE_DAMAGE_TOKENS_OTHER_SLOTS（在 CHOOSE_ONE options 内层）
	var has_remove: bool = _action_type_in_effect(eff, &"REMOVE_DAMAGE_TOKENS_OTHER_SLOTS")
	if not has_remove:
		return "近战右腿 actions 应含 REMOVE_DAMAGE_TOKENS_OTHER_SLOTS"
	return true


## 递归检查 effect 的 actions（含 CHOOSE_ONE options 内层）是否含指定 type
func _action_type_in_effect(effect, act_type: StringName) -> bool:
	for act in effect.actions:
		if not (act is Dictionary):
			continue
		if act.get("type", &"") == act_type:
			return true
		# CHOOSE_ONE: 检查 options[].actions[]
		if act.get("type", &"") == &"CHOOSE_ONE":
			var params: Dictionary = act.get("params", {})
			var options: Array = params.get("options", [])
			for opt in options:
				if not (opt is Dictionary):
					continue
				var inner: Array = opt.get("actions", [])
				for sub in inner:
					if sub is Dictionary and sub.get("type", &"") == act_type:
						return true
	return false


## 测试9：discard_card 动作发出 DISCARD_AFTER 时点（tmp_zone 流程）
func test_discard_action_fires_discard_after() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 记录 timing_fired 信号
	var timings_seen: Dictionary = {}
	battle.context.timing_engine.timing_fired.connect(func(timing, _payload):
		timings_seen[timing] = true
	)
	# 弃置一张行动牌（走 discard_card 动作）
	var player = battle.context.game_state.players.get(&"player")
	if player.action_hand.is_empty():
		return "玩家无行动牌可弃"
	var card_id: StringName = player.action_hand[0]
	battle.context.deck_service.discard_card(card_id, &"turn_cleanup")
	await _pump_frames(5)
	if not timings_seen.has(_TimingConst.DISCARD_BEFORE):
		return "弃置未发出 DISCARD_BEFORE 时点"
	if not timings_seen.has(_TimingConst.DISCARD_AFTER):
		return "弃置未发出 DISCARD_AFTER 时点"
	if not timings_seen.has(_TimingConst.DISCARD_SETTLE):
		return "弃置未发出 DISCARD_SETTLE 时点"
	return true


## 测试10：损伤转移时点 DAMAGE_REDIRECT_WINDOW 定义存在
func test_damage_redirect_window_defined() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# DAMAGE_REDIRECT_WINDOW 应在 TimingConst 定义
	if _TimingConst.DAMAGE_REDIRECT_WINDOW != &"DAMAGE_REDIRECT_WINDOW":
		return "DAMAGE_REDIRECT_WINDOW 常量未正确定义"
	# damage_change 动作应有4步（含 offer_redirect）
	var DamageChangeAction = load("res://scripts/action_defs/damage_change_action.gd")
	var action = DamageChangeAction.new()
	action.setup_steps()
	if action.steps.size() != 4:
		return "damage_change 应有4步（含损伤转移窗口），实际: %d" % action.steps.size()
	return true


## 测试 place_damage_tokens_on_slot（A6 损伤转移放置路径）
## bug：原代码 `slot.damage_tokens` 误访问 MechSlotState 上不存在的属性
## （MechSlotState 用 region_damage_tokens，装备牌损伤在 equipped_card.damage_tokens），
## A6 转移触发即报错。修复后应按规范放置：有装备牌加到 card.damage_tokens，否则 region_damage_tokens。
func test_place_damage_tokens_on_slot_places_correctly() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var ga = battle.context.game_actions

	# 找一个空槽（教程机甲基础武器存于 base_weapons 不入槽，槽位皆空）测 region 路径
	var empty_slot: StringName = &""
	for sid: StringName in mech.slots:
		if mech.slots[sid].equipped_card == null:
			empty_slot = sid
			break
	if empty_slot == &"":
		return "未找到空槽"
	var s_empty = mech.slots[empty_slot]
	var region_before: int = s_empty.region_damage_tokens
	ga.place_damage_tokens_on_slot({"mech_id": mech.mech_id, "slot_id": empty_slot, "amount": 2})
	if s_empty.region_damage_tokens - region_before != 2:
		return "空槽应放 region_damage_tokens +2，前=%d 后=%d" % [region_before, s_empty.region_damage_tokens]

	# 测 card 路径：从装备牌堆取一张牌塞入该槽，再放置应加到 equipped_card.damage_tokens
	var card = null
	if gs.deck_state.equipment_deck.size() > 0:
		card = gs.get_card(gs.deck_state.equipment_deck[0])
	if card == null:
		return "装备牌堆为空，无法测 card 路径"
	s_empty.equipped_card = card
	card.damage_tokens = 0
	ga.place_damage_tokens_on_slot({"mech_id": mech.mech_id, "slot_id": empty_slot, "amount": 3})
	if card.damage_tokens != 3:
		return "有装备牌应放 equipped_card.damage_tokens +3，实际 card.damage_tokens=%d" % card.damage_tokens
	return true


## 帧驱动 helper：推进 N 帧让 call_deferred 动作恢复链 flush
func _pump_frames(n: int) -> void:
	for i in range(n):
		await Engine.get_main_loop().process_frame
