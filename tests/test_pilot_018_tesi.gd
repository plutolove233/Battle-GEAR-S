## test_pilot_018_tesi.gd - 苔丝（pilot_018）效果测试
##
## 苔丝 1 按钮（被动融合）：effect_01a(ATTACK_PRE 抽2牌) + effect_01b(ATTACK_AT 迎击后弃攻击方牌)。
##   01a：每玩家回合1次，被攻击时弹窗问是否发动。确认->抽2行动牌 + 设 flag pilot_018_activated。
##   01b：flag 已设 + 被我方真实迎击牌响应（非虚拟转化）-> 弃攻击方2行动牌或1损伤≥2装备牌。
##        弃的是攻击武器牌 -> _weapon_still_held 失败 -> 未命中立即结算。
##
## 关键覆盖点：
##   1. 01a/01b 定义（LISTEN ATTACK_PRE/AT + once_per_turn + flag 条件 + 真实迎击响应 checker）。
##   2. 01a 确认发动抽2牌 + 设 flag；取消不设 flag 不消耗次数。
##   3. 01b 真实迎击牌响应触发弃牌；虚拟转化迎击牌不触发。
##   4. 01b 弃行动牌（=2直接弃 / ≥3选2）；弃装备牌（损伤≥2）。
##   5. 01a 未发动（无 flag）-> 01b 不触发。
##   6. fork 深拷贝继承 flag -> 双连打苔丝的 fork 触发 01b。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90018
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设苔丝为 owner_id 机甲的机师，返回 {mech, enemy_mech, pilot_card, gs, cdb}；失败返回 null。
func _setup_tesi(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_018_苔丝", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 attack action（fire ATTACK_PRE/AT 用）。attacker_pid 是攻击方玩家。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p018_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 给 player 补 N 张行动牌（从牌堆顶抽）
func _give_player_action_cards(battle, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
		out.append(cid)
	return out


## 确保 enemy 行动手牌至少 count 张（供弃牌测试）
func _ensure_enemy_action_hand(gs, count: int) -> Variant:
	var enemy_player = gs.players.get(&"enemy")
	while enemy_player.action_hand.size() < count and gs.deck_state.action_deck.size() > 0:
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
		var dc = gs.get_card(cid)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"enemy"
	if enemy_player.action_hand.size() < count:
		return "enemy 行动手牌不足%d张" % count
	return null


## 设 enemy 行动手牌恰好 count 张（多的移回牌堆底，少的补抽）
func _set_enemy_action_hand(battle, gs, count: int) -> void:
	var te = battle.context.timing_engine
	var enemy_player = gs.players.get(&"enemy")
	# 多的移回牌堆底
	while enemy_player.action_hand.size() > count:
		var cid: StringName = enemy_player.action_hand.pop_back()
		te.unregister_listeners_for_card(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)
	# 少的补抽
	while enemy_player.action_hand.size() < count and gs.deck_state.action_deck.size() > 0:
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
		var dc = gs.get_card(cid)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"enemy"


## 给 enemy 机甲某槽装一张损伤≥2的装备牌（供弃装备牌测试）
func _equip_damage_token_equipment(gs, cdb, mech, slot_id: StringName, card_def_id: String, damage_tokens: int):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = mech.owner_player_id
	card.mech_id = mech.mech_id
	card.zone = &"equipment_slot"
	card.slot_id = slot_id
	card.damage_tokens = damage_tokens
	gs.cards[inst_id] = card
	var slot = mech.slots.get(slot_id)
	if slot == null:
		slot = _MechSlotState.new()
		slot.slot_id = slot_id
		mech.slots[slot_id] = slot
	slot.equipped_card = card
	return card


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：01a 定义正确
func test_pilot_018_e01a_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_018_effect_01a")
	if e == null:
		return "缺 pilot_018_effect_01a"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "01a mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_PRE:
		return "01a listen_timing 应 ATTACK_PRE"
	if int(e.priority) != 10:
		return "01a priority 应 10 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "01a listen_action_type 应 attack"
	if e.once_per_turn_key != &"pilot_018_effect_01":
		return "01a once_per_turn_key 应 pilot_018_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "01a once_per_turn_max 应 1"
	# conditions: SELF_MECH_IS_ATTACK_TARGET
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACK_TARGET"):
		return "01a 应含 SELF_MECH_IS_ATTACK_TARGET"
	# actions 含 CHOOSE_ONE(optional) -> EXECUTE_GAIN_CARD + SET_ACTION_RECORD_FLAG
	var act_types: Array = _collect_act_types(e.actions)
	if not act_types.has("CHOOSE_ONE"):
		return "01a 应含 CHOOSE_ONE"
	if not act_types.has("EXECUTE_GAIN_CARD"):
		return "01a 应含 EXECUTE_GAIN_CARD"
	if not act_types.has("SET_ACTION_RECORD_FLAG"):
		return "01a 应含 SET_ACTION_RECORD_FLAG"
	return true


## 递归收集 actions 列表里所有 action type（含 CHOOSE_ONE 分支内嵌套）
func _collect_act_types(actions: Array) -> Array:
	var out: Array = []
	for a in actions:
		var t = String(a.get("type", &""))
		out.append(t)
		if t == "CHOOSE_ONE":
			var opts = a.get("params", {}).get("options", [])
			for opt in opts:
				out += _collect_act_types(opt.get("actions", []))
	return out


## 测试2：01b 定义正确
func test_pilot_018_e01b_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_018_effect_01b")
	if e == null:
		return "缺 pilot_018_effect_01b"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "01b mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_AT:
		return "01b listen_timing 应 ATTACK_AT"
	if int(e.priority) != 0:
		return "01b priority 应 0 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "01b listen_action_type 应 attack"
	# conditions: ATTACK_RECORD_FLAG_IS_SET + ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("ATTACK_RECORD_FLAG_IS_SET"):
		return "01b 应含 ATTACK_RECORD_FLAG_IS_SET"
	if not ops.has("ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER"):
		return "01b 应含 ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER"
	# actions 含 PILOT_018_RESPOND_DISCARD
	var act_type = String(e.actions[0].get("type", &"")) if not e.actions.is_empty() else ""
	if act_type != "PILOT_018_RESPOND_DISCARD":
		return "01b actions[0] 应 PILOT_018_RESPOND_DISCARD 实=%s" % act_type
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试3：01a 确认发动 -> 抽2牌 + 设 flag
func test_pilot_018_e01a_confirm_draws_2_sets_flag() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var before = setup.player.action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# 01a 弹 CHOOSE_ONE(optional)，选发动(chosen_option_index=0)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(2)
	var after = setup.player.action_hand.size()
	if after - before != 2:
		return "确认发动应抽2牌 实抽=%d" % (after - before)
	# flag 已设
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	var flag_entry: Dictionary = flags.get(&"pilot_018_activated", {})
	if not bool(flag_entry.get("value", false)):
		return "确认发动应设 pilot_018_activated flag"
	return true


## 测试4：01a 取消 -> 不抽牌 + 不设 flag + 不消耗次数
func test_pilot_018_e01a_cancel_no_flag_no_consume() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var before = setup.player.action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(2)
	if setup.player.action_hand.size() != before:
		return "取消不应抽牌"
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if flags.has(&"pilot_018_activated"):
		return "取消不应设 flag"
	# 第二次攻击应能再触发（次数未消耗）
	var attack2 = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	# attack2 应弹窗（01a 仍可发动）
	if not battle.context.action_registry.get_action(attack2.action_id).state in [&"waiting_timing", &"waiting_effect_action"]:
		return "取消后次数未消耗，第二次应能再触发"
	te.resume_pending_effect(attack2.action_id, {"cancelled": true})
	return true


## 测试5：01b 无 flag（01a 未发动）不触发
func test_pilot_018_e01b_no_trigger_without_flag() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var err = _ensure_enemy_action_hand(gs, 3)
	if err != null:
		return err
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	# 不设 flag（01a 未发动）
	# 模拟被真实迎击牌响应
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": &""}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	# 无 flag -> 01b 不触发 -> enemy 手牌不变
	if gs.players.get(&"enemy").action_hand.size() != enemy_before:
		return "无 flag 时 01b 不应触发（enemy 手牌不应变）"
	return true


## 测试6：01b 被真实迎击牌响应 + flag -> 弃攻击方2行动牌（=2直接弃）
func test_pilot_018_e01b_real_counter_discard_2_cards() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 给 player 一张真实迎击牌（反击）作响应牌
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "缺 action_010_反击"
	# 确保 enemy 恰好 2 张行动牌（走"=2直接弃全部"分支，不弹选牌窗）
	_set_enemy_action_hand(battle, gs, 2)
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	if enemy_before != 2:
		return "enemy 应为2张 实=%d" % enemy_before
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	# 设 flag（01a 已发动）
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	# 模拟被真实迎击牌响应
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(3)
	# 01b 触发：enemy 恰好2张 -> 直接弃全部（不弹选牌窗）
	var enemy_after = gs.players.get(&"enemy").action_hand.size()
	if enemy_after != 0:
		return "enemy=2张应直接弃全部 实剩=%d" % enemy_after
	return true


## 测试7：01b 虚拟转化迎击牌不触发（排除虚拟）
func test_pilot_018_e01b_virtual_counter_no_trigger() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	# 给 player 一张迎击牌，但标记为虚拟转化
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "缺 action_010_反击"
	counter_card.counters["virtual_as_def_id"] = &"action_010_反击"  # 虚拟转化标记
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	# 虚拟转化 -> 01b 不触发 -> enemy 手牌不变
	if gs.players.get(&"enemy").action_hand.size() != enemy_before:
		return "虚拟转化迎击牌不应触发 01b"
	return true


## 测试8：01b 非苔丝方响应不触发
func test_pilot_018_e01b_other_player_respond_no_trigger() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	# 响应方是 enemy（非苔丝方 player）
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"enemy")
	if counter_card == null:
		return "缺 action_010_反击"
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	# 响应方非苔丝方 -> 01b 不触发
	if gs.players.get(&"enemy").action_hand.size() != enemy_before:
		return "非苔丝方响应不应触发 01b"
	return true


## 测试9：01b ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER checker 被响应但未响应（responded=false）不触发
func test_pilot_018_e01b_not_responded_no_trigger() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	# responded=false（未响应）
	attack.record["responded"] = false
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	if gs.players.get(&"enemy").action_hand.size() != enemy_before:
		return "未响应不应触发 01b"
	return true


## 测试10：flag 继承到 fork -> fork 的 ATTACK_AT 触发 01b
func test_pilot_018_flag_inherited_to_fork_e01b_fires() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 创建第二台敌方机甲（双连第2目标，但这里测试 fork 打苔丝）
	# 实际场景：主攻击打苔丝设flag，fork也打苔丝，fork的ATTACK_AT触发01b
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "缺 action_010_反击"
	# enemy 恰好2张（走"=2直接弃全部"分支）
	_set_enemy_action_hand(battle, gs, 2)
	var enemy_before = gs.players.get(&"enemy").action_hand.size()
	if enemy_before != 2:
		return "enemy 应为2张 实=%d" % enemy_before
	# 主攻击打苔丝，设 flag（模拟01a已发动）
	var main_attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, main_attack)
	te.resume_pending_effect(main_attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(2)
	# fork：深拷贝主攻击 record（含 flag）打苔丝
	var fork = _Action.new()
	fork.action_id = &"test_p018_fork_%d" % [randi() % 1000000]
	fork.action_type = &"attack"
	fork.record = main_attack.record.duplicate(true)
	fork.record["target_id"] = setup.mech.mech_id
	fork.record["_is_fork"] = true
	fork.record.erase("responded")
	fork.record.erase("response_source")
	fork.state = &"running"
	fork.context = battle.context
	fork.source = main_attack.source
	battle.context.action_registry.register(fork)
	# fork 被真实迎击牌响应
	fork.record["responded"] = true
	fork.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, fork)
	await _pump_frames(3)
	# fork 继承 flag -> 01b 触发 -> enemy 弃2张
	var enemy_after = gs.players.get(&"enemy").action_hand.size()
	if enemy_after != 0:
		return "fork 继承 flag 应触发 01b 弃2张 实剩=%d" % enemy_after
	return true


