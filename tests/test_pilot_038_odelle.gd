## test_pilot_038_odelle.gd - 奥黛尔（pilot_038，联邦 R）效果测试
##
## 奥黛尔 1 个主动效果按钮（DIRECT，机师槽可点按钮）：
##   effect_01（我方回合1次）「战术协同」：选择最多2台4格范围内的机甲（可以包括我方），
##     使其抽2张行动牌、回复3动力。
##
## 通用机制（新增 CHOOSE_MANY_MECHS 多选机甲件，不绑定机师）：
##   · CHOOSE_MANY_MECHS：地图点选 hex 距离范围内存活机甲（include_self 可含自己），
##     min_count/max_count 控制至少/至多，store_result_key 把选中 mech_id 数组存 payload[key]，
##     挂起 phase=choose_many_mechs -> ActionUIBridge 分发 mech_multi_select -> app_root 弹地图点选。
##   · 显式 MARK_EFFECT_ONCE_PER_TURN_USED（确认才计次，取消不计次）：effect 上不设
##     once_per_turn_key（CHOOSE_MANY_MECHS 挂起时 _execute_effect 提前 return 不走自动 mark，
##     且显式 mark 防重复）。
##   · FOR_EACH_TARGET 按选择顺序逐目标：EXECUTE_GAIN_CARD（mech_ids 数组字面量触发
##     has_explicit_mech_ids 反查目标玩家抽2张行动牌）+ RESTORE_POWER（回目标3动力）。
##   · 条件 HAS_OTHER_MECH_IN_HEX_RANGE include_self=true：自己距离0恒在范围内，条件等价于
##     「4格内存在存活机甲」（保证按钮可用时必有可选项）。
##
## 关键覆盖点：
##   1. 效果定义（MODE_DIRECT + 条件 + NO_TARGET + 无 once_per_turn_key 额度件 + 动作链）。
##   2. 主流程：选自己+enemy（enemy 移到4格内）-> 各抽2张行动牌+回3动力，额度消耗1次。
##   3. 只选自己：enemy 远处 -> 仅自己抽2+回3，enemy 无变化。
##   4. 取消选择 -> 中止，不抽不回不消耗次数（可再触发）。
##   5. 每回合1次用满 -> 第2次触发被跳过。
##   6. PVP3 多人类玩家通用：third 玩家触发按玩家隔离（只动 third 的）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90038
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


## 设奥黛尔为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_aodai(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_038_奥黛尔", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建独立玩家 third + 机甲（PVP3 多人），返回机甲；null 失败
func _create_third_player(battle) -> _MechState:
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
	m.position = {"q": 11, "r": -3}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 触发奥黛尔 DIRECT 按钮（effect_fire）。CHOOSE_MANY_MECHS 会挂起，返回挂起的 effect_fire action。
func _fire_pilot_038(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": effect_id,
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": effect_id,
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


## resume 多选机甲窗：确认选中 target_ids（数组 of mech_id StringName）
func _resume_mechs(battle, ef_action, target_ids: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"target_ids": target_ids})
	await _pump_frames(12)


## resume 取消多选机甲窗（中止，不消耗次数）
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


