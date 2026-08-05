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
const _SellEquipmentPanel = preload("res://scripts/ui/sell_equipment_panel.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _DevModeService = preload("res://scripts/services/DevModeService.gd")


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
	# 从高级装备牌堆找（SR/SSR）
	for i in range(gs.deck_state.advanced_equipment_deck.size()):
		var cid: StringName = gs.deck_state.advanced_equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.advanced_equipment_deck.remove_at(i)
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


## 6部位全装联邦普装时，头部派生护甲应=5（其他5部位各+1，头部自身不计）
func test_federation_head_six_parts_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var dms := _DevModeService.new(battle.context)
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var parts: Array = [
		["part_007_联邦普装_头部", &"头部"],
		["part_008_联邦普装_躯干", &"躯干"],
		["part_009_联邦普装_右臂", &"右臂"],
		["part_010_联邦普装_左臂", &"左臂"],
		["part_011_联邦普装_右腿", &"右腿"],
		["part_012_联邦普装_左腿", &"左腿"],
	]
	for pair in parts:
		var cid: StringName = dms.add_equipment_card_to_player(&"player", pair[0])
		if cid == &"":
			return "创建 %s 失败" % pair[0]
		if not dms.set_equipment_card_to_slot(&"player", cid, pair[1]):
			return "设置 %s 到 %s 失败" % [pair[0], String(pair[1])]
	var head_bonus: int = _GeneratedEquipmentEffects.compute_head_faction_armor_bonus(mech)
	if head_bonus != 5:
		return "6部位全装联邦普装，头部派生护甲应=5（其他5部位），实际 %d" % head_bonus
	return true


## 测试4：重甲头部总损伤阈值免疫（effect_089）+ 重甲左臂无条件免疫（effect_014）
func test_heavy_head_damage_immune_armor() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 设置重甲头部（part_019, effect_089：总损伤<3免疫，≥3失效）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_019_重甲装_头部")
	if head_id == &"":
		return "找不到重甲头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var slot = mech.slots.get(&"头部")
	if slot == null or slot.equipped_card == null:
		return "头部装备未设置"
	var armor_before: int = slot.get_effective_armor(mech)
	# 总损伤2(<3)：免疫，护甲不变
	slot.region_damage_tokens = 2
	if slot.get_effective_armor(mech) != armor_before:
		return "重甲头部总损伤2(<3)应免疫，护甲应不变，前:%d 后:%d" % [armor_before, slot.get_effective_armor(mech)]
	# 总损伤3(≥3)：失效，护甲应降3
	slot.region_damage_tokens = 3
	var armor_3: int = slot.get_effective_armor(mech)
	if armor_3 != armor_before - 3:
		return "重甲头部总损伤3(≥3)应失效护甲降3，前:%d 后:%d" % [armor_before, armor_3]
	# effect_014 无条件免疫（part_022 重甲左臂，牌堆有则测）
	var arm_id: StringName = _ensure_equipment_in_hand(battle, "part_022_重甲装_左臂")
	if arm_id != &"":
		battle.context.card_set_service.set_equipment(&"player", arm_id, &"左臂")
		await _pump_frames(3)
		var aslot = mech.slots.get(&"左臂")
		if aslot != null and aslot.equipped_card != null:
			if not _GeneratedEquipmentEffects.card_has_damage_immune_armor(aslot.equipped_card):
				return "重甲左臂应识别为无条件损伤免疫（effect_014）"
			var ab: int = aslot.get_effective_armor(mech)
			aslot.region_damage_tokens = 4
			if aslot.get_effective_armor(mech) != ab:
				return "重甲左臂无条件免疫，有损伤护甲应不变，前:%d 后:%d" % [ab, aslot.get_effective_armor(mech)]
	return true


## 测试5：机动头部被动效果 once_per_turn（effect_017 监听 BASIC_MOVE_AFTER 耗尽动力）
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
	# effect_017 应注册为 LISTEN permanent listener（timing=BASIC_MOVE_AFTER, action_type=basic_move）
	var effect_found = null
	for timing in battle.context.timing_engine.permanent_listeners:
		for entry in battle.context.timing_engine.permanent_listeners[timing]:
			var eff = entry.get("effect") if entry is Dictionary else null
			if eff and eff.effect_id == &"equipment_effect_017":
				effect_found = eff
				break
		if effect_found:
			break
	if effect_found == null:
		return "机动头部 effect_017 未注册为 permanent listener"
	if effect_found.mode != _TimingConst.MODE_LISTEN:
		return "机动头部 effect_017 应为 LISTEN 模式（非 DIRECT）"
	if effect_found.listen_timing != _TimingConst.BASIC_MOVE_AFTER:
		return "机动头部 effect_017 应监听 BASIC_MOVE_AFTER"
	if String(effect_found.listen_action_type) != "basic_move":
		return "机动头部 effect_017 应监听 basic_move 动作"
	if effect_found.once_per_turn_key == &"":
		return "机动头部 effect_017 应设 once_per_turn_key"
	return true


## 测试6：量产装·头部 卖出已设置装备（effect_001）-- 套装1场景a
## 断言：金币+牌面cost、卖出次数+1、槽位同步清空、牌zone=discard进装备弃牌堆、
##       弃置日志 reason=sell_set_equipment
func test_mass_production_sell_set_equipment() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_001_量产装_头部")
	if head_id == &"":
		return "找不到量产头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var cost: int = gs.get_card(head_id).def.cost
	var gold_before: int = player.gold
	var sells_before: int = player.sell_equipment_count_this_turn
	# 卖出已设置装备
	var sell_result: Dictionary = battle.context.card_set_service.sell_equipment(&"player", head_id)
	if not sell_result.get("ok", false):
		return "卖出已设置装备失败: %s" % String(sell_result.get("message", ""))
	# 金币 +cost、卖出次数 +1（sell_equipment 同步完成）
	if player.gold - gold_before != cost:
		return "卖出金币应 +%d(牌面cost)，前:%d 后:%d" % [cost, gold_before, player.gold]
	if player.sell_equipment_count_this_turn - sells_before != 1:
		return "卖出次数应 +1，前:%d 后:%d" % [sells_before, player.sell_equipment_count_this_turn]
	# 槽位同步清空
	var slot = mech.slots.get(&"头部")
	if slot == null or slot.equipped_card != null:
		return "卖出后头部区域应变空"
	# 弃置异步完成：zone=discard + 进装备弃牌堆 + 日志 reason=sell_set_equipment
	await _pump_frames(6)
	var card = gs.get_card(head_id)
	if card == null or card.zone != &"discard":
		return "卖出后牌 zone 应为 discard，实际: %s" % String(card.zone if card else "null")
	if not gs.deck_state.equipment_discard_pile.has(head_id):
		return "卖出后牌应进入 equipment_discard_pile"
	if not _log_has_discard_reason(gs, head_id, &"sell_set_equipment"):
		return "卖出弃置日志 reason 应为 sell_set_equipment"
	return true


## 测试6b：量产装·躯干 卖出已设置装备（effect_001）-- 套装1场景a 多槽位覆盖
func test_mass_production_sell_torso_slot() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_002_量产装_躯干")
	if torso_id == &"":
		push_warning("教程 deck 无 part_002 量产装·躯干，跳过多槽位卖出测试")
		return true
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	var cost: int = gs.get_card(torso_id).def.cost
	var gold_before: int = player.gold
	var sells_before: int = player.sell_equipment_count_this_turn
	var sell_result: Dictionary = battle.context.card_set_service.sell_equipment(&"player", torso_id)
	if not sell_result.get("ok", false):
		return "卖出躯干已设置装备失败: %s" % String(sell_result.get("message", ""))
	if player.gold - gold_before != cost:
		return "躯干卖出金币应 +%d，前:%d 后:%d" % [cost, gold_before, player.gold]
	if player.sell_equipment_count_this_turn - sells_before != 1:
		return "躯干卖出次数应 +1"
	var slot = mech.slots.get(&"躯干")
	if slot == null or slot.equipped_card != null:
		return "卖出后躯干区域应变空"
	await _pump_frames(6)
	if not gs.deck_state.equipment_discard_pile.has(torso_id):
		return "卖出后躯干牌应进入 equipment_discard_pile"
	if not _log_has_discard_reason(gs, torso_id, &"sell_set_equipment"):
		return "躯干卖出弃置日志 reason 应为 sell_set_equipment"
	return true


## 测试6c：卖出次数已满时卖出已设置装备被拒（effect_001）-- 套装1场景c
func test_mass_production_sell_limit_full() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_001_量产装_头部")
	if head_id == &"":
		return "找不到量产头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 预置本回合卖出次数已满（GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN=2）
	player.sell_equipment_count_this_turn = 2
	var gold_before: int = player.gold
	var sell_result: Dictionary = battle.context.card_set_service.sell_equipment(&"player", head_id)
	if sell_result.get("ok", false):
		return "卖出次数已满应被拒，但卖出成功"
	# 牌仍在头部、金币不变、卖出次数不变
	var slot = mech.slots.get(&"头部")
	if slot == null or slot.equipped_card == null:
		return "被拒后头部装备应仍在"
	if player.gold != gold_before:
		return "被拒后金币应不变，前:%d 后:%d" % [gold_before, player.gold]
	if player.sell_equipment_count_this_turn != 2:
		return "被拒后卖出次数应不变(2)"
	return true


## 测试6d：卖出面板列出已设置量产装且取消不改变状态 -- 套装1场景b
func test_mass_production_sell_cancel_no_change() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_001_量产装_头部")
	if head_id == &"":
		return "找不到量产头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var gold_before: int = player.gold
	var sells_before: int = player.sell_equipment_count_this_turn
	var display_name: String = gs.get_card(head_id).def.display_name
	# 打开卖出面板（不加入场景树亦可构建子节点）
	var panel = _SellEquipmentPanel.new()
	panel.local_player_id = &"player"
	panel.configure(battle.context)
	# 面板应列出已设置的量产装（effect_001 权限识别）
	var listed := false
	if panel._scroll != null and panel._scroll.has_meta("content"):
		var content = panel._scroll.get_meta("content")
		for child in content.get_children():
			if child is Button and String(child.text).find("已设置") >= 0 and String(child.text).find(display_name) >= 0:
				listed = true
				break
	if not listed:
		panel.free()
		return "卖出面板应列出已设置的量产装(%s)" % display_name
	# 取消（不确认）-> 状态不变
	panel.emit_signal("cancelled")
	panel.free()
	await _pump_frames(2)
	if player.gold != gold_before:
		return "取消卖出后金币应不变，前:%d 后:%d" % [gold_before, player.gold]
	if player.sell_equipment_count_this_turn != sells_before:
		return "取消卖出后卖出次数应不变"
	var slot = gs.get_mech_for_player(&"player").slots.get(&"头部")
	if slot == null or slot.equipped_card == null:
		return "取消卖出后头部装备应仍在"
	if _log_has_discard_reason(gs, head_id, &"sell_set_equipment"):
		return "取消卖出不应产生弃置日志"
	return true


## 检查 gs.log 中是否存在指定 card_id + reason 的 card_discarded 条目
func _log_has_discard_reason(gs, card_id: StringName, reason: StringName) -> bool:
	for entry in gs.log:
		if String(entry.get("event", &"")) != "card_discarded":
			continue
		if String(entry.get("card_id", &"")) == String(card_id) and String(entry.get("reason", &"")) == String(reason):
			return true
	return false


## 测试6e：联邦头部 effect_002 计数排除备用区（用户裁定）-- 套装2/007
## 放一张联邦装备到备用区(face_up)，验证 compute_faction_armor_bonus 不计入备用区
func test_federation_head_count_excludes_reserve() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_007_联邦普装_头部")
	if head_id == &"":
		return "找不到联邦头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	if not mech.slots.has(&"reserve_1"):
		push_warning("机甲无 reserve_1 槽，跳过备用区排除测试")
		return true
	# 找另一张联邦装备放入备用区(face_up)
	var reserve_card_id: StringName = &""
	for cid: StringName in gs.deck_state.equipment_deck:
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id).find("联邦") >= 0 and cid != head_id:
			reserve_card_id = cid
			break
	if reserve_card_id == &"":
		push_warning("无额外联邦装备可放入备用区，跳过备用区排除测试")
		return true
	gs.deck_state.equipment_deck.erase(reserve_card_id)
	var rcard = gs.get_card(reserve_card_id)
	if rcard == null:
		return "备用区测试牌实例丢失"
	# 设置前的 bonus（排除头部源槽；其他区域联邦装备会计入）
	var bonus_before: int = _GeneratedEquipmentEffects.compute_faction_armor_bonus(mech, &"头部")
	# 手动放入备用区并翻为正面
	mech.slots[&"reserve_1"].equipped_card = rcard
	rcard.zone = &"equipped"
	rcard.face_down = false
	rcard.mech_id = mech.mech_id
	rcard.slot_id = &"reserve_1"
	var bonus_after: int = _GeneratedEquipmentEffects.compute_faction_armor_bonus(mech, &"头部")
	# 备用区应被排除：放入备用区前后 bonus 不变
	if bonus_after != bonus_before:
		return "联邦头部计数应排除备用区，放入备用区联邦装备前后 bonus 应不变，before=%d after=%d" % [bonus_before, bonus_after]
	return true


