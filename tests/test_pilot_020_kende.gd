## test_pilot_020_kende.gd - 肯德（pilot_020）弃牌阈值分级效果测试
##
## 4 效果（effect_01 主动按钮1 + 02/03/04 被动按钮2）：
##   effect_01（DIRECT 按钮1，我方回合1次）：弃任意张行动牌（thrust_select 多选，
##     取消/空选 -> 中止不消耗次数；选定 -> EXECUTE_DISCARD 子动作弃置 -> 手动 mark once_per_turn）。
##   effect_02（LISTEN DISCARD_SETTLE 按钮2 置灰+悬停X）：每回合开始记录 X = 我方行动牌
##     从手牌区(action_hand)进弃牌堆数量（使用牌 temp_zone 不计；回合超限/预判/肯特/肯耳忒
##     弃的牌也走 discard_card -> DISCARD_SETTLE 计入）。X≥2 时护甲+3 动力+3(上限+当前) 每回合1次。
##   effect_03（LISTEN ATTACK_BEFORE 隐藏被动）：X≥3 时攻击威力+2 所有武器范围+1。
##   effect_04（LISTEN TURN_AFTER_END 隐藏被动）：X≥4 时回合结束后抽 min(X,6) 张行动牌。
##   X 存 counters["pilot_020_x_<turn_number>"] 按回合自动重置（新回合新 key=0）。
##
## 关键覆盖点：
##   1. 4 效果定义（mode/时点/条件/动作）。
##   2. 主动弃任意张：完整流程弃2张 -> 手牌减少 + X=2 + once_per_turn 消耗。
##   3. 主动弃牌取消/选空 -> 中止不消耗次数（可再触发）。
##   4. 被动计数：discard_card 动作弃2张 -> X=2（多次弃置累加）。
##   5. 使用牌（temp_zone 弃入）不计入 X。
##   6. X≥2 -> 护甲+3 动力+3（上限+当前同步）。
##   7. X≥3 -> ATTACK_BEFORE 攻击威力+2(extra_might) 范围+1(extra_range)。
##   8. X≥4 -> 回合结束(TURN_AFTER_END) 抽 min(X,6) 张行动牌。
##   9. X 按回合重置（旧回合保留、新回合从0重新计）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90020
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


func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


## 设肯德机师到 owner 机甲，返回 {gs, mech, pilot_card, te}
func _setup_kende(battle, owner_id: StringName = &"player") -> Dictionary:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var pilot_card = _set_pilot_on_mech(battle, owner_id, mech, "pilot_020_肯德")
	if pilot_card == null:
		return {}
	return {"gs": gs, "mech": mech, "pilot_card": pilot_card, "te": battle.context.timing_engine}


## 清空玩家行动手牌（移回牌堆底）
func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 给玩家行动手牌加一张行动牌（zone=action_hand），返回实例 id
func _add_card_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 走真实 discard_card 动作强制弃置指定牌（fire DISCARD_BEFORE/AFTER/SETTLE 时点，
## 自动生成 discard_snapshots，from_zone=牌当时 zone）。card_ids 须在玩家 action_hand。
func _force_discard(battle, player_id: StringName, card_ids: Array, reason: StringName = &"test") -> void:
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"player_id": player_id,
		"executor": &"system_default",
		"reason": reason,
		"source": {"player_id": String(player_id)},
	})


