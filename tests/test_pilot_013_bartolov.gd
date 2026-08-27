## test_pilot_013_bartolov.gd - 巴托洛夫（pilot_013）效果测试
##
## 巴托洛夫 2 按钮（被动融合）：
##   effect_01（非攻击伤害免疫）：LISTEN HP_CHANGE_BEFORE，攻击伤害外的生命减少一律取消（HP不变），
##       不阻止损伤。靠 reason=attack_damage / created_by_attack_damage_step 判定攻击伤害。
##   effect_02a（同归压制）：LISTEN ATTACK_PRE priority30，每回合1次，弹窗询问是否发动；
##       确认后自身+全部机甲目标护甲/动力-4（护甲 ARMOR_MODIFIER + 动力 POWER_CAP_MODIFIER 均
##       UNTIL_NEXT_OWNER_TURN 到期恢复；动力当前-4 经下回合 restore_power 回满）。写 flag。
##   effect_02b（命中伤害追加，隐藏合并到 02a）：LISTEN ATTACK_AFTER priority20，**不用 requires_effect**
##       （双连 fork 子动作 action_id 不同 -> 失效），纯靠 flag（fork 深拷贝继承）判定，命中目标伤害+3。
##
## 关键修复点（本测试覆盖）：
##   1. effect_01 created_by_attack_damage_step 权威标记（attack 步骤7 写入，_extract 提取）。
##   2. 护甲-4 到期恢复（modify_armor 加 duration_owner_id，_clean_until_next_owner_turn 清 ARMOR_MODIFIER）。
##   3. 02a priority 30 + CHOOSE_ONE title/description 显示效果简介。
##   4. 02b 去掉 requires_effect，纯靠 flag -> 双连每个 fork AFTER 都能触发 +3。
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
	battle.rng_seed = 90013
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


## 设巴托洛夫为 owner_id 机甲的机师，返回 {mech, enemy_mech, pilot_card, gs, cdb}；失败返回 null。
func _setup_bartolov(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_013_巴托洛夫", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 attack action（fire ATTACK_PRE/AFTER 用）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p013_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 创建第 2 台敌方机甲（敌方阵营），放在指定位置，6 部件槽（无装备，护甲=0）。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary) -> MechState:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"enemy"
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
# effect_01 定义 + 行为
# ═══════════════════════════════════════════

## 测试1：effect_01 定义（LISTEN HP_CHANGE_BEFORE priority30，CANCEL_PARENT_ACTION CURRENT_ACTION）
func test_pilot_013_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_013_effect_01")
	if e == null:
		return "缺 pilot_013_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.HP_CHANGE_BEFORE:
		return "effect_01 listen_timing 应 HP_CHANGE_BEFORE"
	if int(e.priority) != 30:
		return "effect_01 priority 应 30 实=%d" % int(e.priority)
	if e.listen_action_type != &"hp_change":
		return "effect_01 listen_action_type 应 hp_change"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("HP_CHANGE_TARGET_IS_SELF"):
		return "effect_01 应含 HP_CHANGE_TARGET_IS_SELF"
	if not ops.has("HP_CHANGE_METHOD_IS"):
		return "effect_01 应含 HP_CHANGE_METHOD_IS"
	if not ops.has("HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE"):
		return "effect_01 应含 HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CANCEL_PARENT_ACTION":
		return "effect_01 actions 应 [CANCEL_PARENT_ACTION]"
	if String(acts[0].get("params", {}).get("scope", &"")) != "CURRENT_ACTION":
		return "effect_01 CANCEL_PARENT_ACTION scope 应 CURRENT_ACTION"
	return true


## 测试2：effect_01 非攻击伤害免疫（reason=effect_damage -> HP 不变）
func test_pilot_013_effect_01_immune_non_attack_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_013_巴托洛夫）"
	var mech = s.mech
	var hp_before: int = mech.current_hp
	battle.context.action_ui_bridge.context = battle.context
	# 非攻击伤害（reason=effect_damage）-> effect_01 免疫，HP 不变
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [mech.mech_id],
		"value": 3,
		"method": &"decrease",
		"reason": &"effect_damage",
	})
	await _pump_frames(5)
	if mech.current_hp != hp_before:
		return "非攻击伤害应被免疫（HP 不变）实=%d（原%d）" % [mech.current_hp, hp_before]
	return true


