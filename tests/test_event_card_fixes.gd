## test_event_card_fixes.gd - 事件牌系统5问题修复验证（2026-08-24 PVP3实机反馈）
##
## 问题1: 任务奖励改为主动按钮--can_trigger 三重门控（我方主阶段/进度达标/未领取）
##         + 领取确认分支写 var_task_claimed + 取消不消耗 + 领取后留槽继续计时
## 问题2: 拾荒（e005）监听 TURN_BEFORE_END，弹窗挂起阻塞弃置超限牌（弃牌在窗口结算之后）
## 问题3: 陷落机甲=障碍--攻击BFS blocked（打后面的须绕路，障碍格本身可作终点）
##         + cannot_be_targeted（预设目标攻击直接取消）+ cannot_move（主动/被动移动全拦截）
## 问题4: 效果只对设置者生效--拾荒在敌方回合结束触发时弹的是牌主（binding_context.player_id）的手牌
## 问题5: DRAW_EQUIPMENT 伪动作在 _seq 续跑链被拦截（拾荒确认后抽装备链不再报未注册动作类型）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


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
	battle.rng_seed = 91003
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_event_static()
	# ActionUIBridge 挂 context（部分链路 resume 依赖桥接上下文）
	if battle.context.action_ui_bridge != null:
		battle.context.action_ui_bridge.context = battle.context
	return battle


## 清空事件派生 registry 静态状态（跨测试泄漏防护，同 test_event_cards 模式）
func _clear_event_static() -> void:
	for mid in _GenEventEffects._derived_registry.keys():
		_GenEventEffects.unregister_derived_bonuses(mid)


## 从事件牌堆移除并领取指定 def 的实例
func _take_event_instance(gs, card_def_id: StringName) -> StringName:
	for cid: StringName in gs.deck_state.event_deck:
		var card = gs.cards.get(cid)
		if card != null and card.def != null and card.def.card_id == card_def_id:
			gs.deck_state.event_deck.erase(cid)
			return cid
	return &""


## 执行 set_event_card（指定实例）并 pump 帧等挂起链完成
func _do_set_event(battle, mech, card_instance_id: StringName, pump: int = 4) -> Dictionary:
	if battle.context.game_state.active_player_id == &"":
		battle.context.game_state.active_player_id = mech.owner_player_id
	var result: Dictionary = battle.context.action_service.execute(&"set_event_card", {
		"mech_id": mech.mech_id,
		"event_card_id": card_instance_id,
		"source": {"mech_id": mech.mech_id},
	})
	await _pump_frames(pump)
	if typeof(result) != TYPE_DICTIONARY:
		return {"state": &"error", "message": "execute 返回异常"}
	return result


## 清空全图特殊地形（避免绿/红格干扰射程/移动断言）
func _clear_terrain(gs) -> void:
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"


## 清空某玩家手牌（注销监听器防残留）
func _clear_hand(battle, player_id: StringName) -> void:
	var gs = battle.context.game_state
	for cid: StringName in gs.players.get(player_id).action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(player_id).action_hand.clear()


## 补行动手牌到 count 张（从行动牌堆顶抽，不动监听器）
func _top_up_hand(gs, player_id: StringName, count: int) -> void:
	var player = gs.players.get(player_id)
	while player.action_hand.size() < count and not gs.deck_state.action_deck.is_empty():
		var cid: StringName = gs.deck_state.action_deck.pop_back()
		var c = gs.cards.get(cid)
		if c != null:
			c.zone = &"action_hand"
		player.action_hand.append(cid)


# ═══════════════════════════════════════════
# 问题1：任务奖励主动按钮
# ═══════════════════════════════════════════


## 门控三重条件：进度达标 + 未领取 + 我方主阶段（缺一置灰）
func test_task_reward_button_gating() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_016")  # 任务·歼灭：e018计数 + e024奖励 阈值1
	if cid == &"":
		return "未找到 event_016 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	var eff = _GenEventEffects.get_effect_by_id(&"event_effect_024")
	if eff == null:
		return "event_effect_024 效果未定义"
	var bind: Dictionary = {"card_instance_id": cid, "mech_id": mech.mech_id,
		"player_id": &"player", "slot_id": &"event", "card_def_id": &"event_016"}
	gs.phase = &"MAIN"
	# ① 进度0：不可点
	gs.active_player_id = &"player"
	if ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "进度0时按钮不应可点"
	# ② 进度达标：可点
	card.counters["var_task_progress"] = 1
	if not ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "进度达标后按钮应可点"
	# ③ 已领取：置灰
	card.counters["var_task_claimed"] = 1
	if ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "已领取后按钮应置灰"
	# ④ 敌方回合：置灰（只能在自己回合点）
	card.counters["var_task_claimed"] = 0
	gs.active_player_id = &"enemy"
	if ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "敌方回合按钮不应可点"
	return true