## 测试6f：套装2 联邦普装 effect_003-007 结构对齐拆解（optional/条件/时点/动作）
func test_federation_suite_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_003（008 联邦躯干）：optional CHOOSE_ONE 包 REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT
	var e003 = effects.get(&"equipment_effect_003")
	if e003 == null:
		return "缺少 effect_003"
	if e003.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_003 应监听 DISCARD_AFTER"
	if not _action_type_in_effect(e003, &"CHOOSE_ONE"):
		return "effect_003 应含 CHOOSE_ONE（重构为 optional）"
	if not _action_type_in_effect(e003, &"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT"):
		return "effect_003 应含 REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT"
	if not _choose_one_is_optional(e003):
		return "effect_003 CHOOSE_ONE 应 optional=true（'可移除'）"
	# effect_004（009 联邦右臂）：DAMAGE_REDIRECT_WINDOW + TARGET_IS_OWN_MECH(目标==我方机甲) + max_points=2
	var e004 = effects.get(&"equipment_effect_004")
	if e004 == null:
		return "缺少 effect_004"
	if e004.listen_timing != &"DAMAGE_REDIRECT_WINDOW":
		return "effect_004 应监听 DAMAGE_REDIRECT_WINDOW"
	if not _has_condition(e004, &"TARGET_IS_OWN_MECH"):
		return "effect_004 条件应含 TARGET_IS_OWN_MECH"
	if not _action_has_param(e004, &"OFFER_DAMAGE_REDIRECT", &"max_points", 2):
		return "effect_004 OFFER_DAMAGE_REDIRECT max_points 应=2"
	# effect_005（010 联邦左臂）：DRAW_EQUIPMENT_AND_IMMEDIATELY_SET on DISCARD_AFTER
	var e005 = effects.get(&"equipment_effect_005")
	if e005 == null:
		return "缺少 effect_005"
	if e005.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_005 应监听 DISCARD_AFTER"
	if not _action_type_in_effect(e005, &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"):
		return "effect_005 应含 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"
	# effect_006（011 联邦右腿）：ATTACK_PRE + optional CHOOSE_ONE + EXECUTE_STAT_MODIFY power+2
	var e006 = effects.get(&"equipment_effect_006")
	if e006 == null:
		return "缺少 effect_006"
	if e006.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_006 应监听 ATTACK_PRE"
	if e006.listen_action_type != &"attack":
		return "effect_006 listen_action_type 应为 attack"
	if not _action_type_in_effect(e006, &"EXECUTE_STAT_MODIFY"):
		return "effect_006 应含 EXECUTE_STAT_MODIFY"
	if not _choose_one_is_optional(e006):
		return "effect_006 CHOOSE_ONE 应 optional=true"
	# effect_007（012 联邦左腿）：ATTACK_AFTER + optional CHOOSE_ONE + DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS
	var e007 = effects.get(&"equipment_effect_007")
	if e007 == null:
		return "缺少 effect_007"
	if e007.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_007 应监听 ATTACK_AFTER"
	if not _action_type_in_effect(e007, &"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS"):
		return "effect_007 应含 DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS"
	if not _choose_one_is_optional(e007):
		return "effect_007 CHOOSE_ONE 应 optional=true（'可以弃置'）"
	# ATTACK_MARKERS_ABOVE threshold=0（严格 > 即 ≥1 损伤）
	var has_markers := false
	for cond in e007.conditions:
		if cond is Dictionary and cond.get("op", &"") == &"ATTACK_MARKERS_ABOVE" and int(cond.get("threshold", -1)) == 0:
			has_markers = true
	if not has_markers:
		return "effect_007 条件应含 ATTACK_MARKERS_ABOVE threshold=0(≥1损伤)"
	return true


## 检查 effect 的首个 CHOOSE_ONE 是否 optional=true
func _choose_one_is_optional(effect) -> bool:
	for act in effect.actions:
		if not (act is Dictionary):
			continue
		if act.get("type", &"") == &"CHOOSE_ONE":
			return bool(act.get("params", {}).get("optional", false))
	return false


## 测试6g：effect_005 联邦左臂弃置抽装备立即设置 -- 确认设置（套装2/010）
func test_federation_larm_draw_equipment_immediate_set_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	player.is_human = true
	var mech = gs.get_mech_for_player(&"player")
	var larm_id: StringName = _ensure_equipment_in_hand(battle, "part_010_联邦普装_左臂")
	if larm_id == &"":
		return "找不到联邦左臂装备牌"
	battle.context.card_set_service.set_equipment(&"player", larm_id, &"左臂")
	await _pump_frames(6)
	# 守卫：part_010 应已设置到左臂
	var larm_slot0 = mech.slots.get(&"左臂")
	if larm_slot0 == null or larm_slot0.equipped_card == null or larm_slot0.equipped_card.instance_id != larm_id:
		return "set_equipment 后联邦左臂应在左臂槽，实际: %s" % str(larm_slot0.equipped_card)
	# 守卫：effect_005 应注册为 DISCARD_AFTER permanent listener
	var eff005_registered := false
	for tl in battle.context.timing_engine.permanent_listeners:
		for le in battle.context.timing_engine.permanent_listeners[tl]:
			var e = le.get("effect") if le is Dictionary else null
			if e and e.effect_id == &"equipment_effect_005":
				eff005_registered = true
				break
		if eff005_registered:
			break
	if not eff005_registered:
		return "effect_005 未注册为 permanent listener"
	# 清空装备手牌（移回牌堆），便于断言抽到的牌
	for cid: StringName in player.equipment_hand.duplicate():
		player.equipment_hand.erase(cid)
		var hc = gs.get_card(cid)
		if hc != null:
			hc.zone = &"equipment_deck"
		gs.deck_state.equipment_deck.append(cid)
	if gs.deck_state.equipment_deck.is_empty():
		return "装备牌堆为空，无法测抽装备"
	# 弃置联邦左臂 -> DISCARD_AFTER 触发 effect_005
	battle.context.deck_service.discard_card(larm_id, &"equipment_replace")
	await _pump_frames(8)
	# 找到挂起的 discard_card 动作（应挂在 DISCARD_AFTER 的 effect_005 立即设置窗）
	var discard_action_id: StringName = &""
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		discard_action_id = a.action_id
		break
	if discard_action_id == &"":
		var active_ids: Array = battle.context.action_registry.get_active_ids()
		var pend_keys: Array = battle.context.timing_engine._pending_effect.keys()
		return "未找到 discard_card 动作（effect_005 未挂起？）active=%s pending=%s" % [str(active_ids), str(pend_keys)]
	var pend: Dictionary = battle.context.timing_engine._pending_effect.get(discard_action_id, {})
	if String(pend.get("phase", &"")) != &"draw_equipment_set":
		return "effect_005 应挂起 phase=draw_equipment_set，实际: %s" % String(pend.get("phase", &""))
	var drawn_id: StringName = pend.get("drawn_card_id", &"")
	var valid_slots: Array = pend.get("valid_slots", [])
	if drawn_id == &"" or not player.equipment_hand.has(drawn_id):
		return "抽到的装备应入手牌"
	if valid_slots.is_empty():
		return "effect_005 应有合法设置槽位"
	var chosen_slot: StringName = valid_slots[0]
	# 确认：设置到 chosen_slot
	battle.context.timing_engine.resume_pending_effect(discard_action_id, {"chosen_slot_id": chosen_slot})
	await _pump_frames(8)
	# 抽到的装备应设置到 chosen_slot
	var slot = mech.slots.get(chosen_slot)
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != drawn_id:
		return "确认后抽到的装备应设到 %s" % String(chosen_slot)
	if player.equipment_hand.has(drawn_id):
		return "设置后抽到的装备应不在手牌"
	if not gs.deck_state.equipment_discard_pile.has(larm_id):
		return "原联邦左臂应进装备弃牌堆"
	return true


## 测试6h：effect_005 联邦左臂弃置抽装备立即设置 -- 取消弃置（套装2/010）
func test_federation_larm_draw_equipment_immediate_set_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	player.is_human = true
	var larm_id: StringName = _ensure_equipment_in_hand(battle, "part_010_联邦普装_左臂")
	if larm_id == &"":
		return "找不到联邦左臂装备牌"
	battle.context.card_set_service.set_equipment(&"player", larm_id, &"左臂")
	await _pump_frames(3)
	for cid: StringName in player.equipment_hand.duplicate():
		player.equipment_hand.erase(cid)
		var hc = gs.get_card(cid)
		if hc != null:
			hc.zone = &"equipment_deck"
		gs.deck_state.equipment_deck.append(cid)
	if gs.deck_state.equipment_deck.is_empty():
		return "装备牌堆为空，无法测抽装备"
	battle.context.deck_service.discard_card(larm_id, &"equipment_replace")
	await _pump_frames(8)
	var discard_action_id: StringName = &""
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		discard_action_id = a.action_id
		break
	if discard_action_id == &"":
		return "未找到 discard_card 动作"
	var pend: Dictionary = battle.context.timing_engine._pending_effect.get(discard_action_id, {})
	var drawn_id: StringName = pend.get("drawn_card_id", &"")
	if drawn_id == &"":
		return "effect_005 未挂起（无 drawn_card_id）"
	# 取消：抽到的牌应被弃置
	battle.context.timing_engine.resume_pending_effect(discard_action_id, {"cancelled": true})
	await _pump_frames(8)
	if not gs.deck_state.equipment_discard_pile.has(drawn_id):
		return "取消后抽到的装备应被弃置进 equipment_discard_pile"
	if player.equipment_hand.has(drawn_id):
		return "取消后抽到的装备应不在手牌"
	if not gs.deck_state.equipment_discard_pile.has(larm_id):
		return "原联邦左臂应进装备弃牌堆"
	return true


## 测试6i：帝国头部 effect_008 派生动力（持恒=加上限）-- 套装3/013
func test_empire_head_power_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_013_帝国普装_头部")
	if head_id == &"":
		return "找不到帝国头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 找另一张帝国装备设到其他部件槽
	var second_id: StringName = &""
	var second_slot: StringName = &""
	for pair in [["part_014_帝国普装_躯干", &"躯干"], ["part_015_帝国普装_右臂", &"右臂"], ["part_016_帝国普装_左臂", &"左臂"], ["part_017_帝国普装_右腿", &"右腿"], ["part_018_帝国普装_左腿", &"左腿"]]:
		var cid: StringName = _ensure_equipment_in_hand(battle, pair[0])
		if cid != &"":
			second_id = cid
			second_slot = pair[1]
			break
	if second_id == &"":
		push_warning("无第二张帝国装备，跳过 effect_008 多装备验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", second_id, second_slot)
	await _pump_frames(3)
	# 帝国头部动力 bonus = 其他区域帝国装备数（计入 get_total_power 上限，持恒）
	var bonus: int = _GeneratedEquipmentEffects.compute_faction_power_bonus(mech, &"头部")
	if bonus < 1:
		return "帝国头部动力 bonus 应≥1（其他区域有帝国装备），实际: %d" % bonus
	return true


## 测试6j：套装3 帝国普装 effect_009-013 结构对齐拆解
func test_empire_suite_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_009（014 帝国躯干）：optional CHOOSE_ONE + power+3 + armor-2 均 THIS_TURN（非 PERMANENT MODIFY_ARMOR）
	var e009 = effects.get(&"equipment_effect_009")
	if e009 == null:
		return "缺少 effect_009"
	if not _choose_one_is_optional(e009):
		return "effect_009 CHOOSE_ONE 应 optional"
	if _action_type_in_effect(e009, &"MODIFY_ARMOR"):
		return "effect_009 护甲-2 应改用 EXECUTE_STAT_MODIFY，不应再有 MODIFY_ARMOR"
	var armor_params: Dictionary = _find_inner_stat_modify(e009, &"armor")
	if armor_params.is_empty():
		return "effect_009 应含 EXECUTE_STAT_MODIFY armor"
	if int(armor_params.get("value", 0)) != -2:
		return "effect_009 armor 值应为 -2，实际: %d" % int(armor_params.get("value", 0))
	if String(armor_params.get("duration", &"")) != "THIS_TURN":
		return "effect_009 armor 持续应为 THIS_TURN，实际: %s" % String(armor_params.get("duration", &""))
	# effect_010（015 帝国右臂）：自动 RESTORE_POWER 2，无 CHOOSE_ONE（"回复"非"可以"）
	var e010 = effects.get(&"equipment_effect_010")
	if e010 == null:
		return "缺少 effect_010"
	if _action_type_in_effect(e010, &"CHOOSE_ONE"):
		return "effect_010 应无 CHOOSE_ONE（自动回复）"
	if not _action_type_in_effect(e010, &"RESTORE_POWER"):
		return "effect_010 应含 RESTORE_POWER"
	# effect_011（016 帝国左臂）：自动 RESTORE_POWER 1，无 CHOOSE_ONE
	var e011 = effects.get(&"equipment_effect_011")
	if e011 == null:
		return "缺少 effect_011"
	if _action_type_in_effect(e011, &"CHOOSE_ONE"):
		return "effect_011 应无 CHOOSE_ONE（自动回复）"
	if not _action_type_in_effect(e011, &"RESTORE_POWER"):
		return "effect_011 应含 RESTORE_POWER"
	# effect_012（017 帝国右腿）：DIRECT 主动 + once_per_turn + MOVED_DISTANCE 8（移动8格点触发按钮回复2动力）
	var e012 = effects.get(&"equipment_effect_012")
	if e012 == null:
		return "缺少 effect_012"
	if e012.mode != _TimingConst.MODE_DIRECT:
		return "effect_012 应 DIRECT 主动触发"
	if e012.listen_timing != &"":
		return "effect_012 主动效果不应监听时点"
	if e012.once_per_turn_key == &"":
		return "effect_012 应有 once_per_turn_key"
	var has_md12 := false
	for cond in e012.conditions:
		if cond is Dictionary and cond.get("op", &"") == &"MOVED_DISTANCE_THIS_TURN_ABOVE" and int(cond.get("threshold", 0)) == 8:
			has_md12 = true
	if not has_md12:
		return "effect_012 条件应含 MOVED_DISTANCE_THIS_TURN_ABOVE threshold=8"
	if not _action_has_param(e012, &"RESTORE_POWER", &"amount", 2):
		return "effect_012 RESTORE_POWER amount 应=2"
	# effect_013（018 帝国左腿）：同 012，回复1动力
	var e013 = effects.get(&"equipment_effect_013")
	if e013 == null:
		return "缺少 effect_013"
	if e013.mode != _TimingConst.MODE_DIRECT:
		return "effect_013 应 DIRECT 主动触发"
	if e013.once_per_turn_key == &"":
		return "effect_013 应有 once_per_turn_key"
	if not _action_has_param(e013, &"RESTORE_POWER", &"amount", 1):
		return "effect_013 RESTORE_POWER amount 应=1"
	return true


## 在 effect 的 CHOOSE_ONE 首个 option 内层 actions 中找 EXECUTE_STAT_MODIFY 且 stat_type 匹配的参数
func _find_inner_stat_modify(effect, stat_type: StringName) -> Dictionary:
	for act in effect.actions:
		if not (act is Dictionary):
			continue
		if act.get("type", &"") == &"CHOOSE_ONE":
			var opts: Array = act.get("params", {}).get("options", [])
			if opts.is_empty():
				return {}
			var inner: Array = opts[0].get("actions", []) if opts[0] is Dictionary else []
			for sa in inner:
				if sa is Dictionary and sa.get("type", &"") == &"EXECUTE_STAT_MODIFY":
					var p: Dictionary = sa.get("params", {})
					if String(p.get("stat_type", &"")) == String(stat_type):
						return p
	return {}


## 测试6k：套装4 重甲装 effect_015 结构 + effect_016 派生动力（020/021）
func test_heavy_suite() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_015（020 重甲躯干）：cost optional + EXECUTE_STAT_MODIFY armor+4 THIS_TURN（非 MODIFY_ATTACK_TEMP_ARMOR）
	var e015 = effects.get(&"equipment_effect_015")
	if e015 == null:
		return "缺少 effect_015"
	var cost_opt := false
	for c in e015.costs:
		if c is Dictionary and c.get("cost_type", &"") == &"DISCARD_ACTION_CARD" and bool(c.get("optional", false)):
			cost_opt = true
	if not cost_opt:
		return "effect_015 cost 应 optional=true（'可弃置'）"
	if _action_type_in_effect(e015, &"MODIFY_ATTACK_TEMP_ARMOR"):
		return "effect_015 应改用 EXECUTE_STAT_MODIFY，不应再有 MODIFY_ATTACK_TEMP_ARMOR"
	if not _action_type_in_effect(e015, &"EXECUTE_STAT_MODIFY"):
		return "effect_015 应含 EXECUTE_STAT_MODIFY"
	# effect_016（021 重甲右臂）：派生值，损伤≥1动力+1
	var e016 = effects.get(&"equipment_effect_016")
	if e016 == null:
		return "缺少 effect_016"
	if e016.mode != _TimingConst.MODE_DIRECT:
		return "effect_016 派生值应为 DIRECT 占位"
	if not e016.actions.is_empty():
		return "effect_016 派生值应无 actions"
	# 行为：设置重甲右臂 + 1损伤 -> slot_damage_threshold_power_bonus 返回1
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var rarm_id: StringName = _ensure_equipment_in_hand(battle, "part_021_重甲装_右臂")
	if rarm_id == &"":
		return "找不到重甲右臂装备牌"
	battle.context.card_set_service.set_equipment(&"player", rarm_id, &"右臂")
	await _pump_frames(3)
	var rarm_slot = mech.slots.get(&"右臂")
	if rarm_slot == null or rarm_slot.equipped_card == null:
		return "重甲右臂未设置"
	rarm_slot.equipped_card.damage_tokens = 1
	var bonus1: int = _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右臂")
	if bonus1 != 1:
		return "重甲右臂损伤≥1应动力+1，bonus=%d" % bonus1
	rarm_slot.equipped_card.damage_tokens = 0
	var bonus0: int = _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右臂")
	if bonus0 != 0:
		return "重甲右臂0损伤应无bonus，bonus=%d" % bonus0
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
	# actions 应含 EXECUTE_DAMAGE_CHANGE（复用维修移除损伤UI，在 CHOOSE_ONE options 内层）
	var has_remove: bool = _action_type_in_effect(eff, &"EXECUTE_DAMAGE_CHANGE")
	if not has_remove:
		return "近战右腿 actions 应含 EXECUTE_DAMAGE_CHANGE"
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


## 测试：机动腿 effect_021 派生值（每损伤+1动力，029右腿/030左腿）
func test_mobile_legs_per_damage_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 029 机动右腿
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_029_机动装_右腿")
	if rleg_id == &"":
		return "找不到机动右腿装备牌"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	var rslot = mech.slots.get(&"右腿")
	if rslot == null or rslot.equipped_card == null:
		return "右腿装备未设置"
	rslot.equipped_card.damage_tokens = 0
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右腿") != 0:
		return "0损伤 bonus应=0"
	rslot.equipped_card.damage_tokens = 1
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右腿") != 1:
		return "1损伤 bonus应=1（每损伤+1）"
	rslot.equipped_card.damage_tokens = 2
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右腿") != 2:
		return "2损伤 bonus应=2"
	# 030 机动左腿
	var lleg_id: StringName = _ensure_equipment_in_hand(battle, "part_030_机动装_左腿")
	if lleg_id == &"":
		return "找不到机动左腿装备牌"
	battle.context.card_set_service.set_equipment(&"player", lleg_id, &"左腿")
	await _pump_frames(3)
	var lslot = mech.slots.get(&"左腿")
	if lslot == null or lslot.equipped_card == null:
		return "左腿装备未设置"
	lslot.equipped_card.damage_tokens = 1
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"左腿") != 1:
		return "左腿1损伤 bonus应=1"
	return true


## 测试：套装5机动装效果定义结构（017 LISTEN / 018 cost optional / 019 DIRECT / 020 无CHOOSE_ONE / 032 LISTEN）
func test_mobile_suite5_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_017：LISTEN BASIC_MOVE_AFTER + once_per_turn + OWNER_POWER_EQUALS
	var e017 = effects.get(&"equipment_effect_017")
	if e017 == null:
		return "缺少 effect_017"
	if e017.mode != _TimingConst.MODE_LISTEN:
		return "effect_017 应 LISTEN"
	if e017.listen_timing != _TimingConst.BASIC_MOVE_AFTER:
		return "effect_017 应监听 BASIC_MOVE_AFTER"
	if String(e017.listen_action_type) != "basic_move":
		return "effect_017 应监听 basic_move"
	if e017.once_per_turn_key == &"":
		return "effect_017 应设 once_per_turn_key"
	if not _has_condition(e017, &"OWNER_POWER_EQUALS"):
		return "effect_017 应含 OWNER_POWER_EQUALS 条件"
	# effect_018：cost DISCARD_ACTION_CARD optional
	var e018 = effects.get(&"equipment_effect_018")
	if e018 == null:
		return "缺少 effect_018"
	var e018_cost_optional: bool = false
	for c in e018.costs:
		if c is Dictionary and c.get("cost_type") == &"DISCARD_ACTION_CARD" and c.get("optional", false):
			e018_cost_optional = true
	if not e018_cost_optional:
		return "effect_018 弃2牌成本应 optional:true"
	# effect_019：DIRECT + IS_OWNER_TURN + CHOOSE_ONE -> DISCARD_SELF_FROM_SLOT + power+4
	var e019 = effects.get(&"equipment_effect_019")
	if e019 == null:
		return "缺少 effect_019"
	if e019.mode != _TimingConst.MODE_DIRECT:
		return "effect_019 应 DIRECT"
	if e019.listen_timing != &"":
		return "effect_019 DIRECT 应无 listen_timing"
	if not _has_condition(e019, &"IS_OWNER_TURN"):
		return "effect_019 应含 IS_OWNER_TURN"
	if not _action_type_in_effect(e019, &"DISCARD_SELF_FROM_SLOT"):
		return "effect_019 应含 DISCARD_SELF_FROM_SLOT"
	# effect_020：无 CHOOSE_ONE，直接 RESTORE_POWER
	var e020 = effects.get(&"equipment_effect_020")
	if e020 == null:
		return "缺少 effect_020"
	if _action_type_in_effect(e020, &"CHOOSE_ONE"):
		return "effect_020 不应有 CHOOSE_ONE（自动回复）"
	if not _action_type_in_effect(e020, &"RESTORE_POWER"):
		return "effect_020 应含 RESTORE_POWER"
	# effect_032：LISTEN USE_ACTION_AT + USED_COUNTER_CARD
	var e032 = effects.get(&"equipment_effect_032")
	if e032 == null:
		return "缺少 effect_032"
	if e032.mode != _TimingConst.MODE_LISTEN:
		return "effect_032 应 LISTEN"
	if e032.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_032 应监听 USE_ACTION_AT"
	if String(e032.listen_action_type) != "use_action_card":
		return "effect_032 应监听 use_action_card"
	if not _has_condition(e032, &"USED_COUNTER_CARD"):
		return "effect_032 应含 USED_COUNTER_CARD"
	if not _has_condition(e032, &"USED_CARD_OWNER_IS_SELF"):
		return "effect_032 应含 USED_CARD_OWNER_IS_SELF"
	return true


