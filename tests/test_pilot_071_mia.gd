## test_pilot_071_mia.gd - 弥雅（pilot_071，帝国 N）效果测试
##
## 弥雅 1 个按钮（被动 LISTEN）：effect_01（LISTEN TURN_AFTER_END 我方回合结束后）。
## 权威效果：「每个我方回合结束后，可以选择1台3格范围内的机甲（包括我方）使其抽3张行动牌，
##             之后其再弃置1张牌。」
##   effect_01：我方回合结束后（IS_OWNER_TURN 过滤）弹通用 CHOOSE_MANY_MECHS 选1台3格内机甲
##              （含自己、可取消=不发动不抽不弃）→ 被选机甲抽3张行动牌（EXECUTE_GAIN_CARD
##              mech_ids 走被选机甲反查目标玩家，GAIN_CARD 时点完整触发）→ 之后被选机甲玩家
##              弹窗选弃自己1张行动牌（EXECUTE_DISCARD，executor/player_id=被选机甲所属玩家，
##              choose=true 弹自己手牌、no_cancel=true 必弃、空手自动跳过）。
##
## 通用模块（与效果绑定不绑机师，改 params 复用）：
##   build_turn_end_choose_mech_draw_discard_effect(params)：
##     params = {effect_id, display_name, description, range, draw_count, discard_count,
##               reason_prefix, priority, store_result_key}。
##   关键扩展点（本测试覆盖）：
##   1. ActionService._resolve_atomic_value 新增 $current_target.owner_player_id 通用表达式
##      （FOR_EACH_TARGET 只注入 mech_id，所属玩家须反查；任意「作用于当前目标机甲所属玩家」
##      的原子/子动作参数都可复用）。
##   2. ActionService._extract_discard_params 支持 executor/player_id 的 $ 表达式解析
##      （字面玩家 id 原样返回，不影响现有效果）。
##   3. 弃牌归属被选机甲玩家：被选玩家必弃自己1张（PvP3 经 discard_player_id 路由到目标玩家）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90071
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


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


