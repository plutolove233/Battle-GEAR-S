## test_pilot_034_cervantes.gd - 塞万提斯（pilot_034，联邦 R）效果测试
##
## 塞万提斯 2 个被动效果按钮：
##   effect_01（损伤减免）：LISTEN ATTACK_AFTER priority10。未对我方造成伤害的攻击产生的损伤-1。
##       只读 attack 步骤6 快照的 base_damage（不含巴托洛夫+3 等 ATTACK_AFTER 追加），<1 即 0 伤害，
##       写 MODIFY_ATTACK_MARKERS -1（_step_apply_damage step7 并入 markers）。
##   effect_02（铭记仇敌）：LISTEN HP_CHANGE_AFTER priority10。我方受到生命减少时，把伤害来源机甲
##       记入本机师静态记录集（_pilot_034_recorded，按机师牌实例隔离）。
##       来源解析（PILOT_034_RECORD_DAMAGE_SOURCE）：hp_change.source.mech_id（效果伤害来源）→
##       退回 source_action_id 指向的 attack 的 attacker_id（攻击伤害）；陷阱/无来源跳过；排除自身。
##   effect_02b（复仇反击，hide_button 隐藏，描述合并到按钮2 hover）：LISTEN ATTACK_AFTER priority10。
##       我方对记录过的机甲攻击命中时，弹窗确认（CHOOSE_ONE optional）可额外造成3伤害
##       （效果伤害，来源=塞万提斯所属机甲，非攻击伤害，不产损伤）并回复我方3生命。
##       永久保留记录，每次命中均可触发（每命中弹窗确认）。
##
## 关键覆盖点：
##   1. 三个效果定义（mode/listen_timing/priority/条件/动作链；02b hide_button+merge_desc_into_index）。
##   2. effect_01：0伤害攻击（base_damage=0）命中我方 -> extra_markers -1（损伤-1）。
##   3. effect_01：有伤害攻击（base_damage=5）命中我方 -> 不触发（extra_markers 不变）。
##   4. effect_02：攻击伤害 -> 记录 attacker 机甲（经 source_action_id -> attack.attacker_id）。
##   5. effect_02：效果伤害（source.mech_id=第三方机甲）-> 记录该机甲。
##   6. effect_02：陷阱/无来源 -> 不记录；自身来源 -> 不记录。
##   7. effect_02b：对已记录机甲攻击命中 -> 弹窗确认 -> 确认后敌方 HP-3、我方 HP+3。
##   8. effect_02b：对未记录机甲攻击命中 -> 不弹窗不触发。
##   9. effect_02b：取消弹窗 -> 无 HP 变化。
##   10. 静态记录集 helper（record/is/clear）。
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
	battle.rng_seed = 90034
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura + 塞万提斯 _pilot_034_recorded），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)
	for src in _ActionPilotEffects._pilot_034_recorded.keys():
		_ActionPilotEffects.clear_pilot_034_recorded(src)


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


