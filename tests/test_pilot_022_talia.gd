## test_pilot_022_talia.gd - 塔莉娅（pilot_022，帝国 SR）效果测试
##
## 2 效果（effect_01 主动按钮1 + effect_02 被动按钮2）：
##   effect_01（DIRECT 按钮1，我方回合1次）：抽3张行动牌打"禁"标签（本回合塔莉娅无法使用），
##     循环赐予4格内其他机甲（选机甲->选牌至少1张->转移，牌给完或选机甲取消结束循环）。
##   effect_02（LISTEN 被动，按钮2 置灰）：行动牌从塔莉娅手牌转移到其他玩家手牌（效果1交牌/
##     识破/玛丽尔偷牌都计入）打"策"标签；带"策"标签的行动牌从临时区进弃牌堆（通用"使用"
##     判定，含迪恩转化代价牌）时塔莉娅抽2；标签入弃牌堆即消失。
##
## 关键覆盖点：
##   1. 2 效果定义（mode/时点/条件/动作）。
##   2. effect_01 完整循环：抽3打禁 -> 选机甲 -> 选牌给2张 -> 续选机甲 -> 选牌给完 -> 结束，
##      交出的牌打"策"标签、once_per_turn 消耗。
##   3. effect_01 取消语义：选机甲取消=结束循环（消耗次数）；选牌取消=回选机甲（不结束）。
##   4. "禁"标签：塔莉娅本回合无法使用禁牌（use_action_card 校验拒绝）；回合结束清禁恢复可用。
##   5. "策"标签：转移/偷牌打策；使用（temp_zone->弃牌堆）塔莉娅抽2；直接弃置（action_hand）
##      不抽2但清标签；标签入弃牌堆消失。
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
	battle.rng_seed = 90021
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


## 设塔莉娅机师到 owner 机甲，返回 {gs, mech, pilot_card, te, enemy_mech}
func _setup_taliyah(battle, owner_id: StringName = &"player") -> Dictionary:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var pilot_card = _set_pilot_on_mech(battle, owner_id, mech, "pilot_022_塔莉娅")
	if pilot_card == null:
		return {}
	return {
		"gs": gs,
		"mech": mech,
		"pilot_card": pilot_card,
		"te": battle.context.timing_engine,
		"enemy_mech": gs.get_mech_for_player(&"enemy"),
	}


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


## 放机甲到指定坐标
func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 走真实 discard_card 动作强制弃置指定牌（fire DISCARD_BEFORE/AFTER/SETTLE 时点）。
## card_ids 可在手牌（action_hand，直接弃置）或已置 temp_zone（模拟使用中的牌结算弃置）。
func _force_discard(battle, player_id: StringName, card_ids: Array, reason: StringName = &"test") -> void:
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"player_id": player_id,
		"executor": &"system_default",
		"reason": reason,
		"source": {"player_id": String(player_id)},
	})


## 触发塔莉娅 DIRECT 按钮1（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_022(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_022_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_022_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	# draw_3 改走 gain_card 子动作后，effect_fire 先 waiting_effect_action（等抽3子动作），
	# 子动作完成由 _continue_pilot_022_draw 续跑才挂起选机甲窗（waiting_timing）。循环等待。
	for i in range(40):
		await _pump_frames(2)
		for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
			if a.state == &"waiting_timing":
				return a
	return null


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：2 效果定义正确
func test_p021_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	# effect_01 主动抽3赐予
	var e1 = effs.get(&"pilot_022_effect_01")
	if e1 == null:
		return "缺 pilot_022_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_022_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_022_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "effect_01 once_per_turn_max 应 1"
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	if not ops1.has("IS_OWNER_MAIN_PHASE"):
		return "effect_01 应含 IS_OWNER_MAIN_PHASE"
	if e1.actions.size() != 1 or String(e1.actions[0].get("type", &"")) != "PILOT_021_LOOP_DEAL":
		return "effect_01 actions 应 [PILOT_021_LOOP_DEAL]"
	# effect_02 被动策回收（LISTEN，无 listen_timing -> 按钮置灰）
	var e2 = effs.get(&"pilot_022_effect_02")
	if e2 == null:
		return "缺 pilot_022_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if String(e2.listen_timing) != "":
		return "effect_02 listen_timing 应为空（无直接时点，随转移/弃牌挂钩）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：effect_01 完整循环——抽3打禁 -> 选机甲 -> 选牌给2张 -> 续选机甲 -> 选牌给完 -> 结束
