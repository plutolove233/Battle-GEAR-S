## test_pilot_069_shade.gd - 影刹（pilot_069）效果测试
##
## 影刹 1 按钮（被动融合）：effect_01(TURN_END 累加) + effect_02(ATTACK_BEFORE 应用) + effect_03(ATTACK_SETTLE 清空)。
##   权威效果：「每个我方回合结束时，若本回合未发动攻击，则下次攻击威力+3；若本回合移动未超过
##              4格，则下次攻击范围+1。上述效果可叠加。」
##   effect_01：LISTEN TURN_END。IS_OWNER_TURN（我方回合结束）时，通用 ACCUMULATE_NEXT_ATTACK_BONUS
##              读机甲 has_attacked_this_turn（攻击动作启动即置位，含铠威窗口/联合/迎击）与
##              cells_moved_this_turn（<=4）累加两张牌计数器 pilot_069_next_might/next_range（跨回合叠加）。
##   effect_02：LISTEN ATTACK_BEFORE。SELF_MECH_IS_ATTACKER（我方发起攻击）时，通用
##              APPLY_NEXT_ATTACK_BONUS 读计数器累加进 attack.record.extra_might/extra_range
##              （选目标前生效，双连 fork 深拷贝 record 继承）。不清空——取消攻击时加成保留。
##   effect_03：LISTEN ATTACK_SETTLE。SELF_MECH_IS_ATTACKER 时 SET_CARD_COUNTER 置 0 两张计数器
##              （攻击完全结算后消失；fork 各枚已深拷贝 record 带加成，任一枚 SETTLE 清空不影响其他）。
##   effect_02/03 hide_button + merge_desc_into_index=1，描述合并到按钮1 hover（共1个按钮）。
##
## 关键扩展点（本测试覆盖）：
##   1. 新增 mech.has_attacked_this_turn（攻击动作置位/回合开始重置），比 attack_count_this_turn
##      精确（窗口/联合/迎击攻击不计攻击数但仍算「发动过攻击」）。
##   2. 新增 2 个参数化 act_type：ACCUMULATE_NEXT_ATTACK_BONUS / APPLY_NEXT_ATTACK_BONUS。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90069
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