## 测试3：effect_01 攻击伤害不免疫（reason=attack_damage -> HP-3）
func test_pilot_013_effect_01_attack_damage_not_immune() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	var hp_before: int = mech.current_hp
	battle.context.action_ui_bridge.context = battle.context
	# 攻击伤害（reason=attack_damage）-> effect_01 不免疫，HP-3
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [mech.mech_id],
		"value": 3,
		"method": &"decrease",
		"reason": &"attack_damage",
	})
	await _pump_frames(5)
	if mech.current_hp != hp_before - 3:
		return "攻击伤害不应被免疫（HP-3）实=%d（原%d）" % [mech.current_hp, hp_before]
	return true


## 测试3b：effect_01 created_by_attack_damage_step 权威标记 -- 即使 reason=effect_damage（本免疫），标记让不免疫
## 验证 attack 步骤7 写入的 created_by_attack_damage_step 标记权威判定为攻击伤害（ConditionChecker 行1891 优先于 reason）。
func test_pilot_013_effect_01_created_by_attack_marker_not_immune() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	# 手动构造 hp_change action（仿 attack 步骤7 走 sub_action 经 _extract 注入 created_by_attack_damage_step）
	var hp_act := _Action.new()
	hp_act.action_id = &"test_p013_hp_%d" % [randi() % 1000000]
	hp_act.action_type = &"hp_change"
	hp_act.record = {
		"mech_ids": [mech.mech_id],
		"value": 3,
		"method": &"decrease",
		"reason": &"effect_damage",  # 本应免疫
		"created_by_attack_damage_step": true,  # 权威标记：来自攻击步骤7 -> 不免疫
	}
	hp_act.state = &"running"
	hp_act.context = battle.context
	hp_act.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(hp_act)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.HP_CHANGE_BEFORE, hp_act)
	await _pump_frames(5)
	# created_by_attack_damage_step 标记 -> effect_01 条件 HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE 返回 false
	# -> effect_01 不触发 CANCEL -> state 不变 cancelled
	if hp_act.state == &"cancelled":
		return "created_by_attack_damage_step 标记应让 effect_01 不免疫（不 CANCEL）state=%s" % String(hp_act.state)
	return true


## 测试4：effect_01 陷阱伤害免疫（reason=trap_explosion -> HP 不变）
func test_pilot_013_effect_01_immune_trap_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	var hp_before: int = mech.current_hp
	battle.context.action_ui_bridge.context = battle.context
	# 陷阱爆炸伤害（reason=trap_explosion）-> effect_01 免疫
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [mech.mech_id],
		"value": 3,
		"method": &"decrease",
		"reason": &"trap_explosion",
	})
	await _pump_frames(5)
	if mech.current_hp != hp_before:
		return "陷阱伤害应被免疫（HP 不变）实=%d（原%d）" % [mech.current_hp, hp_before]
	return true


# ═══════════════════════════════════════════
# effect_02a 定义 + 行为
# ═══════════════════════════════════════════