## 测试11：01b 弃装备牌（损伤≥2）
func test_pilot_018_e01b_discard_damaged_equipment() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 清空 enemy 行动手牌（强制走装备牌分支）
	var enemy_player = gs.players.get(&"enemy")
	for cid in enemy_player.action_hand.duplicate():
		te.unregister_listeners_for_card(cid)
		enemy_player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)
	# 给 enemy 装一张损伤2的装备牌
	var dmg_eq = _equip_damage_token_equipment(gs, cdb, enemy_mech, &"躯干", "part_002_量产装_躯干", 2)
	if dmg_eq == null:
		return "缺 part_002_量产装_躯干"
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "缺 action_010_反击"
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	# 01b 触发：enemy 无行动牌 -> 自动选弃装备牌 -> 1张损伤≥2装备 -> 弹单选窗 -> resume 选该装备牌
	te.resume_pending_effect(attack.action_id, {"selected_card_id": dmg_eq.instance_id})
	await _pump_frames(3)
	# 弃置完成 -> 装备牌 zone 变 discard
	if dmg_eq.zone != &"discard":
		return "应弃置损伤≥2装备牌 实zone=%s" % String(dmg_eq.zone)
	return true


## 测试12：01b 无可弃（无行动牌+无损伤≥2装备）-> 无事发生
func test_pilot_018_e01b_no_cards_no_equipment_noop() -> Variant:
	var battle = _new_battle()
	var setup = _setup_tesi(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup.gs
	var cdb = setup.cdb
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 清空 enemy 行动手牌
	var enemy_player = gs.players.get(&"enemy")
	for cid in enemy_player.action_hand.duplicate():
		te.unregister_listeners_for_card(cid)
		enemy_player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "缺 action_010_反击"
	var attack = _make_attack(battle, enemy_mech.mech_id, setup.mech.mech_id, &"enemy")
	attack.record["_effect_flags"] = {"pilot_018_activated": {"value": true, "data": {"owner_player_id": &"player"}}}
	attack.record["responded"] = true
	attack.record["response_source"] = {"player_id": &"player", "mech_id": setup.mech.mech_id, "card_instance_id": counter_card.instance_id}
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(2)
	# 无可弃 -> 无事发生，不挂死
	return true