func test_p021_effect1_full_loop_give_all() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	# 敌方机甲挪到4格内（player(2,2) -> enemy(4,2) 距离2）
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	var ef = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹选机甲窗）"
	# 已抽3张行动牌，全部打"禁"标签
	var hand: Array = gs.players.get(&"player").action_hand.duplicate()
	if hand.size() != 3:
		return "效果1应抽3张 实=%d" % hand.size()
	for cid in hand:
		if not _ActionPilotEffects.pilot_022_card_has_any_jin(gs.get_card(cid)):
			return "抽的牌应打禁标签 card=%s" % String(cid)

	# 选机甲 -> 选牌（挂起）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_cards":
		return "选中机甲后应挂起选牌阶段"

	# 选牌给2张 -> 转移 -> 续选机甲（挂起）
	te.resume_pending_effect(ef.action_id, {"selected_action_card_ids": [hand[0], hand[1]]})
	await _pump_frames(5)
	if gs.players.get(&"enemy").action_hand.size() != 2:
		return "给2张后敌方手牌应2张 实=%d" % gs.players.get(&"enemy").action_hand.size()
	for cid in [hand[0], hand[1]]:
		if not _ActionPilotEffects.pilot_022_card_has_any_ce(gs.get_card(cid)):
			return "交出的牌应打策标签 card=%s" % String(cid)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_mech":
		return "给2张后应续选机甲"

	# 再选机甲 -> 选牌（仅剩1张）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_cards":
		return "第二次选中机甲后应挂起选牌"

	# 选最后1张给完 -> 结束循环（once_per_turn 消耗）
	te.resume_pending_effect(ef.action_id, {"selected_action_card_ids": [hand[2]]})
	await _pump_frames(8)
	if gs.players.get(&"enemy").action_hand.size() != 3:
		return "给完后敌方手牌应3张 实=%d" % gs.players.get(&"enemy").action_hand.size()
	if not _ActionPilotEffects.pilot_022_card_has_any_ce(gs.get_card(hand[2])):
		return "第3张交出的牌应打策标签"
	if not gs.players.get(&"player").action_hand.is_empty():
		return "牌应全部给出，塔莉娅手牌应为空 实=%d" % gs.players.get(&"player").action_hand.size()

	# once_per_turn 消耗：第二次触发不挂起
	var ef2 = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef2 != null:
		return "once_per_turn 用满第二次不应挂起"
	return true


## 测试3a：effect_01 选机甲取消 = 结束循环（已抽3张保留禁标签，消耗次数）
func test_p021_effect1_cancel_mech_select_ends() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	var ef = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	if gs.players.get(&"player").action_hand.size() != 3:
		return "取消后手牌应保留抽的3张 实=%d" % gs.players.get(&"player").action_hand.size()
	# 抽的牌仍有禁标签（未交出）
	for cid in gs.players.get(&"player").action_hand:
		if not _ActionPilotEffects.pilot_022_card_has_any_jin(gs.get_card(cid)):
			return "取消后抽的牌应保留禁标签"
	# 选机甲取消应消耗 once_per_turn：第二次触发不挂起
	var ef2 = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef2 != null:
		return "选机甲取消应消耗 once_per_turn"
	return true


## 测试3b：effect_01 选牌取消 = 回选机甲（不结束循环、不消耗），可继续循环赐予
func test_p021_effect1_cancel_card_select_rechoose() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	var ef = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_mech":
		return "选牌取消应回选机甲（phase=choose_mech）实=%s" % String(te._pending_effect.get(ef.action_id, {}).get("phase", &""))
	# 回选机甲后再次选中 -> 选牌挂起（循环未结束）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_cards":
		return "回选机甲后再选中应挂起选牌"
	# 选1张给出，剩余2张继续循环 -> 最后选机甲取消结束
	var hand: Array = gs.players.get(&"player").action_hand.duplicate()
	if hand.size() != 3:
		return "此时塔莉娅手牌应3张 实=%d" % hand.size()
	te.resume_pending_effect(ef.action_id, {"selected_action_card_ids": [hand[0]]})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"pilot_022_choose_mech":
		return "给1张后应续选机甲"
	if not _ActionPilotEffects.pilot_022_card_has_any_ce(gs.get_card(hand[0])):
		return "给出的牌应打策标签"
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	return true