## 领取流程：effect_fire -> 选择窗确认 -> 抽4行动 + 写领取标记 + 留槽继续计时
func test_task_reward_claim_flow() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var cid := _take_event_instance(gs, &"event_016")
	if cid == &"":
		return "未找到 event_016 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	card.counters["var_task_progress"] = 1
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	var hand_before: int = player.action_hand.size()

	# 发动（UI 按钮路径 -> effect_fire）
	ctx.action_service.execute(&"effect_fire", {
		"effect_id": &"event_effect_024",
		"player_id": &"player",
		"card_instance_id": cid,
		"source": {"card_instance_id": cid, "mech_id": mech.mech_id, "player_id": &"player", "effect_id": &"event_effect_024"},
	})
	await _pump_frames(3)
	# 应弹选择窗（optional 二选一）
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"choose_one_effect":
		return "领取应弹选择窗，实际: %s" % String(wait.get("input_type", &""))
	# 确认选项0（抽4张行动牌）
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"chosen_option_index": 0})
	await _pump_frames(6)

	# 抽4 + 领取标记 + 留槽（计时/进度不变，牌仍在槽）
	if player.action_hand.size() != hand_before + 4:
		return "领取应抽4张行动牌（前%d 后%d）" % [hand_before, player.action_hand.size()]
	if int(card.counters.get("var_task_claimed", 0)) != 1:
		return "确认领取后应写 var_task_claimed=1"
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != cid:
		return "领取后事件牌应留槽继续计时"
	if int(card.timer) != 3 or int(card.counters.get("var_task_progress", 0)) != 1:
		return "领取不应清进度/计时（timer=%d progress=%d）" % [int(card.timer), int(card.counters.get("var_task_progress", 0))]
	# 按钮永久置灰
	var eff = _GenEventEffects.get_effect_by_id(&"event_effect_024")
	var bind: Dictionary = {"card_instance_id": cid, "mech_id": mech.mech_id,
		"player_id": &"player", "slot_id": &"event"}
	if ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "领取后按钮应永久置灰"
	return true


## 取消不消耗：选择窗取消后标记不写、按钮仍可点
func test_task_reward_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var cid := _take_event_instance(gs, &"event_016")
	if cid == &"":
		return "未找到 event_016 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	card.counters["var_task_progress"] = 1
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	var hand_before: int = player.action_hand.size()

	ctx.action_service.execute(&"effect_fire", {
		"effect_id": &"event_effect_024",
		"player_id": &"player",
		"card_instance_id": cid,
		"source": {"card_instance_id": cid, "mech_id": mech.mech_id, "player_id": &"player", "effect_id": &"event_effect_024"},
	})
	await _pump_frames(3)
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"choose_one_effect":
		return "领取应弹选择窗，实际: %s" % String(wait.get("input_type", &""))
	# 取消（不领取）
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"cancelled": true})
	await _pump_frames(5)

	if int(card.counters.get("var_task_claimed", 0)) != 0:
		return "取消不应写领取标记"
	if player.action_hand.size() != hand_before:
		return "取消不应抽牌（前%d 后%d）" % [hand_before, player.action_hand.size()]
	var eff = _GenEventEffects.get_effect_by_id(&"event_effect_024")
	var bind: Dictionary = {"card_instance_id": cid, "mech_id": mech.mech_id,
		"player_id": &"player", "slot_id": &"event"}
	if not ctx.timing_engine.can_trigger_active_effect(eff, bind):
		return "取消后按钮应仍可点（不消耗领取次数）"
	return true


## 任务计数真实链路：任务·机动（e017）监听 BASIC_MOVE_AFTER，每移动1格累积1点
func test_task_move_counter_accumulates() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_015")  # 任务·机动：e017计数 阈值10
	if cid == &"":
		return "未找到 event_015 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	_clear_terrain(gs)
	_clear_hand(battle, &"player")
	var power_before: int = mech.power

	# 真实移动2格（single_move 逐格 basic_move 各发 BASIC_MOVE_AFTER）
	var mv: Dictionary = battle.move_unit("player", {"q": 2, "r": 0})
	if not bool(mv.get("ok", false)):
		return "移动发起失败: %s" % String(mv.get("message", ""))
	await _pump_frames(20)

	if int(card.counters.get("var_task_progress", 0)) != 2:
		return "移动2格应累积2点进度（实际%d）" % int(card.counters.get("var_task_progress", 0))
	if mech.power != power_before - 2:
		return "移动2格应扣2动力（前%d 后%d）" % [power_before, mech.power]
	return true


