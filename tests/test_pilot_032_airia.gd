## test_pilot_032_airia.gd - 爱瑞娅（pilot_032）效果测试
##
## 爱瑞娅 1 按钮（DIRECT 主动）：
##   effect_01（弃1张行动牌·机师行动上限+2）：我方回合1次（once_per_turn_max=1），点击按钮 ->
##   弹窗① 从我方行动手牌选1张弃置（可取消=中止不计次数）-> 弹窗② 选场上1张机师牌 ->
##   使其行动牌上限+2（复用 pilot_014 grant_pilot_014_bonus 状态烘焙，UNTIL_NEXT_OWNER_TURN 到期）。
##   选机师取消：已弃牌不返还、不计次数（status 不施加）。
##   手牌无行动牌：条件 HAS_ACTION_CARD_IN_HAND 使按钮置灰，_execute_effect 不进入弃牌。
##   场上无机师牌：_pilot_032_show_pilot_select 返回 false 兜底中止（不施加、不计次数）。
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
	battle.rng_seed = 90032
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
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


## 给指定机甲设机师牌，返回机师牌实例
func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


## 给玩家行动手牌加一张行动牌，返回实例 id
func _add_action_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 清空玩家行动手牌（可控弃牌确定性）
func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 触发爱瑞娅 effect_01（DIRECT 按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_032(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_032_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_032_effect_01",
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


## 阶段① resume：确认弃1张行动牌
func _resume_pay(battle, ef_action, card_id: StringName) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {
		"selected_action_card_ids": [card_id],
	})
	await _pump_frames(5)


## 阶段① resume：取消弃牌（中止，不计次数）
func _resume_pay_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


## 阶段② resume：确认选机师牌施加 +2
func _resume_grant(battle, ef_action, target_pilot_inst: StringName, target_pid: StringName, target_mid: StringName) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {
		"pilot_032_target_pilot": target_pilot_inst,
		"pilot_032_player_id": target_pid,
		"pilot_032_mech_id": target_mid,
	})
	await _pump_frames(5)


## 阶段② resume：取消选机师牌（已弃牌不返还、不计次数）
func _resume_grant_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


## 统计某玩家 statuses 中 pilot_014 +2 数量（grant_pilot_014_bonus 复用同一 status 类型）
func _count_p032_on_player(gs, pid: StringName) -> int:
	var p = gs.players.get(pid)
	if p == null:
		return 0
	return p.statuses.filter(func(s): return String(s.get("type", &"")) == "pilot_014_action_limit_bonus").size()


## 设爱瑞娅(player)+刻托(enemy)，player 行动手牌加 n 张进攻牌
## 返回 {aeria_card, aeria_mech, ketuo_card, ketuo_mech, gs, discard_card_id}
func _setup_aeria_vs_ketuo(battle, n_hand: int):
	var gs = battle.context.game_state
	var aeria_mech = gs.get_mech_for_player(&"player")
	var ketuo_mech = gs.get_mech_for_player(&"enemy")
	if aeria_mech == null or ketuo_mech == null:
		return {}
	var aeria_card = _set_pilot_on_mech(battle, &"player", aeria_mech, "pilot_032_爱瑞娅")
	var ketuo_card = _set_pilot_on_mech(battle, &"enemy", ketuo_mech, "pilot_010_刻托")
	if aeria_card == null or ketuo_card == null:
		return {}
	_clear_action_hand(battle, &"player")
	var discard_card_id := &""
	for i in n_hand:
		var cid = _add_action_to_hand(battle, &"player", "action_001_进攻")
		if i == 0:
			discard_card_id = cid
	battle.context.action_ui_bridge.context = battle.context
	return {"aeria_card": aeria_card, "aeria_mech": aeria_mech, "ketuo_card": ketuo_card, "ketuo_mech": ketuo_mech, "gs": gs, "discard_card_id": discard_card_id}


# ═══════════════════════════════════════════
# effect_01 定义
# ═══════════════════════════════════════════

## 测试1：effect_01 定义（MODE_DIRECT, once_per_turn_max=1, IS_OWNER_MAIN_PHASE,
## HAS_ACTION_CARD_IN_HAND, PILOT_032 动作，optional=true, discard_count=1, bonus=2）
func test_pilot_032_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_032_effect_01")
	if e == null:
		return "缺 pilot_032_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if int(e.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1 实=%d" % int(e.once_per_turn_max)
	if e.once_per_turn_key != &"pilot_032_effect_01":
		return "once_per_turn_key 错误"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE"):
		return "应含 IS_OWNER_MAIN_PHASE"
	if not ops.has("HAS_ACTION_CARD_IN_HAND"):
		return "应含 HAS_ACTION_CARD_IN_HAND（无行动牌按钮置灰）"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "PILOT_032_SELECT_TARGET_PILOT_AND_GRANT":
		return "actions 应 [PILOT_032_SELECT_TARGET_PILOT_AND_GRANT]"
	var p: Dictionary = acts[0].get("params", {})
	if not bool(p.get("optional", false)):
		return "PILOT_032 应 optional=true（取消不计次数）"
	if int(p.get("discard_count", 0)) != 1:
		return "discard_count 应 1 实=%d" % int(p.get("discard_count", 0))
	if int(p.get("bonus", 0)) != 2:
		return "bonus 应 2 实=%d" % int(p.get("bonus", 0))
	return true


