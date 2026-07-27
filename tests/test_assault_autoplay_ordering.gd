## test_assault_autoplay_ordering.gd - 强袭2触发时序回归测试（ActionUIBridge 自动决策路径）
##
## 锁定 bug：攻击方使用强袭、响应方用迎击移动牌（回避/疾行）响应后，强袭 effect2 在
## 响应移动**结算前**就触发（_run_pending_regular_listeners 守卫只挡 waiting_timing，
## 不挡 waiting_effect_action），与响应移动并发 waiting_input。call_deferred 的
## _auto_move_target 延迟回调执行时 _waiting_action_id 已被强袭2移动覆盖，on_ui_confirmed
## 把**响应方的移动目标错路由到攻击方** -> 攻击方被 AI 自动移动、响应方卡死不动
## （实机表现：人类玩家用强袭，自己被 AI 自动跳走 12 格）。
##
## 本测试**不断开 ActionUIBridge 信号**（与 test_assault_chase_flow 的 InputDriver 路径
## 互补），双方设为 AI 走 _auto_respond / _auto_move_target 自动决策。
## 修复后：响应方先完成移动，强袭 effect2 再触发追击，攻击方重新进入范围命中。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const SLog = preload("res://scripts/services/slog.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


## 等一帧，flush call_deferred 排入的动作恢复（-s 模式靠 SceneTree 主循环）。
func _frame() -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


func _place_mech(battle: BattleState, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	mech.position = {"q": q, "r": r}


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里（复用自 test_assault_chase_flow）
func _ensure_card_in_player_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
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
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 是否还有动作处于等待态（waiting_input / waiting_timing / waiting_effect_action）
func _has_waiting_actions(battle: BattleState) -> bool:
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			return true
	return false


func test_assault_autoplay_orders_response_before_pursuit():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A：强袭攻击方
	var mech_b = gs.get_mech_for_player(&"enemy")     # B：被攻击方（回避响应）

	# 双方都设为 AI，走 ActionUIBridge 自动决策路径（_auto_respond / _auto_move_target）。
	# 现有 InputDriver 测试断开 ActionUIBridge、按 action_id 直接驱动，绕过了
	# _waiting_action_id 共享槽路由，无法覆盖本 bug。
	gs.players.get(&"player").is_human = false
	gs.players.get(&"enemy").is_human = false

	# 布局：A(10,0) B(11,0)，A 武器1 射程2，距离1在范围内
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)
	# A 动力10（足够追击）；B 动力6 -> 回避半动力X=3 可跳出范围2
	mech_a.power = 10
	mech_b.power = 6

	var a_assault := _ensure_card_in_player_hand(battle, &"player", "action_002_强袭")
	if a_assault == &"":
		return "A 手牌未找到强袭牌"
	var b_evade := _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	if b_evade == &"":
		return "B 手牌未找到回避牌"

	var b_hp0: int = mech_b.current_hp

	# 发起：A 使用强袭牌（ActionUIBridge 保持连接，自动决策武器/目标/响应/移动）
	var use_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": a_assault,
		"player_id": &"player",
		"mech_id": mech_a.mech_id,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if use_result.get("state", &"") == &"error":
		return "使用强袭牌发起失败: %s" % str(use_result)

	# 泵帧驱动 call_deferred 的 _auto_move_target，直到无等待动作（或上限帧）
	for _i in range(200):
		await _frame()
		if not _has_waiting_actions(battle):
			break

	# 诊断
	print("[DIAG autoplay] A pos=", mech_a.position, " B pos=", mech_b.position, " b_hp=", mech_b.current_hp, "/", b_hp0)
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a_diag = battle.context.action_registry.get_action(aid)
		if a_diag:
			print("[DIAG autoplay]   ", aid, " type=", a_diag.action_type, " state=", a_diag.state)

	# 验证1：B 移动了（回避逃跑）。OLD bug 下 B 的 single_move 输入被错路由偷走，B 卡死不动。
	var b_pos = mech_b.position
	if int(b_pos.get("q", -1)) == 11 and int(b_pos.get("r", -1)) == 0:
		return "B 应回避移动跳出范围（bug下B卡死不动），实际仍在 (11,0)"

	# 验证2：A 追击后与 B 在武器射程2内（强袭2追击重新进入范围）
	var _RangeCalc = load("res://scripts/battle/RangeCalculator.gd")
	if not _RangeCalc.is_in_weapon_range(mech_a.position, mech_b.position, 2, gs.map_state.cells):
		return "A 追击后应在 B 的射程2内，实际 A=%s B=%s" % [str(mech_a.position), str(mech_b.position)]

	# 验证3：B 掉血（强袭2追击使命中）。OLD bug 下攻击动作卡死永不结算，B 不掉血。
	if mech_b.current_hp >= b_hp0:
		return "强袭2追击应命中 B（b_hp %d->%d），但 B 未掉血" % [b_hp0, mech_b.current_hp]

	# 验证4：无残留等待动作。OLD bug 下 B 的 single_move 卡在 waiting_input 永不结算。
	if _has_waiting_actions(battle):
		var waiting: Array = []
		for aid: StringName in battle.context.action_registry.get_active_ids():
			var a = battle.context.action_registry.get_action(aid)
			if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
				waiting.append("%s:%s" % [String(aid), String(a.state)])
		return "流程结束后仍有动作等待: %s" % str(waiting)

	return true