func _mech_power(gs, mid: StringName) -> int:
	var m = gs.mechs.get(mid)
	return m.power if m != null else -1


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_038_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_038_effect_01")
	if e == null:
		return "缺 pilot_038_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if int(e.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e.priority)
	# 关键：不用 effect 级 once_per_turn_key（CHOOSE_MANY_MECHS 挂起时 _execute_effect 提前 return，
	# 自动 mark 不会执行；额度走 EFFECT_ONCE_PER_TURN_AVAILABLE + 显式 MARK 通用件）
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（额度走显式 MARK 通用件）"
	# conditions
	var ops: Array = []
	var eoa = null
	var hmr = null
	for c in e.conditions:
		var op: StringName = c.get("op", &"")
		ops.append(String(op))
		if op == &"EFFECT_ONCE_PER_TURN_AVAILABLE":
			eoa = c
		if op == &"HAS_OTHER_MECH_IN_HEX_RANGE":
			hmr = c
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "effect_01 应含条件 %s" % need
	if eoa == null:
		return "effect_01 应含 EFFECT_ONCE_PER_TURN_AVAILABLE"
	if int(eoa.get("params", {}).get("once_per_turn_max", 0)) != 1:
		return "EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_max 应 1 实=%d" % int(eoa.get("params", {}).get("once_per_turn_max", 0))
	if String(eoa.get("params", {}).get("once_per_turn_key", &"")) != "pilot_038_effect_01":
		return "EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_key 应 pilot_038_effect_01"
	if hmr == null:
		return "effect_01 应含 HAS_OTHER_MECH_IN_HEX_RANGE"
	var hmr_p: Dictionary = hmr.get("params", {})
	if int(hmr_p.get("range", 0)) != 4:
		return "HAS_OTHER_MECH_IN_HEX_RANGE range 应 4 实=%d" % int(hmr_p.get("range", 0))
	if not bool(hmr_p.get("include_self", false)):
		return "HAS_OTHER_MECH_IN_HEX_RANGE 应 include_self=true（自己距离0恒在范围内）"
	# target rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	# actions: [CHOOSE_MANY_MECHS, MARK, FOR_EACH_TARGET]
	var acts = e.actions
	if acts.size() != 3:
		return "effect_01 actions 应 3 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_MANY_MECHS":
		return "actions[0] 应 CHOOSE_MANY_MECHS 实=%s" % String(acts[0].get("type", &""))
	var cm_p: Dictionary = acts[0].get("params", {})
	if int(cm_p.get("range", 0)) != 4:
		return "CHOOSE_MANY_MECHS range 应 4"
	if int(cm_p.get("min_count", 0)) != 1 or int(cm_p.get("max_count", 0)) != 2:
		return "CHOOSE_MANY_MECHS 应 min_count=1 max_count=2 实=%d/%d" % [int(cm_p.get("min_count", 0)), int(cm_p.get("max_count", 0))]
	if not bool(cm_p.get("include_self", false)):
		return "CHOOSE_MANY_MECHS 应 include_self=true"
	if String(cm_p.get("store_result_key", &"")) != "pilot_038_selected_mechs":
		return "CHOOSE_MANY_MECHS store_result_key 应 pilot_038_selected_mechs"
	if String(acts[1].get("type", &"")) != "MARK_EFFECT_ONCE_PER_TURN_USED":
		return "actions[1] 应 MARK_EFFECT_ONCE_PER_TURN_USED 实=%s" % String(acts[1].get("type", &""))
	if String(acts[1].get("params", {}).get("once_per_turn_key", &"")) != "pilot_038_effect_01":
		return "MARK once_per_turn_key 应 pilot_038_effect_01"
	if String(acts[2].get("type", &"")) != "FOR_EACH_TARGET":
		return "actions[2] 应 FOR_EACH_TARGET 实=%s" % String(acts[2].get("type", &""))
	var fet_p: Dictionary = acts[2].get("params", {})
	if String(fet_p.get("targets", &"")) != "$runtime.pilot_038_selected_mechs":
		return "FOR_EACH_TARGET targets 应 $runtime.pilot_038_selected_mechs 实=%s" % String(fet_p.get("targets", &""))
	if String(fet_p.get("execution_mode", &"")) != "SERIAL":
		return "FOR_EACH_TARGET execution_mode 应 SERIAL"
	if not bool(fet_p.get("preserve_order", false)):
		return "FOR_EACH_TARGET 应 preserve_order=true（按选择顺序逐目标）"
	var inner: Array = fet_p.get("actions", [])
	if inner.size() != 2:
		return "FOR_EACH_TARGET inner actions 应 2 个 实=%d" % inner.size()
	if String(inner[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "inner[0] 应 EXECUTE_GAIN_CARD"
	var gc_p: Dictionary = inner[0].get("params", {})
	if int(gc_p.get("count", 0)) != 2:
		return "EXECUTE_GAIN_CARD count 应 2 实=%d" % int(gc_p.get("count", 0))
	if String(gc_p.get("from_zone", &"")) != "action_deck" or String(gc_p.get("card_kind", &"")) != "action":
		return "EXECUTE_GAIN_CARD 应从 action_deck 抽行动牌"
	var gc_mech_ids = gc_p.get("mech_ids", [])
	if not (gc_mech_ids is Array) or gc_mech_ids.size() != 1 or String(gc_mech_ids[0]) != "$current_target.mech_id":
		return "EXECUTE_GAIN_CARD mech_ids 应 [\"$current_target.mech_id\"]（数组字面量触发反查目标玩家）"
	if String(inner[1].get("type", &"")) != "RESTORE_POWER":
		return "inner[1] 应 RESTORE_POWER"
	var rp_p: Dictionary = inner[1].get("params", {})
	if String(rp_p.get("mech_id", &"")) != "$current_target.mech_id":
		return "RESTORE_POWER mech_id 应 $current_target.mech_id"
	if int(rp_p.get("amount", 0)) != 3:
		return "RESTORE_POWER amount 应 3 实=%d" % int(rp_p.get("amount", 0))
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：主流程——选自己+enemy（enemy 移到4格内）-> 各抽2张行动牌+回3动力，额度消耗1次。
## 先验证挂起时弹 mech_multi_select 窗（UI 路由链路）。
func test_pilot_038_select_two_mechs_draw2_power3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aodai(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_038_奥黛尔）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# enemy 移到 player (2,2) 4格内（(4,2) 轴向距离2）
	enemy_mech.position = {"q": 4, "r": 2}
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var deck_before: int = _action_deck_size(battle)
	var player_power_before: int = _mech_power(gs, mech.mech_id)
	var enemy_power_before: int = _mech_power(gs, enemy_mech.mech_id)
	# 制造动力差额（满动力时 restore +3 无效）
	mech.power -= 3
	enemy_mech.power -= 3

	var ef = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef == null:
		return "effect_01 未挂起（应弹 mech_multi_select 多选机甲窗）"
	# 弹窗为通用 mech_multi_select（CHOOSE_MANY_MECHS），携带 range/max/min/include_self/source
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != "mech_multi_select":
		return "CHOOSE_MANY_MECHS 应弹 mech_multi_select 窗，wait=%s" % str(wait_info.get("input_type", &""))
	var mm_params: Dictionary = wait_info.get("input_params", {})
	if String(mm_params.get("source_mech_id", &"")) != String(mech.mech_id):
		return "mech_multi_select source_mech_id 应奥黛尔机甲"
	if int(mm_params.get("range", 0)) != 4 or int(mm_params.get("max_count", 0)) != 2 or int(mm_params.get("min_count", 0)) != 1:
		return "mech_multi_select 参数应 range=4 max=2 min=1"
	if not bool(mm_params.get("include_self", false)):
		return "mech_multi_select 应 include_self=true"

	# 确认选自己+enemy
	await _resume_mechs(battle, ef, [mech.mech_id, enemy_mech.mech_id])
	# 自己：抽2张行动牌 + 回3动力
	if _action_hand_size(battle, &"player") != 2:
		return "确认后 player 应抽2张行动牌 实=%d" % _action_hand_size(battle, &"player")
	if _mech_power(gs, mech.mech_id) != player_power_before:
		return "player 机甲应回满动力（+3） 前=%d 后=%d" % [player_power_before, _mech_power(gs, mech.mech_id)]
	# enemy：抽2张行动牌 + 回3动力
	if _action_hand_size(battle, &"enemy") != 2:
		return "确认后 enemy 应抽2张行动牌 实=%d" % _action_hand_size(battle, &"enemy")
	if _mech_power(gs, enemy_mech.mech_id) != enemy_power_before:
		return "enemy 机甲应回满动力（+3） 前=%d 后=%d" % [enemy_power_before, _mech_power(gs, enemy_mech.mech_id)]
	# 牌堆-4
	if _action_deck_size(battle) != deck_before - 4:
		return "行动牌堆应-4（两台各2） 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	# 额度消耗1次
	var cid: StringName = s.pilot_card.instance_id
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_038_effect_01", cid, 1):
		return "确认发动后回合额度应已消耗"
	return true


## 测试3：只选自己（enemy 在4格外）-> 仅自己抽2+回3，enemy 无变化。
func test_pilot_038_select_self_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aodai(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# enemy 默认远处（20,2），不在4格内
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var deck_before: int = _action_deck_size(battle)
	var player_power_before: int = _mech_power(gs, mech.mech_id)
	var enemy_power_before: int = _mech_power(gs, enemy_mech.mech_id)
	mech.power -= 3

	var ef = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef == null:
		return "enemy 远处时含自己仍可点（include_self 自己距离0在范围内）应挂起"
	# 只选自己
	await _resume_mechs(battle, ef, [mech.mech_id])
	if _action_hand_size(battle, &"player") != 2:
		return "只选自己后 player 应抽2张 实=%d" % _action_hand_size(battle, &"player")
	if _mech_power(gs, mech.mech_id) != player_power_before:
		return "player 机甲应回满动力 前=%d 后=%d" % [player_power_before, _mech_power(gs, mech.mech_id)]
	if _action_hand_size(battle, &"enemy") != 0:
		return "只选自己不应抽 enemy 的牌 实=%d" % _action_hand_size(battle, &"enemy")
	if _mech_power(gs, enemy_mech.mech_id) != enemy_power_before:
		return "enemy 机甲动力不应变化 前=%d 后=%d" % [enemy_power_before, _mech_power(gs, enemy_mech.mech_id)]
	if _action_deck_size(battle) != deck_before - 2:
		return "行动牌堆应-2（只自己抽2） 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	return true


## 测试4：取消选择 -> 中止，不抽不回不消耗次数（可再触发）。
func test_pilot_038_cancel_no_effect_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aodai(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var deck_before: int = _action_deck_size(battle)
	mech.power -= 3
	var power_before: int = _mech_power(gs, mech.mech_id)
	var cid: StringName = s.pilot_card.instance_id
	var te = battle.context.timing_engine
	if not te.is_once_per_turn_key_available(&"pilot_038_effect_01", cid, 1):
		return "前置错误：初始额度应可用"

	var ef = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef == null:
		return "effect_01 应挂起（可取消）"
	await _resume_cancel(battle, ef)
	if _action_hand_size(battle, &"player") != 0:
		return "取消不应抽牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_hand_size(battle, &"enemy") != 0:
		return "取消不应抽 enemy 牌"
	if _mech_power(gs, mech.mech_id) != power_before:
		return "取消不应回动力 前=%d 后=%d" % [power_before, _mech_power(gs, mech.mech_id)]
	if _action_deck_size(battle) != deck_before:
		return "取消不应消耗牌堆"
	if not te.is_once_per_turn_key_available(&"pilot_038_effect_01", cid, 1):
		return "取消不计次（额度应仍可用）"
	# 可再触发
	var ef2 = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef2 == null:
		return "取消中止后应可再触发（再次挂起）"
	await _resume_cancel(battle, ef2)
	return true


## 测试5：每回合1次用满 -> 第2次触发被跳过（不弹窗不抽牌）。
func test_pilot_038_once_per_turn_max1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aodai(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 4, "r": 2}
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var deck_before: int = _action_deck_size(battle)
	# 第一次：完整发动
	var ef1 = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef1 == null:
		return "第1次应挂起"
	await _resume_mechs(battle, ef1, [mech.mech_id])
	if _action_hand_size(battle, &"player") != 2:
		return "第1次发动后 player 应抽2张 实=%d" % _action_hand_size(battle, &"player")
	# 第二次：once_per_turn 用满 -> 跳过，不挂起，不抽牌
	var ef2 = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"player", &"pilot_038_effect_01")
	if ef2 != null:
		return "第2次不应挂起（once_per_turn 用满，条件失败跳过）"
	if _action_hand_size(battle, &"player") != 2:
		return "第2次跳过不应再抽牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 2:
		return "第2次跳过不应消耗牌堆 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	return true


## 测试6：PVP3 多人类玩家通用——third 玩家触发按玩家隔离（只动 third 的）。
func test_pilot_038_owner_actions_across_players() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_aodai(battle, &"third")
	if s.is_empty():
		return "third setup 失败（奥黛尔设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	_clear_action_hand(battle, &"third")
	var deck_before: int = _action_deck_size(battle)
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var enemy_hand_before: int = _action_hand_size(battle, &"enemy")
	# third 机甲无基础框架 base_power（max_power=0），restore 动力无效；只验证抽牌按玩家隔离
	var third_power_before: int = _mech_power(gs, third_mech.mech_id)

	# third 触发：只选 third 自己（third_mech 距离0在范围内）
	var ef = await _fire_pilot_038(battle, s.pilot_card, s.mech, &"third", &"pilot_038_effect_01")
	if ef == null:
		return "third effect_01 应挂起（含自己可点）"
	await _resume_mechs(battle, ef, [third_mech.mech_id])
	if _action_hand_size(battle, &"third") != 2:
		return "third 触发后 third 应抽2张行动牌 实=%d" % _action_hand_size(battle, &"third")
	if _mech_power(gs, third_mech.mech_id) != third_power_before:
		return "third 效果不应改变 third 动力（max_power=0 回复无效） 前=%d 后=%d" % [third_power_before, _mech_power(gs, third_mech.mech_id)]
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third 效果不应影响 player 手牌"
	if _action_hand_size(battle, &"enemy") != enemy_hand_before:
		return "third 效果不应影响 enemy 手牌"
	if _action_deck_size(battle) != deck_before - 2:
		return "行动牌堆应-2（third 抽2） 前=%d 后=%d" % [deck_before, _action_deck_size(battle)]
	return true