## 设塞万提斯为 owner_id 机甲的机师，返回 {mech, enemy_mech, pilot_card, gs, cdb, te}；失败返回 null。
func _setup_cervantes(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_034_塞万提斯", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	return {"mech": mech, "enemy_mech": enemy_mech, "pilot_card": card, "gs": gs, "cdb": cdb, "te": battle.context.timing_engine}


## 构造 attack action（fire ATTACK_PRE/AFTER 用），已注册进 action_registry
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p034_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 构造 hp_change action（fire HP_CHANGE_AFTER 用），record 可带 source 字典
func _make_hp_change(battle, mech_ids: Array, value: int, method: StringName, reason: StringName, source: Dictionary) -> _Action:
	var hp_act := _Action.new()
	hp_act.action_id = &"test_p034_hp_%d" % [randi() % 1000000]
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
	hp_act.source = {"player_id": &"enemy"}
	battle.context.action_registry.register(hp_act)
	return hp_act


## 创建独立第三方机甲（效果伤害来源用），返回机甲；null 失败
func _create_third_mech(battle, mech_id: StringName, pos: Dictionary) -> _MechState:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：三个效果定义正确
func test_pilot_034_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_034_effect_01")
	if e1 == null:
		return "缺 pilot_034_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_01 listen_timing 应 ATTACK_AFTER"
	if int(e1.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e1.priority)
	if e1.listen_action_type != &"attack":
		return "effect_01 listen_action_type 应 attack"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	if not e1_ops.has("SELF_MECH_IS_ATTACK_TARGET"):
		return "effect_01 应含 SELF_MECH_IS_ATTACK_TARGET"
	if not e1_ops.has("ATTACK_BASE_DAMAGE_BELOW"):
		return "effect_01 应含 ATTACK_BASE_DAMAGE_BELOW"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "MODIFY_ATTACK_MARKERS":
		return "effect_01 actions 应 [MODIFY_ATTACK_MARKERS]"
	if int(e1_acts[0].get("params", {}).get("delta", 0)) != -1:
		return "effect_01 MODIFY_ATTACK_MARKERS delta 应 -1"
	var e2 = effects.get(&"pilot_034_effect_02")
	if e2 == null:
		return "缺 pilot_034_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.HP_CHANGE_AFTER:
		return "effect_02 listen_timing 应 HP_CHANGE_AFTER"
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10 实=%d" % int(e2.priority)
	if e2.listen_action_type != &"hp_change":
		return "effect_02 listen_action_type 应 hp_change"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	if not e2_ops.has("HP_CHANGE_TARGET_IS_SELF"):
		return "effect_02 应含 HP_CHANGE_TARGET_IS_SELF"
	if not e2_ops.has("HP_CHANGE_METHOD_IS"):
		return "effect_02 应含 HP_CHANGE_METHOD_IS"
	var e2_acts = e2.actions
	if e2_acts.size() != 1 or String(e2_acts[0].get("type", &"")) != "PILOT_034_RECORD_DAMAGE_SOURCE":
		return "effect_02 actions 应 [PILOT_034_RECORD_DAMAGE_SOURCE]"
	var e2b = effects.get(&"pilot_034_effect_02b")
	if e2b == null:
		return "缺 pilot_034_effect_02b"
	if e2b.mode != _TimingConst.MODE_LISTEN:
		return "effect_02b mode 应 LISTEN 实=%s" % String(e2b.mode)
	if e2b.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_02b listen_timing 应 ATTACK_AFTER"
	if int(e2b.priority) != 10:
		return "effect_02b priority 应 10 实=%d" % int(e2b.priority)
	if not bool(e2b.hide_button):
		return "effect_02b 应 hide_button=true（隐藏第3按钮）"
	if int(e2b.merge_desc_into_index) != 2:
		return "effect_02b merge_desc_into_index 应 2（描述合并到按钮2 hover）"
	var e2b_ops: Array = []
	for c in e2b.conditions:
		e2b_ops.append(String(c.get("op", &"")))
	for need in ["SELF_MECH_IS_ATTACKER", "ATTACK_HIT", "ATTACK_TARGET_IN_PILOT_034_RECORDED"]:
		if not e2b_ops.has(need):
			return "effect_02b 应含条件 %s" % need
	var e2b_acts = e2b.actions
	if e2b_acts.size() != 1 or String(e2b_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_02b actions 应 [CHOOSE_ONE]"
	var co_params: Dictionary = e2b_acts[0].get("params", {})
	if not bool(co_params.get("optional", false)):
		return "effect_02b CHOOSE_ONE 应 optional=true（弹窗确认可取消）"
	var options: Array = co_params.get("options", [])
	if options.size() != 1:
		return "effect_02b CHOOSE_ONE options 应1个"
	var opt_actions: Array = options[0].get("actions", [])
	if opt_actions.size() != 2:
		return "effect_02b option actions 应2个（敌方-3伤害 + 我方回复3）"
	var has_damage := false
	var has_heal := false
	for a in opt_actions:
		if String(a.get("type", &"")) == "EXECUTE_HP_CHANGE":
			var p: Dictionary = a.get("params", {})
			if String(p.get("method", &"")) == "decrease" and int(p.get("value", 0)) == 3 and String(p.get("reason", &"")) == "effect_damage":
				has_damage = true
			if String(p.get("method", &"")) == "restore" and int(p.get("value", 0)) == 3:
				has_heal = true
	if not has_damage:
		return "effect_02b 应含 decrease 3（效果伤害）动作"
	if not has_heal:
		return "effect_02b 应含 restore 3（回复我方）动作"
	return true


# ═══════════════════════════════════════════
# effect_01 损伤减免
# ═══════════════════════════════════════════

## 测试2：0伤害攻击（base_damage=0）命中我方 -> extra_markers -1（损伤-1）
func test_pilot_034_effect1_reduce_markers_on_zero_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_034_塞万提斯）"
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, s.enemy_mech.mech_id, s.mech.mech_id, &"enemy")
	attack.record["damage"] = 0
	attack.record["base_damage"] = 0  # 攻击本身0伤害（快照）
	attack.record["hit"] = true
	attack.record["markers"] = 2
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_markers", 0)) != -1:
		return "0伤害攻击应 extra_markers -1 实=%d" % int(attack.record.get("extra_markers", 0))
	return true


## 测试3：有伤害攻击（base_damage=5）命中我方 -> 不触发（extra_markers 不变）
func test_pilot_034_effect1_no_op_on_damaging_hit() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, s.enemy_mech.mech_id, s.mech.mech_id, &"enemy")
	attack.record["damage"] = 5
	attack.record["base_damage"] = 5
	attack.record["hit"] = true
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_markers", 0)) != 0:
		return "有伤害攻击不应触发 effect_01（extra_markers 应为0）实=%d" % int(attack.record.get("extra_markers", 0))
	return true


