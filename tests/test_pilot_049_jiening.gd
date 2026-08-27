## test_pilot_049_jiening.gd — 杰狞 pilot_049 伤害转移 + 受伤加伤 测试
##
## 权威文本：「4格范围内其他机甲即将受到伤害时，可以将该伤害转移由我方承受。
##              我方受到伤害后，使下次我方造成的伤害+4（可叠加）。」
##
## 拆解（2 按钮被动，全部通用机制组装，不新增原子动作、不与机师ID绑定）：
##   - effect_01 伤害转移（按钮1）：LISTEN HP_CHANGE_BEFORE priority -1（最低，最后执行，能看到
##     安德洛美达反转 priority30 改写后的活 record）。条件：其他机甲4格内 + 是伤害(decrease) +
##     伤害>0 + 非我方自伤（negate）。CHOOSE_ONE optional 弹窗确认（可取消）→ REDIRECT_HP_CHANGE_TARGET
##     把本次 hp_change 的 mech_ids 改为我方机甲（只转HP伤害，损伤标记不转）。
##   - effect_02 受伤加伤（按钮2）：LISTEN HP_CHANGE_BEFORE priority 10，我方造成伤害时
##     （来源=我方，含攻击伤害经 source_action_id->attack.attacker_id 回溯）+4*X 并清零 X。
##     MODIFY_HP_CHANGE_VALUE_BY_VARIABLE 改本次 hp_change value，若由攻击步骤发起同步回写
##     attack.record.damage（加成计入攻击伤害，巴托洛夫非攻击免疫不触发）。
##   - effect_02b 受伤计数（隐藏按钮3，merge_desc_into_index=2）：LISTEN HP_CHANGE_SETTLE，
##     我方每受到1次伤害（实际掉血）→ X+1（INCREMENT_VARIABLE 写本卡实例 counters["var_pilot_049_x"]）。
##
## 覆盖（PvP 双人类）：
##   1. 三个效果定义形状
##   2. 效果1：4格内其他机甲受伤害 → 弹窗确认 → mech_ids 改我方 + 记录 _redirected_from_mech
##   3. 效果1：弹窗取消 → 不转移
##   4. 效果1：5格外 → 不弹窗不转移
##   5. 效果1：我方自伤 → 不弹窗
##   6. 效果1：回复（method=restore）→ 不弹窗
##   7. 效果1：陷阱（无来源）→ 仍可转移（排除自伤后空源通过）
##   8. 效果2b：我方受伤害 → X=1（叠加：两次 → X=2）
##   9. 效果2：X=1 我方攻击伤害 → +4（value 5→9）且 X=0
##   10. 效果2：回写父攻击 attack.record.damage +4
##   11. 效果2：陷阱计入 X 但陷阱自身不加伤（空源不匹配绑定）
##   12. 效果2：自身目标不加伤（TARGET_IS_OTHER 排除）
##   13. 效果2：双连只加一次（首个目标消耗 X 后后续目标不再加成）
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
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类
	battle.rng_seed = 90049
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
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


