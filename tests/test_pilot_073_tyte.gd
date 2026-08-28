## test_pilot_073_tyte.gd - 泰特（pilot_073，帝国 N）效果测试
##
## 泰特 2 按钮（DIRECT 主动）+ 4 隐藏 LISTEN：
##   effect_01（按钮1，每回合3次）「近战弃1+3威力」：弃置1张行动牌 → 本回合下次近战武器攻击威力+3
##     （可叠加）。动作链：CHOOSE_MANY_CARDS(选1行动牌, 可取消, 确认计次) → EXECUTE_DISCARD →
##     ACCUMULATE_MELEE_MIGHT(本机甲+3)。待发威力按 (来源牌实例, 机甲) 存 _melee_buff。
##     隐藏 LISTEN（并入按钮1悬停）：
##       · apply（ATTACK_BEFORE，自己近战攻击）：APPLY_MELEE_MIGHT 读 _melee_buff → attack.record.extra_might+。
##       · consume（ATTACK_SETTLE，近战结算）：CLEAR_MELEE_MIGHT 消耗（取消攻击保留）。
##       · turnend（TURN_AFTER_END，自己回合结束）：CLEAR_MELEE_MIGHT 清空"本回合"待发。
##   effect_02（按钮2，每回合1次）「授予他机获效」：CHOOSE_OTHER_MECH 选1台其他机甲 →
##     GRANT_MELEE_MIGHT 向目标机甲注册 DIRECT(虚拟时点 pilot_073_effect_01)+3隐藏LISTEN（binding granted=true，
##     EX 按钮）。隐藏 LISTEN（并入按钮2悬停）：expire（TURN_AFTER_START，自己回合开始后）→
##     EXPIRE_MELEE_MIGHT 注销全部授予 + 清待发威力（EX 消失）。
##
## 通用模块："近战弃牌威力"（_melee_buff/_melee_grant_mechs registry + add/get/clear_melee_buff +
##   grant_melee_might_to_mech/expire_melee_might_grants），与效果绑定不绑机师。
##
## 关键覆盖点：
##   1. 效果定义结构（两 DIRECT + once_per_turn_max 3/1 + 条件 + 动作链 + 4 隐藏 LISTEN 定义）。
##   2. 完整流程：弃1行动牌 → _melee_buff[泰特cid][泰特mech] = 3。
##   3. 取消选牌 → 中止不弃不累加不消耗次数（可再触发）。
##   4. 每回合3次用满 → 第4次跳过。
##   5. 近战攻击（真实 AttackAction）：ATTACK_BEFORE 应用 extra_might+3，选目标前生效。
##   6. 非近战攻击：不应用不消耗（远程 effective_weapon_type 下 extra_might 保持0、buff 保持3）。
##   7. 近战结算（ATTACK_SETTLE）：buff 消耗清0。
##   8. 自己回合结束后（TURN_AFTER_END）：待发 buff 清空。
##   9. effect_02 授予他机：permanent_listeners 注册 granted=true 条目 + _melee_grant_mechs 记录 +
##      他机在自己回合可用 EX 按钮弃牌累积 buff。
##  10. 来源下回合开始后（TURN_AFTER_START）：授予注销（EX 消失）+ 待发清空，泰特自身监听器保留。
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
	battle.rng_seed = 90074
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


func _frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
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


## 设法尔科为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, battle, enemy_mech}；失败返回空字典。
## 同时：双方玩家设 is_human=true（弹窗/弃牌走人类路径，AI 会跳过）且清空该来源牌实例的静态
## "近战弃牌威力"状态（battle 实例 id 确定性一致，静态 registry 跨测试会串扰）。
func _setup_taite(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_073_泰特", owner_id)
	if card == null:
		return {}
	_ActionPilotEffects.clear_melee_might_for_source(card.instance_id)
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	for pid: StringName in gs.players:
		gs.players.get(pid).is_human = true
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "battle": battle,
			"enemy_mech": gs.get_mech_for_player(&"enemy")}


