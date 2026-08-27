## test_pilot_026_ivan.gd - 伊万（pilot_026，混乱 SR，cost 11）效果测试
##
## 伊万 3 效果（运行时机师效果走 ActionPilotEffects 新体系）：
##   effect_01（DIRECT 按钮1，每回合1次）「当作设陷」：消耗1点当前回合攻击数，视为使用出1张设陷。
##     按钮条件 IS_OWNER_MAIN_PHASE + ATTACK_COUNT_ABOVE(threshold 0 = 本回合还可攻击)；
##     cost SPEND_ATTACK_CHANCE；动作 ADD_STATUS SET_TRAP stacks 2（与实体设陷牌 set_trap_direct 一致）。
##     因伊万自带 effect_02，实际落地的 SET_TRAP 会被 GameActions.add_status 覆盖为 4 层。
##   effect_02（LISTEN 按钮2 置灰+悬停）「设陷4次机会」：我方使用的设陷 SET_TRAP 一律 4 层。
##     由 GameActions.add_status SET_TRAP 分支查 mech_has_pilot_effect(pilot_026_effect_02) 实现。
##   effect_03（LISTEN 按钮3 置灰+悬停）「陷阱不设损伤」：陷阱对我方仅造成伤害不设损伤。
##     由 trap_explosion_action 查 mech_has_pilot_effect(pilot_026_effect_03) 清零 tokens 实现。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90026
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


## 设伊万为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_026(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_026_伊万", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 触发伊万 effect_01（DIRECT 按钮）。无输入挂起，effect_fire 自动完成，返回 null。
func _fire_pilot_026_effect1(battle, pilot_card, mech, player_id: StringName) -> void:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_026_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_026_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)


## 读取机甲 SET_TRAP 状态层数（无则 0）
func _set_trap_stacks(mech) -> int:
	var st: Dictionary = mech.get_status(&"SET_TRAP")
	if st.is_empty():
		return 0
	return int(st.get("stacks", 0))


## 统计机甲所有槽位损伤（region + 装备牌双计）。注意 slot 是 MechSlotState 对象，走属性访问。
func _mech_total_damage(mech) -> int:
	var total: int = 0
	if mech.slots == null:
		return 0
	for sid: StringName in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		total += int(slot.region_damage_tokens)
		if slot.equipped_card != null:
			total += int(slot.equipped_card.damage_tokens)
	return total


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：effect_01/02/03 定义
func test_pilot_026_effect_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_026_effect_01")
	if e1 == null:
		return "缺 pilot_026_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_026_effect_01":
		return "once_per_turn_key 应 pilot_026_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（每回合1次）"
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "ATTACK_COUNT_ABOVE"]:
		if not ops.has(need):
			return "effect_01 应含条件 %s" % need
	var aca = e1.conditions.filter(func(c): return String(c.get("op", &"")) == "ATTACK_COUNT_ABOVE")
	if aca.size() == 1 and int(aca[0].get("params", {}).get("threshold", 0)) != 0:
		return "ATTACK_COUNT_ABOVE threshold 应 0（剩余攻击>0）"
	var costs: Array = e1.costs
	if costs.size() != 1 or String(costs[0].get("cost_type", &"")) != "SPEND_ATTACK_CHANCE":
		return "effect_01 costs 应 [SPEND_ATTACK_CHANCE]"
	var acts = e1.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "ADD_STATUS":
		return "effect_01 actions 应 [ADD_STATUS]"
	var st = acts[0].get("params", {})
	if st.get("status_type", &"") != &"SET_TRAP" or int(st.get("stacks", 0)) != 2:
		return "ADD_STATUS 应 SET_TRAP stacks 2"
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_026_effect_02")
	if e2 == null or e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 应 LISTEN（按钮2置灰）"
	if e2.listen_timing != &"" or not e2.actions.is_empty():
		return "effect_02 不应注册 listener（空时点+空动作，仅信息按钮）"
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_026_effect_03")
	if e3 == null or e3.mode != _TimingConst.MODE_LISTEN:
		return "effect_03 应 LISTEN（按钮3置灰）"
	if e3.listen_timing != &"" or not e3.actions.is_empty():
		return "effect_03 不应注册 listener（空时点+空动作，仅信息按钮）"
	return true


# ═══════════════════════════════════════════
# helper：mech_has_pilot_effect（效果2/3通用判定）
# ═══════════════════════════════════════════

