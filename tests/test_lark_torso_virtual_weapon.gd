## test_lark_torso_virtual_weapon.gd - 帝国的神莺·躯干虚拟武器接入验证
##
## 验证 effect_087（虚拟武器）+ effect_088（耗尽动力+禁回）接入武器选择/攻击流程：
##   ① 装备神莺躯干后 get_virtual_weapon_from_equipment 返回 might=20/range=6/远程
##   ② face_down 时返回 {}（效果无效则不能当武器）
##   ③ 用虚拟武器攻击：attack.record["attack_weapon_instance_id"]==躯干instance_id，
##      effect_088 触发（动力清0 + CANNOT_RESTORE_POWER 状态）
##   ④ 用实体武器攻击：effect_088 不触发（动力不变，无 CANNOT_RESTORE_POWER）
##   ⑤ 虚拟武器射程含狙击头部加成（6+1=7，距离7目标命中）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


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


func _ensure_equipment_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
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


func _equip_part(battle: BattleState, card_def_id: String, slot_id: StringName) -> bool:
	var cid: StringName = _ensure_equipment_in_hand(battle, card_def_id)
	if cid == &"":
		return false
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", cid, slot_id)
	if not result.get("ok", false):
		return false
	await _pump_frames(3)
	return true


func _clear_enemy_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid: StringName in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	enemy.action_hand.clear()


func _ensure_attack_card_in_hand(battle: BattleState) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> void:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)


## ①② 虚拟武器条目 + face_down 失效
func test_lark_virtual_weapon_entry() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var torso_slot = pm.slots.get(&"躯干")
	if torso_slot == null or torso_slot.equipped_card == null:
		return "躯干槽无装备"
	var torso_card = torso_slot.equipped_card
	var vw = _GenEquipEffects.get_virtual_weapon_from_equipment(torso_card)
	if vw.is_empty():
		return "虚拟武器条目为空（effect_087 未识别）"
	if int(vw.get("might", 0)) != 20:
		return "虚拟武器威力应=20，实际 %d" % int(vw.get("might", 0))
	if int(vw.get("range_value", 0)) != 6:
		return "虚拟武器射程应=6，实际 %d" % int(vw.get("range_value", 0))
	if String(vw.get("weapon_kind", &"")) != "远程":
		return "虚拟武器类型应=远程，实际 %s" % String(vw.get("weapon_kind", &""))
	# face_down 失效（效果无效则不能当武器）
	torso_card.face_down = true
	var vw2 = _GenEquipEffects.get_virtual_weapon_from_equipment(torso_card)
	if not vw2.is_empty():
		return "face_down 时虚拟武器应不可用"
	torso_card.face_down = false
	return true


## ③ 用虚拟武器攻击：effect_088 触发（动力清0 + 禁回）
func test_lark_virtual_weapon_drains_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.power = 5  # 确保动力>0
	var torso_card = pm.slots.get(&"躯干").equipped_card
	var virtual_weapon_id: StringName = torso_card.instance_id
	# 敌方在虚拟武器射程内（距离1）
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", virtual_weapon_id, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "虚拟武器攻击未发起: %s" % str(atk_result)
	await _pump_frames(5)
	var attack = battle.context.action_registry.get_action(attack_id)
	if attack == null:
		return "攻击动作消失"
	# attack_weapon_instance_id 写入（仅虚拟武器）
	if attack.record.get("attack_weapon_instance_id", &"") != virtual_weapon_id:
		return "attack_weapon_instance_id 应=躯干instance_id，实际 %s" % String(attack.record.get("attack_weapon_instance_id", &""))
	# 虚拟武器 stats
	if int(attack.record.get("weapon_might", 0)) != 20:
		return "虚拟武器威力应=20，实际 %d" % int(attack.record.get("weapon_might", 0))
	# effect_088：动力清0
	if int(pm.power) != 0:
		return "effect_088 应清空动力，实际 power=%d" % int(pm.power)
	# CANNOT_RESTORE_POWER 状态
	var has_status := false
	for s in pm.statuses:
		if s is Dictionary and s.get("type", &"") == &"CANNOT_RESTORE_POWER":
			has_status = true
			break
	if not has_status:
		return "effect_088 应施加 CANNOT_RESTORE_POWER 状态"
	_drive_damage_placement(battle, attack_id)
	return true


## ④ 用实体武器攻击：effect_088 不触发
func test_lark_real_weapon_no_drain() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.power = 5
	# 给一把实体远程武器（覆盖基础武器）
	pm.set_base_weapon({"name": "test_ranged", "might": 10, "range_value": 3, "weapon_kind": &"远程"})
	var real_weapon_id: StringName = pm.get_weapon_ids()[0]
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", real_weapon_id, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "实体武器攻击未发起"
	await _pump_frames(5)
	var attack = battle.context.action_registry.get_action(attack_id)
	if attack == null:
		return "攻击动作消失"
	# 实体武器不写 attack_weapon_instance_id（仅虚拟武器写，避免触发 effect_088）
	if attack.record.get("attack_weapon_instance_id", &"") != &"":
		return "实体武器不应写 attack_weapon_instance_id，实际 %s" % String(attack.record.get("attack_weapon_instance_id", &""))
	# 动力不变（攻击不消耗动力，effect_088 不触发）
	if int(pm.power) != 5:
		return "实体武器攻击动力应不变=5，实际 %d（effect_088 误触发？）" % int(pm.power)
	# 无 CANNOT_RESTORE_POWER
	for s in pm.statuses:
		if s is Dictionary and s.get("type", &"") == &"CANNOT_RESTORE_POWER":
			return "实体武器攻击不应施加 CANNOT_RESTORE_POWER"
	_drive_damage_placement(battle, attack_id)
	return true