## 给玩家行动手牌补一张行动牌（可用），返回实例 id
func _add_action_to_hand(battle, pid: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, "action_001_进攻", pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 触发泰特 effect_01 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_073_effect1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_073_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_073_effect_01",
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


## 触发泰特 effect_02 DIRECT 按钮（effect_fire，CHOOSE_OTHER_MECH 目标选择），返回挂起 action
func _fire_pilot_073_effect2(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_073_effect_02",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_073_effect_02",
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


## resume 选弃窗（确认：弃牌 + 累积威力，无后续弹窗）
func _resume_discard(battle, ef, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": selected})
	await _pump_frames(12)


## resume 取消选弃窗（中止，不消耗次数）
func _resume_cancel(battle, ef) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)


## resume 目标选择（effect_02 授予他机）
func _resume_target(battle, ef, target_mech_id: StringName) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"target_id": target_mech_id})
	await _pump_frames(10)


## 检查 cid 是否在行动弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 收集所有残留的 waiting 动作（卡死判定）
func _waiting_actions(ctx) -> Array:
	var waiting: Array = []
	for aid: StringName in ctx.action_registry.get_active_ids():
		var a = ctx.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	return waiting


## 合成 turn 动作并 fire 一个回合时点（TURN_AFTER_END / TURN_AFTER_START 等）
func _fire_turn_timing(battle, timing: StringName) -> void:
	var ctx = battle.context
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p074_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": &"player"}
	turn_action.state = &"running"
	turn_action.context = ctx
	ctx.action_registry.register(turn_action)
	ctx.timing_engine.fire_timing(timing, turn_action)


## 合成 attack 动作并 fire 攻击时点（ATTACK_BEFORE / ATTACK_SETTLE），用于非近战不触发的条件判定
func _fire_synth_attack_timing(battle, attacker_mech, timing: StringName, eff_kind: StringName) -> _Action:
	var ctx = battle.context
	var atk_action := _Action.new()
	atk_action.action_id = &"test_p074_atk_%d" % [randi() % 1000000]
	atk_action.action_type = &"attack"
	atk_action.record = {
		"attacker_id": attacker_mech.mech_id,
		"effective_weapon_type": eff_kind,
		"weapon_kind": eff_kind,
	}
	atk_action.state = &"running"
	atk_action.context = ctx
	ctx.action_registry.register(atk_action)
	ctx.timing_engine.fire_timing(timing, atk_action)
	await _pump_frames(6)
	return atk_action


## 某时点 × 某效果 id 的永久监听器绑定机甲列表（grant/expire 检查 EX 注册与注销）
func _perm_listener_mechs(ctx, timing: StringName, effect_id: StringName) -> Array:
	var out: Array = []
	var tl: Dictionary = ctx.timing_engine.permanent_listeners
	if not tl.has(timing):
		return out
	for entry: Dictionary in tl[timing]:
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == String(effect_id):
			var bc: Dictionary = entry.get("binding_context", {})
			out.append(String(bc.get("mech_id", &"")))
	return out