## 测试5：effect_02a 定义（LISTEN ATTACK_PRE priority30，CHOOSE_ONE optional+title/description，stat_changes+flag）
func test_pilot_013_effect_02a_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_013_effect_02a")
	if e == null:
		return "缺 pilot_013_effect_02a"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "02a mode 应 LISTEN"
	if e.listen_timing != _TimingConst.ATTACK_PRE:
		return "02a listen_timing 应 ATTACK_PRE"
	if int(e.priority) != 30:
		return "02a priority 应 30 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "02a listen_action_type 应 attack"
	if e.once_per_turn_key != &"pilot_013_effect_02":
		return "02a once_per_turn_key 应 pilot_013_effect_02"
	if int(e.once_per_turn_max) != 1:
		return "02a once_per_turn_max 应 1"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "02a 应含 SELF_MECH_IS_ATTACKER"
	if not ops.has("ATTACK_HAS_OTHER_MECH_TARGET"):
		return "02a 应含 ATTACK_HAS_OTHER_MECH_TARGET"
	if String(e.target_rules[0].get("rule", &"")) != "ALL_CURRENT_ATTACK_MECH_TARGETS":
		return "02a target_rule 应 ALL_CURRENT_ATTACK_MECH_TARGETS"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "02a actions 应 [CHOOSE_ONE]"
	var params: Dictionary = acts[0].get("params", {})
	if not bool(params.get("optional", false)):
		return "02a CHOOSE_ONE 应 optional=true"
	# 弹窗显示效果简介（title + description）
	if String(params.get("title", &"")) == "":
		return "02a CHOOSE_ONE 应有 title（效果简介）"
	if String(params.get("description", &"")) == "":
		return "02a CHOOSE_ONE 应有 description（效果简介）"
	var options = params.get("options", [])
	if options.size() != 1:
		return "02a CHOOSE_ONE options 应1个"
	var opt_actions: Array = options[0].get("actions", [])
	var has_stat_modify_self := false
	var has_fet := false
	var has_flag := false
	for a in opt_actions:
		var at: String = String(a.get("type", &""))
		if at == "EXECUTE_STAT_MODIFY":
			has_stat_modify_self = true
		if at == "FOR_EACH_TARGET":
			has_fet = true
		if at == "SET_ACTION_RECORD_FLAG" and String(a.get("params", {}).get("flag", &"")) == "pilot_013_effect_02_fired":
			has_flag = true
	if not has_stat_modify_self:
		return "02a 应含 EXECUTE_STAT_MODIFY(自身)"
	if not has_fet:
		return "02a 应含 FOR_EACH_TARGET(目标)"
	if not has_flag:
		return "02a 应含 SET_ACTION_RECORD_FLAG(pilot_013_effect_02_fired)"
	return true