## 测试2：mech_has_pilot_effect 按 effect_id 判定（绑定效果而非机师）
func test_pilot_026_mech_has_pilot_effect_helper() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	# 未设机师：任何机甲都应 false
	if _ActionPilotEffects.mech_has_pilot_effect(battle.context, &"player_mech", &"pilot_026_effect_02"):
		return "未设机师时 mech_has_pilot_effect 应 false"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_026_伊万）"
	var ivan_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 伊万机甲：effect_02/03 均 true
	if not _ActionPilotEffects.mech_has_pilot_effect(battle.context, ivan_mech.mech_id, &"pilot_026_effect_02"):
		return "伊万机甲应有 effect_02"
	if not _ActionPilotEffects.mech_has_pilot_effect(battle.context, ivan_mech.mech_id, &"pilot_026_effect_03"):
		return "伊万机甲应有 effect_03"
	# 敌机（无机师）：false
	if _ActionPilotEffects.mech_has_pilot_effect(battle.context, enemy_mech.mech_id, &"pilot_026_effect_02"):
		return "无机师机甲不应有 effect_02"
	# 不存在的机甲：false（不崩溃）
	if _ActionPilotEffects.mech_has_pilot_effect(battle.context, &"no_such_mech", &"pilot_026_effect_02"):
		return "不存在机甲应 false"
	return true


# ═══════════════════════════════════════════
# 效果2：设陷4次机会（add_status SET_TRAP 分支）
# ═══════════════════════════════════════════

## 测试3：add_status SET_TRAP 伊万=4层 / 无机师=2层
func test_pilot_026_effect2_trap_stacks() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var ivan_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var ga = battle.context.game_actions
	# 伊万机甲施加2层 -> 应覆盖为4层
	ga.add_status({"target_id": ivan_mech.mech_id, "status": {"type": &"SET_TRAP", "stacks": 2}})
	if _set_trap_stacks(ivan_mech) != 4:
		return "伊万机甲 SET_TRAP 应4层，实际 %d" % _set_trap_stacks(ivan_mech)
	# 叠加：伊万再加2层 -> 4+4=8
	ga.add_status({"target_id": ivan_mech.mech_id, "status": {"type": &"SET_TRAP", "stacks": 2}})
	if _set_trap_stacks(ivan_mech) != 8:
		return "伊万叠加 SET_TRAP 应8层，实际 %d" % _set_trap_stacks(ivan_mech)
	# 无机师机甲：2层原样
	ga.add_status({"target_id": enemy_mech.mech_id, "status": {"type": &"SET_TRAP", "stacks": 2}})
	if _set_trap_stacks(enemy_mech) != 2:
		return "无机师机甲 SET_TRAP 应2层，实际 %d" % _set_trap_stacks(enemy_mech)
	return true


# ═══════════════════════════════════════════
# 效果1：当作设陷
# ═══════════════════════════════════════════

## 测试4：效果1全流程 - 消耗1点攻击数 + SET_TRAP 落地（因伊万带 effect_02 实为4层）
func test_pilot_026_effect1_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	if int(mech.attack_count_this_turn) != 0:
		return "初始攻击计数应0"
	await _fire_pilot_026_effect1(battle, s.card, mech, &"player")
	if int(mech.attack_count_this_turn) != 1:
		return "效果1应消耗1点攻击数，实际 %d" % int(mech.attack_count_this_turn)
	if _set_trap_stacks(mech) != 4:
		return "效果1落地 SET_TRAP 应4层（效果2覆盖），实际 %d" % _set_trap_stacks(mech)
	return true


## 测试5：效果1每回合1次 - 第1次生效；重置攻击数后第2次被 once_per_turn_max=1 拦截
func test_pilot_026_effect1_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	# 第1次
	await _fire_pilot_026_effect1(battle, s.card, mech, &"player")
	if int(mech.attack_count_this_turn) != 1:
		return "第1次应消耗1点攻击数，实际 %d" % int(mech.attack_count_this_turn)
	if _set_trap_stacks(mech) != 4:
		return "第1次应 SET_TRAP 4层，实际 %d" % _set_trap_stacks(mech)
	# 重置攻击数（隔离 once_per_turn：此时条件 ATTACK_COUNT_ABOVE 恢复通过，仅 once_per_turn 拦）
	mech.attack_count_this_turn = 0
	await _fire_pilot_026_effect1(battle, s.card, mech, &"player")
	if int(mech.attack_count_this_turn) != 0:
		return "第2次应被 once_per_turn 拦截（不消耗攻击数），实际 %d" % int(mech.attack_count_this_turn)
	if _set_trap_stacks(mech) != 4:
		return "第2次不应再设陷（仍4层），实际 %d" % _set_trap_stacks(mech)
	return true