# ═══════════════════════════════════════════
# 完整流程：弃牌 + 施加 +2
# ═══════════════════════════════════════════

## 测试2：完整流程（弃1张行动牌 -> 选刻托 -> 敌方 action_card_limit 1->3）
func test_pilot_032_full_grant_to_enemy() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 1)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim_before: int = enemy.action_card_limit  # 刻托=1
	var hand_before: int = gs.players.get(&"player").action_hand.size()  # 1
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应先弹弃牌窗）"
	await _resume_pay(battle, ef, s.discard_card_id)
	# 弃牌后手牌应空（牌已弃置）
	if gs.players.get(&"player").action_hand.size() != hand_before - 1:
		return "弃牌后行动手牌应剩 %d 实=%d" % [hand_before - 1, gs.players.get(&"player").action_hand.size()]
	# 阶段②选刻托
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim_before + 2:
		return "对刻托+2 应 %d->%d，实=%d" % [lim_before, lim_before + 2, enemy.action_card_limit]
	if _count_p032_on_player(gs, &"enemy") != 1:
		return "敌方应留下1个 +2 status"
	var st = enemy.statuses.filter(func(x): return String(x.get("type", &"")) == "pilot_014_action_limit_bonus")[0]
	if String(st.get("source_pilot_instance", &"")) != String(s.aeria_card.instance_id):
		return "status source_pilot_instance 应=爱瑞娅"
	if String(st.get("target_pilot_instance", &"")) != String(s.ketuo_card.instance_id):
		return "status target_pilot_instance 应=刻托"
	if String(st.get("duration_owner_id", &"")) != &"player":
		return "duration_owner_id 应=爱瑞娅拥有者(player)"
	return true


## 测试3：爱瑞娅对自己施加 +2（action_card_limit 5->7）
func test_pilot_032_grant_to_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 1)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var lim_before: int = player.action_card_limit
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_pay(battle, ef, s.discard_card_id)
	await _resume_grant(battle, ef, s.aeria_card.instance_id, &"player", s.aeria_mech.mech_id)
	if player.action_card_limit != lim_before + 2:
		return "对自己+2 应 %d->%d，实=%d" % [lim_before, lim_before + 2, player.action_card_limit]
	if _count_p032_on_player(gs, &"player") != 1:
		return "应留下1个 +2 status"
	return true


# ═══════════════════════════════════════════
# 取消语义
# ═══════════════════════════════════════════

## 测试4：阶段①弃牌取消 -> 不弃牌、不施加、不计次数（仍可再发）
func test_pilot_032_pay_cancel_no_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 1)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit
	var hand0: int = player.action_hand.size()
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef == null:
		return "未挂起（应先弹弃牌窗）"
	await _resume_pay_cancel(battle, ef)
	if player.action_hand.size() != hand0:
		return "弃牌取消后手牌应不变 实=%d" % player.action_hand.size()
	if enemy.action_card_limit != lim0:
		return "取消后 action_card_limit 应不变 实=%d" % enemy.action_card_limit
	if _count_p032_on_player(gs, &"enemy") != 0:
		return "取消后不应留 status"
	# 不计次数：仍可再次发动（弃牌窗再挂起）
	var ef2 = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef2 == null:
		return "取消后应仍可再次发动（弃牌窗挂起）"
	await _resume_pay_cancel(battle, ef2)
	return true


## 测试5：阶段②选机师取消 -> 已弃牌不返还、不施加、不计次数（仍可再发）
func test_pilot_032_select_cancel_discard_kept() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 2)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit
	var hand0: int = gs.players.get(&"player").action_hand.size()  # 2
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef == null:
		return "未挂起"
	await _resume_pay(battle, ef, s.discard_card_id)
	# 弃牌已发生
	if gs.players.get(&"player").action_hand.size() != hand0 - 1:
		return "弃牌应已发生 剩=%d" % gs.players.get(&"player").action_hand.size()
	# 阶段②取消
	await _resume_grant_cancel(battle, ef)
	if enemy.action_card_limit != lim0:
		return "选机师取消后不施加 实=%d" % enemy.action_card_limit
	if _count_p032_on_player(gs, &"enemy") != 0:
		return "选机师取消后不应留 status"
	if gs.players.get(&"player").action_hand.size() != hand0 - 1:
		return "选机师取消后已弃牌不返还（应仍剩 %d）实=%d" % [hand0 - 1, gs.players.get(&"player").action_hand.size()]
	# 不计次数：仍可再次发动（手牌还有1张）
	var ef2 = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef2 == null:
		return "选机师取消后应仍可再次发动（弃牌窗挂起）"
	return true