# ═══════════════════════════════════════════
# effect_02 铭记仇敌（记录伤害来源）
# ═══════════════════════════════════════════

## 测试4：攻击伤害 -> 记录 attacker 机甲（source_action_id -> attack.attacker_id）
func test_pilot_034_effect2_record_on_attack_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 攻击动作（注册进 action_registry），attacker = enemy
	var attack := _make_attack(battle, s.enemy_mech.mech_id, s.mech.mech_id, &"enemy")
	# 该攻击造成伤害 -> hp_change 的 source.source_action_id = 攻击 action_id（mech_id 空 = 攻击伤害）
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"attack_damage",
		{"source_action_id": attack.action_id, "mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_AFTER, hp_act)
	await _pump_frames(5)
	if not _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, s.enemy_mech.mech_id):
		return "攻击伤害应记录 enemy 机甲"
	return true


## 测试4b（真实链路回归）：attack 经 execute_sub_action 创建 hp_change（record 不含 source，
## 由 fire_timing 注入 action.source）-> 记录 attacker 机甲。
## 此前 payload.source 恒空（source 不在 record_keys），记录集永不填充、复仇反击完全没触发的根因。
func test_pilot_034_effect2_record_via_real_hp_change() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, s.enemy_mech.mech_id, s.mech.mech_id, &"enemy")
	var mech_hp0: int = s.mech.current_hp
	# 完全复刻 attack_action._step_apply_damage 的攻击伤害路径
	battle.context.action_service.execute_sub_action(
		{"type": &"EXECUTE_HP_CHANGE", "params": {
			"mech_ids": [s.mech.mech_id],
			"value": 3,
			"method": &"decrease",
			"reason": &"attack_damage",
			"created_by_attack_damage_step": true,
		}},
		{}, attack)
	await _pump_frames(8)
	if s.mech.current_hp != mech_hp0 - 3:
		return "hp_change 应扣血3 实=%d（原%d）" % [s.mech.current_hp, mech_hp0]
	if not _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, s.enemy_mech.mech_id):
		return "真实链路：攻击伤害应记录 enemy 机甲"
	return true


## 测试5：效果伤害（source.mech_id=第三方机甲）-> 记录该机甲
func test_pilot_034_effect2_record_on_effect_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	var third_mech := _create_third_mech(battle, &"third_mech_p034", {"q": 3, "r": 4})
	battle.context.action_ui_bridge.context = battle.context
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"effect_damage",
		{"mech_id": third_mech.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_AFTER, hp_act)
	await _pump_frames(5)
	if not _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, third_mech.mech_id):
		return "效果伤害应记录来源机甲"
	return true


## 测试6：陷阱/无来源 -> 不记录；自身来源 -> 不记录
func test_pilot_034_effect2_no_record_for_trap_or_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 陷阱：source_action_id 指向非 attack 动作（trap_explosion），mech_id 空 -> 无法解析来源
	var trap_act := _Action.new()
	trap_act.action_id = &"test_p034_trap_%d" % [randi() % 1000000]
	trap_act.action_type = &"trap_explosion"
	trap_act.record = {}
	trap_act.state = &"running"
	trap_act.context = battle.context
	battle.context.action_registry.register(trap_act)
	var hp_trap := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"trap_explosion",
		{"source_action_id": trap_act.action_id, "mech_id": &""})
	s.te.fire_timing(_TimingConst.HP_CHANGE_AFTER, hp_trap)
	await _pump_frames(5)
	if _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, &"any_mech"):
		return "陷阱伤害不应记录"
	if not _ActionPilotEffects._pilot_034_recorded.get(s.pilot_card.instance_id, {}).is_empty():
		return "陷阱伤害不应写入任何记录"
	# 自身来源：source.mech_id == 塞万提斯所属机甲 -> 排除（不记录自己）
	var hp_self := _make_hp_change(battle, [s.mech.mech_id], 3, &"decrease", &"effect_damage",
		{"mech_id": s.mech.mech_id})
	s.te.fire_timing(_TimingConst.HP_CHANGE_AFTER, hp_self)
	await _pump_frames(5)
	if _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, s.mech.mech_id):
		return "自身来源不应记录（排除自己）"
	return true