# ═══════════════════════════════════════════
# 输入驱动器：标准输入自动回填（真实攻击流程）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class Driver:
	var context = null
	var pending: Dictionary = {}
	var popups: Array = []
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		if context.action_engine != null:
			context.action_engine.action_needs_input.connect(_on_need)
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
		if _STD_INPUTS.has(input_type):
			pending[action_id] = {"input_type": input_type, "input_params": input_params}
		else:
			popups.append({"action_id": action_id, "type": String(input_type), "params": input_params})

	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		match input_type:
			&"select_weapon":
				context.action_service.continue_action(action_id, {"weapon_id": weapon_for.call(action_id)})
			&"select_attack_target":
				context.action_service.continue_action(action_id, {"target_id": target_for.call(action_id, input_params)})
			&"select_move_target":
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				context.timing_engine.handle_response_selection(action_id, response_for.call(action_id))
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				context.action_service.continue_action(action_id, d if not d.is_empty() else {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01/effect_02 + 4 隐藏 LISTEN 定义正确
func test_pilot_073_effect_definitions() -> Variant:
	var effects: Dictionary = _ActionPilotEffects.build_pilot_effects()

	# ── effect_01（按钮1 DIRECT）──
	var e1 = effects.get(&"pilot_073_effect_01")
	if e1 == null:
		return "缺 pilot_073_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if String(e1.once_per_turn_key) != "pilot_073_effect_01":
		return "e1 once_per_turn_key 应 pilot_073_effect_01"
	if int(e1.once_per_turn_max) != 3:
		return "e1 once_per_turn_max 应 3"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	if not e1_ops.has("IS_OWNER_MAIN_PHASE"):
		return "e1 应含 IS_OWNER_MAIN_PHASE 条件"
	var e1_found_count: bool = false
	for c in e1.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("count", 0)) != 1:
				return "e1 HAS_ACTION_CARD_IN_HAND count 应 1"
			e1_found_count = true
	if not e1_found_count:
		return "e1 应含 HAS_ACTION_CARD_IN_HAND"
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "e1 target_rule 应 NO_TARGET"
	var e1_acts: Array = e1.actions
	if e1_acts.size() != 3:
		return "e1 应有3个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "e1 动作0 应 CHOOSE_MANY_CARDS"
	var e1cm: Dictionary = e1_acts[0].get("params", {})
	if String(e1cm.get("source", &"")) != "OWNER_ACTION_HAND":
		return "e1 选择来源应 OWNER_ACTION_HAND"
	if int(e1cm.get("min_count", 0)) != 1 or int(e1cm.get("max_count", 0)) != 1:
		return "e1 min/max_count 应 1"
	if String(e1cm.get("store_result_key", &"")) != "pilot_073_discard_ids":
		return "e1 store_result_key 应 pilot_073_discard_ids"
	if String(e1_acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "e1 动作1 应 EXECUTE_DISCARD"
	var e1acc: Dictionary = e1_acts[2].get("params", {})
	if String(e1_acts[2].get("type", &"")) != "ACCUMULATE_MELEE_MIGHT":
		return "e1 动作2 应 ACCUMULATE_MELEE_MIGHT"
	if String(e1acc.get("source_cid", &"")) != "$binding_context.card_instance_id":
		return "e1 ACCUMULATE source_cid 应 $binding_context.card_instance_id"
	if String(e1acc.get("mech_id", &"")) != "$binding_context.mech_id":
		return "e1 ACCUMULATE mech_id 应 $binding_context.mech_id"
	if int(e1acc.get("delta", 0)) != 3:
		return "e1 ACCUMULATE delta 应 3"

	# ── effect_01 隐藏 LISTEN（apply/consume/turnend，并入按钮1）──
	var e1a = effects.get(&"pilot_073_effect_01_apply")
	var e1c = effects.get(&"pilot_073_effect_01_consume")
	var e1t = effects.get(&"pilot_073_effect_01_turnend")
	if e1a == null or e1c == null or e1t == null:
		return "缺 e1 隐藏 LISTEN（apply/consume/turnend）"
	for he in [e1a, e1c, e1t]:
		if he.mode != _TimingConst.MODE_LISTEN:
			return "隐藏效果 mode 应 MODE_LISTEN 实=%s" % String(he.mode)
		if not bool(he.hide_button):
			return "隐藏效果应 hide_button=true"
		if int(he.merge_desc_into_index) != 1:
			return "隐藏效果 merge_desc_into_index 应 1"
	if e1a.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "apply listen_timing 应 ATTACK_BEFORE"
	if e1c.listen_timing != _TimingConst.ATTACK_SETTLE:
		return "consume listen_timing 应 ATTACK_SETTLE"
	if e1t.listen_timing != _TimingConst.TURN_AFTER_END:
		return "turnend listen_timing 应 TURN_AFTER_END"
	var e1a_ops: Array = []
	for c in e1a.conditions:
		e1a_ops.append(String(c.get("op", &"")))
	if not e1a_ops.has("SELF_MECH_IS_ATTACKER") or not e1a_ops.has("ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "apply 应含 SELF_MECH_IS_ATTACKER + ATTACK_EFFECTIVE_WEAPON_KIND"
	var e1a_kind_found: bool = false
	for c in e1a.conditions:
		if String(c.get("op", &"")) == "ATTACK_EFFECTIVE_WEAPON_KIND" and String(c.get("weapon_kind", &"")) == "近战":
			e1a_kind_found = true
	if not e1a_kind_found:
		return "apply ATTACK_EFFECTIVE_WEAPON_KIND 应近战"
	if String(e1a.actions[0].get("type", &"")) != "APPLY_MELEE_MIGHT":
		return "apply 动作应 APPLY_MELEE_MIGHT"
	if String(e1c.actions[0].get("type", &"")) != "CLEAR_MELEE_MIGHT":
		return "consume 动作应 CLEAR_MELEE_MIGHT"
	if String(e1t.actions[0].get("type", &"")) != "CLEAR_MELEE_MIGHT":
		return "turnend 动作应 CLEAR_MELEE_MIGHT"
	var e1t_ops: Array = []
	for c in e1t.conditions:
		e1t_ops.append(String(c.get("op", &"")))
	if not e1t_ops.has("IS_OWNER_TURN"):
		return "turnend 应含 IS_OWNER_TURN 条件"

	# ── effect_02（按钮2 DIRECT）──
	var e2 = effects.get(&"pilot_073_effect_02")
	if e2 == null:
		return "缺 pilot_073_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "e2 mode 应 MODE_DIRECT"
	if String(e2.once_per_turn_key) != "pilot_073_effect_02":
		return "e2 once_per_turn_key 应 pilot_073_effect_02"
	if int(e2.once_per_turn_max) != 1:
		return "e2 once_per_turn_max 应 1"
	if String(e2.target_rules[0].get("rule", &"")) != "CHOOSE_OTHER_MECH":
		return "e2 target_rule 应 CHOOSE_OTHER_MECH"
	if String(e2.actions[0].get("type", &"")) != "GRANT_MELEE_MIGHT":
		return "e2 动作应 GRANT_MELEE_MIGHT"
	var e2g: Dictionary = e2.actions[0].get("params", {})
	if String(e2g.get("source_cid", &"")) != "$binding_context.card_instance_id":
		return "e2 GRANT source_cid 应 $binding_context.card_instance_id"
	if String(e2g.get("target_mech_id", &"")) != "$payload.target_id":
		return "e2 GRANT target_mech_id 应 $payload.target_id"

	# ── effect_02_expire 隐藏 LISTEN（并入按钮2）──
	var e2x = effects.get(&"pilot_073_effect_02_expire")
	if e2x == null:
		return "缺 pilot_073_effect_02_expire"
	if e2x.mode != _TimingConst.MODE_LISTEN:
		return "expire mode 应 MODE_LISTEN"
	if not bool(e2x.hide_button):
		return "expire 应 hide_button=true"
	if int(e2x.merge_desc_into_index) != 2:
		return "expire merge_desc_into_index 应 2"
	if e2x.listen_timing != _TimingConst.TURN_AFTER_START:
		return "expire listen_timing 应 TURN_AFTER_START"
	if String(e2x.actions[0].get("type", &"")) != "EXPIRE_MELEE_MIGHT":
		return "expire 动作应 EXPIRE_MELEE_MIGHT"
	return true


# ═══════════════════════════════════════════
# 行为测试：effect_01
# ═══════════════════════════════════════════

## 测试2：完整流程——弃1行动牌 → buff=3（泰特自己）
func test_pilot_073_discard_accumulate() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_073_泰特）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand = player.action_hand.duplicate()
	if hand.size() < 1:
		return "起手行动牌不足1张 实=%d" % hand.size()
	var sel: StringName = hand[0]
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起（应弹选弃行动牌窗）"
	await _resume_discard(battle, ef, [sel])
	# 弃1：不在手牌，进行动弃牌堆
	if player.action_hand.has(sel):
		return "被弃行动牌不应仍在手牌"
	if not _in_action_discard(battle, sel):
		return "被弃行动牌应进行动弃牌堆"
	# 累积 +3（泰特自己）
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "弃牌后应累积 buff=3 实=%d" % _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id)
	# 每回合3次额度消耗1次（3次内仍可用）
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_073_effect_01", s.pilot_card.instance_id, 3):
		return "完整发动后第1次应仍可用（3次额度）"
	# 无残留等待动作
	var waiting := _waiting_actions(battle.context)
	if not waiting.is_empty():
		return "效果后仍有动作等待: %s" % str(waiting)
	return true


## 测试3：取消选牌 -> 中止，不弃不累加不消耗次数（可再触发）
func test_pilot_073_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand_size_before: int = player.action_hand.size()
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel(battle, ef)
	if player.action_hand.size() != hand_size_before:
		return "取消不应弃牌"
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 0:
		return "取消不应累积 buff"
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_073_effect_01", s.pilot_card.instance_id, 3):
		return "取消不应消耗每回合3次额度"
	var ef2 = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "取消中止后应可再触发"
	return true


## 测试4：每回合3次用满 -> 第4次跳过
func test_pilot_073_once_per_turn_3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	# 3 次完整发动（每次补1张行动牌确保够弃）
	for i in range(3):
		var hand = player.action_hand.duplicate()
		if hand.size() < 1:
			return "第%d次起手行动牌不足" % (i + 1)
		var sel: StringName = hand[0]
		var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
		if ef == null:
			return "第%d次未挂起" % (i + 1)
		await _resume_discard(battle, ef, [sel])
		if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != (i + 1) * 3:
			return "第%d次后 buff 应=%d 实=%d" % [i + 1, (i + 1) * 3, _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id)]
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_073_effect_01", s.pilot_card.instance_id, 3):
		return "3次用满后额度应不可用"
	# 第4次触发：once_per_turn 用满 -> 跳过，不挂起、不再弃牌
	var hand_before: int = player.action_hand.size()
	var ef4 = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef4 != null:
		return "第4次不应挂起（每回合3次用满）"
	if player.action_hand.size() != hand_before:
		return "第4次跳过不应再弃牌"
	return true


## 测试5：近战攻击（真实 AttackAction）——ATTACK_BEFORE 应用 extra_might+3，选目标前生效
func test_pilot_073_melee_attack_applies() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var ctx = battle.context
	# 累积 +3
	var hand = player.action_hand.duplicate()
	if hand.size() < 1:
		return "起手行动牌不足"
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [hand[0]])
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "前置：buff 应=3"
	# 布置相邻 + 发起真实近战攻击（frame_base_weapon_1=振动匕首，近战，射程2）
	s.mech.power = 10
	_place_mech(battle, s.mech.mech_id, 10, 0)
	_place_mech(battle, s.enemy_mech.mech_id, 11, 0)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName: return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName: return s.enemy_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]: return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary: return {"auto_placed": true}
	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": s.mech.mech_id,
		"target_id": &"",
		"weapon_id": &"frame_base_weapon_1",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": s.mech.mech_id},
	})
	if atk.get("state", &"") == &"error":
		return "攻击发起失败: %s" % str(atk)
	var attack_id: StringName = atk.get("action_id", &"")
	# 等攻击挂起于选目标（ATTACK_BEFORE 已 fire，extra_might 已写）
	var atk_act = null
	for i in range(40):
		await _frame()
		atk_act = ctx.action_registry.get_action(attack_id)
		if atk_act != null and atk_act.state == &"waiting_input":
			break
	if atk_act == null:
		return "攻击动作缺失"
	if atk_act.state != &"waiting_input":
		return "攻击未挂起于选目标 实=%s" % String(atk_act.state)
	if int(atk_act.record.get("extra_might", 0)) != 3:
		return "近战攻击应含 extra_might=3 实=%d" % int(atk_act.record.get("extra_might", 0))
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "选目标阶段 buff 应仍为3（未消耗）"
	# 走完攻击（结算由测试7单独验证；此处保证无卡死）
	var guard: int = 0
	while guard < 200:
		guard += 1
		if not driver.popups.is_empty():
			return "出现未预期弹窗: %s" % str(driver.popups)
		var progressed: bool = driver.pump()
		await _frame()
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break
	if not _waiting_actions(ctx).is_empty():
		return "攻击后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true