# ═══════════════════════════════════════════
# 条件门 / 每回合1次
# ═══════════════════════════════════════════

## 测试6：无行动牌 -> 效果不发动（HAS_ACTION_CARD_IN_HAND 条件拦截，effect_fire 不挂起）
func test_pilot_032_no_action_card_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 0)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef != null:
		return "无行动牌时 effect_fire 不应挂起（按钮应置灰）"
	if enemy.action_card_limit != lim0:
		return "无行动牌不应施加 实=%d" % enemy.action_card_limit
	return true


## 测试7：每回合1次（成功后第2次不挂起）
func test_pilot_032_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 2)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit
	# 第1次：完整成功（+2）
	var ef1 = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_pay(battle, ef1, s.discard_card_id)
	await _resume_grant(battle, ef1, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0 + 2:
		return "第1次后应 %d 实=%d" % [lim0 + 2, enemy.action_card_limit]
	# 第2次：once_per_turn_max=1 用满，_execute_effect 跳过，不挂起、不再加
	var ef2 = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef2 != null:
		return "第2次应用满不挂起（once_per_turn_max=1）"
	if enemy.action_card_limit != lim0 + 2:
		return "第2次不应再加 实=%d" % enemy.action_card_limit
	return true


## 测试8：场上无机师牌兜底 -> 弃牌后中止（不施加、不计次数，还可再发）。
## 注：爱瑞娅在场时她自身就是候选（可自选），兜底仅在弃牌窗挂起期间她离场（场上无人装
## 机师牌）时触发。构造：fire -> 弃牌窗挂起 -> unset_pilot(爱瑞娅) -> resume 弃牌 -> 阶段②候选空 -> continue。
func test_pilot_032_no_field_pilot_fallback() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var aeria_mech = gs.get_mech_for_player(&"player")
	var aeria_card = _set_pilot_on_mech(battle, &"player", aeria_mech, "pilot_032_爱瑞娅")
	if aeria_card == null:
		return "setup 爱瑞娅失败"
	_clear_action_hand(battle, &"player")
	var discard_card_id = _add_action_to_hand(battle, &"player", "action_001_进攻")
	battle.context.action_ui_bridge.context = battle.context
	var ef = await _fire_pilot_032(battle, aeria_card, aeria_mech, &"player")
	if ef == null:
		return "未挂起（应先弹弃牌窗）"
	# 弃牌窗挂起期间爱瑞娅离场 -> 场上无人装机师牌 -> 阶段②候选空 -> 兜底中止
	battle.context.game_setup_service.unset_pilot(aeria_mech.mech_id)
	await _resume_pay(battle, ef, discard_card_id)
	if battle.context.timing_engine.has_pending_effect(ef.action_id):
		return "无机师牌兜底后不应残留 pending effect"
	if gs.players.get(&"player").action_hand.size() != 0:
		return "弃牌应已发生 实剩=%d" % gs.players.get(&"player").action_hand.size()
	if _count_p032_on_player(gs, &"player") != 0 or _count_p032_on_player(gs, &"enemy") != 0:
		return "兜底中止不应留 status"
	# 不计次数：重新装回爱瑞娅 + 补行动牌后可再发（弃牌窗再挂起）
	battle.context.game_setup_service.set_pilot(aeria_mech.mech_id, aeria_card)
	_add_action_to_hand(battle, &"player", "action_001_进攻")
	var ef2 = await _fire_pilot_032(battle, aeria_card, aeria_mech, &"player")
	if ef2 == null:
		return "无机师牌兜底后应仍可再发"
	return true


# ═══════════════════════════════════════════
# 到期恢复
# ═══════════════════════════════════════════

## 测试9：到期恢复（下个爱瑞娅回合开始 _clean_until_next_owner_turn 扣回）
func test_pilot_032_expiry_next_owner_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aeria_vs_ketuo(battle, 1)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim_before: int = enemy.action_card_limit  # 刻托=1
	var ef = await _fire_pilot_032(battle, s.aeria_card, s.aeria_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_pay(battle, ef, s.discard_card_id)
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim_before + 2:
		return "施加后应 %d 实=%d" % [lim_before + 2, enemy.action_card_limit]
	# 下个爱瑞娅(player)回合开始 -> 扣回
	battle.context.turn_service._clean_until_next_owner_turn(&"player")
	if enemy.action_card_limit != lim_before:
		return "到期应扣回 %d 实=%d" % [lim_before, enemy.action_card_limit]
	if _count_p032_on_player(gs, &"enemy") != 0:
		return "到期后 status 应清空"
	return true