## 测试4："禁"标签——塔莉娅本回合无法使用禁牌；回合结束清禁恢复可用
func test_p021_jin_block_and_endturn_clear() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = s.te
	var pilot_card = s.pilot_card
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")

	var ef = await _fire_pilot_022(battle, pilot_card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	var hand: Array = gs.players.get(&"player").action_hand.duplicate()
	if hand.size() != 3:
		return "手牌应3张 实=%d" % hand.size()

	# 使用禁牌应被拒（use_action_card validate -> cancelled，牌不离开手牌）
	var use_res: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": hand[0],
		"player_id": &"player",
		"mech_id": mech.mech_id,
		"source": {"player_id": &"player", "mech_id": mech.mech_id},
	})
	if use_res.get("state", &"") == &"completed":
		return "禁标签牌不应可用"
	if not gs.players.get(&"player").action_hand.has(hand[0]):
		return "禁牌使用被拒后应仍留手牌"
	if not _ActionPilotEffects.pilot_022_has_jin(gs.get_card(hand[0]), &"player"):
		return "禁牌使用被拒后禁标签应保留"

	# 回合结束 -> 清禁标签（剩余牌恢复可用）
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(6)
	for cid in gs.players.get(&"player").action_hand:
		if _ActionPilotEffects.pilot_022_card_has_any_jin(gs.get_card(cid)):
			return "回合结束后禁标签应清除"
	return true


## 测试5："策"标签——使用（temp_zone->弃牌堆）塔莉娅抽2；直接弃置（action_hand）不抽2但清标签
func test_p021_ce_draw_on_use_not_direct_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	# ── 直接弃置（手牌 action_hand）：不抽2，仅清策标签 ──
	var c1 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	if c1 == &"":
		return "c1 手牌设置失败"
	# 模拟塔莉娅转移打策标签（owner=塔莉娅玩家）
	var c1_card = gs.get_card(c1)
	_ActionPilotEffects.pilot_022_on_card_left_taliyah_hand(c1_card, &"player")
	if not _ActionPilotEffects.pilot_022_card_has_any_ce(c1_card):
		return "c1 应带策标签"
	_force_discard(battle, &"enemy", [c1])
	await _pump_frames(5)
	if not gs.players.get(&"player").action_hand.is_empty():
		return "直接弃置不应触发塔莉娅抽牌 实=%d" % gs.players.get(&"player").action_hand.size()
	if _ActionPilotEffects.pilot_022_card_has_any_ce(c1_card):
		return "直接弃置入弃牌堆后策标签应消失"

	# ── 使用（temp_zone -> 弃牌堆）：塔莉娅抽2 ──
	var c2 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	if c2 == &"":
		return "c2 手牌设置失败"
	var c2_card = gs.get_card(c2)
	_ActionPilotEffects.pilot_022_on_card_left_taliyah_hand(c2_card, &"player")
	# 模拟使用中：牌移出敌方手牌、置 temp_zone
	gs.players.get(&"enemy").action_hand.erase(c2)
	c2_card.zone = &"temp_zone"
	_force_discard(battle, &"enemy", [c2], &"ACTION_CARD_PLAYED")
	await _pump_frames(5)
	if gs.players.get(&"player").action_hand.size() != 2:
		return "使用策牌后塔莉娅应抽2张 实=%d" % gs.players.get(&"player").action_hand.size()
	if _ActionPilotEffects.pilot_022_card_has_any_ce(c2_card):
		return "使用入弃牌堆后策标签应消失"
	return true


## 测试6：转移/偷牌打"策"标签——行动牌从塔莉娅手牌转出（效果1交牌/识破/玛丽尔偷牌都计入）
func test_p021_transfer_and_steal_apply_ce() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taliyah(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	# ── 转移（效果1交牌路径走 transfer_action_cards）──
	var c1 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"":
		return "c1 手牌设置失败"
	battle.context.game_actions.transfer_action_cards({
		"from_player_id": &"player",
		"to_player_id": &"enemy",
		"card_ids": [c1],
	})
	await _pump_frames(3)
	if not gs.players.get(&"enemy").action_hand.has(c1):
		return "转移后敌方手牌应含 c1"
	if not _ActionPilotEffects.pilot_022_card_has_any_ce(gs.get_card(c1)):
		return "转移交牌应打策标签"

	# ── 偷牌（识破/玛丽尔路径走 steal_action_card）──
	var c2 = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if c2 == &"":
		return "c2 手牌设置失败"
	battle.context.game_actions.steal_action_card({
		"from_player_id": &"player",
		"to_player_id": &"enemy",
		"count": 1,
	})
	await _pump_frames(3)
	if not gs.players.get(&"enemy").action_hand.has(c2):
		return "偷牌后敌方手牌应含 c2"
	if not _ActionPilotEffects.pilot_022_card_has_any_ce(gs.get_card(c2)):
		return "偷牌也应打策标签"
	return true