## 测试6：非近战攻击——不应用不消耗（buff 保持3、extra_might 保持0）
func test_pilot_073_ranged_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var ctx = battle.context
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 累积 +3
	var hand = player.action_hand.duplicate()
	if hand.size() < 1:
		return "起手行动牌不足"
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [hand[0]])
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "前置：buff 应=3"
	# 远程攻击：ATTACK_BEFORE 不应用（条件近战不满足）
	var atk_a = await _fire_synth_attack_timing(battle, s.mech, _TimingConst.ATTACK_BEFORE, &"远程")
	if int(atk_a.record.get("extra_might", 0)) != 0:
		return "远程攻击不应应用 extra_might 实=%d" % int(atk_a.record.get("extra_might", 0))
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "远程攻击不应消耗 buff"
	# 远程结算：ATTACK_SETTLE 不消耗
	var atk_s = await _fire_synth_attack_timing(battle, s.mech, _TimingConst.ATTACK_SETTLE, &"远程")
	if int(atk_s.record.get("extra_might", 0)) != 0:
		return "远程结算不应应用 extra_might"
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "远程结算不应消耗 buff 实=%d" % _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id)
	return true


## 测试7：近战结算（ATTACK_SETTLE）——buff 消耗清0
func test_pilot_073_settle_consumes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var ctx = battle.context
	var hand = player.action_hand.duplicate()
	if hand.size() < 1:
		return "起手行动牌不足"
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [hand[0]])
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "前置：buff 应=3"
	# 近战攻击全流程（结算消耗）
	s.mech.power = 10
	_place_mech(battle, s.mech.mech_id, 10, 0)
	_place_mech(battle, s.enemy_mech.mech_id, 11, 0)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName: return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName: return s.enemy_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]: return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary: return {"auto_placed": true}
	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": s.mech.mech_id,
		"target_id": &"",
		"weapon_id": &"frame_base_weapon_1",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": s.mech.mech_id},
	})
	if atk.get("state", &"") == &"error":
		return "攻击发起失败: %s" % str(atk)
	var attack_id: StringName = atk.get("action_id", &"")
	var guard: int = 0
	while guard < 200:
		guard += 1
		if not driver.popups.is_empty():
			return "出现未预期弹窗: %s" % str(driver.popups)
		var progressed: bool = driver.pump()
		await _frame()
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break
	if not _waiting_actions(ctx).is_empty():
		return "攻击后仍有动作等待: %s" % str(_waiting_actions(ctx))
	# 近战完全结算 -> buff 消耗清0
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 0:
		return "近战结算后 buff 应清0 实=%d" % _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id)
	return true