# ═══════════════════════════════════════════
# 问题2：拾荒先于弃置超限牌
# ═══════════════════════════════════════════


## 回合结束：拾荒窗挂起期间手牌未弃（弃超限牌在窗口结算之后）；取消窗口后弃牌补跑
func test_scavenge_window_blocks_discard() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 event_005 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	_clear_terrain(gs)
	_clear_hand(battle, &"enemy")
	# 手牌7张（上限5，超限2）
	_top_up_hand(gs, &"player", 7)
	gs.active_player_id = &"player"

	var end_result: Dictionary = ctx.turn_service.end_turn(&"player")
	await _pump_frames(5)
	# 拾荒窗应挂起（有行动牌可弃），流程 suspended
	if not bool(end_result.get("suspended", false)):
		return "拾荒窗应挂起回合结束流程（suspended=%s）" % str(end_result.get("suspended", false))
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹拾荒弃牌窗 select_thrust_cards，实际: %s" % String(wait.get("input_type", &""))
	# 关键断言：窗口期间手牌仍未弃（拾荒先于弃置超限牌）
	if player.action_hand.size() != 7:
		return "拾荒窗期间不应弃超限牌（手牌%d 应7）" % player.action_hand.size()

	# 取消拾荒 -> 流程续跑 -> 第5步弹弃超限【阻塞窗】（手牌仍7）
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"cancelled": true})
	await _pump_frames(8)
	var dw: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(dw.get("input_type", &"")) != &"select_discard_cards":
		return "取消拾荒后应弹弃超限阻塞窗，实际: %s" % String(dw.get("input_type", &""))
	if player.action_hand.size() != 7:
		return "弃超限窗期间手牌应一张不少（实%d）" % player.action_hand.size()
	# 选牌续跑 -> 恰弃所选2张
	ctx.turn_service.resume_end_turn_discard(dw.get("action_id", &""), [player.action_hand[5], player.action_hand[6]])
	await _pump_frames(5)
	if player.action_hand.size() != 5:
		return "选牌续跑后应弃置2张超限牌（手牌%d 应5）" % player.action_hand.size()
	return true


## app 路径（end_player_turn 同 _finish_player_turn 调用形态，无预选参数）：
## 正常顺序执行：拾荒窗先弹（阻塞）-> 取消 -> 第5步弹弃超限阻塞窗（手牌一张不少）
## -> 选牌续跑恰弃所选2张
func test_scavenge_then_discard_blocking_windows_app_path() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 event_005 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	_clear_terrain(gs)
	_clear_hand(battle, &"enemy")
	_top_up_hand(gs, &"player", 7)
	gs.active_player_id = &"player"
	var end_result: Dictionary = battle.end_player_turn()
	await _pump_frames(5)
	if not bool(end_result.get("suspended", false)):
		return "拾荒窗应挂起回合结束流程（suspended=%s）" % str(end_result.get("suspended", false))
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应先弹拾荒弃牌窗，实际: %s" % String(wait.get("input_type", &""))
	if player.action_hand.size() != 7:
		return "拾荒窗期间手牌应一张不少（实%d）" % player.action_hand.size()
	# 取消拾荒 -> 续跑 -> 第5步弹弃超限阻塞窗
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"cancelled": true})
	await _pump_frames(8)
	var dw: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(dw.get("input_type", &"")) != &"select_discard_cards":
		return "取消拾荒后应弹弃超限阻塞窗，实际: %s" % String(dw.get("input_type", &""))
	if player.action_hand.size() != 7:
		return "弃超限窗期间手牌应一张不少（实%d）" % player.action_hand.size()
	# 选末2张 -> 续跑 -> 恰弃所选
	var pick_a: StringName = player.action_hand[5]
	var pick_b: StringName = player.action_hand[6]
	ctx.turn_service.resume_end_turn_discard(dw.get("action_id", &""), [pick_a, pick_b])
	await _pump_frames(5)
	if player.action_hand.size() != 5:
		return "选牌续跑后应弃置2张超限牌（手牌%d 应5）" % player.action_hand.size()
	if player.action_hand.has(pick_a) or player.action_hand.has(pick_b):
		return "应恰弃所选2张（所选牌仍在手）"
	return true