## helper：effect.conditions 是否含某 op
func _has_condition(effect, op_name: StringName) -> bool:
	for c in effect.conditions:
		if c is Dictionary and c.get("op") == op_name:
			return true
	return false


## 测试：机动右臂 effect_019 DIRECT 主动弃此牌本回合动力+4（我方主阶段）
func test_mobile_right_arm_direct_power_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var arm_id: StringName = _ensure_equipment_in_hand(battle, "part_027_机动装_右臂")
	if arm_id == &"":
		return "找不到机动右臂装备牌"
	battle.context.card_set_service.set_equipment(&"player", arm_id, &"右臂")
	await _pump_frames(3)
	var slot = mech.slots.get(&"右臂")
	if slot == null or slot.equipped_card == null:
		return "右臂装备未设置"
	var power_before: int = mech.power
	# 发动 effect_019（DIRECT，payload.phase=MAIN 满足 IS_OWNER_TURN）
	var src: Dictionary = {
		"card_instance_id": arm_id, "mech_id": mech.mech_id,
		"player_id": &"player", "effect_id": &"equipment_effect_019",
	}
	gs.active_player_id = &"player"  # 持有者回合（IS_OWNER_TURN）
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_019", "player_id": &"player",
		"source_mech_id": mech.mech_id, "card_instance_id": arm_id,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	# effect_fire 应挂起在 CHOOSE_ONE（optional 弹窗）
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_fire 未挂起在 CHOOSE_ONE"
	# 确认弃置动力+4
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	if slot.equipped_card != null:
		return "右臂牌应已弃置（槽应空）"
	if mech.power != power_before + 4:
		return "动力应+4（%d -> %d）" % [power_before, mech.power]
	# 取消路径：再次设置右臂，发动后取消应不变
	var arm_id2: StringName = _ensure_equipment_in_hand(battle, "part_027_机动装_右臂")
	if arm_id2 != &"":
		battle.context.card_set_service.set_equipment(&"player", arm_id2, &"右臂")
		await _pump_frames(3)
		var power_before2: int = mech.power
		var src2: Dictionary = {
			"card_instance_id": arm_id2, "mech_id": mech.mech_id,
			"player_id": &"player", "effect_id": &"equipment_effect_019",
		}
		battle.context.action_service.execute(&"effect_fire", {
			"effect_id": &"equipment_effect_019", "player_id": &"player",
			"source_mech_id": mech.mech_id, "card_instance_id": arm_id2,
			"phase": &"MAIN", "source": src2,
		})
		await _pump_frames(3)
		var ef2 = null
		for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
			if a.state == &"waiting_timing":
				ef2 = a
				break
		if ef2 != null:
			battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"cancelled": true})
			await _pump_frames(4)
			if mech.power != power_before2:
				return "取消发动动力应不变（%d -> %d）" % [power_before2, mech.power]
	return true


## 测试：动力未耗尽时 effect_017 不触发（OWNER_POWER_EQUALS(0) 条件边界）
func test_mobile_head_no_trigger_when_power_left() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_025_机动装_头部")
	if head_id == &"":
		return "找不到机动头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var bm = battle.context.action_service._create_action(&"basic_move", {"mech_id": mech.mech_id, "target_cell": "3,2"})
	bm.context = battle.context
	battle.context.action_registry.register(bm)
	mech.power = 2  # 未耗尽
	battle.context.timing_engine.fire_timing(_TimingConst.BASIC_MOVE_AFTER, bm)
	await _pump_frames(3)
	# effect_017 不应触发（动力=2 != 0），bm 不挂起
	if bm.state == &"waiting_timing":
		return "动力=2 时 effect_017 不应触发"
	return true


## 测试：套装6狙击装效果定义结构（022-027，含026/027 free_move 参数）
func test_sniper_suite6_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_022：远程武器范围+1（派生值实时重算，不注册监听器，由 get_passive_weapon_range_bonus 重算）
	var e022 = effects.get(&"equipment_effect_022")
	if e022 == null or e022.mode != _TimingConst.MODE_DIRECT:
		return "effect_022 应 DIRECT（派生占位）"
	if e022.listen_timing != &"":
		return "effect_022 不应注册监听（派生值实时重算）"
	if e022.actions.size() != 0:
		return "effect_022 应无 actions（派生占位）"
	# effect_023：被远程攻击弃牌减威力-4
	var e023 = effects.get(&"equipment_effect_023")
	if e023 == null or e023.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_023 应监听 ATTACK_PRE"
	if not _action_type_in_effect(e023, &"DISCARD_SELF_FROM_SLOT"):
		return "effect_023 应含 DISCARD_SELF_FROM_SLOT"
	# effect_024：DIRECT 弃1牌回复2动力
	var e024 = effects.get(&"equipment_effect_024")
	if e024 == null or e024.mode != _TimingConst.MODE_DIRECT:
		return "effect_024 应 DIRECT"
	if e024.once_per_turn_key == &"":
		return "effect_024 应设 once_per_turn_key"
	if not _action_has_param(e024, &"RESTORE_POWER", &"amount", 2):
		return "effect_024 RESTORE_POWER amount 应=2"
	# effect_025：远程攻击弃1牌威力+2
	var e025 = effects.get(&"equipment_effect_025")
	if e025 == null or not _has_condition(e025, &"HAS_ACTION_CARD_IN_HAND"):
		return "effect_025 应含 HAS_ACTION_CARD_IN_HAND"
	# effect_026：使用攻击牌免费移动1格（free_move/max_cells/adjacent_only，无 CHOOSE_ONE）
	var e026 = effects.get(&"equipment_effect_026")
	if e026 == null or e026.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_026 应监听 USE_ACTION_AT"
	if _action_type_in_effect(e026, &"CHOOSE_ONE"):
		return "effect_026 不应有 CHOOSE_ONE（直接 EXECUTE_SINGLE_MOVE）"
	if not _action_type_in_effect(e026, &"EXECUTE_SINGLE_MOVE"):
		return "effect_026 应含 EXECUTE_SINGLE_MOVE"
	if not _action_has_param(e026, &"EXECUTE_SINGLE_MOVE", &"free_move", true):
		return "effect_026 EXECUTE_SINGLE_MOVE 应 free_move:true"
	if not _action_has_param(e026, &"EXECUTE_SINGLE_MOVE", &"max_cells", 1):
		return "effect_026 EXECUTE_SINGLE_MOVE 应 max_cells:1"
	if not _action_has_param(e026, &"EXECUTE_SINGLE_MOVE", &"adjacent_only", true):
		return "effect_026 EXECUTE_SINGLE_MOVE 应 adjacent_only:true"
	# effect_027：使用迎击牌免费移动1格
	var e027 = effects.get(&"equipment_effect_027")
	if e027 == null or not _action_has_param(e027, &"EXECUTE_SINGLE_MOVE", &"free_move", true):
		return "effect_027 EXECUTE_SINGLE_MOVE 应 free_move:true"
	return true


## 测试：狙击腿 free_move 免费相邻1格移动（不消耗动力）
func test_sniper_leg_free_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# 找一个可达相邻格（free_move max_cells=1，需 cost≤1 的 NORMAL 相邻格）
	var reachable_target: String = ""
	for n in [[3,2],[3,1],[1,2],[1,1],[2,3],[2,1]]:
		var path = battle.context.map_service.find_optimal_path(mech.mech_id, {"q":n[0],"r":n[1]}, 1)
		if not path.is_empty():
			reachable_target = "%d,%d" % [n[0], n[1]]
			break
	if reachable_target == "":
		return "教程地图无可达相邻格，跳过 free_move 位置验证"
	var power_before: int = mech.power
	battle.context.action_service.execute(&"single_move", {
		"mech_id": mech.mech_id, "target_cell": reachable_target,
		"max_cells": 1, "free_move": true, "adjacent_only": true,
		"use_current_power": false, "loop_until_cancel": false,
	})
	await _pump_frames(5)
	# 免费移动：动力不变
	if mech.power != power_before:
		return "free_move 动力应不变（%d -> %d）" % [power_before, mech.power]
	# 位置应更新到目标格
	var parts = reachable_target.split(",")
	if int(mech.position.get("q", -1)) != int(parts[0]) or int(mech.position.get("r", -1)) != int(parts[1]):
		return "应移动到 %s，实际 %s" % [reachable_target, str(mech.position)]
	return true


## helper：effect 的某 action 是否含指定 param 值（支持 CHOOSE_ONE 嵌套与直接 actions）
func _action_has_param(effect, act_type: StringName, param_key: StringName, expected) -> bool:
	return _action_has_param_in_list(effect.actions, act_type, param_key, expected)


func _action_has_param_in_list(actions: Array, act_type: StringName, param_key: StringName, expected) -> bool:
	for act in actions:
		if not (act is Dictionary):
			continue
		if act.get("type", &"") == act_type:
			var p: Dictionary = act.get("params", {})
			if p.get(param_key) == expected:
				return true
		# 递归：CHOOSE_ONE options[].actions / CHOOSE_INTEGER params.actions
		if act.get("type", &"") == &"CHOOSE_ONE":
			var options: Array = act.get("params", {}).get("options", [])
			for opt in options:
				if opt is Dictionary and _action_has_param_in_list(opt.get("actions", []), act_type, param_key, expected):
					return true
		elif act.get("type", &"") == &"CHOOSE_INTEGER":
			if _action_has_param_in_list(act.get("params", {}).get("actions", []), act_type, param_key, expected):
				return true
		elif act.get("type", &"") == &"CHOOSE_MANY_CARDS":
			var cm_p: Dictionary = act.get("params", {})
			if _action_has_param_in_list(cm_p.get("post_actions", []), act_type, param_key, expected):
				return true
			if _action_has_param_in_list(cm_p.get("per_card_actions", []), act_type, param_key, expected):
				return true
	return false