## 测试6：效果1条件 gate（can_trigger_active_effect：主阶段+己方回合+剩余攻击>0）
func test_pilot_026_effect1_condition_gates() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var te = battle.context.timing_engine
	var eff_01 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_026_effect_01")
	var bind_ctx: Dictionary = {}
	var found: bool = false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == "pilot_026_effect_01":
				bind_ctx = entry.get("binding_context", {})
				found = true
				break
		if found:
			break
	if not found:
		return "effect_01 应已注册 permanent listener（pilot_026_effect_01 虚拟时点）"
	# 己方主阶段 + 剩余攻击>0 -> 可用
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	mech.attack_count_this_turn = 0
	if not te.can_trigger_active_effect(eff_01, bind_ctx):
		return "己方主阶段+剩余攻击应可用"
	# 攻击用满（剩余0）-> 不可用
	mech.attack_count_this_turn = int(mech.max_attacks_per_turn)
	if te.can_trigger_active_effect(eff_01, bind_ctx):
		return "剩余攻击0不应可用"
	# 恢复攻击数；非己方回合 -> 不可用
	mech.attack_count_this_turn = 0
	gs.active_player_id = &"enemy"
	if te.can_trigger_active_effect(eff_01, bind_ctx):
		return "非己方回合不应可用"
	# 回己方回合；非主阶段 -> 不可用
	gs.active_player_id = &"player"
	gs.phase = &"PLAYER_SETUP"
	if te.can_trigger_active_effect(eff_01, bind_ctx):
		return "非主阶段不应可用"
	return true


# ═══════════════════════════════════════════
# 效果3：陷阱不设损伤
# ═══════════════════════════════════════════

## 测试7：陷阱爆炸对伊万机甲仅造成HP伤害，不设损伤（tokens清零）
func test_pilot_026_effect3_trap_no_tokens() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_026(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var ctx = battle.context
	var player_mech = s.mech
	# 敌机移远（隔离：确保爆炸只波及伊万机甲）
	gs.get_mech_for_player(&"enemy").position = {"q": 20, "r": 3}
	var target := _HexGrid.neighbors(player_mech.position)[0]
	gs.map_state.add_marker(gs.next_id(&"marker"), int(target.q), int(target.r), &"TRAP")
	var hp_before: int = player_mech.current_hp
	var tokens_before: int = _mech_total_damage(player_mech)
	# 触发陷阱（tokens=0 -> 仅 hp_change 子动作同步完成，trap_explosion 可能当帧完成即被清理，
	# 不依赖查 action_registry，直接 pump 后断言结算结果）
	ctx.map_service._check_map_markers(player_mech, target)
	if not gs.map_state.get_markers_at(int(target.q), int(target.r)).is_empty():
		return "陷阱触发后应被移除"
	var guard: int = 0
	while guard < 30:
		guard += 1
		await _pump_frames(1)
		var expls: Array = ctx.action_registry.get_actions_by_type(&"trap_explosion")
		if expls.is_empty():
			break  # 已完成并清理
		var ta = expls[0]
		if ta.state == &"completed" or ta.state == &"cancelled":
			break
		if ta.state == &"waiting_effect_action":
			var pending: Array = ta.pending_effect_action_ids.duplicate()
			if pending.is_empty():
				ctx.action_engine.continue_action(ta.action_id, {})
			else:
				for cid: StringName in pending:
					ctx.action_engine.notify_effect_action_completed(cid, ta.action_id)
	if player_mech.current_hp != hp_before - 2:
		return "陷阱爆炸应使伊万机甲HP-2（前%d 后%d）" % [hp_before, player_mech.current_hp]
	if _mech_total_damage(player_mech) != tokens_before:
		return "陷阱爆炸不应给伊万机甲设损伤（前%d 后%d）" % [tokens_before, _mech_total_damage(player_mech)]
	return true