# ═══════════════════════════════════════════
# 问题3：陷落=障碍 + 不能被指定 + 不能移动
# ═══════════════════════════════════════════


## 攻击BFS障碍：**陷落机甲**格不可穿过（打后面的须绕路），但障碍格本身可作终点；
## 普通机甲不阻挡攻击路径（规则书默认，可被指向/命中）
## odd-q 偏移坐标几何：(5,0)->(11,0) 的6步最短路径唯一，必经 (8,1)--
## 障碍放在 (8,1) 才能构成"挡在唯一最短路径上"（放 (8,0) 会被 BFS 正确绕过）
func test_attack_bfs_obstacle() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 8, "r": 1}
	_clear_terrain(gs)

	# ① 普通机甲不阻挡：blocked 不含敌方机甲格
	var blocked_normal: Dictionary = battle.context.map_service.get_attack_blocked_keys(player_mech.mech_id)
	if blocked_normal.has("8,1"):
		return "普通机甲不应作为攻击障碍（规则书默认不阻挡）"
	# ② 陷落机甲（cannot_be_targeted）：所在格作为障碍
	enemy_mech.add_status({"type": &"cannot_be_targeted"})
	var blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(player_mech.mech_id)
	if not blocked.has("8,1"):
		return "blocked 应含陷落机甲格 8,1（实际 %s）" % str(blocked.keys())
	if blocked.has("5,0"):
		return "blocked 不应含攻击方自身格"

	var cells: Dictionary = gs.map_state.cells
	# 障碍后方 (11,0)：距离6，唯一最短路径必经 (8,1)。无障碍 range6 可达；有障碍须绕路7+步
	if not _RangeCalculator.is_in_weapon_range(player_mech.position, {"q": 11, "r": 0}, 6, cells, {}, blocked_normal):
		return "普通机甲在场时 (11,0) 直线可达（普通机甲不阻挡）"
	if _RangeCalculator.is_in_weapon_range(player_mech.position, {"q": 11, "r": 0}, 6, cells, {}, blocked):
		return "陷落障碍后方 (11,0) 不应直达（唯一最短路径被挡，须绕路）"
	# 绕远后可达：range 8 > 绕路7步
	if not _RangeCalculator.is_in_weapon_range(player_mech.position, {"q": 11, "r": 0}, 8, cells, {}, blocked):
		return "绕路射程（8）应可达障碍后方"
	# 障碍格本身：可作终点（机甲格可被指向）
	if not _RangeCalculator.is_in_weapon_range(player_mech.position, {"q": 8, "r": 1}, 3, cells, {}, blocked):
		return "障碍格 (8,1) 本身应可作攻击终点"
	# 侧翼不受影响：(6,1) 与攻击方相邻
	if not _RangeCalculator.is_in_weapon_range(player_mech.position, {"q": 6, "r": 1}, 1, cells, {}, blocked):
		return "侧翼 (6,1) 应可达"
	return true


## 陷落机甲不能被指定目标：预设目标攻击直接取消，不掉血
func test_sinkhole_cannot_be_targeted() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_clear_terrain(gs)
	_clear_hand(battle, &"enemy")
	enemy_mech.position = {"q": 3, "r": 2}  # 相邻
	# 敌方机甲设置陷落（e006 施加 cannot_be_targeted 等）
	var cid := _take_event_instance(gs, &"event_006")
	if cid == &"":
		return "未找到 event_006 实例（数据缺失）"
	await _do_set_event(battle, enemy_mech, cid)
	if not enemy_mech.has_status(&"cannot_be_targeted"):
		return "陷落应施加 cannot_be_targeted"

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var hp_before: int = enemy_mech.current_hp
	var result: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": player_mech.mech_id,
		"target_id": enemy_mech.mech_id,
		"weapon_id": weapon_ids[0],
		"attack_card_id": &"",
		"player_id": &"player",
	})
	await _pump_frames(5)
	var st := String(result.get("state", &""))
	if st != &"cancelled":
		return "预设目标为陷落机甲的攻击应取消（state=%s）" % st
	if enemy_mech.current_hp != hp_before:
		return "攻击取消后敌方不应掉血（前%d 后%d）" % [hp_before, enemy_mech.current_hp]
	return true