## 设影刹为 owner_id 机甲的机师，返回 {mech, enemy_mech, card, gs, cdb, battle}；失败返回 null。
func _setup_yingsha(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_069_影刹", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	# tutorial 初始 active_player_id 为空（start_tutorial 不 start_turn），手动设为 owner 使
	# IS_OWNER_TURN 条件在 fire TURN_END 时通过（模拟 owner 回合正在结束）。
	gs.active_player_id = owner_id
	var enemy_mech = gs.get_mech_for_player(&"enemy") if owner_id == &"player" else gs.get_mech_for_player(&"player")
	return {"card": card, "mech": mech, "enemy_mech": enemy_mech, "gs": gs, "cdb": cdb, "battle": battle}


## 构造 TURN_END 虚拟动作（action_type=turn，仿 TurnService._fire_timing）。
func _make_turn_end(battle, player_id: StringName, turn_number: int) -> _Action:
	var vact := _Action.new()
	vact.action_id = &"test_p069_turn_%d" % [randi() % 1000000]
	vact.action_type = &"turn"
	vact.record = {"player_id": player_id, "turn_number": turn_number}
	vact.state = &"running"
	vact.context = battle.context
	battle.context.action_registry.register(vact)
	return vact


## 构造攻击 action（fire ATTACK_BEFORE/ATTACK_SETTLE 用）。record 带 attacker_id/target_id/weapon_range。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, weapon_range: int = 3) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p069_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id, "weapon_range": weapon_range, "extra_range": 0, "extra_might": 0}
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


func _next_might(s) -> int:
	return int(s.card.counters.get("pilot_069_next_might", 0))


func _next_range(s) -> int:
	return int(s.card.counters.get("pilot_069_next_range", 0))


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN TURN_END + turn + IS_OWNER_TURN + ACCUMULATE_NEXT_ATTACK_BONUS 参数）
func test_pilot_069_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_069_effect_01")
	if e == null:
		return "缺 pilot_069_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.TURN_END:
		return "effect_01 listen_timing 应 TURN_END"
	if e.listen_action_type != &"turn":
		return "effect_01 listen_action_type 应 turn"
	if bool(e.hide_button):
		return "effect_01 应是按钮1（hide_button 应为 false）"
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（可叠加）实=%s" % String(e.once_per_turn_key)
	# 条件：IS_OWNER_TURN（我方回合结束）
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_TURN"):
		return "effect_01 应含条件 IS_OWNER_TURN，实际 ops=%s" % str(ops)
	# actions: [ACCUMULATE_NEXT_ATTACK_BONUS 参数化]
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "ACCUMULATE_NEXT_ATTACK_BONUS":
		return "effect_01 actions 应 [ACCUMULATE_NEXT_ATTACK_BONUS]"
	var ap: Dictionary = acts[0].get("params", {})
	if int(ap.get("might_delta", 0)) != 3:
		return "might_delta 应 3 实=%d" % int(ap.get("might_delta", 0))
	if int(ap.get("range_delta", 0)) != 1:
		return "range_delta 应 1 实=%d" % int(ap.get("range_delta", 0))
	if int(ap.get("range_when_moved_at_most", -1)) != 4:
		return "range_when_moved_at_most 应 4（移动≤4触发）实=%d" % int(ap.get("range_when_moved_at_most", -1))
	if String(ap.get("might_key", &"")) != "pilot_069_next_might":
		return "might_key 应 pilot_069_next_might"
	if String(ap.get("range_key", &"")) != "pilot_069_next_range":
		return "range_key 应 pilot_069_next_range"
	return true


## 测试2：effect_02 定义正确（LISTEN ATTACK_BEFORE + attack + SELF_MECH_IS_ATTACKER + APPLY_NEXT_ATTACK_BONUS + 隐藏合并）
func test_pilot_069_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_069_effect_02")
	if e == null:
		return "缺 pilot_069_effect_02"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "effect_02 listen_timing 应 ATTACK_BEFORE"
	if e.listen_action_type != &"attack":
		return "effect_02 listen_action_type 应 attack"
	if not bool(e.hide_button):
		return "effect_02 应 hide_button=true（合并到按钮1）"
	if int(e.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_02 应含条件 SELF_MECH_IS_ATTACKER，实际 ops=%s" % str(ops)
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "APPLY_NEXT_ATTACK_BONUS":
		return "effect_02 actions 应 [APPLY_NEXT_ATTACK_BONUS]"
	var ap: Dictionary = acts[0].get("params", {})
	if String(ap.get("might_key", &"")) != "pilot_069_next_might":
		return "effect_02 might_key 应 pilot_069_next_might"
	if String(ap.get("range_key", &"")) != "pilot_069_next_range":
		return "effect_02 range_key 应 pilot_069_next_range"
	return true


## 测试3：effect_03 定义正确（LISTEN ATTACK_SETTLE + attack + SELF_MECH_IS_ATTACKER + SET_CARD_COUNTER×2 隐藏合并）
func test_pilot_069_effect_03_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_069_effect_03")
	if e == null:
		return "缺 pilot_069_effect_03"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_03 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_SETTLE:
		return "effect_03 listen_timing 应 ATTACK_SETTLE"
	if e.listen_action_type != &"attack":
		return "effect_03 listen_action_type 应 attack"
	if not bool(e.hide_button):
		return "effect_03 应 hide_button=true（合并到按钮1）"
	if int(e.merge_desc_into_index) != 1:
		return "effect_03 merge_desc_into_index 应 1"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_03 应含条件 SELF_MECH_IS_ATTACKER，实际 ops=%s" % str(ops)
	var acts = e.actions
	if acts.size() != 2:
		return "effect_03 actions 应2个 SET_CARD_COUNTER 实=%d" % acts.size()
	for a in acts:
		if String(a.get("type", &"")) != "SET_CARD_COUNTER":
			return "effect_03 action 应 SET_CARD_COUNTER"
		if int(a.get("params", {}).get("value", -1)) != 0:
			return "SET_CARD_COUNTER value 应 0（清空）"
	return true


# ═══════════════════════════════════════════
# 功能测试
# ═══════════════════════════════════════════

## 测试4：回合结束未攻击未移动 → 威力+3 范围+1（累加进牌计数器）
func test_pilot_069_turn_end_accumulate_both() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_069_影刹）"
	battle.context.action_ui_bridge.context = battle.context
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	if _next_might(s) != 3:
		return "未攻击应累加威力+3 实=%d" % _next_might(s)
	if _next_range(s) != 1:
		return "移动0≤4应累加范围+1 实=%d" % _next_range(s)
	return true


## 测试5：本回合发动过攻击 → 威力不累加（has_attacked_this_turn 拦截）；范围仍累加
func test_pilot_069_turn_end_attacked_skip_might() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.mech.has_attacked_this_turn = true  # 本回合发动过攻击（窗口/联合/正常均可置位）
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	if _next_might(s) != 0:
		return "已攻击不应累加威力 实=%d" % _next_might(s)
	if _next_range(s) != 1:
		return "未移动仍应累加范围+1 实=%d" % _next_range(s)
	return true


## 测试6：本回合移动超过4格（=5）→ 范围不累加；威力仍累加
func test_pilot_069_turn_end_moved_over4_skip_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.mech.cells_moved_this_turn = 5  # 移动超过4格
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	if _next_might(s) != 3:
		return "未攻击应累加威力+3 实=%d" % _next_might(s)
	if _next_range(s) != 0:
		return "移动>4不应累加范围 实=%d" % _next_range(s)
	return true


## 测试7：跨回合可叠加（两个我方回合结束都未攻击未移动 → 威力+6 范围+2）
func test_pilot_069_stack_across_turns() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var v1 := _make_turn_end(battle, &"player", 1)
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, v1)
	await _pump_frames(3)
	var v2 := _make_turn_end(battle, &"player", 2)
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, v2)
	await _pump_frames(3)
	if _next_might(s) != 6:
		return "两个回合叠加威力应+6 实=%d" % _next_might(s)
	if _next_range(s) != 2:
		return "两个回合叠加范围应+2 实=%d" % _next_range(s)
	return true