## 测试：套装7近战装效果定义结构（028-031 + 005 复用，effect_029 双 EXECUTE_STAT_MODIFY）
func test_melee_suite7_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_028：近战头 priority20 转换（范围-2威力+3转近战，optional CHOOSE_ONE）
	var e028 = effects.get(&"equipment_effect_028")
	if e028 == null or e028.priority != 20:
		return "effect_028 应 priority20"
	if e028.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_028 应监听 ATTACK_BEFORE"
	if not _has_condition(e028, &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT"):
		return "effect_028 应含 ATTACK_EFFECTIVE_WEAPON_KIND_NOT"
	if not _action_type_in_effect(e028, &"SET_ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "effect_028 应含 SET_ATTACK_EFFECTIVE_WEAPON_KIND"
	# effect_029：使用迎击牌护甲+2动力+2（两个 EXECUTE_STAT_MODIFY，无 CHOOSE_ONE 自动）
	var e029 = effects.get(&"equipment_effect_029")
	if e029 == null or e029.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_029 应监听 USE_ACTION_AT"
	if _action_type_in_effect(e029, &"CHOOSE_ONE"):
		return "effect_029 不应有 CHOOSE_ONE（自动发动）"
	if _action_type_in_effect(e029, &"MODIFY_ARMOR"):
		return "effect_029 不应用 MODIFY_ARMOR（拆解要求 EXECUTE_STAT_MODIFY）"
	var e029_armor: bool = false
	var e029_power: bool = false
	for act in e029.actions:
		if act is Dictionary and act.get("type") == &"EXECUTE_STAT_MODIFY":
			var st = act.get("params", {}).get("stat_type")
			if st == &"armor":
				e029_armor = true
			elif st == &"power":
				e029_power = true
	if not e029_armor:
		return "effect_029 应含 EXECUTE_STAT_MODIFY armor+2"
	if not e029_power:
		return "effect_029 应含 EXECUTE_STAT_MODIFY power+2"
	# effect_030：近战攻击弃1牌威力+2（priority30，晚于028转换；与063/078臂效果统一为30，先于目标躯干效果）
	var e030 = effects.get(&"equipment_effect_030")
	if e030 == null or e030.priority != 30:
		return "effect_030 应 priority30"
	if not _has_condition(e030, &"ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "effect_030 应含 ATTACK_EFFECTIVE_WEAPON_KIND"
	# effect_031：因损伤弃置移除其他区域2损伤
	var e031 = effects.get(&"equipment_effect_031")
	if e031 == null or e031.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_031 应监听 DISCARD_AFTER"
	if not _has_condition(e031, &"DISCARD_REASON_IS"):
		return "effect_031 应含 DISCARD_REASON_IS"
	if not _action_type_in_effect(e031, &"EXECUTE_DAMAGE_CHANGE"):
		return "effect_031 应含 EXECUTE_DAMAGE_CHANGE"
	# effect_005：弃置抽装备立即设置（042 近战左腿复用）
	var e005 = effects.get(&"equipment_effect_005")
	if e005 == null or e005.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_005 应监听 DISCARD_AFTER"
	if not _action_type_in_effect(e005, &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"):
		return "effect_005 应含 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"
	return true


## 测试：套装8精英装效果定义结构（033设置抽1 + 034损伤弃置抽2）
func test_elite_suite8_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_033：设置时抽1（LISTEN SET_EQUIP_AFTER + SET_EQUIP_IS_SELF + CHOOSE_ONE optional -> DRAW_ACTION 1）
	var e033 = effects.get(&"equipment_effect_033")
	if e033 == null or e033.mode != _TimingConst.MODE_LISTEN:
		return "effect_033 应 LISTEN"
	if e033.listen_timing != _TimingConst.SET_EQUIP_AFTER:
		return "effect_033 应监听 SET_EQUIP_AFTER"
	if String(e033.listen_action_type) != "set_equipment":
		return "effect_033 应监听 set_equipment"
	if not _has_condition(e033, &"SET_EQUIP_IS_SELF"):
		return "effect_033 应含 SET_EQUIP_IS_SELF"
	if not _action_has_param(e033, &"DRAW_ACTION", &"count", 1):
		return "effect_033 DRAW_ACTION count 应=1"
	# effect_034：因损伤弃置抽2（LISTEN DISCARD_AFTER + DISCARD_IS_SELF_FROM_SLOT + DISCARD_REASON_IS + DRAW_ACTION 2）
	var e034 = effects.get(&"equipment_effect_034")
	if e034 == null or e034.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_034 应监听 DISCARD_AFTER"
	if not _has_condition(e034, &"DISCARD_REASON_IS"):
		return "effect_034 应含 DISCARD_REASON_IS"
	if not _action_has_param(e034, &"DRAW_ACTION", &"count", 2):
		return "effect_034 DRAW_ACTION count 应=2"
	return true


## 测试：精英装·头部 effect_033 设置时抽1行动牌（行为）
func test_elite_head_set_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_043_精英装_头部")
	if head_id == &"":
		return "找不到精英头部装备牌"
	var hand_before: int = player.action_hand.size()
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(5)
	# effect_033 应触发 CHOOSE_ONE 挂起 set_equipment
	var set_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"set_equipment"):
		if a.state == &"waiting_timing":
			set_action = a
			break
	if set_action == null:
		return "effect_033 未触发（set_equipment 未挂起 CHOOSE_ONE）"
	# 确认抽1行动牌
	battle.context.timing_engine.resume_pending_effect(set_action.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	if player.action_hand.size() != hand_before + 1:
		return "应抽1行动牌（%d -> %d）" % [hand_before, player.action_hand.size()]
	return true


## 测试：装备效果选项弹窗携带拥有者 player_id（PvP 弹窗路由用）
## effect_033 经 set_equipment 触发 CHOOSE_ONE。set_equipment 动作的 player_id 只注入到
## action.source 不在 record 顶层，旧实现 CHOOSE_ONE emit 又不传 player_id ->
## _popup_owner 兜底 _waiting_action_owner 读 record.player_id 落空返回空 -> PvP 两端都弹。
## 修复后 emit 显式带 player_id=装备拥有者（_effect_popup_owner_pid 优先 binding_context.player_id）。
func test_equipment_popup_carries_owner_player_id() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var bridge = battle.context.action_ui_bridge
	if bridge == null:
		return "action_ui_bridge 未就绪"
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_043_精英装_头部")
	if head_id == &"":
		return "找不到精英头部装备牌"
	# 设置装备 -> effect_033 LISTEN SET_EQUIP_AFTER 触发 CHOOSE_ONE 挂起
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(5)
	var w: Dictionary = bridge.get_waiting_action_info()
	if w.get("input_type", &"") != &"choose_one_effect":
		return "未挂起 choose_one_effect（实际 %s）" % w.get("input_type", &"<none>")
	var params: Dictionary = w.get("input_params", {})
	var pid: StringName = params.get("player_id", &"")
	if pid != &"player":
		return "装备效果弹窗 player_id 应为拥有者 player，实际 '%s'（PvP 下会两端都弹）" % String(pid)
	# 清理：确认选项让 set_equipment 完成
	var set_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"set_equipment"):
		if a.state == &"waiting_timing":
			set_action = a
			break
	if set_action != null:
		battle.context.timing_engine.resume_pending_effect(set_action.action_id, {"chosen_option_index": 0})
		await _pump_frames(5)
	return true


## 测试：套装9联邦白马效果定义结构（035-039 + 002复用）+ JSON part_049-054 effect_ids 对齐
func test_fed_whitemane_suite9_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_035：迎击置1损伤减威力4（LISTEN USE_ACTION_AT + USED_COUNTER_CARD + USED_ACTION_HAS_LINKED_ATTACK）
	var e035 = effects.get(&"equipment_effect_035")
	if e035 == null or e035.mode != _TimingConst.MODE_LISTEN:
		return "effect_035 应 LISTEN"
	if e035.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_035 应监听 USE_ACTION_AT"
	if String(e035.listen_action_type) != "use_action_card":
		return "effect_035 应监听 use_action_card"
	if not _has_condition(e035, &"USED_COUNTER_CARD"):
		return "effect_035 应含 USED_COUNTER_CARD"
	if not _has_condition(e035, &"USED_ACTION_HAS_LINKED_ATTACK"):
		return "effect_035 应含 USED_ACTION_HAS_LINKED_ATTACK"
	if not _action_has_param(e035, &"EXECUTE_DAMAGE_CHANGE", &"fixed_slot", true):
		return "effect_035 EXECUTE_DAMAGE_CHANGE 应 fixed_slot=true"
	if not _action_has_param(e035, &"EXECUTE_DAMAGE_CHANGE", &"value", 1):
		return "effect_035 EXECUTE_DAMAGE_CHANGE value 应=1"
	if not _action_has_param(e035, &"MODIFY_ATTACK_MIGHT", &"delta", -4):
		return "effect_035 MODIFY_ATTACK_MIGHT delta 应=-4"
	# effect_036：光束近战威力+3
	var e036 = effects.get(&"equipment_effect_036")
	if e036 == null or e036.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_036 应监听 ATTACK_BEFORE"
	if not _has_condition(e036, &"ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "effect_036 应含 ATTACK_EFFECTIVE_WEAPON_KIND"
	if not _has_condition(e036, &"WEAPON_NAME_CONTAINS"):
		return "effect_036 应含 WEAPON_NAME_CONTAINS"
	if not _action_has_param(e036, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_036 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_037：光束远程威力+3
	var e037 = effects.get(&"equipment_effect_037")
	if e037 == null or not _action_has_param(e037, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_037 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_038：被攻击目标时动力+3（仿 effect_006，value 2->3）
	var e038 = effects.get(&"equipment_effect_038")
	if e038 == null or e038.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_038 应监听 ATTACK_PRE"
	if not _has_condition(e038, &"SELF_MECH_IS_ATTACK_TARGET"):
		return "effect_038 应含 SELF_MECH_IS_ATTACK_TARGET"
	if not _action_has_param(e038, &"EXECUTE_STAT_MODIFY", &"value", 3):
		return "effect_038 EXECUTE_STAT_MODIFY value 应=3"
	# effect_039：被命中置2损伤减3攻击损伤
	var e039 = effects.get(&"equipment_effect_039")
	if e039 == null or e039.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_039 应监听 ATTACK_AFTER"
	if not _has_condition(e039, &"ATTACK_HIT"):
		return "effect_039 应含 ATTACK_HIT"
	if not _action_has_param(e039, &"EXECUTE_DAMAGE_CHANGE", &"fixed_slot", true):
		return "effect_039 EXECUTE_DAMAGE_CHANGE 应 fixed_slot=true"
	if not _action_has_param(e039, &"EXECUTE_DAMAGE_CHANGE", &"value", 2):
		return "effect_039 EXECUTE_DAMAGE_CHANGE value 应=2"
	if not _action_has_param(e039, &"MODIFY_ATTACK_MARKERS", &"delta", -3):
		return "effect_039 MODIFY_ATTACK_MARKERS delta 应=-3"
	# JSON part_049-054 effect_ids 对齐（修正错位后）
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_049_联邦的白马_头部": "equipment_effect_002",
		"part_050_联邦的白马_躯干": "equipment_effect_035",
		"part_051_联邦的白马_右臂": "equipment_effect_036",
		"part_052_联邦的白马_左臂": "equipment_effect_037",
		"part_053_联邦的白马_右腿": "equipment_effect_038",
		"part_054_联邦的白马_左腿": "equipment_effect_039",
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		if eids.size() != 1 or String(eids[0]) != String(json_map[part_id]):
			return "%s effect_ids 应=[%s]，实际=%s" % [part_id, String(json_map[part_id]), str(eids)]
	return true


## 把指定 card_def_id 的行动牌塞入玩家行动手牌，返回卡牌实例ID
func _ensure_action_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
			return cid
	return &""


## 测试：effect_035 迎击响应置1损伤减威力4（手动 fire USE_ACTION_AT，验证 fixed_slot + attack_action_id 定位）
func test_fed_whitemane_torso_counter_reduce_might() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 装备 part_050 联邦白马躯干到玩家躯干（耐久4，0损伤）
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_050_联邦的白马_躯干")
	if torso_id == &"":
		return "找不到联邦白马躯干"
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	var torso_slot = player_mech.slots.get(&"躯干")
	if torso_slot == null or torso_slot.equipped_card == null:
		return "躯干未装备"
	# 玩家手牌迎击牌（反击，action_type=迎击）
	var counter_id: StringName = _ensure_action_card_in_hand(battle, "action_010_反击")
	if counter_id == &"":
		return "找不到反击牌"
	var counter_card = gs.get_card(counter_id)
	counter_card.owner_player_id = &"player"
	counter_card.mech_id = player_mech.mech_id
	# mock attack action（敌方攻击玩家），注册到 registry；MODIFY_ATTACK_MIGHT 经 attack_action_id 定位写 extra_might
	var mock_attack: _Action = _Action.new()
	mock_attack.action_type = &"attack"
	mock_attack.record = {"attacker_id": enemy_mech.mech_id, "target_id": player_mech.mech_id, "extra_might": 0}
	mock_attack.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	mock_attack.state = &"running"
	battle.context.action_registry.register(mock_attack)
	# mock use_action_card action（玩家迎击），record.attack_action_id 绑定 mock attack
	var mock_uac: _Action = _Action.new()
	mock_uac.action_type = &"use_action_card"
	mock_uac.record = {"card_instance_id": counter_id, "attack_action_id": mock_attack.action_id, "player_id": &"player"}
	mock_uac.source = {"player_id": &"player", "mech_id": player_mech.mech_id, "card_instance_id": counter_id}
	mock_uac.state = &"running"
	battle.context.action_registry.register(mock_uac)
	# fire USE_ACTION_AT -> effect_035 触发弹 CHOOSE_ONE，挂起 mock_uac
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock_uac)
	await _pump_frames(3)
	if String(mock_uac.state) != &"waiting_timing":
		return "effect_035 应弹 CHOOSE_ONE 挂起 mock_uac，实际 state=%s" % String(mock_uac.state)
	# 确认 effect_035（选0：置1损伤减威力4）
	battle.context.timing_engine.resume_pending_effect(mock_uac.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# 断言1：躯干装备牌 +1 损伤（fixed_slot 直接置损伤到此牌）
	var torso_card = torso_slot.equipped_card
	if torso_card == null:
		return "躯干牌不应弃置（耐久4，1损伤）"
	if int(torso_card.damage_tokens) != 1:
		return "effect_035 应置1损伤到躯干牌，实际 damage_tokens=%d" % int(torso_card.damage_tokens)
	# 断言2：mock attack extra_might -4（MODIFY_ATTACK_MIGHT 经 payload.attack_action_id 定位原 attack）
	if int(mock_attack.record.get("extra_might", 0)) != -4:
		return "effect_035 应减威力4，实际 extra_might=%d" % int(mock_attack.record.get("extra_might", 0))
	return true


## 测试：effect_039 Q3 守卫--置2损伤致本牌弃置后，减3攻击损伤不执行
func test_fed_whitemane_lleg_q3_discard_stops_reduce() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 装备 part_054 联邦白马左腿（耐久3），预置1损伤 -> 置2后达耐久弃置
	var lleg_id: StringName = _ensure_equipment_in_hand(battle, "part_054_联邦的白马_左腿")
	if lleg_id == &"":
		return "找不到联邦白马左腿"
	battle.context.card_set_service.set_equipment(&"player", lleg_id, &"左腿")
	await _pump_frames(3)
	var lleg_slot = player_mech.slots.get(&"左腿")
	if lleg_slot == null or lleg_slot.equipped_card == null:
		return "左腿未装备"
	lleg_slot.equipped_card.damage_tokens = 1  # 预置1损伤
	# mock attack（命中，markers=4），注册到 registry
	var mock_attack: _Action = _Action.new()
	mock_attack.action_type = &"attack"
	mock_attack.record = {"attacker_id": enemy_mech.mech_id, "target_id": player_mech.mech_id, "hit": true, "markers": 4, "extra_markers": 0}
	mock_attack.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	mock_attack.state = &"running"
	battle.context.action_registry.register(mock_attack)
	# fire ATTACK_AFTER -> effect_039 触发（SELF_MECH_IS_ATTACK_TARGET + ATTACK_HIT + ATTACK_MARKERS_ABOVE0）
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(3)
	if String(mock_attack.state) != &"waiting_timing":
		return "effect_039 应弹 CHOOSE_ONE 挂起 mock_attack，实际 state=%s" % String(mock_attack.state)
	# 确认 effect_039（选0：置2损伤减3攻击损伤）
	battle.context.timing_engine.resume_pending_effect(mock_attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(8)
	# 断言1：左腿牌置2损伤（1+2=3达耐久）-> 弃置，槽位清空
	if lleg_slot.equipped_card != null:
		return "effect_039 置2损伤应致左腿牌弃置（耐久3），槽位应清空"
	var lleg_card = gs.get_card(lleg_id)
	if lleg_card == null or lleg_card.zone != &"discard":
		return "左腿牌应进弃牌堆，zone=%s" % (String(lleg_card.zone) if lleg_card else "null")
	# 断言2：Q3 守卫--牌弃置后 MODIFY_ATTACK_MARKERS 不执行，extra_markers 仍 0
	if int(mock_attack.record.get("extra_markers", 0)) != 0:
		return "Q3：牌弃置后减损伤应停止，extra_markers 应=0，实际=%d" % int(mock_attack.record.get("extra_markers", 0))
	return true


## 测试：套装10帝国赤枭效果定义结构（040-045 + 008复用）+ JSON part_055-060 effect_ids 对齐
func test_red_owl_suite10_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_040：DIRECT 主阶段弃牌换动力（CHOOSE_INTEGER + once）
	var e040 = effects.get(&"equipment_effect_040")
	if e040 == null or e040.mode != _TimingConst.MODE_DIRECT:
		return "effect_040 应 DIRECT"
	if not _has_condition(e040, &"IS_OWNER_TURN"):
		return "effect_040 应含 IS_OWNER_TURN"
	if not _has_condition(e040, &"OWNER_ACTION_HAND_ABOVE"):
		return "effect_040 应含 OWNER_ACTION_HAND_ABOVE"
	if e040.once_per_turn_key != &"red_owl_torso_card_power":
		return "effect_040 once_per_turn_key 应 red_owl_torso_card_power"
	# CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND 列全部行动牌多选弃置
	var has_cmc = false
	for act in e040.actions:
		if act is Dictionary and act.get("type") == &"CHOOSE_MANY_CARDS":
			has_cmc = true
			if String(act.get("params", {}).get("source", "")) != "OWNER_ACTION_HAND":
				return "effect_040 CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND"
			if bool(act.get("params", {}).get("discard_selected", false)) != true:
				return "effect_040 CHOOSE_MANY_CARDS discard_selected 应 true"
	if not has_cmc:
		return "effect_040 应含 CHOOSE_MANY_CARDS"
	# effect_041：LISTEN USE_ACTION_AT 迎击金币换动力（共享 once）
	var e041 = effects.get(&"equipment_effect_041")
	if e041 == null or e041.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_041 应监听 USE_ACTION_AT"
	if not _has_condition(e041, &"USED_COUNTER_CARD"):
		return "effect_041 应含 USED_COUNTER_CARD"
	if e041.once_per_turn_key != &"red_owl_torso_card_power":
		return "effect_041 once_per_turn_key 应与040共享"
	# effect_042：热能远程+3
	var e042 = effects.get(&"equipment_effect_042")
	if e042 == null or e042.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_042 应监听 ATTACK_BEFORE"
	if not _action_has_param(e042, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_042 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_043：热能近战+3
	var e043 = effects.get(&"equipment_effect_043")
	if e043 == null or not _action_has_param(e043, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_043 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_044：消耗8动力回复2（DIRECT 主动 + POWER_SPENT_THIS_TURN_ABOVE 8 + once）
	var e044 = effects.get(&"equipment_effect_044")
	if e044 == null or e044.mode != _TimingConst.MODE_DIRECT:
		return "effect_044 应 DIRECT 主动触发"
	if not _has_condition(e044, &"POWER_SPENT_THIS_TURN_ABOVE"):
		return "effect_044 应含 POWER_SPENT_THIS_TURN_ABOVE"
	if e044.once_per_turn_key == &"":
		return "effect_044 应设 once_per_turn_key"
	if not _action_has_param(e044, &"RESTORE_POWER", &"amount", 2):
		return "effect_044 RESTORE_POWER amount 应=2"
	# effect_045：消耗8动力回复1
	var e045 = effects.get(&"equipment_effect_045")
	if e045 == null or not _action_has_param(e045, &"RESTORE_POWER", &"amount", 1):
		return "effect_045 RESTORE_POWER amount 应=1"
	# JSON part_055-060 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_055_帝国的赤枭_头部": "equipment_effect_008",
		"part_057_帝国的赤枭_右臂": "equipment_effect_042",
		"part_058_帝国的赤枭_左臂": "equipment_effect_043",
		"part_059_帝国的赤枭_右腿": "equipment_effect_044",
		"part_060_帝国的赤枭_左腿": "equipment_effect_045",
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		if eids.size() != 1 or String(eids[0]) != String(json_map[part_id]):
			return "%s effect_ids 应=[%s]，实际=%s" % [part_id, String(json_map[part_id]), str(eids)]
	# 056 双 effect
	var raw056: Dictionary = registry.get_equipment_part("part_056_帝国的赤枭_躯干")
	if raw056.get("effect_ids", []).size() != 2:
		return "part_056 应有2个 effect_id（040+041）"
	return true


## 测试：effect_040 弃牌换动力（CHOOSE_MANY_CARDS 多选2张，弃2张行动牌，动力+4）
func test_red_owl_torso_card_for_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	# 确保手牌 >=4 张行动牌（弃2张后留>=2）
	_ensure_n_action_cards_in_hand(battle, 4)
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_056_帝国的赤枭_躯干")
	if torso_id == &"":
		return "找不到赤枭躯干"
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	var power_before: int = mech.power
	var hand_before: int = player.action_hand.size()
	var src: Dictionary = {
		"card_instance_id": torso_id, "mech_id": mech.mech_id,
		"player_id": &"player", "effect_id": &"equipment_effect_040",
	}
	gs.active_player_id = &"player"  # 持有者回合（IS_OWNER_TURN）
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_040", "player_id": &"player",
		"source_mech_id": mech.mech_id, "card_instance_id": torso_id,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	# effect_fire 应挂起在 CHOOSE_MANY_CARDS（select_thrust_cards 多选窗）
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_040 未挂起在 CHOOSE_MANY_CARDS"
	# 多选2张牌弃置
	var sel: Array = player.action_hand.slice(0, 2)
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": sel})
	await _pump_frames(6)
	# 断言：弃2张，动力+4（每张+2 THIS_TURN）
	if player.action_hand.size() != hand_before - 2:
		return "应弃2张行动牌（%d->%d），实际 %d" % [hand_before, hand_before - 2, player.action_hand.size()]
	if mech.power != power_before + 4:
		return "应动力+4（每张+2），实际 %d -> %d" % [power_before, mech.power]
	return true


## 把行动牌堆顶的牌移入玩家手牌，直到手牌数 >= n
func _ensure_n_action_cards_in_hand(battle: BattleState, n: int) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	while player.action_hand.size() < n and not gs.deck_state.action_deck.is_empty():
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_hand"
			c.owner_player_id = &"player"


## 测试：effect_071 多选弃牌换移动（CHOOSE_MANY_CARDS 选2张，弃2张行动牌，免费移动2格）
func test_eagle_torso_card_for_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	_ensure_n_action_cards_in_hand(battle, 4)
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_098_帝国的雄鹰_躯干")
	if torso_id == &"":
		return "找不到雄鹰躯干"
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	# 机甲放 (5,0)，目标 (7,0) 距离2（free_move max_cells=2 可达）
	mech.position = {"q": 5, "r": 0}
	var hand_before: int = player.action_hand.size()
	var src: Dictionary = {
		"card_instance_id": torso_id, "mech_id": mech.mech_id,
		"player_id": &"player", "effect_id": &"equipment_effect_071",
	}
	gs.active_player_id = &"player"  # 持有者回合（IS_OWNER_TURN）
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_071", "player_id": &"player",
		"source_mech_id": mech.mech_id, "card_instance_id": torso_id,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_071 未挂起在 CHOOSE_MANY_CARDS"
	# 多选2张牌弃置 -> 弃2张 + post_actions 创建 single_move（max_cells=2, free_move）
	var sel: Array = player.action_hand.slice(0, 2)
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": sel})
	await _pump_frames(5)
	# 弃牌完成后串行续跑 EXECUTE_SINGLE_MOVE（post_actions），弹选格窗
	var move_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"single_move"):
		if a.state == &"waiting_input":
			move_action = a
			break
	if move_action == null:
		return "effect_071 弃牌后未创建 single_move 选格子动作（post_actions 未生效？）"
	if int(move_action.record.get("max_cells", 0)) != 2:
		return "single_move max_cells 应=2(弃牌数)，实际 %d" % int(move_action.record.get("max_cells", 0))
	battle.context.action_engine.continue_action(move_action.action_id, {"target_cell": "7,0"})
	await _pump_frames(6)
	# 断言：弃2张 + 移动到 (7,0)
	if player.action_hand.size() != hand_before - 2:
		return "应弃2张行动牌（%d->%d），实际 %d" % [hand_before, hand_before - 2, player.action_hand.size()]
	if int(mech.position.get("q", 0)) != 7 or int(mech.position.get("r", 0)) != 0:
		return "应免费移动2格到 (7,0)，实际 (%d,%d)" % [int(mech.position.get("q", 0)), int(mech.position.get("r", 0))]
	return true


## 测试：effect_079 离场移除"其他区域"损伤 -- exclude_slot_id 透传到 damage_change（排除来源槽）
func test_polar_rleg_exclude_slot_on_leave() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	# 装备 113 极电装右腿（effect_079）
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_113_极电装_右腿")
	if rleg_id == &"":
		return "找不到极电装右腿"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	# 给右腿(来源槽)与头部(其他区域)各设2损伤
	var rleg_slot = mech.slots.get(&"右腿")
	var head_slot = mech.slots.get(&"头部")
	if rleg_slot == null or head_slot == null:
		return "槽位缺失"
	rleg_slot.region_damage_tokens = 2
	if rleg_slot.equipped_card != null:
		rleg_slot.equipped_card.damage_tokens = 2
	head_slot.region_damage_tokens = 2
	# 弃置 113 -> DISCARD_AFTER 触发 effect_079（CHOOSE_ONE optional 移除其他区域最多2损伤）
	battle.context.deck_service.discard_card(rleg_id, &"equipment_replace")
	await _pump_frames(8)
	# 找到挂起的 discard_card 动作（应挂在 effect_079 的 CHOOSE_ONE）
	var discard_action_id: StringName = &""
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		discard_action_id = a.action_id
		break
	if discard_action_id == &"":
		return "未找到 discard_card 动作（effect_079 未挂起？）"
	# 选"移除其他区域最多2损伤"（option 0）
	battle.context.timing_engine.resume_pending_effect(discard_action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	# damage_change 动作应挂起在 place_damage_tokens(removal)，record 含 exclude_slot_id=右腿
	var dc_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"damage_change"):
		if a.state == &"waiting_input":
			dc_action = a
			break
	if dc_action == null:
		return "effect_079 未创建 damage_change 移除损伤子动作"
	if StringName(dc_action.record.get("exclude_slot_id", &"")) != &"右腿":
		return "damage_change 应 exclude_slot_id=右腿（排除来源槽），实际: %s" % String(dc_action.record.get("exclude_slot_id", &""))
	# 清理：取消 damage_change 避免残留影响后续测试
	battle.context.action_engine.cancel_action(dc_action.action_id)
	await _pump_frames(3)
	return true
func test_red_owl_rleg_power_spent_restore() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_059_帝国的赤枭_右腿")
	if rleg_id == &"":
		return "找不到赤枭右腿"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	# 模拟累计消耗8动力，当前动力0、上限10（确保回复2生效不被 clamp）
	mech.power_spent_this_turn = 8
	mech.max_power = 10
	mech.power = 0
	var power_before: int = mech.power
	# 主动触发 effect_044（装备面板「触发」按钮路径 = effect_fire）
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_044",
		"source": {"card_instance_id": rleg_id, "mech_id": mech.mech_id, "player_id": &"player"},
	})
	await _pump_frames(5)
	if mech.power != power_before + 2:
		return "应回复2动力，实际 %d -> %d" % [power_before, mech.power]
	return true


## 问题2回归：net_move（battle.move_unit → move_mech_to_hex）路径应增量 cells_moved_this_turn。
## 此前仅 basic_move 动作路径增量；PvP 人类移动走 move_mech_to_hex 致帝国腿 effect_012
## 条件恒 false（日志 session_log_20260730_170451：移动10格仍 conditions_not_met）。
## 问题3回归：狙击右臂 effect_024（optional 弃牌费用 + once_per_turn）确认弃牌后应标记每回合1次，
## 再次触发被 _execute_effect 的 once_per_turn 检查跳过。
## 此前 resume_pending_effect 默认阶段漏调 _mark_once_per_turn_used（_execute_effect 在
## _request_optional_discard 提前返回未标记），致 024/057/069 可每回合重复触发。
func test_sniper_rarm_once_per_turn_after_optional_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	gs.active_player_id = &"player"  # 持有者回合（IS_OWNER_TURN）
	var rarm_id: StringName = _ensure_equipment_in_hand(battle, "part_033_狙击装_右臂")
	if rarm_id == &"":
		return "找不到狙击右臂"
	battle.context.card_set_service.set_equipment(&"player", rarm_id, &"右臂")
	await _pump_frames(3)
	# 确保手牌>=2张行动牌（弃1后仍剩，便于二次触发条件判定 HAS_ACTION_CARD_IN_HAND）
	var player = gs.players.get(&"player")
	while player.action_hand.size() < 2:
		if gs.deck_state.action_deck.is_empty():
			return "行动牌堆为空，无法补手牌"
		var dcid: StringName = gs.deck_state.action_deck.pop_back()
		player.action_hand.append(dcid)
		var dc = gs.get_card(dcid)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"player"
	mech.max_power = 10
	mech.power = 0
	var power_before: int = mech.power
	var src: Dictionary = {
		"card_instance_id": rarm_id, "mech_id": mech.mech_id,
		"player_id": &"player", "effect_id": &"equipment_effect_024",
	}
	# 第一次主动触发
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_024", "player_id": &"player",
		"source_mech_id": mech.mech_id, "card_instance_id": rarm_id,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	# effect_fire 应挂起在 optional 弃牌弹窗（waiting_timing + _pending_effect）
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_024 未挂起在 optional 弃牌弹窗"
	# 确认弃第一张行动牌（resume 默认阶段：_pay_costs + _mark_once_per_turn_used）
	var discard_cid: StringName = player.action_hand[0]
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_action_card_ids": [discard_cid]})
	await _pump_frames(5)
	if mech.power != power_before + 2:
		return "effect_024 应回复2动力（%d -> %d），实际 %d" % [power_before, power_before + 2, mech.power]
	# once_per_turn 应已标记：can_trigger_active_effect 返回 false
	var te = battle.context.timing_engine
	var can_again: bool = false
	for timing in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and eff.effect_id == &"equipment_effect_024":
				can_again = te.can_trigger_active_effect(eff, entry.get("binding_context", {}))
	if can_again:
		return "effect_024 本回合已用1次，can_trigger_active_effect 应为 false（once_per_turn 未标记）"
	# 第二次直接触发：once_per_turn 检查在 optional 弃牌拦截之前，应直接跳过（动力不再+2）
	var power_before2: int = mech.power
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_024", "player_id": &"player",
		"source_mech_id": mech.mech_id, "card_instance_id": rarm_id,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(5)
	if mech.power != power_before2:
		return "第二次触发应被 once_per_turn 跳过（动力不应再+2），实际 %d -> %d" % [power_before2, mech.power]
	return true


## 问题2回归：net_move（battle.move_unit -> move_mech_to_hex）路径应增量 cells_moved_this_turn。
## 此前仅 basic_move 动作路径增量；PvP 人类移动走 move_mech_to_hex 致帝国腿 effect_012
## 条件恒 false（日志 session_log_20260730_170451：移动10格仍 conditions_not_met）。
func test_empire_rleg_cells_moved_via_move_unit() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	mech.power = 5
	var before: int = mech.cells_moved_this_turn
	var r: Dictionary = battle.move_unit("player", {"q": 3, "r": 2})  # 相邻1格（实际距离视起始位置）
	if not r.get("ok", false):
		return "move_unit 失败: %s" % String(r.get("message", ""))
	# 核心：net_move 路径应增量 cells_moved_this_turn（此前恒 0 致帝国腿条件永 false）
	if mech.cells_moved_this_turn < before + 1:
		return "net_move 后 cells_moved_this_turn 应至少 +1（%d -> >=%d），实际 %d" % [before, before + 1, mech.cells_moved_this_turn]
	return true


## 问题2：帝国右腿 effect_012 在本回合移动>=8格后，触发按钮可点 + 主动触发回复2动力。
func test_empire_rleg_effect012_restore_after_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_017_帝国普装_右腿")
	if rleg_id == &"":
		return "找不到帝国右腿"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	# 真实移动8格（沿 q 轴逐格），验证 net_move 累计 cells_moved_this_turn
	mech.max_power = 30
	mech.power = 30
	for q in [3, 4, 5, 6, 7, 8, 9, 10]:
		var mr: Dictionary = battle.move_unit("player", {"q": q, "r": 2})
		if not mr.get("ok", false):
			return "移动到 (%d,2) 失败: %s" % [q, String(mr.get("message", ""))]
	if mech.cells_moved_this_turn < 8:
		return "移动8格后 cells_moved_this_turn 应>=8，实际 %d" % mech.cells_moved_this_turn
	# 触发按钮可点性：条件满足 -> can_trigger_active_effect=true
	var te = battle.context.timing_engine
	var can_t: bool = false
	for timing in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and eff.effect_id == &"equipment_effect_012":
				can_t = te.can_trigger_active_effect(eff, entry.get("binding_context", {}))
	if not can_t:
		return "移动8格后 effect_012 触发按钮应可点（can_trigger_active_effect=true）"
	# 主动触发 effect_012，回复2动力（显式设动力隔离移动消耗，避免 clamp 干扰断言）
	mech.max_power = 30
	mech.power = 10
	var power_before: int = mech.power
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_012",
		"source": {"card_instance_id": rleg_id, "mech_id": mech.mech_id, "player_id": &"player"},
	})
	await _pump_frames(5)
	if mech.power != power_before + 2:
		return "effect_012 应回复2动力（%d -> %d），实际 %d" % [power_before, power_before + 2, mech.power]
	return true


## 损伤转移/固定置损伤：损伤应设置在区域上，装备牌因耐久损坏弃置后区域损伤保留。
## 此前 GameState.place_one_damage_token 有装备时只加 card 不加 region，
## 致 effect_004 转移损伤到右臂后卡损坏弃置、区域损伤丢失（用户报"损伤消失了"）。
func test_damage_on_equipped_slot_persists_after_break() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	# 装备联邦右臂（effect_004，durability 2）到右臂
	var rarm_id: StringName = _ensure_equipment_in_hand(battle, "part_009_联邦普装_右臂")
	if rarm_id == &"":
		return "找不到联邦右臂"
	battle.context.card_set_service.set_equipment(&"player", rarm_id, &"右臂")
	await _pump_frames(3)
	var slot = mech.slots.get(&"右臂")
	var durability: int = slot.get_equipment_durability()
	if durability <= 0:
		return "联邦右臂耐久应>0，实际 %d" % durability
	# 转移 durability 点损伤到右臂（与 effect_004 转移路径一致：place_damage_tokens_on_slot）
	battle.context.game_actions.place_damage_tokens_on_slot({"mech_id": mech.mech_id, "slot_id": &"右臂", "amount": durability})
	# 触发耐久损坏检查（=耐久 -> 弃置装备）
	battle.context.damage_token_service.check_and_handle_equipment_break(mech.mech_id, &"右臂")
	await _pump_frames(3)
	# 装备应已损坏弃置
	if slot.equipped_card != null:
		return "转移%d损伤(=耐久)后右臂装备应已损坏弃置" % durability
	# 关键：区域损伤应保留（=durability），不应随装备弃置而消失
	if slot.region_damage_tokens != durability:
		return "装备弃置后区域损伤应保留=%d，实际 %d" % [durability, slot.region_damage_tokens]
	return true


## 测试：区域有损伤时设置新装备牌 -> 弃「新牌耐久数」损伤 -> 新牌继承剩余损伤 -> 损伤≥耐久立即损坏（区域损伤保留）
## 用户场景：区域12损伤 + 耐久3新牌 -> 弃3剩9 -> 新牌9损伤 -> 9≥3损坏弃置 -> 区域留9
func test_set_equipment_on_damaged_region_breaks() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var slot_id: StringName = &"右臂"
	var slot = mech.slots.get(slot_id)
	# 确保槽位为空（区域损伤模型：损伤在区域上，与牌独立）
	if slot.equipped_card != null:
		battle.context.deck_service.discard_card(slot.equipped_card.instance_id, &"test")
		slot.equipped_card = null
	# 区域放12损伤
	slot.region_damage_tokens = 12
	# 设置耐久3的量产装右臂
	var card_id: StringName = _ensure_equipment_in_hand(battle, "part_003_量产装_右臂")
	if card_id == &"":
		return "找不到量产装右臂(耐久3)"
	battle.context.card_set_service.set_equipment(&"player", card_id, slot_id)
	await _pump_frames(5)
	# 期望：新牌继承9损伤(12-3) -> 9≥3 立即损坏弃置 -> 区域留9
	if slot.equipped_card != null:
		return "新牌应因9损伤≥耐久3立即损坏弃置，实际仍装备"
	if slot.region_damage_tokens != 9:
		return "区域损伤应留9，实际 %d" % slot.region_damage_tokens
	return true


## 测试：区域损伤<2倍耐久时设置新装备牌 -> 新牌继承剩余损伤并存活（区域/牌损伤同步）
## 区域5损伤 + 耐久3新牌 -> 弃3剩2 -> 新牌继承2损伤 -> 2<3 存活
func test_set_equipment_on_damaged_region_inherits_and_survives() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var slot_id: StringName = &"左臂"
	var slot = mech.slots.get(slot_id)
	if slot.equipped_card != null:
		battle.context.deck_service.discard_card(slot.equipped_card.instance_id, &"test")
		slot.equipped_card = null
	slot.region_damage_tokens = 5
	var card_id: StringName = _ensure_equipment_in_hand(battle, "part_004_量产装_左臂")
	if card_id == &"":
		return "找不到量产装左臂(耐久3)"
	battle.context.card_set_service.set_equipment(&"player", card_id, slot_id)
	await _pump_frames(5)
	# 期望：新牌继承2损伤(5-3) -> 2<3 存活，区域2/牌2同步
	if slot.equipped_card == null:
		return "新牌应继承2损伤存活(2<3)，实际未装备"
	if slot.equipped_card.damage_tokens != 2:
		return "新牌应继承2损伤，实际 %d" % slot.equipped_card.damage_tokens
	if slot.region_damage_tokens != 2:
		return "区域损伤应为2，实际 %d" % slot.region_damage_tokens
	return true


## 测试：套装11超重甲效果定义结构（046-049）+ JSON part_061-066 effect_ids 对齐
func test_heavy_armor_suite11_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_046：总损伤<4免疫（派生值，DIRECT 占位 + 无 actions）
	var e046 = effects.get(&"equipment_effect_046")
	if e046 == null or e046.mode != _TimingConst.MODE_DIRECT:
		return "effect_046 应 DIRECT 占位（派生值）"
	if not _has_condition(e046, &"ALWAYS"):
		return "effect_046 应含 ALWAYS"
	# effect_047：被攻击弃2牌护甲+5（LISTEN ATTACK_PRE + cost + EXECUTE_STAT_MODIFY armor+5）
	var e047 = effects.get(&"equipment_effect_047")
	if e047 == null or e047.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_047 应监听 ATTACK_PRE"
	if not _has_condition(e047, &"OWNER_ACTION_HAND_ABOVE"):
		return "effect_047 应含 OWNER_ACTION_HAND_ABOVE"
	if not _action_has_param(e047, &"EXECUTE_STAT_MODIFY", &"value", 5):
		return "effect_047 EXECUTE_STAT_MODIFY value 应=5"
	# effect_048：损伤≥2动力+2（派生值）
	var e048 = effects.get(&"equipment_effect_048")
	if e048 == null or e048.mode != _TimingConst.MODE_DIRECT:
		return "effect_048 应 DIRECT 占位（派生值）"
	# effect_049：此牌损伤<2免疫（派生值）
	var e049 = effects.get(&"equipment_effect_049")
	if e049 == null or e049.mode != _TimingConst.MODE_DIRECT:
		return "effect_049 应 DIRECT 占位（派生值）"
	# JSON part_061-066 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_061_超重甲装_头部": "equipment_effect_046",
		"part_062_超重甲装_躯干": "equipment_effect_047",
		"part_063_超重甲装_右臂": "equipment_effect_048",
		"part_064_超重甲装_左臂": "equipment_effect_049",
		"part_065_超重甲装_右腿": "equipment_effect_049",
		"part_066_超重甲装_左腿": "equipment_effect_049",
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		if eids.size() != 1 or String(eids[0]) != String(json_map[part_id]):
			return "%s effect_ids 应=[%s]，实际=%s" % [part_id, String(json_map[part_id]), str(eids)]
	return true


## 测试：effect_046/048/049 派生值阈值（总损伤<4免疫 / 此牌损伤≥2动力+2 / 此牌损伤<2免疫）
func test_heavy_armor_derived_thresholds() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# effect_046 超重甲头部：总损伤<4免疫，≥4失效
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_061_超重甲装_头部")
	if head_id == &"":
		return "找不到超重甲头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var head_slot = mech.slots.get(&"头部")
	var head_card = head_slot.equipped_card
	head_slot.region_damage_tokens = 3
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(head_card, mech, 3) != 0:
		return "effect_046 总损伤3<4 应免疫(返回0)"
	head_slot.region_damage_tokens = 4
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(head_card, mech, 4) != 4:
		return "effect_046 总损伤4≥4 应失效(返回4)"
	# effect_049 超重甲左臂：此牌损伤<2免疫，≥2扣全部
	var larm_id: StringName = _ensure_equipment_in_hand(battle, "part_064_超重甲装_左臂")
	if larm_id == &"":
		return "找不到超重甲左臂"
	battle.context.card_set_service.set_equipment(&"player", larm_id, &"左臂")
	await _pump_frames(3)
	var larm_slot = mech.slots.get(&"左臂")
	var larm_card = larm_slot.equipped_card
	larm_card.damage_tokens = 1
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(larm_card, mech, 2) != 0:
		return "effect_049 此牌损伤1<2 应免疫(返回0)"
	larm_card.damage_tokens = 2
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(larm_card, mech, 2) != 2:
		return "effect_049 此牌损伤2≥2 应失效扣全部(返回2)"
	# effect_048 超重甲右臂：此牌损伤≥2动力+2
	var rarm_id: StringName = _ensure_equipment_in_hand(battle, "part_063_超重甲装_右臂")
	if rarm_id == &"":
		return "找不到超重甲右臂"
	battle.context.card_set_service.set_equipment(&"player", rarm_id, &"右臂")
	await _pump_frames(3)
	var rarm_slot = mech.slots.get(&"右臂")
	rarm_slot.equipped_card.damage_tokens = 1
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右臂") != 0:
		return "effect_048 损伤1<2 应+0动力"
	rarm_slot.equipped_card.damage_tokens = 2
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"右臂") != 2:
		return "effect_048 损伤2≥2 应+2动力"
	return true


## 帧驱动 helper：推进 N 帧让 call_deferred 动作恢复链 flush
func _pump_frames(n: int) -> void:
	for i in range(n):
		await Engine.get_main_loop().process_frame


# ════════════════════════════════════════════════════════════════
# 套装12 高机动装 067-072（effect_050-054 + 复用 effect_021）
# ════════════════════════════════════════════════════════════════

## 测试：effect_050-054 定义结构 + JSON part_067-072 effect_ids 对齐 + 071/072 复用 021
func test_high_mobility_suite12_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_050：耗尽动力回复3+移动（LISTEN BASIC_MOVE_AFTER + once + OWNER_POWER_EQUALS(0)）
	var e050 = effects.get(&"equipment_effect_050")
	if e050 == null or e050.mode != _TimingConst.MODE_LISTEN:
		return "effect_050 应 LISTEN"
	if e050.listen_timing != _TimingConst.BASIC_MOVE_AFTER:
		return "effect_050 应监听 BASIC_MOVE_AFTER"
	if e050.once_per_turn_key == &"":
		return "effect_050 应有 once_per_turn_key"
	if not _has_condition(e050, &"SELF_MECH_IS_MOVE_SUBJECT"):
		return "effect_050 应含 SELF_MECH_IS_MOVE_SUBJECT"
	if not _has_condition(e050, &"OWNER_POWER_EQUALS"):
		return "effect_050 应含 OWNER_POWER_EQUALS"
	if not _action_has_param(e050, &"RESTORE_POWER", &"amount", 3):
		return "effect_050 RESTORE_POWER amount 应=3"
	# effect_051：被攻击弃2牌动力+6（LISTEN ATTACK_PRE + cost + EXECUTE_STAT_MODIFY power 6）
	var e051 = effects.get(&"equipment_effect_051")
	if e051 == null or e051.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_051 应监听 ATTACK_PRE"
	if not _has_condition(e051, &"OWNER_ACTION_HAND_ABOVE"):
		return "effect_051 应含 OWNER_ACTION_HAND_ABOVE"
	if not _action_has_param(e051, &"EXECUTE_STAT_MODIFY", &"value", 6):
		return "effect_051 EXECUTE_STAT_MODIFY value 应=6"
	# effect_052：DIRECT 主动弃此牌动力+5
	var e052 = effects.get(&"equipment_effect_052")
	if e052 == null or e052.mode != _TimingConst.MODE_DIRECT:
		return "effect_052 应 DIRECT"
	if not _has_condition(e052, &"IS_OWNER_TURN"):
		return "effect_052 应含 IS_OWNER_TURN"
	if not _action_has_param(e052, &"EXECUTE_STAT_MODIFY", &"value", 5):
		return "effect_052 EXECUTE_STAT_MODIFY value 应=5"
	# effect_053：使用迎击牌弃此牌动力+5（LISTEN USE_ACTION_AT）
	var e053 = effects.get(&"equipment_effect_053")
	if e053 == null or e053.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_053 应监听 USE_ACTION_AT"
	if not _has_condition(e053, &"USED_COUNTER_CARD"):
		return "effect_053 应含 USED_COUNTER_CARD"
	if not _action_has_param(e053, &"EXECUTE_STAT_MODIFY", &"value", 5):
		return "effect_053 EXECUTE_STAT_MODIFY value 应=5"
	# effect_054：攻击命中后回复4动力（LISTEN ATTACK_AFTER）
	var e054 = effects.get(&"equipment_effect_054")
	if e054 == null or e054.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_054 应监听 ATTACK_AFTER"
	if not _action_has_param(e054, &"RESTORE_POWER", &"amount", 4):
		return "effect_054 RESTORE_POWER amount 应=4"
	# JSON part_067-072 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_067_高机动装_头部": ["equipment_effect_050"],
		"part_068_高机动装_躯干": ["equipment_effect_051"],
		"part_069_高机动装_右臂": ["equipment_effect_052", "equipment_effect_053"],
		"part_070_高机动装_左臂": ["equipment_effect_054"],
		"part_071_高机动装_右腿": ["equipment_effect_021"],
		"part_072_高机动装_左腿": ["equipment_effect_021"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：effect_050 触发条件（动力=0 触发挂起；动力=2 不触发）-- 仿 test_mobile_head_no_trigger_when_power_left
func test_high_mobility_head_trigger_condition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_067_高机动装_头部")
	if head_id == &"":
		return "找不到高机动装头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 动力=0：fire BASIC_MOVE_AFTER 应触发 effect_050 -> 挂起 waiting_timing
	var bm0 = battle.context.action_service._create_action(&"basic_move", {"mech_id": mech.mech_id, "target_cell": "3,2"})
	bm0.context = battle.context
	battle.context.action_registry.register(bm0)
	mech.power = 0
	battle.context.timing_engine.fire_timing(_TimingConst.BASIC_MOVE_AFTER, bm0)
	await _pump_frames(3)
	if bm0.state != &"waiting_timing":
		return "动力=0 时 effect_050 应触发(挂起 waiting_timing)，实际 state=%s" % String(bm0.state)
	return true


# ════════════════════════════════════════════════════════════════
# 套装13 狙击影装 073-078（effect_055-060 + 复用 effect_023）
# ════════════════════════════════════════════════════════════════

## 测试：effect_055-060 定义结构 + JSON part_073-078 effect_ids 对齐
func test_sniper_shadow_suite13_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_055：远程武器范围+2（派生值实时重算，不注册监听器，由 get_passive_weapon_range_bonus 重算）
	var e055 = effects.get(&"equipment_effect_055")
	if e055 == null or e055.mode != _TimingConst.MODE_DIRECT:
		return "effect_055 应 DIRECT（派生占位）"
	if e055.listen_timing != &"":
		return "effect_055 不应注册监听（派生值实时重算）"
	if e055.actions.size() != 0:
		return "effect_055 应无 actions（派生占位）"
	# effect_056：离场获2金币（LISTEN DISCARD_AFTER + GAIN_GOLD）
	var e056 = effects.get(&"equipment_effect_056")
	if e056 == null or e056.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_056 应监听 DISCARD_AFTER"
	if not _has_condition(e056, &"DISCARD_IS_SELF_FROM_SLOT"):
		return "effect_056 应含 DISCARD_IS_SELF_FROM_SLOT"
	if not _action_has_param(e056, &"GAIN_GOLD", &"amount", 2):
		return "effect_056 GAIN_GOLD amount 应=2"
	# effect_057：DIRECT 弃1牌回复3动力（once）
	var e057 = effects.get(&"equipment_effect_057")
	if e057 == null or e057.mode != _TimingConst.MODE_DIRECT:
		return "effect_057 应 DIRECT"
	if e057.once_per_turn_key == &"":
		return "effect_057 应有 once_per_turn_key"
	if not _action_has_param(e057, &"RESTORE_POWER", &"amount", 3):
		return "effect_057 RESTORE_POWER amount 应=3"
	# effect_058：远程弃1牌威力+3
	var e058 = effects.get(&"equipment_effect_058")
	if e058 == null or e058.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_058 应监听 ATTACK_BEFORE"
	if not _action_has_param(e058, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_058 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_059：使用攻击牌回复2+移动1格
	var e059 = effects.get(&"equipment_effect_059")
	if e059 == null or e059.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_059 应监听 USE_ACTION_AT"
	if not _has_condition(e059, &"USED_CARD_TYPE_IS"):
		return "effect_059 应含 USED_CARD_TYPE_IS"
	if not _action_has_param(e059, &"RESTORE_POWER", &"amount", 2):
		return "effect_059 RESTORE_POWER amount 应=2"
	if not _action_has_param(e059, &"EXECUTE_SINGLE_MOVE", &"max_cells", 1):
		return "effect_059 EXECUTE_SINGLE_MOVE max_cells 应=1"
	# effect_060：使用迎击牌回复2+移动1格
	var e060 = effects.get(&"equipment_effect_060")
	if e060 == null or e060.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_060 应监听 USE_ACTION_AT"
	if not _has_condition(e060, &"USED_COUNTER_CARD"):
		return "effect_060 应含 USED_COUNTER_CARD"
	# JSON part_073-078 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_073_狙击影装_头部": ["equipment_effect_055"],
		"part_074_狙击影装_躯干": ["equipment_effect_023", "equipment_effect_056"],
		"part_075_狙击影装_右臂": ["equipment_effect_057"],
		"part_076_狙击影装_左臂": ["equipment_effect_058"],
		"part_077_狙击影装_右腿": ["equipment_effect_059"],
		"part_078_狙击影装_左腿": ["equipment_effect_060"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


# ════════════════════════════════════════════════════════════════
# 套装14 近战特装 079-084（effect_061-064 + 复用 effect_005）
# ════════════════════════════════════════════════════════════════

## 测试：effect_061-064 定义结构 + JSON part_079-084 effect_ids 对齐
func test_melee_special_suite14_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_061：范围-2威力+4转近战（priority 20，不适用近战）
	var e061 = effects.get(&"equipment_effect_061")
	if e061 == null or e061.priority != 20:
		return "effect_061 priority 应=20"
	if e061.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_061 应监听 ATTACK_BEFORE"
	if not _has_condition(e061, &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT"):
		return "effect_061 应含 ATTACK_EFFECTIVE_WEAPON_KIND_NOT"
	if not _action_has_param(e061, &"MODIFY_ATTACK_MIGHT", &"delta", 4):
		return "effect_061 MODIFY_ATTACK_MIGHT delta 应=4"
	if not _action_has_param(e061, &"SET_ATTACK_EFFECTIVE_WEAPON_KIND", &"weapon_kind", &"近战"):
		return "effect_061 应含 SET_ATTACK_EFFECTIVE_WEAPON_KIND 近战"
	# effect_062：使用迎击牌护甲+3动力+3
	var e062 = effects.get(&"equipment_effect_062")
	if e062 == null or e062.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_062 应监听 USE_ACTION_AT"
	if not _action_has_param(e062, &"EXECUTE_STAT_MODIFY", &"value", 3):
		return "effect_062 EXECUTE_STAT_MODIFY value 应=3"
	# effect_063：近战弃1牌威力+2 + 选目标装备无效（CHOOSE_MANY_CARDS source=ATTACK_TARGET_EQUIPMENT）
	var e063 = effects.get(&"equipment_effect_063")
	if e063 == null or e063.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_063 应监听 ATTACK_PRE"
	if not _has_condition(e063, &"ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "effect_063 应含 ATTACK_EFFECTIVE_WEAPON_KIND"
	if not _action_has_param(e063, &"MODIFY_ATTACK_MIGHT", &"delta", 2):
		return "effect_063 MODIFY_ATTACK_MIGHT delta 应=2"
	if not _action_has_param(e063, &"CHOOSE_MANY_CARDS", &"source", &"ATTACK_TARGET_EQUIPMENT"):
		return "effect_063 CHOOSE_MANY_CARDS source 应=ATTACK_TARGET_EQUIPMENT"
	if not _action_has_param(e063, &"CHOOSE_MANY_CARDS", &"discard_selected", false):
		return "effect_063 CHOOSE_MANY_CARDS discard_selected 应=false"
	# effect_064：离场回复3+移动
	var e064 = effects.get(&"equipment_effect_064")
	if e064 == null or e064.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_064 应监听 DISCARD_AFTER"
	if not _has_condition(e064, &"DISCARD_IS_SELF_FROM_SLOT"):
		return "effect_064 应含 DISCARD_IS_SELF_FROM_SLOT"
	if not _action_has_param(e064, &"RESTORE_POWER", &"amount", 3):
		return "effect_064 RESTORE_POWER amount 应=3"
	# JSON part_079-084 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_079_近战特装_头部": ["equipment_effect_061"],
		"part_080_近战特装_躯干": ["equipment_effect_062"],
		"part_081_近战特装_右臂": ["equipment_effect_063"],
		"part_082_近战特装_左臂": ["equipment_effect_063"],
		"part_083_近战特装_右腿": ["equipment_effect_064"],
		"part_084_近战特装_左腿": ["equipment_effect_005"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


# ════════════════════════════════════════════════════════════════
# 套装16 联邦的圣牛 091-096（effect_066-069 + 复用 039）
# ════════════════════════════════════════════════════════════════

## 测试：effect_066-069 定义结构 + JSON part_091-096 effect_ids 对齐
func test_holyox_suite16_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_066：每联邦装备护甲+1(含自身)（派生值 DIRECT 占位）
	var e066 = effects.get(&"equipment_effect_066")
	if e066 == null or e066.mode != _TimingConst.MODE_DIRECT:
		return "effect_066 应 DIRECT 占位（派生值）"
	if not _has_condition(e066, &"ALWAYS"):
		return "effect_066 应含 ALWAYS"
	# effect_067：被攻击弃2牌威力-4
	var e067 = effects.get(&"equipment_effect_067")
	if e067 == null or e067.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_067 应监听 ATTACK_PRE"
	if not _has_condition(e067, &"OWNER_ACTION_HAND_ABOVE"):
		return "effect_067 应含 OWNER_ACTION_HAND_ABOVE"
	if not _action_has_param(e067, &"MODIFY_ATTACK_MIGHT", &"delta", -4):
		return "effect_067 MODIFY_ATTACK_MIGHT delta 应=-4"
	# effect_068：光束弃1牌威力+3
	var e068 = effects.get(&"equipment_effect_068")
	if e068 == null or e068.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_068 应监听 ATTACK_BEFORE"
	if not _has_condition(e068, &"WEAPON_NAME_CONTAINS"):
		return "effect_068 应含 WEAPON_NAME_CONTAINS"
	if not _action_has_param(e068, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_068 MODIFY_ATTACK_MIGHT delta 应=3"
	# effect_069：DIRECT 弃1牌抽1或回复2（once + CHOOSE_ONE 二选一）
	var e069 = effects.get(&"equipment_effect_069")
	if e069 == null or e069.mode != _TimingConst.MODE_DIRECT:
		return "effect_069 应 DIRECT"
	if e069.once_per_turn_key == &"":
		return "effect_069 应有 once_per_turn_key"
	if not _action_has_param(e069, &"DRAW_ACTION", &"count", 1):
		return "effect_069 DRAW_ACTION count 应=1"
	if not _action_has_param(e069, &"RESTORE_POWER", &"amount", 2):
		return "effect_069 RESTORE_POWER amount 应=2"
	# 复用 effect_039 存在
	if effects.get(&"equipment_effect_039") == null:
		return "effect_039 应存在（复用）"
	# JSON part_091-096 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_091_联邦的圣牛_头部": ["equipment_effect_066"],
		"part_092_联邦的圣牛_躯干": ["equipment_effect_067"],
		"part_093_联邦的圣牛_右臂": ["equipment_effect_068"],
		"part_094_联邦的圣牛_左臂": ["equipment_effect_068"],
		"part_095_联邦的圣牛_右腿": ["equipment_effect_069"],
		"part_096_联邦的圣牛_左腿": ["equipment_effect_039"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：effect_066 联邦圣牛头部含自身计数（头部+1张其他联邦装备=2护甲加成）
func test_holyox_head_inclusive_faction_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_091_联邦的圣牛_头部")
	if head_id == &"":
		return "找不到联邦圣牛头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 仅头部（自身联邦）：含自身计数=1
	if _GeneratedEquipmentEffects.compute_head_faction_armor_bonus(mech) != 1:
		return "effect_066 仅头部(含自身)应+1护甲"
	# 加1张其他联邦装备：含自身计数=2
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_008_联邦普装_躯干")
	if torso_id == &"":
		push_warning("教程 deck 无联邦普装躯干，跳过双装备验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	if _GeneratedEquipmentEffects.compute_head_faction_armor_bonus(mech) != 2:
		return "effect_066 头部+1其他联邦装备应+2护甲(含自身)"
	return true


# ════════════════════════════════════════════════════════════════
# 套装17 帝国的雄鹰 097-102（effect_070-073 + 复用 044）
# ════════════════════════════════════════════════════════════════

## 测试：effect_070-073 定义结构 + JSON part_097-102 effect_ids 对齐
func test_eagle_suite17_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_070：每帝国装备动力+1(含自身)（派生值 DIRECT 占位）
	var e070 = effects.get(&"equipment_effect_070")
	if e070 == null or e070.mode != _TimingConst.MODE_DIRECT:
		return "effect_070 应 DIRECT 占位（派生值）"
	# effect_071：弃牌换移动（DIRECT + CHOOSE_MANY_CARDS 多选 + post_actions EXECUTE_SINGLE_MOVE free_move）
	var e071 = effects.get(&"equipment_effect_071")
	if e071 == null or e071.mode != _TimingConst.MODE_DIRECT:
		return "effect_071 应 DIRECT"
	if e071.once_per_turn_key == &"":
		return "effect_071 应有 once_per_turn_key"
	if not _action_has_param(e071, &"EXECUTE_SINGLE_MOVE", &"max_cells_expr", "$choice.count"):
		return "effect_071 EXECUTE_SINGLE_MOVE max_cells_expr 应=$choice.count"
	if not _action_has_param(e071, &"EXECUTE_SINGLE_MOVE", &"free_move", true):
		return "effect_071 EXECUTE_SINGLE_MOVE free_move 应=true"
	# effect_072：迎击路径弃牌换移动（LISTEN USE_ACTION_AT，与071共享once）
	var e072 = effects.get(&"equipment_effect_072")
	if e072 == null or e072.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_072 应监听 USE_ACTION_AT"
	if e072.once_per_turn_key != e071.once_per_turn_key:
		return "effect_072 应与071共享 once_per_turn_key"
	# effect_073：热能弃1牌威力+3
	var e073 = effects.get(&"equipment_effect_073")
	if e073 == null or e073.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_073 应监听 ATTACK_BEFORE"
	if not _action_has_param(e073, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_073 MODIFY_ATTACK_MIGHT delta 应=3"
	# 复用 effect_044 存在
	if effects.get(&"equipment_effect_044") == null:
		return "effect_044 应存在（复用）"
	# JSON part_097-102 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_097_帝国的雄鹰_头部": ["equipment_effect_070"],
		"part_098_帝国的雄鹰_躯干": ["equipment_effect_071", "equipment_effect_072"],
		"part_099_帝国的雄鹰_右臂": ["equipment_effect_073"],
		"part_100_帝国的雄鹰_左臂": ["equipment_effect_073"],
		"part_101_帝国的雄鹰_右腿": ["equipment_effect_044"],
		"part_102_帝国的雄鹰_左腿": ["equipment_effect_044"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：effect_070 帝国雄鹰头部含自身计数（头部+1张其他帝国装备=2动力加成）
func test_eagle_head_inclusive_faction_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_097_帝国的雄鹰_头部")
	if head_id == &"":
		return "找不到帝国雄鹰头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	if _GeneratedEquipmentEffects.compute_head_faction_power_bonus(mech) != 1:
		return "effect_070 仅头部(含自身)应+1动力"
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_014_帝国普装_躯干")
	if torso_id == &"":
		push_warning("教程 deck 无帝国普装躯干，跳过双装备验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	if _GeneratedEquipmentEffects.compute_head_faction_power_bonus(mech) != 2:
		return "effect_070 头部+1其他帝国装备应+2动力(含自身)"
	return true


# ════════════════════════════════════════════════════════════════
# 套装18 轰雷装 103-108（effect_074/075 + 复用 055/058/026/027/048/019/032）
# ════════════════════════════════════════════════════════════════

## 测试：effect_074/075 定义结构 + JSON part_103-108 effect_ids 对齐
func test_thunder_suite18_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_074：此牌损伤<3免疫护甲（派生值 DIRECT 占位）
	var e074 = effects.get(&"equipment_effect_074")
	if e074 == null or e074.mode != _TimingConst.MODE_DIRECT:
		return "effect_074 应 DIRECT 占位（派生值）"
	# effect_075：被攻击弃2牌护甲+5 + 远程威力-3（内层 CHOOSE_ONE 互斥条件自动选）
	# 护甲+5 不指定 target_id（默认 payload.target_id=攻击目标=自身），远程威力-3（原-4，用户裁定改-3）
	var e075 = effects.get(&"equipment_effect_075")
	if e075 == null or e075.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_075 应监听 ATTACK_PRE"
	if not _has_condition(e075, &"OWNER_ACTION_HAND_ABOVE"):
		return "effect_075 应含 OWNER_ACTION_HAND_ABOVE"
	if not _action_has_param(e075, &"EXECUTE_STAT_MODIFY", &"value", 5):
		return "effect_075 EXECUTE_STAT_MODIFY value 应=5(护甲)"
	if not _action_has_param(e075, &"MODIFY_ATTACK_MIGHT", &"delta", -3):
		return "effect_075 内层 CHOOSE_ONE 应含 MODIFY_ATTACK_MIGHT delta=-3(远程)"
	# effect_092：轰雷右臂·损伤≥2动力+3（派生值 DIRECT 占位，替代原 048+019+032）
	var e092 = effects.get(&"equipment_effect_092")
	if e092 == null or e092.mode != _TimingConst.MODE_DIRECT:
		return "effect_092 应 DIRECT 占位（派生值）"
	# 复用 effect_055/058/026/027/048/019/032 存在（048/019/032 仍由超重甲右臂/机动右臂使用）
	for eid in [&"equipment_effect_055", &"equipment_effect_058", &"equipment_effect_026", &"equipment_effect_027", &"equipment_effect_048", &"equipment_effect_019", &"equipment_effect_032"]:
		if effects.get(eid) == null:
			return "%s 应存在（复用）" % String(eid)
	# JSON part_103-108 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_103_轰雷装_头部": ["equipment_effect_055", "equipment_effect_074"],
		"part_104_轰雷装_躯干": ["equipment_effect_075"],
		"part_105_轰雷装_右臂": ["equipment_effect_092"],
		"part_106_轰雷装_左臂": ["equipment_effect_058", "equipment_effect_074"],
		"part_107_轰雷装_右腿": ["equipment_effect_026", "equipment_effect_074"],
		"part_108_轰雷装_左腿": ["equipment_effect_027", "equipment_effect_074"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


# ════════════════════════════════════════════════════════════════
# 套装20 联邦的一角兽 115-120（effect_080-085）
# ════════════════════════════════════════════════════════════════

## 测试：effect_080-085 定义结构 + JSON part_115-120 effect_ids 对齐
func test_unicorn_suite20_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_080：全场联邦光环护甲（派生值 DIRECT 占位）
	var e080 = effects.get(&"equipment_effect_080")
	if e080 == null or e080.mode != _TimingConst.MODE_DIRECT:
		return "effect_080 应 DIRECT 占位（派生值）"
	# effect_081：置4损伤无效攻击（priority 30 + ATTACK_CAN_BE_NEGATED + NEGATE_ATTACK）
	var e081 = effects.get(&"equipment_effect_081")
	if e081 == null or e081.priority != 30:
		return "effect_081 priority 应=30"
	if e081.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_081 应监听 ATTACK_PRE"
	if not _has_condition(e081, &"ATTACK_CAN_BE_NEGATED"):
		return "effect_081 应含 ATTACK_CAN_BE_NEGATED"
	if not _action_has_param(e081, &"EXECUTE_DAMAGE_CHANGE", &"value", 4):
		return "effect_081 EXECUTE_DAMAGE_CHANGE value 应=4"
	if not _action_type_in_effect(e081, &"NEGATE_ATTACK"):
		return "effect_081 应含 NEGATE_ATTACK"
	# effect_082：置2损伤威力+4
	var e082 = effects.get(&"equipment_effect_082")
	if e082 == null or e082.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_082 应监听 ATTACK_BEFORE"
	if not _action_has_param(e082, &"EXECUTE_DAMAGE_CHANGE", &"value", 2):
		return "effect_082 EXECUTE_DAMAGE_CHANGE value 应=2"
	if not _action_has_param(e082, &"MODIFY_ATTACK_MIGHT", &"delta", 4):
		return "effect_082 MODIFY_ATTACK_MIGHT delta 应=4"
	# effect_083：置3损伤攻击次数+1
	var e083 = effects.get(&"equipment_effect_083")
	if e083 == null or e083.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_083 应监听 ATTACK_AFTER"
	if not _action_has_param(e083, &"EXECUTE_DAMAGE_CHANGE", &"value", 3):
		return "effect_083 EXECUTE_DAMAGE_CHANGE value 应=3"
	if not _action_has_param(e083, &"MODIFY_ATTACK_COUNT", &"delta", 1):
		return "effect_083 MODIFY_ATTACK_COUNT delta 应=1"
	# effect_084：AVAILABILITY 响应自损+移动循环
	var e084 = effects.get(&"equipment_effect_084")
	if e084 == null or e084.mode != _TimingConst.MODE_AVAILABILITY:
		return "effect_084 应 MODE_AVAILABILITY"
	if e084.availability_condition != _TimingConst.AVAIL_RESPOND_ATTACK:
		return "effect_084 availability_condition 应=AVAIL_RESPOND_ATTACK"
	if not _action_type_in_effect(e084, &"REPEAT_SELF_DAMAGE_AND_FREE_MOVE"):
		return "effect_084 应含 REPEAT_SELF_DAMAGE_AND_FREE_MOVE"
	# effect_085：置3损伤最多减5攻击损伤
	var e085 = effects.get(&"equipment_effect_085")
	if e085 == null or e085.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_085 应监听 ATTACK_AFTER"
	if not _action_has_param(e085, &"EXECUTE_DAMAGE_CHANGE", &"value", 3):
		return "effect_085 EXECUTE_DAMAGE_CHANGE value 应=3"
	if not _action_has_param(e085, &"MODIFY_ATTACK_MARKERS", &"delta", -5):
		return "effect_085 MODIFY_ATTACK_MARKERS delta 应=-5"
	# JSON part_115-120 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_115_联邦的一角兽_头部": ["equipment_effect_080"],
		"part_116_联邦的一角兽_躯干": ["equipment_effect_081"],
		"part_117_联邦的一角兽_右臂": ["equipment_effect_082"],
		"part_118_联邦的一角兽_左臂": ["equipment_effect_083"],
		"part_119_联邦的一角兽_右腿": ["equipment_effect_084"],
		"part_120_联邦的一角兽_左腿": ["equipment_effect_085"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：effect_080 全场联邦光环（1张一角兽头来源 -> 联邦装备+1护甲；非联邦装备+0）
func test_unicorn_global_aura_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# 设置一角兽头（effect_080 来源）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_115_联邦的一角兽_头部")
	if head_id == &"":
		return "找不到一角兽头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	# 设置1张联邦装备（躯干）
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_008_联邦普装_躯干")
	if torso_id == &"":
		push_warning("教程 deck 无联邦普装躯干，跳过光环验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	var torso_card = mech.slots.get(&"躯干").equipped_card
	# 1张 effect_080 来源 -> 联邦装备 +1护甲
	if _GeneratedEquipmentEffects.get_global_faction_equipment_aura_bonus(torso_card, "联邦") != 1:
		return "effect_080 1张来源应给联邦装备+1护甲光环"
	return true


# ════════════════════════════════════════════════════════════════
# 套装21 帝国的神莺 121-126（effect_086-091 + 复用 082）
# ════════════════════════════════════════════════════════════════

## 测试：effect_086-091 定义结构 + JSON part_121-126 effect_ids 对齐
func test_lark_suite21_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_086：全场帝国光环动力（派生值 DIRECT 占位）
	var e086 = effects.get(&"equipment_effect_086")
	if e086 == null or e086.mode != _TimingConst.MODE_DIRECT:
		return "effect_086 应 DIRECT 占位（派生值）"
	# effect_087：虚拟武器（权限型 DIRECT 占位）
	var e087 = effects.get(&"equipment_effect_087")
	if e087 == null or e087.mode != _TimingConst.MODE_DIRECT:
		return "effect_087 应 DIRECT 占位（权限型）"
	# effect_088：虚拟武器耗尽动力+禁回（priority 30 + ATTACK_SOURCE_IS_SELF + SPEND_POWER ALL_CURRENT + CANNOT_RESTORE_POWER）
	var e088 = effects.get(&"equipment_effect_088")
	if e088 == null or e088.priority != 30:
		return "effect_088 priority 应=30"
	if e088.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_088 应监听 ATTACK_BEFORE"
	if not _has_condition(e088, &"ATTACK_SOURCE_IS_SELF"):
		return "effect_088 应含 ATTACK_SOURCE_IS_SELF"
	if not _action_type_in_effect(e088, &"ADD_STATUS"):
		return "effect_088 应含 ADD_STATUS"
	# effect_090：置2损伤抽3回复3
	var e090 = effects.get(&"equipment_effect_090")
	if e090 == null or e090.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_090 应监听 ATTACK_AFTER"
	if not _action_has_param(e090, &"DRAW_ACTION", &"count", 3):
		return "effect_090 DRAW_ACTION count 应=3"
	if not _action_has_param(e090, &"RESTORE_POWER", &"amount", 3):
		return "effect_090 RESTORE_POWER amount 应=3"
	# effect_091：消耗8动力免费移动2格，并回复2动力（DIRECT 主动触发）
	var e091 = effects.get(&"equipment_effect_091")
	if e091 == null or e091.mode != _TimingConst.MODE_DIRECT:
		return "effect_091 应 DIRECT 主动触发"
	if e091.once_per_turn_key == &"":
		return "effect_091 应有 once_per_turn_key"
	if not _action_has_param(e091, &"EXECUTE_SINGLE_MOVE", &"max_cells", 2):
		return "effect_091 EXECUTE_SINGLE_MOVE max_cells 应=2"
	if not _action_has_param(e091, &"EXECUTE_SINGLE_MOVE", &"free_move", true):
		return "effect_091 EXECUTE_SINGLE_MOVE free_move 应=true"
	if not _action_has_param(e091, &"RESTORE_POWER", &"amount", 2):
		return "effect_091 RESTORE_POWER amount 应=2（并回复2动力）"
	# 复用 effect_082 存在
	if effects.get(&"equipment_effect_082") == null:
		return "effect_082 应存在（复用）"
	# JSON part_121-126 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_121_帝国的神莺_头部": ["equipment_effect_086"],
		"part_122_帝国的神莺_躯干": ["equipment_effect_087", "equipment_effect_088"],
		"part_123_帝国的神莺_右臂": ["equipment_effect_090"],
		"part_124_帝国的神莺_左臂": ["equipment_effect_082"],
		"part_125_帝国的神莺_右腿": ["equipment_effect_091"],
		"part_126_帝国的神莺_左腿": ["equipment_effect_091"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：effect_086 全场帝国光环（1张神莺头来源 -> 帝国装备+1动力）
func test_lark_global_aura_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_121_帝国的神莺_头部")
	if head_id == &"":
		return "找不到神莺头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_014_帝国普装_躯干")
	if torso_id == &"":
		push_warning("教程 deck 无帝国普装躯干，跳过光环验证")
		return true
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	var torso_card = mech.slots.get(&"躯干").equipped_card
	if _GeneratedEquipmentEffects.get_global_faction_equipment_aura_bonus(torso_card, "帝国") != 1:
		return "effect_086 1张来源应给帝国装备+1动力光环"
	return true


## 测试：CANNOT_RESTORE_POWER 状态拦截回复（移除后正常回复）
func test_cannot_restore_power_status() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	mech.power = 0
	# 施加 CANNOT_RESTORE_POWER
	mech.statuses.append({"type": &"CANNOT_RESTORE_POWER", "duration": &"UNTIL_OWNER_TURN_START"})
	battle.context.game_actions.restore_power({"mech_id": mech.mech_id, "amount": 1})
	if mech.power != 0:
		return "CANNOT_RESTORE_POWER 状态下应无法回复(动力应仍=0)，实际=%d" % mech.power
	# 移除状态后正常回复
	mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
		return s.get("type", &"") != &"CANNOT_RESTORE_POWER"
	)
	battle.context.game_actions.restore_power({"mech_id": mech.mech_id, "amount": 1})
	if mech.power != 1:
		return "移除 CANNOT_RESTORE_POWER 后应回复1(0+1=1)，实际=%d" % mech.power
	return true
func test_thunder_damage_threshold_immune() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# part_103 轰雷头（effect_074）
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_103_轰雷装_头部")
	if head_id == &"":
		return "找不到轰雷头部"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var head_card = mech.slots.get(&"头部").equipped_card
	head_card.damage_tokens = 2
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(head_card, mech, 2) != 0:
		return "effect_074 此牌损伤2<3 应免疫(返回0)"
	head_card.damage_tokens = 3
	if _GeneratedEquipmentEffects.card_damage_immune_armor_amount(head_card, mech, 3) != 3:
		return "effect_074 此牌损伤3≥3 应失效扣全部(返回3)"
	return true


# ════════════════════════════════════════════════════════════════
# 套装19 极电装 109-114（effect_076-079 + 复用 021/005）
# ════════════════════════════════════════════════════════════════

## 测试：effect_076-079 定义结构 + JSON part_109-114 effect_ids 对齐
func test_polar_suite19_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_076：范围-2威力+4转近战+回复2（priority 20，适用近战=无 NOT近战 条件）
	var e076 = effects.get(&"equipment_effect_076")
	if e076 == null or e076.priority != 20:
		return "effect_076 priority 应=20"
	if e076.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_076 应监听 ATTACK_BEFORE"
	if _has_condition(e076, &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT"):
		return "effect_076 应适用近战(无 ATTACK_EFFECTIVE_WEAPON_KIND_NOT 条件)"
	if not _action_has_param(e076, &"MODIFY_ATTACK_MIGHT", &"delta", 4):
		return "effect_076 MODIFY_ATTACK_MIGHT delta 应=4"
	if not _action_has_param(e076, &"RESTORE_POWER", &"amount", 2):
		return "effect_076 RESTORE_POWER amount 应=2"
	# effect_077：被攻击弃2牌抽1动力+3
	var e077 = effects.get(&"equipment_effect_077")
	if e077 == null or e077.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_077 应监听 ATTACK_PRE"
	if not _action_has_param(e077, &"DRAW_ACTION", &"count", 1):
		return "effect_077 DRAW_ACTION count 应=1"
	if not _action_has_param(e077, &"EXECUTE_STAT_MODIFY", &"value", 3):
		return "effect_077 EXECUTE_STAT_MODIFY value 应=3(动力)"
	# effect_078：近战弃2牌威力+3 + 选2装备无效
	var e078 = effects.get(&"equipment_effect_078")
	if e078 == null or e078.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_078 应监听 ATTACK_PRE"
	if not _action_has_param(e078, &"MODIFY_ATTACK_MIGHT", &"delta", 3):
		return "effect_078 MODIFY_ATTACK_MIGHT delta 应=3"
	if not _action_has_param(e078, &"CHOOSE_MANY_CARDS", &"max_count", 2):
		return "effect_078 CHOOSE_MANY_CARDS max_count 应=2"
	# effect_079：离场移除最多2损伤
	var e079 = effects.get(&"equipment_effect_079")
	if e079 == null or e079.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_079 应监听 DISCARD_AFTER"
	if not _has_condition(e079, &"TARGET_HAS_DAMAGE"):
		return "effect_079 应含 TARGET_HAS_DAMAGE"
	if not _action_has_param(e079, &"EXECUTE_DAMAGE_CHANGE", &"value", 2):
		return "effect_079 EXECUTE_DAMAGE_CHANGE value 应=2"
	# 复用 effect_021/005 存在
	if effects.get(&"equipment_effect_021") == null:
		return "effect_021 应存在（复用）"
	if effects.get(&"equipment_effect_005") == null:
		return "effect_005 应存在（复用）"
	# JSON part_109-114 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_109_极电装_头部": ["equipment_effect_076"],
		"part_110_极电装_躯干": ["equipment_effect_077"],
		"part_111_极电装_右臂": ["equipment_effect_078"],
		"part_112_极电装_左臂": ["equipment_effect_078"],
		"part_113_极电装_右腿": ["equipment_effect_021", "equipment_effect_079"],
		"part_114_极电装_左腿": ["equipment_effect_021", "equipment_effect_005"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true
func test_negate_equipment_suppresses_derived() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# 装备机动左腿（effect_021：每损伤+1动力）
	var leg_id: StringName = _ensure_equipment_in_hand(battle, "part_030_机动装_左腿")
	if leg_id == &"":
		return "找不到机动左腿"
	battle.context.card_set_service.set_equipment(&"player", leg_id, &"左腿")
	await _pump_frames(3)
	var slot = mech.slots.get(&"左腿")
	slot.equipped_card.damage_tokens = 2
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"左腿") != 2:
		return "effect_021 损伤2 应+2动力"
	# 压制该装备效果（effect_negated）
	battle.context.game_actions.negate_equipment_effect({"target_card_id": leg_id, "duration": "THIS_TURN"})
	if _GeneratedEquipmentEffects.slot_damage_threshold_power_bonus(mech, &"左腿") != 0:
		return "压制后 effect_021 派生值应失效(返回0)"
	# 牌面 stats 仍保留（未 disabled）
	if slot.equipped_card.get("disabled") == true:
		return "压制不应 disabled 装备（保留牌面 stats）"
	return true


# ════════════════════════════════════════════════════════════════
# 套装15 王牌装 085-090（effect_065 + 复用 033/034/056）
# ════════════════════════════════════════════════════════════════

## 测试：effect_065 定义结构 + JSON part_085-090 effect_ids 对齐 + 复用 033/034/056
func test_ace_suite15_structure() -> Variant:
	var effects: Dictionary = _GeneratedEquipmentEffects.build_equipment_effects()
	# effect_065：损伤弃置抽装备立即设置或卖出（LISTEN DISCARD_AFTER + DISCARD_REASON_IS + DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL）
	var e065 = effects.get(&"equipment_effect_065")
	if e065 == null or e065.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_065 应监听 DISCARD_AFTER"
	if not _has_condition(e065, &"DISCARD_REASON_IS"):
		return "effect_065 应含 DISCARD_REASON_IS"
	if not _action_type_in_effect(e065, &"DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL"):
		return "effect_065 应含 DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL"
	# 复用 effect_033/034/056 存在
	if effects.get(&"equipment_effect_033") == null:
		return "effect_033 应存在（复用）"
	if effects.get(&"equipment_effect_034") == null:
		return "effect_034 应存在（复用）"
	if effects.get(&"equipment_effect_056") == null:
		return "effect_056 应存在（复用）"
	# JSON part_085-090 effect_ids 对齐
	var registry := DataRegistry.new()
	registry.load_all()
	var json_map: Dictionary = {
		"part_085_王牌装_头部": ["equipment_effect_033", "equipment_effect_056"],
		"part_086_王牌装_躯干": ["equipment_effect_033", "equipment_effect_034"],
		"part_087_王牌装_右臂": ["equipment_effect_033", "equipment_effect_065"],
		"part_088_王牌装_左臂": ["equipment_effect_033", "equipment_effect_065"],
		"part_089_王牌装_右腿": ["equipment_effect_033", "equipment_effect_056"],
		"part_090_王牌装_左腿": ["equipment_effect_033", "equipment_effect_056"],
	}
	for part_id: String in json_map:
		var raw: Dictionary = registry.get_equipment_part(part_id)
		if raw.is_empty():
			return "JSON 缺少 %s" % part_id
		var eids: Array = raw.get("effect_ids", [])
		var want: Array = json_map[part_id]
		if eids.size() != want.size():
			return "%s effect_ids 数量应为%d，实际%d" % [part_id, want.size(), eids.size()]
		for i in range(want.size()):
			if String(eids[i]) != String(want[i]):
				return "%s effect_ids[%d] 应=%s，实际=%s" % [part_id, i, String(want[i]), String(eids[i])]
	return true


## 测试：重甲头部(effect_089)双计损伤下总损伤阈值正确。
## 损伤放置为 region+card 双计，"机甲部件总损伤数"只应算 region；若误加 card 会双计翻倍，
## 致放2个损伤(双计算4)误判≥3失效。文档:1~2不影响护甲,≥3才失效。
func test_heavy_head_double_count_immune() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var head_id: StringName = _ensure_equipment_in_hand(battle, "part_019_重甲装_头部")
	if head_id == &"":
		return "找不到重甲头部装备牌"
	battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	await _pump_frames(3)
	var slot = mech.slots.get(&"头部")
	if slot == null or slot.equipped_card == null:
		return "头部装备未设置"
	# 双计放2个损伤：region=2 且 card.damage_tokens=2（与 DamageTokenService 双计一致）
	slot.region_damage_tokens = 2
	slot.equipped_card.damage_tokens = 2
	# 总损伤应只算 region=2 <3 -> 免疫（旧双计代码会算成4误失效）
	var dmg2: int = _GeneratedEquipmentEffects.card_damage_immune_armor_amount(slot.equipped_card, mech, 2)
	if dmg2 != 0:
		return "重甲头部双计2损伤(总损伤应=2<3)应免疫返回0，实际:%d" % dmg2
	# 双计放3个损伤：region=3 且 card=3 -> 总损伤=3≥3 -> 失效
	slot.region_damage_tokens = 3
	slot.equipped_card.damage_tokens = 3
	var dmg3: int = _GeneratedEquipmentEffects.card_damage_immune_armor_amount(slot.equipped_card, mech, 3)
	if dmg3 != 3:
		return "重甲头部双计3损伤(总损伤应=3≥3)应失效返回3，实际:%d" % dmg3
	return true


## 测试：派生动力(effect_016重甲右臂阈值+1 / effect_021机动腿逐点)随损伤变化时，
## recalc_power_limits 正确同步 max_power 与 power（修复 dev/真实路径损伤变动后
## "详情派生+动力显示但 max_power 不加"的问题）。
func test_damage_power_recalc_sync() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	# 重甲右臂(effect_016)：损伤≥1动力+1（阈值型，固定+1，不逐点累加）
	var rarm_id: StringName = _ensure_equipment_in_hand(battle, "part_021_重甲装_右臂")
	if rarm_id == &"":
		return "找不到重甲右臂装备牌"
	battle.context.card_set_service.set_equipment(&"player", rarm_id, &"右臂")
	await _pump_frames(3)
	var rarm_slot = mech.slots.get(&"右臂")
	if rarm_slot == null or rarm_slot.equipped_card == null:
		return "重甲右臂未设置"
	var max_before: int = mech.max_power
	var pwr_before: int = mech.power
	# 双计加1损伤 + recalc（修复后所有损伤路径都调 recalc_power_limits）
	rarm_slot.region_damage_tokens = 1
	rarm_slot.equipped_card.damage_tokens = 1
	mech.recalc_power_limits()
	if mech.max_power != max_before + 1:
		return "重甲右臂1损伤后 max_power 应+1，实际+%d" % [mech.max_power - max_before]
	if mech.power != pwr_before + 1:
		return "重甲右臂1损伤后 power 应+1(上下限都加)，实际+%d" % [mech.power - pwr_before]
	# 再加1损伤(共2)：effect_016 阈值型固定+1，max_power 不再增
	rarm_slot.region_damage_tokens = 2
	rarm_slot.equipped_card.damage_tokens = 2
	mech.recalc_power_limits()
	if mech.max_power != max_before + 1:
		return "重甲右臂2损伤(阈值型固定+1)max_power 应仍+1，实际+%d" % [mech.max_power - max_before]
	# 机动右腿(effect_021 逐点型)：每损伤+1
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_029_机动装_右腿")
	if rleg_id == &"":
		return "找不到机动右腿装备牌"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	var rleg_slot = mech.slots.get(&"右腿")
	if rleg_slot == null or rleg_slot.equipped_card == null:
		return "机动右腿未设置"
	var leg_max_before: int = mech.max_power
	rleg_slot.region_damage_tokens = 2
	rleg_slot.equipped_card.damage_tokens = 2
	mech.recalc_power_limits()
	# effect_021 逐点：2损伤 -> +2
	if mech.max_power != leg_max_before + 2:
		return "机动右腿2损伤(逐点)max_power 应+2，实际+%d" % [mech.max_power - leg_max_before]
	return true


## 测试：高机动装左右腿 effect_021 经真实损伤放置路径(place_one_damage_token)
## 放1个损伤时 max_power 与 power 都应+1（用户报：1损伤只升上限不升数值，2损伤才都升）。
## 覆盖满动力(power==max)与已消耗动力(power<max)两种情形。
func test_hm_leg_damage_power_via_real_path() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_071_高机动装_右腿")
	if rleg_id == &"":
		return "找不到高机动右腿装备牌"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	var rleg_slot = mech.slots.get(&"右腿")
	if rleg_slot == null or rleg_slot.equipped_card == null:
		return "高机动右腿未设置"

	# ── 情形A：满动力下放1损伤 ──
	# 确保满动力
	mech.power = mech.max_power
	var max0: int = mech.max_power
	var pwr0: int = mech.power
	# 真实路径：PvP damage_place op 调用的就是 place_one_damage_token（传 mech_id）
	battle.context.damage_token_service.place_one_damage_token(mech.mech_id, &"右腿")
	if mech.max_power != max0 + 1:
		return "A1: 高机动右腿1损伤后 max_power 应+1，实际+%d" % [mech.max_power - max0]
	if mech.power != pwr0 + 1:
		return "A2: 高机动右腿1损伤后 power 应+1(满动力)，实际+%d (max=%d power=%d)" % [mech.power - pwr0, mech.max_power, mech.power]

	# ── 情形B：已消耗动力下再放1损伤(共2) ──
	# 模拟已移动消耗：把 power 降到 max 以下
	mech.power = mech.max_power - 3
	var max1: int = mech.max_power
	var pwr1: int = mech.power
	battle.context.damage_token_service.place_one_damage_token(mech.mech_id, &"右腿")
	if mech.max_power != max1 + 1:
		return "B1: 高机动右腿2损伤后 max_power 应再+1，实际+%d" % [mech.max_power - max1]
	if mech.power != pwr1 + 1:
		return "B2: 高机动右腿2损伤后 power 应+1(已消耗动力)，实际+%d (max=%d power=%d)" % [mech.power - pwr1, mech.max_power, mech.power]
	return true


## 测试：高机动装腿 effect_021 走 F3 开发模式真实路径（直接 region+card 双计 + recalc，
## 不走 place_one_damage_token 的 hook/损坏检查），核对 max_power/power/get_total_power 三者一致。
## 用户报：F3 加1损伤只升上限不升数值。本测试复现该路径以定位。
func test_hm_leg_dev_mode_path() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_071_高机动装_右腿")
	if rleg_id == &"":
		return "找不到高机动右腿装备牌"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	var slot = mech.slots.get(&"右腿")
	if slot == null or slot.equipped_card == null:
		return "高机动右腿未设置"
	# 满动力
	mech.power = mech.max_power
	var max0: int = mech.max_power
	var pwr0: int = mech.power
	var tot0: int = mech.get_total_power()
	# ── F3 dev 路径：直接双计 + recalc（与 app_root._apply_dev_edit add_region_damage 一致）──
	slot.region_damage_tokens += 1
	slot.equipped_card.damage_tokens += 1
	mech.recalc_power_limits()
	# 三者都应 +1
	if mech.get_total_power() != tot0 + 1:
		return "dev路径: get_total_power 应+1，实际+%d" % [mech.get_total_power() - tot0]
	if mech.max_power != max0 + 1:
		return "dev路径: max_power 应+1，实际+%d (get_total_power=%d)" % [mech.max_power - max0, mech.get_total_power()]
	if mech.power != pwr0 + 1:
		return "dev路径: power 应+1，实际+%d (max=%d power=%d tot=%d)" % [mech.power - pwr0, mech.max_power, mech.power, mech.get_total_power()]
	# 再加1损伤(共2)
	mech.power = mech.max_power  # 重置满动力
	var max1: int = mech.max_power
	var pwr1: int = mech.power
	slot.region_damage_tokens += 1
	slot.equipped_card.damage_tokens += 1
	mech.recalc_power_limits()
	if mech.max_power != max1 + 1:
		return "dev路径2损伤: max_power 应+1，实际+%d" % [mech.max_power - max1]
	if mech.power != pwr1 + 1:
		return "dev路径2损伤: power 应+1，实际+%d (max=%d power=%d)" % [mech.power - pwr1, mech.max_power, mech.power]
	return true


## 测试：近战特装右腿 effect_064 离场 -> CHOOSE_ONE 选"回复3+移动" -> EXECUTE_SINGLE_MOVE
## 应创建 single_move 子动作并请求 select_move_target（mech_id 解析正确）。
## 用户报：回复动力生效但"用当前动力移动"不生效。根因疑为 _extract_single_move_params
## 在装备离场效果上下文里解析不到 mech_id（payload 无 source_mech_id，只在 binding_context）。
func test_melee_rleg_leave_move_creates_single_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var mech = gs.get_mech_for_player(&"player")
	var rleg_id: StringName = _ensure_equipment_in_hand(battle, "part_083_近战特装_右腿")
	if rleg_id == &"":
		return "找不到近战特装右腿"
	battle.context.card_set_service.set_equipment(&"player", rleg_id, &"右腿")
	await _pump_frames(3)
	# 给机甲留些动力供移动
	mech.power = maxi(mech.power, 3)
	var power_before: int = mech.power
	# 弃置近战右腿 -> DISCARD_AFTER 触发 effect_064（CHOOSE_ONE optional 回复3+移动）
	battle.context.deck_service.discard_card(rleg_id, &"equipment_replace")
	await _pump_frames(8)
	# 找到挂起的 discard_card 动作（应挂在 effect_064 的 CHOOSE_ONE）
	var discard_action_id: StringName = &""
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		discard_action_id = a.action_id
		break
	if discard_action_id == &"":
		return "未找到 discard_card 动作（effect_064 未挂起？）"
	# 选"回复3动力并用当前所有动力移动"（option 0）
	battle.context.timing_engine.resume_pending_effect(discard_action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	# RESTORE_POWER 应已生效（+3，clamp 到 max_power）
	if mech.power != clampi(power_before + 3, 0, mech.max_power):
		return "RESTORE_POWER 应+3，实际 %d -> %d (max=%d)" % [power_before, mech.power, mech.max_power]
	# EXECUTE_SINGLE_MOVE 应创建 single_move 子动作，挂起在 select_move_target
	var sm_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"single_move"):
		sm_action = a
		break
	if sm_action == null:
		return "effect_064 未创建 single_move 子动作（移动未生效）"
	if String(sm_action.record.get("mech_id", &"")) == &"":
		return "single_move mech_id 为空（_extract_single_move_params 未解析到机甲）"
	if String(sm_action.record.get("mech_id", &"")) != String(mech.mech_id):
		return "single_move mech_id 应=玩家机甲，实际: %s" % String(sm_action.record.get("mech_id", &""))
	# 清理：取消 single_move 避免残留
	battle.context.action_engine.cancel_action(sm_action.action_id)
	await _pump_frames(3)
	return true


## 测试：帝国赤枭躯干 effect_040 CHOOSE_MANY_CARDS 多选弃牌换动力
## 列出全部行动牌 -> 选2张 -> 弃置2张 + 本回合动力+4；取消不发动不消耗；选0张消耗1次。
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
func test_red_owl_torso_multidiscard_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	gs.active_player_id = &"player"
	var mech = gs.get_mech_for_player(&"player")
	var db = battle.context.card_database
	# 装备赤枭躯干（effect_040/041）
	var torso_id: StringName = _ensure_equipment_in_hand(battle, "part_056_帝国的赤枭_躯干")
	if torso_id == &"":
		return "找不到赤枭躯干"
	battle.context.card_set_service.set_equipment(&"player", torso_id, &"躯干")
	await _pump_frames(3)
	# 清空手牌并加3张行动牌
	var player = gs.players.get(&"player")
	for cid in player.action_hand.duplicate():
		var c = gs.get_card(cid)
		if c: c.zone = &"discard"
	player.action_hand.clear()
	var card_a := _add_action_card(battle, db, "action_001_进攻")
	var card_b := _add_action_card(battle, db, "action_001_进攻")
	var card_c := _add_action_card(battle, db, "action_001_进攻")
	if card_a == &"" or card_b == &"" or card_c == &"":
		return "加行动牌失败"
	# 记录初始动力
	mech.power = 5
	mech.max_power = 10
	var pwr0: int = mech.power
	# 主动触发 effect_040
	var ef_res = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_040",
		"source": {"card_instance_id": torso_id, "mech_id": mech.mech_id, "player_id": &"player"},
	})
	await _pump_frames(5)
	var ef_id: StringName = ef_res.get("action_id", &"") if ef_res is Dictionary else &""
	if ef_id == &"":
		return "effect_fire 未创建动作"
	# 选 card_a + card_b（2张）
	battle.context.timing_engine.resume_pending_effect(ef_id, {"selected_card_ids": [card_a, card_b]})
	await _pump_frames(6)
	# 应弃置2张（手牌只剩 card_c），动力+4（THIS_TURN，允许超上限）
	if player.action_hand.size() != 1 or not player.action_hand.has(card_c):
		return "应弃置2张牌，剩余手牌=%s" % str(player.action_hand)
	if mech.power != pwr0 + 4:
		return "应+4动力，实际 %d -> %d" % [pwr0, mech.power]
	# once_per_turn 应已标记：再次触发应被跳过（不再弹窗）
	var ef2 = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_040",
		"source": {"card_instance_id": torso_id, "mech_id": mech.mech_id, "player_id": &"player"},
	})
	await _pump_frames(4)
	# 第二次不应挂起多选窗（once_per_turn 已用）
	var still_pending := false
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			still_pending = true
	if still_pending:
		return "第二次 effect_040 应被 once_per_turn 跳过，不应再弹窗"
	return true


## 辅助：加一张行动牌到玩家手牌，返回 instance_id
func _add_action_card(battle, db, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var def = db.get_card(card_def_id) if db != null else null
	if def == null:
		return &""
	var mech = gs.get_mech_for_player(&"player")
	var inst = _CardInstance.new(gs.next_id("card"), def)
	inst.owner_player_id = &"player"
	inst.mech_id = mech.mech_id if mech else &""
	inst.zone = &"action_hand"
	gs.cards[inst.instance_id] = inst
	gs.players.get(&"player").action_hand.append(inst.instance_id)
	return inst.instance_id