## 陷落机甲不能移动：move_unit 拒绝 + single_move 动作取消（疾行等被动同链路）
func test_sinkhole_cannot_move() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	_clear_terrain(gs)
	var cid := _take_event_instance(gs, &"event_006")
	if cid == &"":
		return "未找到 event_006 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	if not mech.has_status(&"cannot_move"):
		return "陷落应施加 cannot_move"
	var pos_before: Dictionary = mech.position.duplicate()
	var power_before: int = mech.power

	# ① 主动移动入口：直接拒绝
	var mv: Dictionary = battle.move_unit("player", {"q": 3, "r": 2})
	if bool(mv.get("ok", false)):
		return "陷落机甲 move_unit 应被拒绝"
	# ② single_move 动作（疾行/回避等被动移动同型）：取消
	var sm: Dictionary = ctx.action_service.execute(&"single_move", {
		"mech_id": mech.mech_id,
		"target_cell": "3,2",
		"player_id": &"player",
		"available_power": mech.power,
	})
	await _pump_frames(4)
	if String(sm.get("state", &"")) != &"cancelled":
		return "陷落机甲 single_move 应取消（state=%s）" % String(sm.get("state", &""))
	# ③ 位置/动力不变
	if HexGrid_keys_equal(mech.position, pos_before) == false or mech.power != power_before:
		return "陷落机甲位置/动力不应变化"
	return true


func HexGrid_keys_equal(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("q", -999)) == int(b.get("q", -998)) and int(a.get("r", -999)) == int(b.get("r", -998))


# ═══════════════════════════════════════════
# 问题4：效果只对设置者生效（弹窗主体=牌主）
# ═══════════════════════════════════════════


## 拾荒在敌方回合结束触发：弹窗候选是牌主（玩家）的手牌，不是回合玩家（敌方）的
func test_scavenge_window_shows_owner_hand() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 event_005 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	_clear_terrain(gs)
	# 玩家手牌2张 / 敌方手牌4张
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	_top_up_hand(gs, &"player", 2)
	_top_up_hand(gs, &"enemy", 4)
	# 敌方回合结束（拾荒 every_turn_end 任意回合结束都触发）
	gs.active_player_id = &"enemy"

	ctx.turn_service.end_turn(&"enemy")
	await _pump_frames(5)
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "敌方回合结束拾荒应弹窗，实际: %s" % String(wait.get("input_type", &""))
	# 候选牌应来自玩家（牌主 binding_context.player_id），不是敌方（回合玩家）
	var shown_ids: Array = wait.get("input_params", {}).get("card_ids", [])
	if shown_ids.size() != 2:
		return "弹窗应显示牌主（玩家）的2张手牌，实际%d张" % shown_ids.size()
	var player_hand: Array = gs.players.get(&"player").action_hand.duplicate()
	for shown: StringName in shown_ids:
		if not player_hand.has(shown):
			return "弹窗候选含非玩家手牌 %s（应只显示牌主手牌）" % String(shown)
	# 弹窗路由主体也应是玩家
	var shown_owner: StringName = StringName(String(wait.get("input_params", {}).get("player_id", &"")))
	if shown_owner != &"player":
		return "弹窗 player_id 应为牌主 player（实际 %s）" % String(shown_owner)
	# 清理挂起
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"cancelled": true})
	await _pump_frames(5)
	return true


# ═══════════════════════════════════════════
# 问题5：拾荒抽装备链（DRAW_EQUIPMENT 伪动作 _seq 拦截）
# ═══════════════════════════════════════════