## 设杰狞为 owner_id 机甲的机师（set_pilot 注册 LISTEN 永久监听器）；失败返回 null
func _setup_jiening(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return null
	var card = _make_instance(gs, cdb, "pilot_049_杰狞", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"mech": mech, "pilot_card": card, "gs": gs, "cdb": cdb, "te": battle.context.timing_engine}


## 构造 attack action（fire ATTACK_PRE/AFTER 用），已注册进 action_registry
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p049_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 构造 hp_change action（fire HP_CHANGE_BEFORE/SETTLE 用），record 可带 source 字典
func _make_hp_change(battle, mech_ids: Array, value: int, method: StringName, reason: StringName, source: Dictionary) -> _Action:
	var hp_act := _Action.new()
	hp_act.action_id = &"test_p049_hp_%d" % [randi() % 1000000]
	hp_act.action_type = &"hp_change"
	hp_act.record = {
		"mech_ids": mech_ids,
		"value": value,
		"method": method,
		"reason": reason,
		"source": source,
	}
	hp_act.state = &"running"
	hp_act.context = battle.context
	battle.context.action_registry.register(hp_act)
	return hp_act


## 创建独立第三方机甲（效果伤害来源用），返回机甲；null 失败
func _create_third_mech(battle, mech_id: StringName, pos: Dictionary):
	var gs = battle.context.game_state
	var m = preload("res://scripts/runtime/MechState.gd").new()
	m.mech_id = mech_id
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var slot = preload("res://scripts/runtime/MechSlotState.gd").new()
		slot.slot_id = slot_id
		slot.slot_kind = &"PART"
		m.slots[slot_id] = slot
	gs.mechs[m.mech_id] = m
	return m


## 读杰狞受伤计数 X（card.counters["var_pilot_049_x"]）
func _get_x(s) -> int:
	if s.pilot_card.counters == null:
		return 0
	return int(s.pilot_card.counters.get("var_pilot_049_x", 0))


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

func test_pilot_049_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_049_effect_01")
	if e1 == null:
		return "缺 pilot_049_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e1.mode)
	if int(e1.priority) != -1:
		return "effect_01 priority 应 -1（最低最后执行）实=%d" % int(e1.priority)
	if e1.listen_timing != _TimingConst.HP_CHANGE_BEFORE:
		return "effect_01 listen_timing 应 HP_CHANGE_BEFORE"
	if e1.listen_action_type != &"hp_change":
		return "effect_01 listen_action_type 应 hp_change"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE", "HP_CHANGE_LIVE_METHOD_IS", "HP_CHANGE_AMOUNT_ABOVE", "HP_CHANGE_SOURCE_MECH_IS_BINDING"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s: %s" % [need, str(e1_ops)]
	if int(e1.conditions[0].get("params", {}).get("base_range", 0)) != 4:
		return "effect_01 条件0 base_range 应 4"
	if not bool(e1.conditions[3].get("params", {}).get("negate", false)):
		return "effect_01 条件3 应 negate=true（排除自伤）"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions 应 [CHOOSE_ONE]"
	var co: Dictionary = e1_acts[0].get("params", {})
	if not bool(co.get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true（可取消）"
	var opts: Array = co.get("options", [])
	if opts.size() != 1:
		return "effect_01 CHOOSE_ONE options 应1个"
	var opt_acts: Array = opts[0].get("actions", [])
	if opt_acts.size() != 1 or String(opt_acts[0].get("type", &"")) != "REDIRECT_HP_CHANGE_TARGET":
		return "effect_01 option actions 应 [REDIRECT_HP_CHANGE_TARGET]"

	var e2 = effects.get(&"pilot_049_effect_02")
	if e2 == null:
		return "缺 pilot_049_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e2.mode)
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10 实=%d" % int(e2.priority)
	if e2.listen_timing != _TimingConst.HP_CHANGE_BEFORE:
		return "effect_02 listen_timing 应 HP_CHANGE_BEFORE"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	for need in ["HP_CHANGE_SOURCE_MECH_IS_BINDING", "HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE", "HP_CHANGE_LIVE_METHOD_IS", "HP_CHANGE_AMOUNT_ABOVE", "BINDING_CARD_COUNTER_ABOVE"]:
		if not e2_ops.has(need):
			return "effect_02 应含条件 %s: %s" % [need, str(e2_ops)]
	var e2_acts = e2.actions
	if e2_acts.size() != 1 or String(e2_acts[0].get("type", &"")) != "MODIFY_HP_CHANGE_VALUE_BY_VARIABLE":
		return "effect_02 actions 应 [MODIFY_HP_CHANGE_VALUE_BY_VARIABLE]"
	var e2_params: Dictionary = e2_acts[0].get("params", {})
	if String(e2_params.get("variable", &"")) != "pilot_049_x":
		return "effect_02 variable 应 pilot_049_x"
	if int(e2_params.get("multiplier", 0)) != 4:
		return "effect_02 multiplier 应 4"

	var e2b = effects.get(&"pilot_049_effect_02b")
	if e2b == null:
		return "缺 pilot_049_effect_02b"
	if e2b.mode != _TimingConst.MODE_LISTEN:
		return "effect_02b mode 应 LISTEN 实=%s" % String(e2b.mode)
	if e2b.listen_timing != _TimingConst.HP_CHANGE_SETTLE:
		return "effect_02b listen_timing 应 HP_CHANGE_SETTLE"
	if not bool(e2b.hide_button):
		return "effect_02b 应 hide_button=true（隐藏第3按钮）"
	if int(e2b.merge_desc_into_index) != 2:
		return "effect_02b merge_desc_into_index 应 2（描述合并到按钮2 hover）"
	var e2b_ops: Array = []
	for c in e2b.conditions:
		e2b_ops.append(String(c.get("op", &"")))
	for need in ["HP_CHANGE_TARGET_IS_SELF", "HP_CHANGE_LIVE_METHOD_IS", "HP_CHANGE_AMOUNT_ABOVE"]:
		if not e2b_ops.has(need):
			return "effect_02b 应含条件 %s: %s" % [need, str(e2b_ops)]
	var e2b_acts = e2b.actions
	if e2b_acts.size() != 1 or String(e2b_acts[0].get("type", &"")) != "INCREMENT_VARIABLE":
		return "effect_02b actions 应 [INCREMENT_VARIABLE]"
	var e2bp: Dictionary = e2b_acts[0].get("params", {})
	if String(e2bp.get("variable_name", &"")) != "pilot_049_x":
		return "effect_02b variable_name 应 pilot_049_x"
	if int(e2bp.get("delta", 0)) != 1:
		return "effect_02b delta 应 1"
	return true


# ═══════════════════════════════════════════
# effect_01 伤害转移
# ═══════════════════════════════════════════

## 测试2：4格内其他机甲受伤害（第三方来源）→ 弹窗确认 → mech_ids 改我方 + _redirected_from_mech
func test_pilot_049_effect1_redirect_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_049_杰狞）"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}  # 距离1 ≤ 4
	var third = _create_third_mech(battle, &"third_mech_p049", {"q": 3, "r": 4})
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": third.mech_id, "source_action_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "4格内受伤害应挂起 CHOOSE_ONE（弹窗确认），state=%s" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	var new_mids: Array = hp_act.record.get("mech_ids", [])
	if new_mids.size() != 1 or String(new_mids[0]) != String(s.mech.mech_id):
		return "确认后 mech_ids 应=[我方]，实=%s" % str(new_mids)
	if String(hp_act.record.get("_redirected_from_mech", &"")) != String(enemy_mech.mech_id):
		return "应记录 _redirected_from_mech=enemy，实=%s" % String(hp_act.record.get("_redirected_from_mech", &""))
	return true


## 测试3：弹窗取消 → 不转移
func test_pilot_049_effect1_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var third = _create_third_mech(battle, &"third_mech_p049b", {"q": 3, "r": 4})
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": third.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "应挂起 CHOOSE_ONE（可选取消），state=%s" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"cancelled": true})
	await _pump_frames(12)
	var new_mids: Array = hp_act.record.get("mech_ids", [])
	if new_mids.size() != 1 or String(new_mids[0]) != String(enemy_mech.mech_id):
		return "取消后 mech_ids 应保持=[enemy]，实=%s" % str(new_mids)
	if hp_act.record.has("_redirected_from_mech"):
		return "取消后不应写 _redirected_from_mech"
	return true


## 测试4：5格外 → 不弹窗不转移
func test_pilot_049_effect1_outside_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 10, "r": 0}  # 距离5 > 4
	var third = _create_third_mech(battle, &"third_mech_p049c", {"q": 3, "r": 4})
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": third.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if hp_act.state == &"waiting_timing":
		return "5格外不应弹窗（state=%s）" % String(hp_act.state)
	if String(hp_act.record.get("mech_ids", [])[0]) != String(enemy_mech.mech_id):
		return "5格外不应转移"
	return true


## 测试5：我方自伤（来源=我方）→ 不弹窗
func test_pilot_049_effect1_self_caused_no() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"effect_damage",
		{"mech_id": s.mech.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if hp_act.state == &"waiting_timing":
		return "我方自伤不应弹窗（state=%s）" % String(hp_act.state)
	if String(hp_act.record.get("mech_ids", [])[0]) != String(enemy_mech.mech_id):
		return "我方自伤不应转移"
	return true


## 测试6：回复（method=restore）→ 不弹窗
func test_pilot_049_effect1_heal_no() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var third = _create_third_mech(battle, &"third_mech_p049d", {"q": 3, "r": 4})
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"restore", &"repair",
		{"mech_id": third.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if hp_act.state == &"waiting_timing":
		return "回复不应弹窗（state=%s）" % String(hp_act.state)
	return true


## 测试7：陷阱（无来源）→ 排除自伤后空源仍可转移
func test_pilot_049_effect1_trap_transferable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 3, &"decrease", &"trap_explosion",
		{"mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "陷阱伤害（空源）应仍可弹窗转移，state=%s" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	var new_mids: Array = hp_act.record.get("mech_ids", [])
	if new_mids.size() != 1 or String(new_mids[0]) != String(s.mech.mech_id):
		return "陷阱伤害确认后应转移到我方，实=%s" % str(new_mids)
	return true


# ═══════════════════════════════════════════
# effect_02b 受伤计数（X+1）
# ═══════════════════════════════════════════

## 测试8：我方受伤害 → X=1；再受 → X=2（可叠加）
func test_pilot_049_effect2_x_increment_on_self_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var hp1 := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"attack_damage",
		{"mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp1)
	await _pump_frames(5)
	if _get_x(s) != 1:
		return "我方受1次伤害 X 应=1，实=%d" % _get_x(s)
	var hp2 := _make_hp_change(battle, [s.mech.mech_id], 2, &"decrease", &"attack_damage",
		{"mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp2)
	await _pump_frames(5)
	if _get_x(s) != 2:
		return "我方受2次伤害 X 应=2（可叠加），实=%d" % _get_x(s)
	return true


# ═══════════════════════════════════════════
# effect_02 受伤加伤（+4*X，消耗X）
# ═══════════════════════════════════════════

## 测试9：X=1 我方攻击伤害 → value 5→9 且 X=0
func test_pilot_049_effect2_boost_on_attack_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.pilot_card.counters = {"var_pilot_049_x": 1}
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var attack := _make_attack(battle, s.mech.mech_id, enemy_mech.mech_id, &"player")
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": &"", "source_action_id": attack.action_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if int(hp_act.record.get("value", 0)) != 9:
		return "X=1 我方攻击伤害应+4 value=9，实=%d" % int(hp_act.record.get("value", 0))
	if _get_x(s) != 0:
		return "加成后 X 应清零=0，实=%d" % _get_x(s)
	return true


## 测试10：加成回写父攻击 attack.record.damage +4
func test_pilot_049_effect2_boost_writes_back_to_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.pilot_card.counters = {"var_pilot_049_x": 2}
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var attack := _make_attack(battle, s.mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	var hp_act := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": &"", "source_action_id": attack.action_id})
	hp_act.parent_action_id = attack.action_id
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if int(hp_act.record.get("value", 0)) != 13:
		return "X=2 应+8 value=13，实=%d" % int(hp_act.record.get("value", 0))
	if int(attack.record.get("damage", 0)) != 13:
		return "应回写父攻击 damage=5+8=13，实=%d" % int(attack.record.get("damage", 0))
	if _get_x(s) != 0:
		return "加成后 X 应清零=0，实=%d" % _get_x(s)
	return true


## 测试11：陷阱计入 X 但陷阱自身不加伤（空源不匹配绑定）
func test_pilot_049_effect2_trap_counts_but_no_boost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 陷阱伤害我方 → X=1（无来源也计入）
	var hp_trap := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"trap_explosion",
		{"mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_trap)
	await _pump_frames(5)
	if _get_x(s) != 1:
		return "陷阱伤害我方 X 应=1，实=%d" % _get_x(s)
	# 陷阱自身对他人造成伤害（空源）→ 不是我方造成的伤害 → 不加伤，X 保留
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var hp_out := _make_hp_change(battle, [enemy_mech.mech_id], 3, &"decrease", &"trap_explosion",
		{"mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_out)
	await _pump_frames(5)
	if int(hp_out.record.get("value", 0)) != 3:
		return "陷阱（空源）伤害他人不应加伤 value 应=3，实=%d" % int(hp_out.record.get("value", 0))
	if _get_x(s) != 1:
		return "陷阱不加伤不应消耗 X（应保持1），实=%d" % _get_x(s)
	return true


## 测试12：自身目标不加伤（TARGET_IS_OTHER 排除自打）
func test_pilot_049_effect2_no_self_boost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.pilot_card.counters = {"var_pilot_049_x": 1}
	var attack := _make_attack(battle, s.mech.mech_id, s.mech.mech_id, &"player")
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 5, &"decrease", &"effect_damage",
		{"mech_id": &"", "source_action_id": attack.action_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	if int(hp_act.record.get("value", 0)) != 5:
		return "自身目标不应加伤 value 应=5，实=%d" % int(hp_act.record.get("value", 0))
	if _get_x(s) != 1:
		return "自身目标不加伤不应消耗 X（应保持1），实=%d" % _get_x(s)
	return true


## 测试13：双连多目标只加一次（首个目标消耗 X，后续目标不再加成）
func test_pilot_049_effect2_double_no_double_boost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.pilot_card.counters = {"var_pilot_049_x": 1}
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	var third = _create_third_mech(battle, &"third_mech_p049e", {"q": 8, "r": 0})
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	third.position = {"q": 7, "r": 0}
	var attack := _make_attack(battle, s.mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	# 目标1（enemy）
	var hp1 := _make_hp_change(battle, [enemy_mech.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": &"", "source_action_id": attack.action_id})
	hp1.parent_action_id = attack.action_id
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp1)
	await _pump_frames(5)
	if int(hp1.record.get("value", 0)) != 9:
		return "双连目标1 应+4 value=9，实=%d" % int(hp1.record.get("value", 0))
	if _get_x(s) != 0:
		return "双连目标1 加成后 X 应清零，实=%d" % _get_x(s)
	# 目标2（third，同一 attack 的多目标 fork）
	var hp2 := _make_hp_change(battle, [third.mech_id], 5, &"decrease", &"attack_damage",
		{"mech_id": &"", "source_action_id": attack.action_id})
	hp2.parent_action_id = attack.action_id
	s.te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp2)
	await _pump_frames(5)
	if int(hp2.record.get("value", 0)) != 5:
		return "双连目标2 不应再加成（X=0）value 应=5，实=%d" % int(hp2.record.get("value", 0))
	if int(attack.record.get("damage", 0)) != 9:
		return "双连总伤害应只加一次 damage=5+4=9，实=%d" % int(attack.record.get("damage", 0))
	return true


# ═══════════════════════════════════════════
# 端到端复现（Bug3：真实 action 引擎执行路径）
# ═══════════════════════════════════════════
# 现有测试均手动 fire_timing；以下走 action_engine.execute_action 真实执行 hp_change
# （3 时点 HP_CHANGE_BEFORE/AFTER/SETTLE 全 fire + binding_context 注入 + 条件判定 + 原子动作），
# 与攻击步骤7（attack._step_apply_damage 的 EXECUTE_HP_CHANGE 子动作）等价。

## 用真实 action 引擎执行 hp_change（模拟攻击步骤7创建的 hp_change 子动作），返回该动作。
## 注意：必须用 HpChangeAction（3 时点 steps），不能用裸 _Action——
## 裸 _Action 的 steps 为空，execute_action 在 _run_step_loop 直接完成，时点不 fire，测试无效。
func _exec_hp_change_real(battle, parent_attack, mech_ids: Array, value: int):
	var ctx = battle.context
	var hp_act: HpChangeAction = HpChangeAction.new()
	hp_act.action_id = &"test_p049_hpreal_%d" % [randi() % 1000000]
	hp_act.context = ctx
	hp_act.setup_steps()
	# record/source 对齐 _extract_hp_change_params 的输出（source_action_id 供 effect_02 回溯攻击来源）
	hp_act.record = {
		"mech_ids": mech_ids,
		"value": value,
		"method": &"decrease",
		"reason": &"attack_damage",
		"created_by_attack_damage_step": true,
		"source": {"mech_id": &"", "source_action_id": parent_attack.action_id},
	}
	hp_act.parent_action_id = parent_attack.action_id
	ctx.action_registry.register(hp_act)
	ctx.action_engine.execute_action(hp_act)
	return hp_act


## 测试14：端到端——敌方攻击杰狞所在机甲（真实 hp_change 动作）→ X 累加
func test_pilot_049_e2e_x_increment_on_real_attack_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 10, "r": 0}  # 距离5：敌方来源不触发转移/加伤，仅 X 计数
	var enemy_attack := _make_attack(battle, enemy_mech.mech_id, s.mech.mech_id, &"enemy")
	enemy_attack.record["damage"] = 5
	var hp_act = _exec_hp_change_real(battle, enemy_attack, [s.mech.mech_id], 5)
	await _pump_frames(8)
	if _get_x(s) != 1:
		return "真实 hp_change（敌方攻击杰狞）后 X 应=1，实=%d" % _get_x(s)
	if int(hp_act.record.get("value", 0)) != 5:
		return "敌方攻击伤害应保持5（加伤仅我方攻击触发），实=%d" % int(hp_act.record.get("value", 0))
	return true


## 测试15：端到端——杰狞（X=1）真实 hp_change 攻击 → 伤害 +4（目标5格外，隔离伤害转移 effect_01）
func test_pilot_049_e2e_boost_on_real_attack_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jiening(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.pilot_card.counters = {"var_pilot_049_x": 1}
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 10, "r": 0}  # 距离5 > 4：effect_01 不触发，仅 effect_02 加伤
	var attack := _make_attack(battle, s.mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	var hp_act = _exec_hp_change_real(battle, attack, [enemy_mech.mech_id], 5)
	await _pump_frames(8)
	if int(hp_act.record.get("value", 0)) != 9:
		return "真实 hp_change（杰狞 X=1 攻击）应+4 value=9，实=%d" % int(hp_act.record.get("value", 0))
	if int(attack.record.get("damage", 0)) != 9:
		return "应回写父攻击 damage=5+4=9，实=%d" % int(attack.record.get("damage", 0))
	if _get_x(s) != 0:
		return "加成后 X 应清零=0，实=%d" % _get_x(s)
	return true