## 触发肯德 DIRECT 按钮1（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_020(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_020_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_020_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 构造 attack action（带 attacker/target，fire ATTACK_BEFORE 用）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p020_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"attack_card_id": &"",
		"weapon_might": 5,
		"target_count": 1,
	}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid, "card_instance_id": &""}
	battle.context.action_registry.register(attack)
	return attack


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：4 效果定义正确
func test_p020_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	# effect_01 主动弃任意张
	var e1 = effs.get(&"pilot_020_effect_01")
	if e1 == null:
		return "缺 pilot_020_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_020_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_020_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "effect_01 once_per_turn_max 应 1"
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	if not ops1.has("IS_OWNER_MAIN_PHASE"):
		return "effect_01 应含 IS_OWNER_MAIN_PHASE"
	if not ops1.has("HAS_ACTION_CARD_IN_HAND"):
		return "effect_01 应含 HAS_ACTION_CARD_IN_HAND"
	if e1.actions.size() != 1 or String(e1.actions[0].get("type", &"")) != "PILOT_020_ACTIVE_DISCARD":
		return "effect_01 actions 应 [PILOT_020_ACTIVE_DISCARD]"
	# effect_02 弃置计数（LISTEN DISCARD_SETTLE）
	var e2 = effs.get(&"pilot_020_effect_02")
	if e2 == null:
		return "缺 pilot_020_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.DISCARD_SETTLE:
		return "effect_02 listen_timing 应 DISCARD_SETTLE"
	if e2.listen_action_type != &"discard_card":
		return "effect_02 listen_action_type 应 discard_card"
	# effect_03 攻击强化（LISTEN ATTACK_BEFORE，X≥3）
	var e3 = effs.get(&"pilot_020_effect_03")
	if e3 == null:
		return "缺 pilot_020_effect_03"
	if e3.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_03 listen_timing 应 ATTACK_BEFORE"
	var ops3: Array = []
	for c in e3.conditions:
		ops3.append(String(c.get("op", &"")))
	if not ops3.has("SELF_MECH_IS_ATTACKER"):
		return "effect_03 应含 SELF_MECH_IS_ATTACKER"
	if not ops3.has("PILOT_020_X_AT_LEAST"):
		return "effect_03 应含 PILOT_020_X_AT_LEAST"
	if int(e3.actions[0].get("params", {}).get("delta", 0)) != 2:
		return "effect_03 actions[0] delta 应 2"
	if int(e3.actions[1].get("params", {}).get("delta", 0)) != 1:
		return "effect_03 actions[1] delta 应 1"
	# effect_04 回合末抽牌（LISTEN TURN_AFTER_END，X≥4）
	var e4 = effs.get(&"pilot_020_effect_04")
	if e4 == null:
		return "缺 pilot_020_effect_04"
	if e4.listen_timing != _TimingConst.TURN_AFTER_END:
		return "effect_04 listen_timing 应 TURN_AFTER_END"
	if String(e4.actions[0].get("type", &"")) != "PILOT_020_DRAW_X":
		return "effect_04 actions 应 [PILOT_020_DRAW_X]"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：主动弃任意张——完整流程弃2张 -> 手牌减少 + X=2 + once_per_turn 消耗
func test_p020_active_discard_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var c3 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"" or c2 == &"" or c3 == &"":
		return "手牌设置失败"
	var ef = await _fire_pilot_020(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹弃牌多选窗）"
	# 选定弃2张
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": [c1, c2]})
	await _pump_frames(8)
	# 手牌：3 张 -> 剩 1 张；弃牌堆含 c1/c2
	if gs.players.get(&"player").action_hand.size() != 1:
		return "弃2张后手牌应剩1张 实=%d" % gs.players.get(&"player").action_hand.size()
	if not gs.deck_state.action_discard_pile.has(c1) or not gs.deck_state.action_discard_pile.has(c2):
		return "弃置的 c1/c2 应在弃牌堆"
	# X=2（主动弃牌计入 X）
	var turn: int = te._current_turn_number()
	var x: int = _ActionPilotEffects.get_pilot_020_x(pilot_card, turn)
	if x != 2:
		return "主动弃2张后 X 应 2 实=%d" % x
	# once_per_turn 消耗：第二次触发被跳过
	var ef2 = await _fire_pilot_020(battle, pilot_card, mech, &"player")
	if ef2 != null:
		return "once_per_turn 用满第二次不应挂起"
	return true


## 测试3：主动弃牌取消 -> 中止不消耗次数（可再触发）
func test_p020_active_discard_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"":
		return "手牌设置失败"
	var ef = await _fire_pilot_020(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	# 取消
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(4)
	if gs.players.get(&"player").action_hand.size() != 1:
		return "取消不应弃 player 牌"
	# once_per_turn 未消耗：可再触发
	var ef2 = await _fire_pilot_020(battle, pilot_card, mech, &"player")
	if ef2 == null:
		return "取消中止后应可再触发"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"cancelled": true})
	await _pump_frames(4)
	return true