## 拾荒确认弃1张后：EXECUTE_DISCARD -> DRAW_EQUIPMENT_AND_IMMEDIATELY_SET 链不再报
## 「未注册的动作类型」，弹"立即设置"窗（或牌堆空跳过），不残留报错动作
func test_scavenge_draw_equipment_chain() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 event_005 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	_clear_terrain(gs)
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	_top_up_hand(gs, &"player", 1)
	gs.active_player_id = &"player"
	var discard_cid: StringName = player.action_hand[0] if not player.action_hand.is_empty() else &""
	if discard_cid == &"":
		return "补手牌失败"

	ctx.turn_service.end_turn(&"player")
	await _pump_frames(5)
	var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹拾荒弃牌窗，实际: %s" % String(wait.get("input_type", &""))
	# 确认弃置那1张 -> EXECUTE_DISCARD -> DRAW_EQUIPMENT_AND_IMMEDIATELY_SET
	# （输入键 selected_card_ids 对齐真实 UI 路径 ThrustSelectPanel confirm ->
	#  resume_effect；旧 card_ids 键走"空选回退系统默认弃手牌[0]"巧合，非真实链路）
	ctx.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"selected_card_ids": [discard_cid]})
	await _pump_frames(8)

	# 弃牌已执行
	if player.action_hand.has(discard_cid):
		return "确认后应弃置所选行动牌"
	# 装备牌堆非空时应弹"立即设置"窗（伪动作被 _seq 拦截而非 execute_sub_action 报错）
	var deck_size: int = gs.deck_state.equipment_deck.size()
	if deck_size > 0:
		var wait2: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
		if String(wait2.get("input_type", &"")) != &"immediate_set_equipment":
			return "拾荒抽装备应弹立即设置窗，实际: %s" % String(wait2.get("input_type", &""))
		# 取消=不设置则弃置
		ctx.timing_engine.resume_pending_effect(wait2.get("action_id", &""), {"cancelled": true})
		await _pump_frames(6)
		var drawn_id: StringName = StringName(String(wait2.get("input_params", {}).get("drawn_card_id", &"")))
		if drawn_id != &"" and player.equipment_hand.has(drawn_id):
			return "取消设置后抽到的装备牌应弃置"
	# end_turn 流程应已续跑完成（不残留 cancelled/error 动作阻塞）
	var hand_final: int = player.action_hand.size()
	if hand_final != 0:
		return "回合结束流程应完成弃牌清理（手牌%d 应0）" % hand_final
	return true


# ═══════════════════════════════════════════
# 多玩家并行分发（2026-08-24 复数玩家拾荒/宝藏/修悟）
# ═══════════════════════════════════════════