## 设弥雅为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_miya(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_071_弥雅", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建独立玩家 third + 机甲（PVP3 多人，is_human=true），可指定位置；返回机甲；null 失败
func _create_third_player(battle, position: Dictionary = {}) -> _MechState:
	var gs = battle.context.game_state
	var p = _PlayerState.new()
	p.player_id = &"third"
	p.gold = 15
	p.is_human = true
	gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = &"third_mech"
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = position if not position.is_empty() else {"q": 3, "r": 2}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 构造 turn 虚拟 action（fire TURN_AFTER_END 用；action_type 须与 TurnService._fire_timing
## 一致 &"turn"，否则 listen_action_type 过滤跳过）。record 带 player_id + source。
func _make_turn_action(battle, owner_id: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p071_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": owner_id, "player_id": owner_id}
	turn_action.state = &"running"
	turn_action.context = battle.context
	var mech = battle.context.game_state.get_mech_for_player(owner_id)
	turn_action.source = {"player_id": owner_id, "mech_id": mech.mech_id if mech != null else &""}
	battle.context.action_registry.register(turn_action)
	return turn_action


## fire 指定回合时点，返回虚拟 action（供检查 effect 是否挂起）。
func _fire_turn(battle, timing: StringName, owner_id: StringName) -> _Action:
	var ta := _make_turn_action(battle, owner_id)
	battle.context.timing_engine.fire_timing(timing, ta)
	return ta


## 读取当前等待输入信息（UI 路由等待），无则返回 {}
func _get_wait(battle) -> Dictionary:
	return battle.context.action_ui_bridge.get_waiting_action_info()


## resume 多选机甲窗：确认选中 target_ids（数组 of mech_id StringName）
func _resume_mechs(battle, wait_info: Dictionary, target_ids: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(wait_info.get("action_id", &""), {"target_ids": target_ids})
	await _pump_frames(12)


## resume 取消多选机甲窗（中止，不发动不抽不弃）
func _resume_cancel(battle, wait_info: Dictionary) -> void:
	battle.context.timing_engine.resume_pending_effect(wait_info.get("action_id", &""), {"cancelled": true})
	await _pump_frames(6)


## 清空玩家行动手牌（移回牌堆底，抽牌断言用）
func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(pid)
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


func _action_hand_size(battle, pid: StringName) -> int:
	var p = battle.context.game_state.players.get(pid)
	return p.action_hand.size() if p != null else -1


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN TURN_AFTER_END + turn + IS_OWNER_TURN +
##         HAS_OTHER_MECH_IN_HEX_RANGE(range3 include_self) + CHOOSE_MANY_MECHS(单选含自己)
##         + FOR_EACH_TARGET[EXECUTE_GAIN_CARD 抽3 + EXECUTE_DISCARD 被选玩家必弃1]）
func test_p071_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_071_effect_01")
	if e == null:
		return "缺 pilot_071_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.TURN_AFTER_END:
		return "effect_01 listen_timing 应 TURN_AFTER_END"
	if e.listen_action_type != &"turn":
		return "effect_01 listen_action_type 应 turn"
	if int(e.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e.priority)
	if bool(e.hide_button):
		return "effect_01 应是按钮1（hide_button 应为 false）"
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（每次回合结束都能选，无每回合限制）实=%s" % String(e.once_per_turn_key)
	# 条件：IS_OWNER_TURN + HAS_OTHER_MECH_IN_HEX_RANGE(range=3 include_self=true)
	var ops: Array = []
	var hmr = null
	for c in e.conditions:
		var op: StringName = c.get("op", &"")
		ops.append(String(op))
		if op == &"HAS_OTHER_MECH_IN_HEX_RANGE":
			hmr = c
	for need in ["IS_OWNER_TURN", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "effect_01 应含条件 %s，实际 ops=%s" % [need, str(ops)]
	if hmr == null:
		return "effect_01 应含 HAS_OTHER_MECH_IN_HEX_RANGE"
	var hmr_p: Dictionary = hmr.get("params", {})
	if int(hmr_p.get("range", 0)) != 3:
		return "HAS_OTHER_MECH_IN_HEX_RANGE range 应 3 实=%d" % int(hmr_p.get("range", 0))
	if not bool(hmr_p.get("include_self", false)):
		return "HAS_OTHER_MECH_IN_HEX_RANGE 应 include_self=true（自己距离0恒在范围内）"
	# target rule: NO_TARGET（目标经 CHOOSE_MANY_MECHS 弹窗选）
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	# actions: [CHOOSE_MANY_MECHS, FOR_EACH_TARGET]
	var acts = e.actions
	if acts.size() != 2:
		return "effect_01 actions 应 2 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_MANY_MECHS":
		return "actions[0] 应 CHOOSE_MANY_MECHS 实=%s" % String(acts[0].get("type", &""))
	var cm_p: Dictionary = acts[0].get("params", {})
	if int(cm_p.get("range", 0)) != 3:
		return "CHOOSE_MANY_MECHS range 应 3"
	if int(cm_p.get("min_count", 0)) != 1 or int(cm_p.get("max_count", 0)) != 1:
		return "CHOOSE_MANY_MECHS 应 min_count=1 max_count=1 实=%d/%d" % [int(cm_p.get("min_count", 0)), int(cm_p.get("max_count", 0))]
	if not bool(cm_p.get("include_self", false)):
		return "CHOOSE_MANY_MECHS 应 include_self=true"
	if String(cm_p.get("store_result_key", &"")) != "pilot_071_effect_01_selected_mechs":
		return "CHOOSE_MANY_MECHS store_result_key 应 pilot_071_effect_01_selected_mechs 实=%s" % String(cm_p.get("store_result_key", &""))
	if String(acts[1].get("type", &"")) != "FOR_EACH_TARGET":
		return "actions[1] 应 FOR_EACH_TARGET 实=%s" % String(acts[1].get("type", &""))
	var fet_p: Dictionary = acts[1].get("params", {})
	if String(fet_p.get("targets", &"")) != "$runtime.pilot_071_effect_01_selected_mechs":
		return "FOR_EACH_TARGET targets 应 $runtime.pilot_071_effect_01_selected_mechs 实=%s" % String(fet_p.get("targets", &""))
	if String(fet_p.get("execution_mode", &"")) != "SERIAL":
		return "FOR_EACH_TARGET execution_mode 应 SERIAL"
	if not bool(fet_p.get("preserve_order", false)):
		return "FOR_EACH_TARGET 应 preserve_order=true"
	var inner: Array = fet_p.get("actions", [])
	if inner.size() != 2:
		return "FOR_EACH_TARGET inner actions 应 2 个 实=%d" % inner.size()
	if String(inner[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "inner[0] 应 EXECUTE_GAIN_CARD"
	var gc_p: Dictionary = inner[0].get("params", {})
	if int(gc_p.get("count", 0)) != 3:
		return "EXECUTE_GAIN_CARD count 应 3 实=%d" % int(gc_p.get("count", 0))
	if String(gc_p.get("from_zone", &"")) != "action_deck" or String(gc_p.get("card_kind", &"")) != "action":
		return "EXECUTE_GAIN_CARD 应从 action_deck 抽行动牌"
	var gc_mech_ids = gc_p.get("mech_ids", [])
	if not (gc_mech_ids is Array) or gc_mech_ids.size() != 1 or String(gc_mech_ids[0]) != "$current_target.mech_id":
		return "EXECUTE_GAIN_CARD mech_ids 应 [\"$current_target.mech_id\"]（数组字面量反查目标玩家）"
	if String(inner[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "inner[1] 应 EXECUTE_DISCARD"
	var dp: Dictionary = inner[1].get("params", {})
	if String(dp.get("player_id", &"")) != "$current_target.owner_player_id":
		return "EXECUTE_DISCARD player_id 应 $current_target.owner_player_id（被选机甲所属玩家）"
	if String(dp.get("executor", &"")) != "$current_target.owner_player_id":
		return "EXECUTE_DISCARD executor 应 $current_target.owner_player_id"
	if int(dp.get("count", 0)) != 1:
		return "EXECUTE_DISCARD count 应 1 实=%d" % int(dp.get("count", 0))
	if not bool(dp.get("choose", false)):
		return "EXECUTE_DISCARD 应 choose=true（弹被选玩家自己手牌选择）"
	if not bool(dp.get("no_cancel", false)):
		return "EXECUTE_DISCARD 应 no_cancel=true（必弃1张，不能取消）"
	if not bool(dp.get("face_up", false)):
		return "EXECUTE_DISCARD 应 face_up=true"
	if String(dp.get("reason", &"")) != "pilot_071_discard":
		return "EXECUTE_DISCARD reason 应 pilot_071_discard 实=%s" % String(dp.get("reason", &""))
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：我方回合结束（TURN_AFTER_END）→ 弹多选机甲窗（含自己、可取消）→ 选自己 →
##        抽3张行动牌 → 弹必弃1张窗 → 弃1张 → 手牌净+2。
func test_p071_turn_after_end_select_self_draw3_discard1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_miya(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_071_弥雅）"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_clear_action_hand(battle, &"player")
	var deck_before: int = _action_deck_size(battle)
	var pile_before: int = gs.deck_state.action_discard_pile.size()

	# fire TURN_AFTER_END → effect_01：CHOOSE_MANY_MECHS 挂起，弹 mech_multi_select 窗
	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait: Dictionary = _get_wait(battle)
	if String(wait.get("input_type", &"")) != "mech_multi_select":
		return "TURN_AFTER_END 应弹 mech_multi_select 窗，wait=%s" % str(wait)
	var mm_p: Dictionary = wait.get("input_params", {})
	if String(mm_p.get("source_mech_id", &"")) != String(mech.mech_id):
		return "mech_multi_select source_mech_id 应弥雅机甲"
	if int(mm_p.get("range", 0)) != 3 or int(mm_p.get("max_count", 0)) != 1 or int(mm_p.get("min_count", 0)) != 1:
		return "mech_multi_select 参数应 range=3 max=1 min=1 实=%s" % str(mm_p)
	if not bool(mm_p.get("include_self", false)):
		return "mech_multi_select 应 include_self=true"

	# 确认选自己
	await _resume_mechs(battle, wait, [mech.mech_id])
	# 抽3张行动牌（FOR_EACH_TARGET → EXECUTE_GAIN_CARD）
	if _action_hand_size(battle, &"player") != 3:
		return "选自己后应抽3张行动牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 3:
		return "行动牌堆应-3 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	# 之后弹必弃1张窗（EXECUTE_DISCARD：executor=被选玩家自己，choose+no_cancel）
	var wait2: Dictionary = _get_wait(battle)
	if String(wait2.get("input_type", &"")) != "select_discard_cards":
		return "抽牌后应弹 select_discard_cards 弃牌窗，wait=%s" % str(wait2)
	var dp: Dictionary = wait2.get("input_params", {})
	if int(dp.get("count", 0)) != 1:
		return "弃牌 count 应1 实=%d" % int(dp.get("count", 0))
	if not bool(dp.get("no_cancel", false)):
		return "弃牌应 no_cancel=true（必弃）"
	if String(dp.get("discard_player_id", &"")) != "player":
		return "弃牌 discard_player_id 应 player（被选自己） 实=%s" % String(dp.get("discard_player_id", &""))
	# 弃1张
	var player = gs.players.get(&"player")
	var to_discard: Array = [player.action_hand[0]]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": to_discard})
	await _pump_frames(12)
	if _action_hand_size(battle, &"player") != 2:
		return "弃1后手牌应剩2 实=%d" % _action_hand_size(battle, &"player")
	if gs.deck_state.action_discard_pile.size() != pile_before + 1:
		return "弃牌堆应+1 前=%d 后=%d" % [pile_before, gs.deck_state.action_discard_pile.size()]
	return true


## 测试3：取消多选机甲窗 → 不抽不弃（效果不发动），且可再触发。
func test_p071_cancel_no_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_miya(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_clear_action_hand(battle, &"player")
	var deck_before: int = _action_deck_size(battle)
	var pile_before: int = gs.deck_state.action_discard_pile.size()

	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait: Dictionary = _get_wait(battle)
	if String(wait.get("input_type", &"")) != "mech_multi_select":
		return "应弹 mech_multi_select 窗，wait=%s" % str(wait)
	await _resume_cancel(battle, wait)
	if _action_hand_size(battle, &"player") != 0:
		return "取消不应抽牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before:
		return "取消不应消耗牌堆 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	if gs.deck_state.action_discard_pile.size() != pile_before:
		return "取消不应产生弃牌"
	# 可再触发：再次 fire 仍弹窗（守卫已清除）
	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait2: Dictionary = _get_wait(battle)
	if String(wait2.get("input_type", &"")) != "mech_multi_select":
		return "取消中止后应可再触发（再次弹窗），wait=%s" % str(wait2)
	await _resume_cancel(battle, wait2)
	return true


## 测试4：非我方回合（enemy 回合结束）→ 不触发（IS_OWNER_TURN 拦截），不弹窗不抽牌。
func test_p071_enemy_turn_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_miya(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var deck_before: int = _action_deck_size(battle)
	gs.active_player_id = &"enemy"

	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"enemy")
	await _pump_frames(3)
	var wait: Dictionary = _get_wait(battle)
	if not wait.is_empty():
		return "敌方回合结束不应弹窗，wait=%s" % str(wait)
	if _action_hand_size(battle, &"player") != 0:
		return "敌方回合结束不应抽我方牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before:
		return "敌方回合结束不应消耗牌堆 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	return true


## 测试6：真实 bug 场景——挂起后回合已切换再确认 → 效果仍执行（条件重检豁免）。
##        弥雅 TURN_AFTER_END 挂起 mech_multi_select 后，_net_end_turn 立即 start_turn
##        下家（active_player_id 变成 enemy），此时玩家确认目标。若 resume 重跑时重检
##        IS_OWNER_TURN 会误判"不再满足"→ skip（选完没反应）。修复：resume 分支设
##        _effect_conditions_prechecked=true，跳过条件重检只续跑后续 actions。
func test_p071_resume_after_turn_switch_still_executes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_miya(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_clear_action_hand(battle, &"player")
	var deck_before: int = _action_deck_size(battle)

	# fire TURN_AFTER_END → effect_01 挂起 mech_multi_select
	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait: Dictionary = _get_wait(battle)
	if String(wait.get("input_type", &"")) != "mech_multi_select":
		return "应弹 mech_multi_select 窗，wait=%s" % str(wait)

	# 模拟 _net_end_turn：挂起期间切到 enemy 回合（active_player_id 变更）
	gs.active_player_id = &"enemy"

	# 玩家确认选自己 → 条件重检豁免 → 仍抽3张行动牌（不再 skip）
	await _resume_mechs(battle, wait, [mech.mech_id])
	if _action_hand_size(battle, &"player") != 3:
		return "切回合后确认应仍抽3张行动牌（条件重检豁免）实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 3:
		return "行动牌堆应-3 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	# 之后弹必弃1张窗 → 弃1 → 手牌净+2
	var wait2: Dictionary = _get_wait(battle)
	if String(wait2.get("input_type", &"")) != "select_discard_cards":
		return "抽牌后应弹 select_discard_cards 弃牌窗，wait=%s" % str(wait2)
	var player = gs.players.get(&"player")
	var to_discard: Array = [player.action_hand[0]]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": to_discard})
	await _pump_frames(12)
	if _action_hand_size(battle, &"player") != 2:
		return "切回合后弃1手牌应剩2 实=%d" % _action_hand_size(battle, &"player")
	return true


## 测试5：PVP3 多人类玩家——选 third 机甲（3格内）→ third 抽3张行动牌 → third 必弃1张
##        （discard_player_id 路由到 third），player 手牌不受影响。
func test_p071_select_third_mech_draws3_discards1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle, {"q": 3, "r": 2})
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_miya(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"third")
	var deck_before: int = _action_deck_size(battle)
	var third_pile_before: int = gs.deck_state.action_discard_pile.size()
	var player_hand_before: int = _action_hand_size(battle, &"player")

	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait: Dictionary = _get_wait(battle)
	if String(wait.get("input_type", &"")) != "mech_multi_select":
		return "应弹 mech_multi_select 窗，wait=%s" % str(wait)
	# 选 third 机甲
	await _resume_mechs(battle, wait, [third_mech.mech_id])
	# third 抽3张行动牌（mech_ids 反查目标玩家=third）
	if _action_hand_size(battle, &"third") != 3:
		return "选 third 后 third 应抽3张行动牌 实=%d" % _action_hand_size(battle, &"third")
	if _action_deck_size(battle) != deck_before - 3:
		return "行动牌堆应-3 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "选 third 不应影响 player 手牌 实=%d" % _action_hand_size(battle, &"player")
	# third 弹必弃1张窗（discard_player_id 路由到 third）
	var wait2: Dictionary = _get_wait(battle)
	if String(wait2.get("input_type", &"")) != "select_discard_cards":
		return "third 应弹 select_discard_cards 弃牌窗，wait=%s" % str(wait2)
	var dp: Dictionary = wait2.get("input_params", {})
	if int(dp.get("count", 0)) != 1:
		return "弃牌 count 应1 实=%d" % int(dp.get("count", 0))
	if not bool(dp.get("no_cancel", false)):
		return "弃牌应 no_cancel=true（必弃）"
	if String(dp.get("discard_player_id", &"")) != "third":
		return "弃牌 discard_player_id 应 third（被选机甲所属玩家） 实=%s" % String(dp.get("discard_player_id", &""))
	# third 弃自己1张
	var third_player = gs.players.get(&"third")
	var to_discard: Array = [third_player.action_hand[0]]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": to_discard})
	await _pump_frames(12)
	if _action_hand_size(battle, &"third") != 2:
		return "third 弃1后手牌应剩2 实=%d" % _action_hand_size(battle, &"third")
	if gs.deck_state.action_discard_pile.size() != third_pile_before + 1:
		return "弃牌堆应+1 前=%d 后=%d" % [third_pile_before, gs.deck_state.action_discard_pile.size()]
	return true