# ═══════════════════════════════════════════
# effect_02b 复仇反击（命中已记录机甲弹窗确认）
# ═══════════════════════════════════════════

## 测试7：对已记录机甲攻击命中 -> 弹窗确认 -> 确认后敌方 HP-3、我方 HP+3
func test_pilot_034_effect2b_confirm_extra_damage_and_heal() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 预置记录：enemy 曾对我方造成伤害
	_ActionPilotEffects.pilot_034_record_source(s.pilot_card.instance_id, s.enemy_mech.mech_id)
	if not _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, s.enemy_mech.mech_id):
		return "前置错误：应已记录 enemy"
	var enemy_hp0: int = s.enemy_mech.current_hp
	# 我方先受损，确保非满血才能观察到回复3（满血时 restore 被 clamp 到上限）
	s.mech.current_hp = max(0, s.mech.max_hp - 5)
	var self_hp0: int = s.mech.current_hp
	var attack := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	attack.record["base_damage"] = 5
	attack.record["hit"] = true
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state != &"waiting_timing":
		return "命中已记录机甲应挂起 CHOOSE_ONE（弹窗确认），state=%s" % String(attack.state)
	s.te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	if s.enemy_mech.current_hp != enemy_hp0 - 3:
		return "确认后敌方应-3 HP 实=%d（原%d）" % [s.enemy_mech.current_hp, enemy_hp0]
	if s.mech.current_hp != self_hp0 + 3:
		return "确认后我方应+3 HP 实=%d（原%d）" % [s.mech.current_hp, self_hp0]
	return true


## 测试8：对未记录机甲攻击命中 -> 不弹窗不触发
func test_pilot_034_effect2b_no_trigger_on_unrecorded() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 不预置记录
	if _ActionPilotEffects.pilot_034_is_recorded(s.pilot_card.instance_id, s.enemy_mech.mech_id):
		return "前置错误：enemy 不应已记录"
	var enemy_hp0: int = s.enemy_mech.current_hp
	var attack := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	attack.record["base_damage"] = 5
	attack.record["hit"] = true
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if attack.state == &"waiting_timing":
		return "对未记录机甲不应弹窗（state=%s）" % String(attack.state)
	if s.enemy_mech.current_hp != enemy_hp0:
		return "未记录机甲不应受到额外伤害"
	return true


## 测试9：对已记录机甲命中但取消弹窗 -> 无 HP 变化
func test_pilot_034_effect2b_cancel_no_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_cervantes(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_ActionPilotEffects.pilot_034_record_source(s.pilot_card.instance_id, s.enemy_mech.mech_id)
	var enemy_hp0: int = s.enemy_mech.current_hp
	var self_hp0: int = s.mech.current_hp
	var attack := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	attack.record["base_damage"] = 5
	attack.record["hit"] = true
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state != &"waiting_timing":
		return "命中已记录机甲应挂起 CHOOSE_ONE（optional 弹窗）"
	s.te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(8)
	if s.enemy_mech.current_hp != enemy_hp0:
		return "取消后敌方 HP 不应变化 实=%d（原%d）" % [s.enemy_mech.current_hp, enemy_hp0]
	if s.mech.current_hp != self_hp0:
		return "取消后我方 HP 不应变化 实=%d（原%d）" % [s.mech.current_hp, self_hp0]
	return true


## 测试10：静态记录集 helper（record/is/clear 按机师牌实例隔离）
func test_pilot_034_static_record_helpers() -> Variant:
	if _ActionPilotEffects.pilot_034_is_recorded(&"pilot_a", &"mech_x"):
		return "初始不应记录"
	_ActionPilotEffects.pilot_034_record_source(&"pilot_a", &"mech_x")
	if not _ActionPilotEffects.pilot_034_is_recorded(&"pilot_a", &"mech_x"):
		return "record 后应记录 mech_x"
	if _ActionPilotEffects.pilot_034_is_recorded(&"pilot_a", &"mech_y"):
		return "不应记录未写入的 mech_y"
	if _ActionPilotEffects.pilot_034_is_recorded(&"pilot_b", &"mech_x"):
		return "应按机师牌实例隔离（pilot_b 不应见 pilot_a 的记录）"
	_ActionPilotEffects.clear_pilot_034_recorded(&"pilot_a")
	if _ActionPilotEffects.pilot_034_is_recorded(&"pilot_a", &"mech_x"):
		return "clear 后应不再记录"
	return true