## 测试6：02a 发动后自身+目标护甲/动力-4（弹窗确认发动）
func test_pilot_013_effect_02a_apply_debuff() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 确保满动力（current_only 减本身动力，clamp[0,max]）
	mech.power = mech.max_power
	enemy_mech.power = enemy_mech.max_power
	var armor0: int = mech.get_armor()
	var maxp0: int = mech.max_power
	var power0: int = mech.power
	var e_armor0: int = enemy_mech.get_armor()
	var e_maxp0: int = enemy_mech.max_power
	var e_power0: int = enemy_mech.power

	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "02a 应在 ATTACK_PRE 挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(10)
	# 自身护甲-4, 动力上限-4, 当前动力-4
	if mech.get_armor() != armor0 - 4:
		return "自身护甲应-4 实=%d->%d" % [armor0, mech.get_armor()]
	if mech.max_power != maxp0 - 4:
		return "自身动力上限应-4 实=%d->%d" % [maxp0, mech.max_power]
	if mech.power != power0 - 4:
		return "自身当前动力应-4 实=%d->%d" % [power0, mech.power]
	# 目标护甲-4, 动力上限-4, 当前动力-4
	if enemy_mech.get_armor() != e_armor0 - 4:
		return "目标护甲应-4 实=%d->%d" % [e_armor0, enemy_mech.get_armor()]
	if enemy_mech.max_power != e_maxp0 - 4:
		return "目标动力上限应-4 实=%d->%d" % [e_maxp0, enemy_mech.max_power]
	if enemy_mech.power != e_power0 - 4:
		return "目标当前动力应-4 实=%d->%d" % [e_power0, enemy_mech.power]
	# flag 已写
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if not bool(flags.get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "02a 发动应写 flag pilot_013_effect_02_fired"
	return true


## 测试7：02a 到期恢复（护甲+动力上限恢复，当前动力 restore_power 回满）
func test_pilot_013_effect_02a_expire_restore() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	mech.power = mech.max_power
	enemy_mech.power = enemy_mech.max_power
	var armor0: int = mech.get_armor()
	var maxp0: int = mech.max_power
	var e_armor0: int = enemy_mech.get_armor()
	var e_maxp0: int = enemy_mech.max_power

	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(10)
	# 前置：发动后已-4
	if mech.get_armor() != armor0 - 4 or mech.max_power != maxp0 - 4:
		return "前置错误：发动后自身护甲/上限应-4"
	if enemy_mech.get_armor() != e_armor0 - 4 or enemy_mech.max_power != e_maxp0 - 4:
		return "前置错误：发动后目标护甲/上限应-4"
	# 模拟 player 下回合开始：_clean_until_next_owner_turn 清 ARMOR_MODIFIER + POWER_CAP_MODIFIER，
	# 随后 restore_power 回满当前动力。
	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(3)
	# 自身护甲恢复（ARMOR_MODIFIER 移除）
	if mech.get_armor() != armor0:
		return "到期后自身护甲应恢复 实=%d（原%d）" % [mech.get_armor(), armor0]
	# 自身动力上限恢复 + 当前动力回满
	if mech.max_power != maxp0:
		return "到期后自身动力上限应恢复 实=%d（原%d）" % [mech.max_power, maxp0]
	if mech.power != maxp0:
		return "到期后自身当前动力应回满 实=%d（应%d）" % [mech.power, maxp0]
	# 目标护甲恢复（目标非 duration_owner，但其 ARMOR_MODIFIER 也带 duration_owner_id=player，
	# player 回合开始时同样清理）
	if enemy_mech.get_armor() != e_armor0:
		return "到期后目标护甲应恢复 实=%d（原%d）" % [enemy_mech.get_armor(), e_armor0]
	if enemy_mech.max_power != e_maxp0:
		return "到期后目标动力上限应恢复 实=%d（原%d）" % [enemy_mech.max_power, e_maxp0]
	return true


# ═══════════════════════════════════════════
# effect_02b 定义 + 行为
# ═══════════════════════════════════════════

## 测试8：effect_02b 定义（LISTEN ATTACK_AFTER priority20，无 requires_effect，flag 条件+MODIFY_ATTACK_DAMAGE+3）
func test_pilot_013_effect_02b_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_013_effect_02b")
	if e == null:
		return "缺 pilot_013_effect_02b"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "02b mode 应 LISTEN"
	if e.listen_timing != _TimingConst.ATTACK_AFTER:
		return "02b listen_timing 应 ATTACK_AFTER"
	if int(e.priority) != 20:
		return "02b priority 应 20 实=%d" % int(e.priority)
	# 关键：不应有 requires_effect（双连 fork 子动作 id 不同 -> 失效）
	if e.requires_effect != &"":
		return "02b 不应有 requires_effect（fork 失效根因）实=%s" % String(e.requires_effect)
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "02b 应含 SELF_MECH_IS_ATTACKER"
	if not ops.has("RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT"):
		return "02b 应含 RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT"
	if String(e.target_rules[0].get("rule", &"")) != "ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG":
		return "02b target_rule 应 ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "FOR_EACH_TARGET":
		return "02b actions 应 [FOR_EACH_TARGET]"
	var inner: Array = acts[0].get("params", {}).get("actions", [])
	if inner.size() != 1 or String(inner[0].get("type", &"")) != "MODIFY_ATTACK_DAMAGE":
		return "02b FOR_EACH_TARGET inner 应 [MODIFY_ATTACK_DAMAGE]"
	if int(inner[0].get("params", {}).get("delta", 0)) != 3:
		return "02b MODIFY_ATTACK_DAMAGE delta 应 3"
	return true


## 测试9：02b 命中伤害+3（flag 已设 + 命中 -> damage+3）
func test_pilot_013_effect_02b_hit_damage_plus3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 构造已命中 + 02a 已发动(flag) 的攻击
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	attack.record["hit"] = true
	attack.record["_effect_flags"] = {"pilot_013_effect_02_fired": {
		"value": true,
		"data": {"affected_target_ids": [enemy_mech.mech_id], "self_mech_id": mech.mech_id, "limit_counted_per_attack": true},
	}}
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("damage", 0)) != 8:
		return "命中伤害应+3（5->8）实=%d" % int(attack.record.get("damage", 0))
	return true