## 测试4：主动弃牌选空 -> 中止不发动
func test_p020_active_discard_empty_selection_abort() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	var ef = await _fire_pilot_020(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	# 选空（视为中止）
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": []})
	await _pump_frames(4)
	if gs.players.get(&"player").action_hand.size() != 1:
		return "选空不应弃牌"
	return true


## 测试5：被动计数——discard_card 动作弃2张 -> X=2（多次弃置累加）
func test_p020_passive_discard_counts_x() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	_clear_action_hand(battle, &"player")
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"" or c2 == &"":
		return "手牌设置失败"
	# 走 discard_card 动作（模拟回合超限/预判/肯特/肯耳忒弃牌路径）
	_force_discard(battle, &"player", [c1])
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 1:
		return "弃1张后 X 应 1"
	_force_discard(battle, &"player", [c2])
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 2:
		return "再弃1张后 X 应 2"
	return true


## 测试6：使用牌（temp_zone 弃入）不计入 X
func test_p020_used_card_temp_zone_not_counted() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	_clear_action_hand(battle, &"player")
	# 模拟使用中的行动牌（zone=temp_zone，已移出手牌）
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"":
		return "手牌设置失败"
	gs.players.get(&"player").action_hand.erase(c1)
	var c = gs.get_card(c1)
	c.zone = &"temp_zone"
	# 使用牌结算后弃入弃牌堆（快照 from_zone=temp_zone）-> 不计入 X
	_force_discard(battle, &"player", [c1])
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 0:
		return "使用牌(temp_zone)弃置不应计入 X"
	return true


## 测试7：X≥2 -> 护甲+3 动力+3（上限+当前同步）
func test_p020_x2_armor_power_buff() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var armor_before: int = mech.get_armor()
	var power_before: int = mech.power
	var max_power_before: int = mech.max_power
	_clear_action_hand(battle, &"player")
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"" or c2 == &"":
		return "手牌设置失败"
	_force_discard(battle, &"player", [c1, c2])
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 2:
		return "弃2张后 X 应 2"
	if mech.get_armor() != armor_before + 3:
		return "X≥2 护甲应+3 实增=%d" % (mech.get_armor() - armor_before)
	if mech.power != power_before + 3:
		return "X≥2 动力应+3 实增=%d" % (mech.power - power_before)
	if mech.max_power != max_power_before + 3:
		return "X≥2 动力上限应+3 实增=%d" % (mech.max_power - max_power_before)
	return true


## 测试8：X≥3 -> ATTACK_BEFORE 攻击威力+2(extra_might) 范围+1(extra_range)
func test_p020_x3_attack_might_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var ids: Array = []
	for i in 3:
		var cid = _add_card_to_hand(battle, &"player", "action_001_进攻")
		if cid == &"":
			return "手牌设置失败"
		ids.append(cid)
	_force_discard(battle, &"player", ids)
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 3:
		return "弃3张后 X 应 3"
	# 肯德攻击 -> fire ATTACK_BEFORE -> effect_03 写 extra_might/extra_range
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_might", 0)) != 2:
		return "X≥3 攻击威力应+2(extra_might=2) 实=%d" % int(attack.record.get("extra_might", 0))
	if int(attack.record.get("extra_range", 0)) != 1:
		return "X≥3 范围应+1(extra_range=1) 实=%d" % int(attack.record.get("extra_range", 0))
	return true


## 测试9：X≥4 -> 回合结束(TURN_AFTER_END) 抽 min(X,6) 张行动牌
func test_p020_x4_draw_at_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	_clear_action_hand(battle, &"player")
	var ids: Array = []
	for i in 4:
		var cid = _add_card_to_hand(battle, &"player", "action_001_进攻")
		if cid == &"":
			return "手牌设置失败"
		ids.append(cid)
	_force_discard(battle, &"player", ids)
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, te._current_turn_number()) != 4:
		return "弃4张后 X 应 4"
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	# 结束回合 -> TURN_AFTER_END -> 抽 min(4,6)=4 张（手牌4张全弃光，无超限弃牌干扰）
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(6)
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after != hand_before + 4:
		return "X≥4 回合末应抽4张 手牌 %d -> %d" % [hand_before, hand_after]
	return true


## 测试10：X 按回合重置（旧回合保留、新回合从0重新计）
func test_p020_x_resets_next_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kende(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	_clear_action_hand(battle, &"player")
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"" or c2 == &"":
		return "手牌设置失败"
	_force_discard(battle, &"player", [c1, c2])
	await _pump_frames(3)
	var turn_old: int = te._current_turn_number()
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, turn_old) != 2:
		return "本回合 X 应 2"
	# 模拟下回合开始（turn_number +1，与 start_turn 顶部逻辑一致）
	gs.turn_number += 1
	_clear_action_hand(battle, &"player")
	var c3 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	_force_discard(battle, &"player", [c3])
	await _pump_frames(3)
	var turn_new: int = te._current_turn_number()
	if turn_new != turn_old + 1:
		return "turn_number 应+1"
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, turn_new) != 1:
		return "新回合 X 应从0重新计 实=%d" % _ActionPilotEffects.get_pilot_020_x(pilot_card, turn_new)
	if _ActionPilotEffects.get_pilot_020_x(pilot_card, turn_old) != 2:
		return "旧回合 X 应保留 2"
	return true