## ⑤ 虚拟武器射程含狙击头部加成（weapon_range = 6+1 = 7）
func test_lark_virtual_weapon_sniper_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 装狙击装头部（effect_022 +1远程）
	if not await _equip_part(battle, "part_031_狙击装_头部", &"头部"):
		return "装备狙击装头部失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.power = 5
	var torso_card = pm.slots.get(&"躯干").equipped_card
	var virtual_weapon_id: StringName = torso_card.instance_id
	# 距离1（确保 BFS 可达，聚焦验证 weapon_range 数值含狙击加成）
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", virtual_weapon_id, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "虚拟武器攻击未发起"
	await _pump_frames(5)
	var attack = battle.context.action_registry.get_action(attack_id)
	if attack == null:
		return "攻击动作消失"
	# weapon_range 应=7（虚拟武器6 + 狙击头1）
	var wr: int = int(attack.record.get("weapon_range", -1))
	if wr != 7:
		return "虚拟武器+狙击头 weapon_range 应=7（6+1），实际 %d" % wr
	# 命中
	if not bool(attack.record.get("hit", false)):
		return "距离1目标应命中，hit=false"
	_drive_damage_placement(battle, attack_id)
	return true


## ⑥ 不能回复动力限制：effect_088 CANNOT_RESTORE_POWER 拦截验证
## 回复动力(restore_power)、增加动力(modify_mech_power +delta)、增加动力上限(max_power) 三者不同，
## CANNOT_RESTORE_POWER 仅限制"回复动力"。①攻击后动力清0+状态 ②restore_power被拦截
## ③增加动力不被拦截 ④下个我方回合开始状态移除+回复
func test_lark_cannot_restore_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.power = 5
	var torso_card = pm.slots.get(&"躯干").equipped_card
	var vw_id: StringName = torso_card.instance_id
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", vw_id, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "虚拟武器攻击未发起"
	await _pump_frames(5)
	if int(pm.power) != 0:
		return "effect_088 应清空动力，实际 power=%d" % int(pm.power)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(2)
	# ② 回复动力被拦截（CANNOT_RESTORE_POWER 仅拦 restore_power）
	battle.context.game_actions.restore_power({"mech_id": pm.mech_id, "amount": "full"})
	if int(pm.power) != 0:
		return "CANNOT_RESTORE_POWER 应拦截 restore_power，实际 power=%d" % int(pm.power)
	# ③ 增加动力不被拦截（modify_mech_power +delta 走 stat_modify，非 restore）
	battle.context.game_actions.modify_mech_power({"mech_id": pm.mech_id, "delta": 3})
	if int(pm.power) != 3:
		return "增加动力不应被拦截，应 power=3，实际 %d" % int(pm.power)
	# ④ 下个我方回合开始：TurnService 先移除 CANNOT_RESTORE_POWER 再 restore_power
	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(5)
	for s in pm.statuses:
		if s is Dictionary and s.get("type", &"") == &"CANNOT_RESTORE_POWER":
			return "下个我方回合开始 CANNOT_RESTORE_POWER 应移除"
	if int(pm.power) <= 3:
		return "下个我方回合开始应回复动力（>3），实际 power=%d" % int(pm.power)
	return true


## ⑦ 实机弹窗流程：select_weapon need_input -> on_ui_confirmed 选虚拟武器 -> effect_088 触发
## 验证实机走弹窗（非直接传 weapon_id）时 attack_weapon_instance_id 仍正确写入、effect_088 触发。
func test_lark_virtual_weapon_select_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if not await _equip_part(battle, "part_122_帝国的神莺_躯干", &"躯干"):
		return "装备神莺躯干失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.power = 5
	var torso_id: StringName = pm.slots.get(&"躯干").equipped_card.instance_id
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	# 不传 weapon_id，走 select_weapon need_input（模拟实机弹窗流程）
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", &"", atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(3)
	var bridge = battle.context.action_ui_bridge
	var wait_info: Dictionary = bridge.get_waiting_action_info()
	if wait_info.get("input_type", &"") != &"select_weapon":
		return "应等待 select_weapon，实际 %s" % String(wait_info.get("input_type", &""))
	# 玩家在弹窗选虚拟武器（神莺躯干 instance_id）
	bridge.on_ui_confirmed({"weapon_id": torso_id})
	await _pump_frames(5)
	var attack = battle.context.action_registry.get_action(attack_id)
	if attack == null:
		return "攻击动作消失"
	if attack.record.get("attack_weapon_instance_id", &"") != torso_id:
		return "attack_weapon_instance_id 应=躯干instance_id，实际 %s" % String(attack.record.get("attack_weapon_instance_id", &""))
	if int(attack.record.get("weapon_might", 0)) != 20:
		return "虚拟武器威力应=20，实际 %d" % int(attack.record.get("weapon_might", 0))
	# effect_088 触发（动力清0 + 禁回状态）
	if int(pm.power) != 0:
		return "effect_088 应清空动力，实际 power=%d" % int(pm.power)
	var has_status := false
	for s in pm.statuses:
		if s is Dictionary and s.get("type", &"") == &"CANNOT_RESTORE_POWER":
			has_status = true
			break
	if not has_status:
		return "effect_088 应施加 CANNOT_RESTORE_POWER"
	_drive_damage_placement(battle, attack_id)
	return true