## 测试10：02b 无 flag（02a 未发动）-> 不触发（伤害不变）
func test_pilot_013_effect_02b_no_trigger_without_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["damage"] = 5
	attack.record["hit"] = true
	# 不设 _effect_flags（02a 未发动）
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("damage", 0)) != 5:
		return "无 flag 时 02b 不应触发（伤害不变）实=%d" % int(attack.record.get("damage", 0))
	return true


# ═══════════════════════════════════════════
# 双连 fork flag 继承测试（核心修复点）
# ═══════════════════════════════════════════

## 测试11：主攻击 PRE 02a 写 flag -> fork 深拷贝继承 -> fork AFTER 02b 触发 +3
## 验证去 requires_effect 后纯靠 flag，双连每个 fork AFTER 都能触发命中伤害+3。
func test_pilot_013_fork_flag_inherited_02b_fires() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 第2台敌方机甲（fork 的目标）
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech_p013", {"q": 2, "r": 3})
	battle.context.action_ui_bridge.context = battle.context

	# ── 主攻击 PRE：02a 发动写 flag（affected_target_ids 含两个目标）──
	var main_attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, main_attack)
	te.resume_pending_effect(main_attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(10)
	if not bool(main_attack.record.get("_effect_flags", {}).get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "前置错误：主攻击 02a 应写 flag"
	# 注：02b 的 ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG / RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT 收集的是
	# attack.record 的 target_id/target_ids（非 flag.data.affected_target_ids），故 fork 改 target_id 即可。

	# ── 模拟 fork：深拷贝主攻击 record（仿 attack_action _create_fork_sub_action 的 record.duplicate(true)）──
	var fork_attack := _Action.new()
	fork_attack.action_id = &"test_p013_fork_%d" % [randi() % 1000000]
	fork_attack.action_type = &"attack"
	fork_attack.record = main_attack.record.duplicate(true)  # 深拷贝继承 flag
	fork_attack.record["target_id"] = enemy2_mech.mech_id
	fork_attack.record["hit"] = true
	fork_attack.record["damage"] = 5
	fork_attack.state = &"running"
	fork_attack.context = battle.context
	fork_attack.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(fork_attack)

	# ── fork AFTER：02b 应因 flag 继承而触发 +3 ──
	te.fire_timing(_TimingConst.ATTACK_AFTER, fork_attack)
	await _pump_frames(5)
	if int(fork_attack.record.get("damage", 0)) != 8:
		return "fork AFTER 02b 应+3（5->8，flag 深拷贝继承）实=%d" % int(fork_attack.record.get("damage", 0))
	# fork 的 flag 应仍存在（深拷贝独立于主攻击）
	if not bool(fork_attack.record.get("_effect_flags", {}).get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "fork record 应继承 flag（深拷贝）"
	return true


# ═══════════════════════════════════════════
# 每回合1次
# ═══════════════════════════════════════════

## 测试12：02a 每回合1次 -- 同回合第2次攻击 02a 不触发
func test_pilot_013_once_per_turn_second_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bartolov(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 第1次：02a 发动消耗额度
	var attack1 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack1)
	te.resume_pending_effect(attack1.action_id, {"chosen_option_index": 0})
	await _pump_frames(10)
	if not bool(attack1.record.get("_effect_flags", {}).get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "前置错误：第1次 02a 应写 flag"
	# 第2次（同回合）：02a 应因 once_per_turn 已用满而跳过（不挂起）
	var attack2 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	if attack2.state == &"waiting_timing":
		return "同回合第2次 02a 应因 once_per_turn 已用满而跳过（不挂起）"
	if bool(attack2.record.get("_effect_flags", {}).get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "第2次 02a 未发动不应写 flag"
	return true