## 测试8：自己回合结束后（TURN_AFTER_END）——待发 buff 清空
func test_pilot_073_turn_after_end_clear() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var hand = player.action_hand.duplicate()
	if hand.size() < 1:
		return "起手行动牌不足"
	var ef = await _fire_pilot_073_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [hand[0]])
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "前置：buff 应=3"
	# 回合结束后清空（"本回合"待发不带入下回合）
	_fire_turn_timing(battle, _TimingConst.TURN_AFTER_END)
	await _pump_frames(6)
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 0:
		return "回合结束后 buff 应清0 实=%d" % _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id)
	return true


# ═══════════════════════════════════════════
# 行为测试：effect_02 授予/到期
# ═══════════════════════════════════════════

## 测试9：授予他机获效——EX 注册 + 他机在自己回合可用弃牌累积 buff
func test_pilot_073_grant_other_mech() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var ctx = battle.context
	var enemy = gs.players.get(&"enemy")
	var enemy_mech = s.enemy_mech
	# 授予敌方机甲
	var ef2 = await _fire_pilot_073_effect2(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "effect_02 未挂起（应弹目标选择）"
	await _resume_target(battle, ef2, enemy_mech.mech_id)
	# 记录授予
	if not _ActionPilotEffects._melee_grant_mechs.has(s.pilot_card.instance_id):
		return "未记录 _melee_grant_mechs[source]"
	if not bool(_ActionPilotEffects._melee_grant_mechs[s.pilot_card.instance_id].get(enemy_mech.mech_id, false)):
		return "未记录 _melee_grant_mechs[source][enemy]"
	# EX DIRECT（虚拟时点 pilot_073_effect_01）+ 隐藏 LISTEN 注册到敌方机甲（granted=true）
	var ex_mechs: Array = _perm_listener_mechs(ctx, &"pilot_073_effect_01", &"pilot_073_effect_01")
	if not ex_mechs.has(String(enemy_mech.mech_id)):
		return "敌方机甲应注册 EX DIRECT（虚拟时点）"
	var ab_mechs: Array = _perm_listener_mechs(ctx, _TimingConst.ATTACK_BEFORE, &"pilot_073_effect_01_apply")
	if not ab_mechs.has(String(enemy_mech.mech_id)):
		return "敌方机甲应注册 ATTACK_BEFORE apply 监听器"
	var st_mechs: Array = _perm_listener_mechs(ctx, _TimingConst.ATTACK_SETTLE, &"pilot_073_effect_01_consume")
	if not st_mechs.has(String(enemy_mech.mech_id)):
		return "敌方机甲应注册 ATTACK_SETTLE consume 监听器"
	# granted binding 打标记（equipment_panel EX 按钮检测）
	var tl: Dictionary = ctx.timing_engine.permanent_listeners
	var found_granted: bool = false
	if tl.has(&"pilot_073_effect_01"):
		for entry: Dictionary in tl[&"pilot_073_effect_01"]:
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("mech_id", &"")) == String(enemy_mech.mech_id) and bool(bc.get("granted", false)):
				found_granted = true
	if not found_granted:
		return "敌方 EX binding 应带 granted=true"
	# effect_02 每回合1次已消耗
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_073_effect_02", s.pilot_card.instance_id, 1):
		return "授予后每回合1次应已消耗"
	# 敌方在自己回合可弃牌累积 buff（EX 按钮 = 该 DIRECT 效果）
	if enemy.action_hand.size() < 1:
		_add_action_to_hand(battle, &"enemy")
	var e_hand: Array = enemy.action_hand.duplicate()
	var e_sel: StringName = e_hand[0]
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	var src: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": enemy_mech.mech_id,
		"player_id": &"enemy",
		"effect_id": &"pilot_073_effect_01",
	}
	ctx.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_073_effect_01",
		"player_id": &"enemy",
		"source_mech_id": enemy_mech.mech_id,
		"card_instance_id": s.pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	var e_ef: _Action = null
	for a in ctx.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			e_ef = a
			break
	if e_ef == null:
		return "敌方 EX 效果未挂起（应弹选弃窗）"
	await _resume_discard(battle, e_ef, [e_sel])
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, enemy_mech.mech_id) != 3:
		return "敌方用 EX 弃牌后应累积 buff=3 实=%d" % _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, enemy_mech.mech_id)
	# 泰特自己不受影响（自己 buff 仍0，独立分离）
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 0:
		return "泰特自身 buff 应仍0（与他机独立）"
	return true