## 给指定玩家机甲设事件牌并 pump（set_event_card 走 action_service）
func _set_event_on_mech(battle, mech, card_def_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cid := _take_event_instance(gs, card_def_id)
	if cid == &"":
		return &""
	await _do_set_event(battle, mech, cid)
	return cid


## 并行窗口通用驱动：循环处理槽内窗口直到无等待（拾荒/宝藏/修悟/弃超限混合场景）。
## 并行分发下不同玩家的窗口在槽/队列间交替（A 的中间窗弹出时 B 的窗可能已 refire
## 占槽），驱动不假设固定顺序，按槽内窗口类型分派：
## select_thrust_cards 按窗口牌主选其手牌第1张；immediate_set_equipment 取消（不设置则弃置）；
## choose_one_effect 选选项0；select_discard_cards 走 resume_end_turn_discard 选前 count 张。
func _drive_all_windows(battle, max_rounds: int = 24) -> int:
	var ctx = battle.context
	var handled: int = 0
	var idle_rounds: int = 0
	for i in max_rounds:
		var wait: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
		if wait.is_empty():
			idle_rounds += 1
			await _pump_frames(2)
			if idle_rounds >= 2:
				break
			continue
		idle_rounds = 0
		var it: StringName = StringName(String(wait.get("input_type", &"")))
		var aid: StringName = StringName(String(wait.get("action_id", &"")))
		if it == &"select_thrust_cards":
			var pid: StringName = StringName(String(wait.get("input_params", {}).get("player_id", &"")))
			var hand: Array = ctx.game_state.players.get(pid).action_hand
			if hand.is_empty():
				ctx.timing_engine.resume_pending_effect(aid, {"cancelled": true})
			else:
				ctx.timing_engine.resume_pending_effect(aid, {"selected_card_ids": [hand[0]]})
		elif it == &"immediate_set_equipment":
			ctx.timing_engine.resume_pending_effect(aid, {"cancelled": true})
		elif it == &"choose_one_effect":
			ctx.timing_engine.resume_pending_effect(aid, {"chosen_option_index": 0})
		elif it == &"select_discard_cards":
			var dp: Dictionary = wait.get("input_params", {})
			var dpid: StringName = StringName(String(dp.get("discard_player_id", dp.get("player_id", &""))))
			var dhand: Array = ctx.game_state.players.get(dpid).action_hand
			var cnt: int = int(dp.get("count", 1))
			var picks: Array = []
			for k in range(min(cnt, dhand.size())):
				picks.append(dhand[k])
			ctx.turn_service.resume_end_turn_discard(aid, picks)
		else:
			# 未知窗口类型：取消，避免卡死
			ctx.timing_engine.resume_pending_effect(aid, {"cancelled": true})
		handled += 1
		await _pump_frames(4)
	return handled


## 两个玩家都设拾荒（e005）：双方拾荒窗并行挂起（一槽一队列），各自交互完成后
## 才续跑回合结束后续步骤（第6步清装备手牌作流程推进哨兵）；两张所选牌都弃置
func test_parallel_scavenge_two_players() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if await _set_event_on_mech(battle, player_mech, &"event_005") == &"":
		return "未找到 event_005 实例1（数据缺失）"
	if await _set_event_on_mech(battle, enemy_mech, &"event_005") == &"":
		return "未找到 event_005 实例2（数据缺失）"
	# 敌方设为人类操控（PvP 双人语义：双方窗口都挂起等交互，AI 会跳窗）
	enemy.is_human = true
	_clear_terrain(gs)
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	_top_up_hand(gs, &"player", 2)
	_top_up_hand(gs, &"enemy", 2)
	# 流程推进哨兵：给回合玩家塞1张装备手牌，第6步（全部 TURN_BEFORE_END 交互完成后）才清
	var equip_sentinel: StringName = &""
	if not gs.deck_state.equipment_deck.is_empty():
		equip_sentinel = gs.deck_state.equipment_deck.pop_back()
		var ec = gs.cards.get(equip_sentinel)
		if ec != null:
			ec.zone = &"equipment_hand"
		player.equipment_hand.append(equip_sentinel)
	gs.active_player_id = &"player"
	var player_pick: StringName = player.action_hand[0]
	var enemy_pick: StringName = enemy.action_hand[0]

	var end_result: Dictionary = ctx.turn_service.end_turn(&"player")
	await _pump_frames(5)
	if not bool(end_result.get("suspended", false)):
		return "双拾荒应挂起回合结束流程（suspended=%s）" % str(end_result.get("suspended", false))
	# 并行挂起证据：第一个窗口占槽，第二个窗口在等待队列（不同玩家可同时决策）
	var wait_a: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait_a.get("input_type", &"")) != &"select_thrust_cards":
		return "槽内应是第一个拾荒窗，实际: %s" % String(wait_a.get("input_type", &""))
	var queued: Array = ctx.action_ui_bridge.get_queued_waiting_action_ids()
	if queued.size() != 1:
		return "第二玩家拾荒窗应在等待队列（并行挂起），队列长度%d 应1" % queued.size()

	# ── 玩家A选牌弃置（其后的"立即设置"窗与B窗可能在槽/队列间交替，统一驱动）──
	ctx.timing_engine.resume_pending_effect(wait_a.get("action_id", &""), {"selected_card_ids": [player_pick]})
	await _pump_frames(6)
	if player.action_hand.has(player_pick):
		return "玩家A确认后应弃置所选行动牌"
	# A 已交互但 B 尚未：流程不得推进到第6步（装备手牌哨兵仍在）
	if equip_sentinel != &"" and not player.equipment_hand.has(equip_sentinel):
		return "玩家B拾荒窗挂起期间流程不应推进到清装备手牌（第6步）"
	# B（牌主=敌方）的拾荒窗仍在等待（槽或队列），其候选应来自敌方手牌
	var b_pending: bool = false
	var probe: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(probe.get("input_type", &"")) == &"select_thrust_cards" \
			and StringName(String(probe.get("input_params", {}).get("player_id", &""))) == &"enemy":
		b_pending = true
	if not b_pending:
		return "玩家A交互完成后，玩家B拾荒窗应仍在等待（槽内实际: %s）" % String(probe.get("input_type", &""))

	# ── 驱动剩余全部窗口（B 拾荒窗 + 双方"立即设置"窗 + 后续步骤窗口）──
	await _drive_all_windows(battle)

	# ── 全部组完成：流程推进（第6步清装备手牌哨兵），双方所选牌都已弃置 ──
	if equip_sentinel != &"" and player.equipment_hand.has(equip_sentinel):
		return "全部拾荒交互完成后应推进到清装备手牌（第6步），哨兵仍在"
	if enemy.action_hand.has(enemy_pick):
		return "玩家B确认后应弃置所选行动牌"
	return true