## 测试8：我方攻击 ATTACK_BEFORE → 应用加成进 record.extra_might/extra_range（选目标前生效），且计数器保留
func test_pilot_069_apply_at_attack_before() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 先累加
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	# 我方攻击 -> ATTACK_BEFORE
	var atk := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_BEFORE, atk)
	await _pump_frames(3)
	if int(atk.record.get("extra_might", 0)) != 3:
		return "ATTACK_BEFORE 应写 extra_might=3 实=%d" % int(atk.record.get("extra_might", 0))
	if int(atk.record.get("extra_range", 0)) != 1:
		return "ATTACK_BEFORE 应写 extra_range=1 实=%d" % int(atk.record.get("extra_range", 0))
	# 应用后计数器保留（不清空——取消攻击不消耗）
	if _next_might(s) != 3 or _next_range(s) != 1:
		return "应用后计数器应保留（取消攻击不消耗）might=%d range=%d" % [_next_might(s), _next_range(s)]
	return true


## 测试9：攻击完全结算 ATTACK_SETTLE → 两张计数器清零（「下次攻击」用完即消失）
func test_pilot_069_clear_at_attack_settle() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	var atk := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_BEFORE, atk)
	await _pump_frames(3)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, atk)
	await _pump_frames(3)
	if _next_might(s) != 0 or _next_range(s) != 0:
		return "ATTACK_SETTLE 应清空计数器 might=%d range=%d" % [_next_might(s), _next_range(s)]
	return true


## 测试10：攻击被取消（无 SETTLE）→ 计数器保留（下次攻击继续生效）
func test_pilot_069_no_settle_keep_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	# 只 fire ATTACK_BEFORE（模拟攻击启动后取消），不 fire SETTLE
	var atk := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_BEFORE, atk)
	await _pump_frames(3)
	if _next_might(s) != 3 or _next_range(s) != 1:
		return "取消攻击应保留计数器 might=%d range=%d" % [_next_might(s), _next_range(s)]
	return true


## 测试11：全链路——TURN_END 累加 → ATTACK_BEFORE 应用 → ATTACK_SETTLE 清空
func test_pilot_069_full_flow_accumulate_apply_clear() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yingsha(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# ① 我方回合结束（未攻击未移动）累加
	var vact := _make_turn_end(battle, &"player", int(s.gs.turn_number))
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_END, vact)
	await _pump_frames(3)
	if _next_might(s) != 3 or _next_range(s) != 1:
		return "累加失败 might=%d range=%d" % [_next_might(s), _next_range(s)]
	# ② 我方攻击：ATTACK_BEFORE 应用
	var atk := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_BEFORE, atk)
	await _pump_frames(3)
	if int(atk.record.get("extra_might", 0)) != 3:
		return "应用失败 extra_might=%d" % int(atk.record.get("extra_might", 0))
	if int(atk.record.get("extra_range", 0)) != 1:
		return "应用失败 extra_range=%d" % int(atk.record.get("extra_range", 0))
	# ③ 攻击结算：SETTLE 清空
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, atk)
	await _pump_frames(3)
	if _next_might(s) != 0 or _next_range(s) != 0:
		return "清空失败 might=%d range=%d" % [_next_might(s), _next_range(s)]
	return true