## 测试10：来源下回合开始后（TURN_AFTER_START）——授予注销（EX 消失）+ 待发清空，泰特自身保留
func test_pilot_073_expire_at_turn_start() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_taite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var ctx = battle.context
	var enemy_mech = s.enemy_mech
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 授予敌方 + 敌方用一次（待发3）
	var ef2 = await _fire_pilot_073_effect2(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "effect_02 未挂起"
	await _resume_target(battle, ef2, enemy_mech.mech_id)
	_ActionPilotEffects.add_melee_buff(s.pilot_card.instance_id, enemy_mech.mech_id, 3)
	if not _ActionPilotEffects._melee_grant_mechs.has(s.pilot_card.instance_id):
		return "前置：应已记录授予"
	# 泰特自己也有待发（模拟已弃牌）
	_ActionPilotEffects.add_melee_buff(s.pilot_card.instance_id, s.mech.mech_id, 3)
	# 泰特下回合开始后 -> 到期注销授予 + 清他机待发
	_fire_turn_timing(battle, _TimingConst.TURN_AFTER_START)
	await _pump_frames(8)
	# 授予登记清除
	if _ActionPilotEffects._melee_grant_mechs.has(s.pilot_card.instance_id):
		return "到期后应清除 _melee_grant_mechs"
	# 敌方 EX/监听器注销
	if _perm_listener_mechs(ctx, &"pilot_073_effect_01", &"pilot_073_effect_01").has(String(enemy_mech.mech_id)):
		return "到期后敌方 EX DIRECT 应注销"
	if _perm_listener_mechs(ctx, _TimingConst.ATTACK_BEFORE, &"pilot_073_effect_01_apply").has(String(enemy_mech.mech_id)):
		return "到期后敌方 apply 监听器应注销"
	if _perm_listener_mechs(ctx, _TimingConst.ATTACK_SETTLE, &"pilot_073_effect_01_consume").has(String(enemy_mech.mech_id)):
		return "到期后敌方 consume 监听器应注销"
	# 敌方待发清空
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, enemy_mech.mech_id) != 0:
		return "到期后敌方待发应清空"
	# 泰特自身监听器保留（EX/apply/consume/turnend 仍在，且自身待发保留——本回合未结算不清）
	if not _perm_listener_mechs(ctx, &"pilot_073_effect_01", &"pilot_073_effect_01").has(String(s.mech.mech_id)):
		return "泰特自身 EX DIRECT 应保留"
	if not _perm_listener_mechs(ctx, _TimingConst.ATTACK_BEFORE, &"pilot_073_effect_01_apply").has(String(s.mech.mech_id)):
		return "泰特自身 apply 监听器应保留"
	if not _perm_listener_mechs(ctx, _TimingConst.TURN_AFTER_END, &"pilot_073_effect_01_turnend").has(String(s.mech.mech_id)):
		return "泰特自身 turnend 监听器应保留"
	if _ActionPilotEffects.get_melee_buff(s.pilot_card.instance_id, s.mech.mech_id) != 3:
		return "泰特自身待发应保留（到期只清他机授予）"
	return true