## 两个玩家都设宝藏（event_009，效果 event_effect_011）：双方弃牌窗并行挂起，
## 各自确认掷骰获金；两人金币都增加、所选牌都弃置、流程续跑完成
func test_parallel_treasure_two_players() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if await _set_event_on_mech(battle, player_mech, &"event_009") == &"":
		return "未找到 event_009 实例1（数据缺失）"
	if await _set_event_on_mech(battle, enemy_mech, &"event_009") == &"":
		return "未找到 event_009 实例2（数据缺失）"
	enemy.is_human = true
	_clear_terrain(gs)
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	_top_up_hand(gs, &"player", 1)
	_top_up_hand(gs, &"enemy", 1)
	gs.active_player_id = &"player"
	var gold_p_before: int = player.gold
	var gold_e_before: int = enemy.gold
	var player_pick: StringName = player.action_hand[0]
	var enemy_pick: StringName = enemy.action_hand[0]

	var end_result: Dictionary = ctx.turn_service.end_turn(&"player")
	await _pump_frames(5)
	if not bool(end_result.get("suspended", false)):
		return "双宝藏应挂起回合结束流程"
	var queued: Array = ctx.action_ui_bridge.get_queued_waiting_action_ids()
	if queued.size() != 1:
		return "第二玩家宝藏窗应在等待队列（并行挂起），队列长度%d 应1" % queued.size()

	# 玩家A确认弃牌掷骰（骰子同步结算无第二窗口）
	var wait_a: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait_a.get("input_type", &"")) != &"select_thrust_cards":
		return "槽内应是第一个宝藏弃牌窗，实际: %s" % String(wait_a.get("input_type", &""))
	ctx.timing_engine.resume_pending_effect(wait_a.get("action_id", &""), {"selected_card_ids": [player_pick]})
	await _pump_frames(8)
	if player.gold <= gold_p_before:
		return "玩家A宝藏确认后金币应增加（前%d 后%d）" % [gold_p_before, player.gold]
	# A 已获金但 B 尚未交互：B 金币不变
	if enemy.gold != gold_e_before:
		return "玩家B未交互前金币不应变化（前%d 后%d）" % [gold_e_before, enemy.gold]

	# 驱动玩家B弃牌窗（骰子同步结算）
	await _drive_all_windows(battle)
	if enemy.gold <= gold_e_before:
		return "玩家B宝藏确认后金币应增加（前%d 后%d）" % [gold_e_before, enemy.gold]
	if enemy.action_hand.has(enemy_pick) or player.action_hand.has(player_pick):
		return "双方所选弃牌都应已弃置"
	return true


## 两个玩家都设修悟（event_020，效果 event_effect_023）：双方选择窗并行挂起，
## 各选「抽2张行动牌」后双方手牌都+2，流程续跑完成
func test_parallel_enlighten_two_players() -> Variant:
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if await _set_event_on_mech(battle, player_mech, &"event_020") == &"":
		return "未找到 event_020 实例1（数据缺失）"
	if await _set_event_on_mech(battle, enemy_mech, &"event_020") == &"":
		return "未找到 event_020 实例2（数据缺失）"
	enemy.is_human = true
	_clear_terrain(gs)
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	gs.active_player_id = &"player"

	var end_result: Dictionary = ctx.turn_service.end_turn(&"player")
	await _pump_frames(5)
	if not bool(end_result.get("suspended", false)):
		return "双修悟应挂起回合结束流程"
	var queued: Array = ctx.action_ui_bridge.get_queued_waiting_action_ids()
	if queued.size() != 1:
		return "第二玩家修悟窗应在等待队列（并行挂起），队列长度%d 应1" % queued.size()

	# 玩家A选「抽2张行动牌」
	var wait_a: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait_a.get("input_type", &"")) != &"choose_one_effect":
		return "槽内应是第一个修悟选择窗，实际: %s" % String(wait_a.get("input_type", &""))
	ctx.timing_engine.resume_pending_effect(wait_a.get("action_id", &""), {"chosen_option_index": 0})
	await _pump_frames(8)
	if player.action_hand.size() != 2:
		return "玩家A修悟抽2后手牌应2张（实%d）" % player.action_hand.size()

	# 玩家B窗口恢复，同样抽2
	var wait_b: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
	if String(wait_b.get("input_type", &"")) != &"choose_one_effect":
		return "玩家A完成后应恢复玩家B修悟窗，实际: %s" % String(wait_b.get("input_type", &""))
	ctx.timing_engine.resume_pending_effect(wait_b.get("action_id", &""), {"chosen_option_index": 0})
	await _pump_frames(8)
	if enemy.action_hand.size() != 2:
		return "玩家B修悟抽2后手牌应2张（实%d）" % enemy.action_hand.size()
	return true
