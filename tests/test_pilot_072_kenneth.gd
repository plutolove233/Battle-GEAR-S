## test_pilot_072_kenneth.gd - 肯尼斯（pilot_072，帝国 N）效果测试
##
## 肯尼斯 2 按钮（1 DIRECT 主动 + 1 LISTEN 被动置灰）+ 4 隐藏 LISTEN：
##   effect_01（按钮1 DIRECT，我方回合1次）「弃1行动牌」：选1张行动牌弃置（可取消）。
##     动作链：CHOOSE_MANY_CARDS(选1行动牌,可取消) → MARK_EFFECT_ONCE_PER_TURN_USED(确认计次,每回合1次)
##       → EXECUTE_DISCARD(弃选中,触发效果2)。取消选牌不计次数（德伦迪 042 显式计次同款）。
##   effect_02（按钮2 LISTEN，被动置灰+悬停）「弃置加成」：每次自己的行动手牌（action_hand）
##     被弃置后弹 CHOOSE_ONE optional 二选一：抽1张行动牌 / 本回合下次攻击威力+2（可叠加），
##     也可取消不发动。条件：基础 DISCARD_INCLUDED_OWNER_ACTION_CARD(action_hand) +
##     negate(DISCARD_INCLUDED_OWNER_ACTION_CARD action_type=辅助)——本次弃置【不含】辅助牌时才弹窗。
##     隐藏 LISTEN（并入按钮2悬停）：
##       · effect_02_auto（DISCARD_AFTER，本次弃置含辅助牌）：自动 抽1 + 威力+2（两效果都执行，不弹窗）。
##       · effect_02_apply（ATTACK_BEFORE，SELF_MECH_IS_ATTACKER，任意武器）：
##         APPLY_NEXT_ATTACK_BONUS 读来源牌实例计数器 var_p075_next_might → attack.record.extra_might+。
##       · effect_02_consume（ATTACK_SETTLE，SELF_MECH_IS_ATTACKER）：SET_CARD_COUNTER 置0（攻击结算消耗，
##         取消攻击保留；双连 fork 深拷贝 record 各带加成，任一枚结算清空不影响其他）。
##       · effect_02_turnend（TURN_AFTER_END，IS_OWNER_TURN）：SET_CARD_COUNTER 置0（"本回合"限定）。
##   "含辅助牌"判定：DISCARD_INCLUDED_OWNER_ACTION_CARD 通用条件扩展的 action_type+negate 参数
##     （按快照 card_id 查 def.action_type，ConditionChecker 通用，任何"弃置含X类型牌"效果可复制复用）。
##   待发威力：来源牌实例计数器（INCREMENT_VARIABLE/APPLY_NEXT_ATTACK_BONUS/SET_CARD_COUNTER，
##     零新增原子动作，复用影刹 069"下次攻击加成"通用件，与效果绑定不绑机师）。
##
## 关键覆盖点：
##   1. 效果定义结构（e1 DIRECT once_per_turn_max 1 + 条件 + 3动作链；e2 LISTEN 双条件互斥 +
##      CHOOSE_ONE 2选项；4 隐藏 LISTEN 定义/时点/动作）。
##   2. 完整流程：弃1张行动牌（非辅助）→ 弹窗 → 选抽1 → 手牌净回原数、弃牌入弃牌堆、威力不累积。
##   3. 弹窗选威力+2：可叠加（弃2次弹2次窗威力+4）。
##   4. 弹窗取消：不抽不累加。
##   5. 弃辅助牌：自动双效果（抽1 + 威力+2），不弹窗。
##   6. 真实攻击（任意武器）：ATTACK_BEFORE 应用 extra_might+2，选目标前生效。
##   7. 攻击完全结算（ATTACK_SETTLE）：待发威力清0。
##   8. 自己回合结束（TURN_AFTER_END）：待发威力清0（本回合限定）。
##   9. 弃置条件边界（合成 DISCARD_AFTER）：非辅助弹窗 / 辅助自动 / 混合走自动 / 他人机甲弃不触发 /
##      临时区弃不触发。
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
	battle.rng_seed = 90075
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


## 设肯尼斯为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, battle, enemy_mech}；失败返回空字典。
## 双方玩家设 is_human=true（弹窗/弃牌走人类路径，AI 会跳过）。
## 待发威力走来源牌实例计数器（card.counters），每 battle 新建实例无跨测试静态串扰，无需清静态。
func _setup_kenensi(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_072_肯尼斯", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	for pid: StringName in gs.players:
		gs.players.get(pid).is_human = true
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "battle": battle,
			"enemy_mech": gs.get_mech_for_player(&"enemy")}


## 给玩家行动手牌补一张行动牌（可用），card.mech_id 挂到所属机甲（与真实抽取一致），返回实例 id
func _add_action_to_hand(battle, pid: StringName, def_id: String, mech_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	card.mech_id = mech_id
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 触发肯尼斯 effect_01 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_072_effect1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_072_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_072_effect_01",
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


## resume 选弃窗（确认：弃牌，随后 effect_02 弹窗/自动）
func _resume_discard(battle, ef, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": selected})
	await _pump_frames(14)


## resume 取消选弃窗（中止，不消耗次数、不弃牌、不触发效果2）
func _resume_cancel(battle, ef) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)


## 读来源牌实例的待发威力计数（var_p075_next_might）
func _counter(gs, cid: StringName) -> int:
	var card = gs.cards.get(cid)
	if card == null or not "counters" in card:
		return 0
	return int(card.counters.get("var_p075_next_might", 0))


## 检查 cid 是否在行动弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


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


## 合成 turn 动作并 fire 一个回合时点（TURN_AFTER_END 等）
func _fire_turn_timing(battle, timing: StringName) -> void:
	var ctx = battle.context
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p075_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": &"player"}
	turn_action.state = &"running"
	turn_action.context = ctx
	ctx.action_registry.register(turn_action)
	ctx.timing_engine.fire_timing(timing, turn_action)


## 合成 discard 动作并 fire DISCARD_AFTER（直接测 effect_02/auto 监听条件）。
## snapshots 里 card_id 须为 gs.cards 中真实实例（action_type 判定按 def 查）。返回 mock action。
func _fire_discard_after_mock(battle, snapshots: Array) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p075_da_%d" % [randi() % 1000000]
	mock.action_type = &"discard_card"
	mock.record = {"discard_snapshots": snapshots}
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.DISCARD_AFTER, mock)
	return mock


## 构造一条弃牌快照（from_zone/card_kind 默认行动手牌行动牌）
func _snap(card_id: StringName, from_mech_id: StringName, from_zone: String = "action_hand") -> Dictionary:
	return {
		"card_id": card_id,
		"card_kind": &"action",
		"from_mech_id": from_mech_id,
		"from_zone": from_zone,
		"reason": &"pilot_072_test",
	}


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
func test_pilot_072_effect_definitions() -> Variant:
	var effects: Dictionary = _ActionPilotEffects.build_pilot_effects()

	# ── effect_01（按钮1 DIRECT）──
	var e1 = effects.get(&"pilot_072_effect_01")
	if e1 == null:
		return "缺 pilot_072_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	var e1_ops: Array = []
	var e1_ot_found: bool = false
	var e1_hand_found: bool = false
	for c in e1.conditions:
		var c_op: String = String(c.get("op", &""))
		e1_ops.append(c_op)
		if c_op == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var cp: Dictionary = c.get("params", {})
			if String(cp.get("once_per_turn_key", &"")) != "pilot_072_effect_01":
				return "e1 once_per_turn_key 应 pilot_072_effect_01"
			if int(cp.get("once_per_turn_max", 0)) != 1:
				return "e1 once_per_turn_max 应 1"
			e1_ot_found = true
		if c_op == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("count", 0)) != 1:
				return "e1 HAS_ACTION_CARD_IN_HAND count 应 1"
			e1_hand_found = true
	if not e1_ops.has("IS_OWNER_MAIN_PHASE"):
		return "e1 应含 IS_OWNER_MAIN_PHASE"
	if not e1_ot_found:
		return "e1 应含 EFFECT_ONCE_PER_TURN_AVAILABLE(max=1)"
	if not e1_hand_found:
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
	if String(e1cm.get("store_result_key", &"")) != "pilot_072_discard_ids":
		return "e1 store_result_key 应 pilot_072_discard_ids"
	if String(e1_acts[1].get("type", &"")) != "MARK_EFFECT_ONCE_PER_TURN_USED":
		return "e1 动作1 应 MARK_EFFECT_ONCE_PER_TURN_USED（显式计次）"
	if String(e1_acts[2].get("type", &"")) != "EXECUTE_DISCARD":
		return "e1 动作2 应 EXECUTE_DISCARD"
	var e1dis: Dictionary = e1_acts[2].get("params", {})
	if String(e1dis.get("card_ids", &"")) != "$runtime.pilot_072_discard_ids":
		return "e1 EXECUTE_DISCARD card_ids 应 $runtime.pilot_072_discard_ids"

	# ── effect_02（按钮2 LISTEN 被动）──
	var e2 = effects.get(&"pilot_072_effect_02")
	if e2 == null:
		return "缺 pilot_072_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "e2 mode 应 MODE_LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.DISCARD_AFTER:
		return "e2 listen_timing 应 DISCARD_AFTER"
	if String(e2.listen_action_type) != "discard_card":
		return "e2 listen_action_type 应 discard_card"
	# 双条件互斥：基础 action_hand + negate(辅助)
	var e2_base: bool = false
	var e2_neg: bool = false
	for c in e2.conditions:
		if String(c.get("op", &"")) != "DISCARD_INCLUDED_OWNER_ACTION_CARD":
			return "e2 条件应仅 DISCARD_INCLUDED_OWNER_ACTION_CARD 实=%s" % String(c.get("op", &""))
		var cp: Dictionary = c.get("params", c)
		if bool(cp.get("negate", false)):
			if String(cp.get("action_type", &"")) != "辅助":
				return "e2 negate 条件 action_type 应 辅助"
			if not bool(cp.get("negate", false)):
				return "e2 negate 条件应 negate=true"
			e2_neg = true
		else:
			if String(cp.get("from_zone", &"")) != "action_hand":
				return "e2 基础条件 from_zone 应 action_hand"
			e2_base = true
	if not e2_base or not e2_neg:
		return "e2 应同时含 基础(action_hand) + negate(辅助) 两个条件"
	if String(e2.actions[0].get("type", &"")) != "CHOOSE_ONE":
		return "e2 动作应 CHOOSE_ONE"
	var e2co: Dictionary = e2.actions[0].get("params", {})
	if not bool(e2co.get("optional", false)):
		return "e2 CHOOSE_ONE 应 optional=true（可取消不发动）"
	var e2opts: Array = e2co.get("options", [])
	if e2opts.size() != 2:
		return "e2 应有2个选项 实=%d" % e2opts.size()
	if String(e2opts[0].get("label", &"")) != "抽1张行动牌":
		return "e2 选项0 应 抽1张行动牌"
	if String(e2opts[0].get("actions", [{}])[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "e2 选项0 动作应 EXECUTE_GAIN_CARD"
	if String(e2opts[1].get("label", &"")) != "本回合下次攻击威力+2":
		return "e2 选项1 应 本回合下次攻击威力+2"
	var e2opt1a: Array = e2opts[1].get("actions", [{}])
	if String(e2opt1a[0].get("type", &"")) != "INCREMENT_VARIABLE":
		return "e2 选项1 动作应 INCREMENT_VARIABLE"
	var e2inc: Dictionary = e2opt1a[0].get("params", {})
	if String(e2inc.get("source_card_instance_id", &"")) != "$binding_context.card_instance_id":
		return "e2 INCREMENT source_card_instance_id 应 $binding_context.card_instance_id"
	if String(e2inc.get("variable_name", &"")) != "p075_next_might":
		return "e2 INCREMENT variable_name 应 p075_next_might"
	if int(e2inc.get("delta", 0)) != 2:
		return "e2 INCREMENT delta 应 2"

	# ── effect_02 隐藏 LISTEN（auto/apply/consume/turnend，并入按钮2）──
	var e2a = effects.get(&"pilot_072_effect_02_auto")
	var e2b = effects.get(&"pilot_072_effect_02_apply")
	var e2c = effects.get(&"pilot_072_effect_02_consume")
	var e2d = effects.get(&"pilot_072_effect_02_turnend")
	if e2a == null or e2b == null or e2c == null or e2d == null:
		return "缺 e2 隐藏 LISTEN（auto/apply/consume/turnend）"
	for he in [e2a, e2b, e2c, e2d]:
		if he.mode != _TimingConst.MODE_LISTEN:
			return "隐藏效果 mode 应 MODE_LISTEN 实=%s" % String(he.mode)
		if not bool(he.hide_button):
			return "隐藏效果应 hide_button=true"
		if int(he.merge_desc_into_index) != 2:
			return "隐藏效果 merge_desc_into_index 应 2"
	if e2a.listen_timing != _TimingConst.DISCARD_AFTER:
		return "auto listen_timing 应 DISCARD_AFTER"
	if e2b.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "apply listen_timing 应 ATTACK_BEFORE"
	if e2c.listen_timing != _TimingConst.ATTACK_SETTLE:
		return "consume listen_timing 应 ATTACK_SETTLE"
	if e2d.listen_timing != _TimingConst.TURN_AFTER_END:
		return "turnend listen_timing 应 TURN_AFTER_END"
	# auto 条件 = action_type 辅助
	var e2a_aux: bool = false
	for c in e2a.conditions:
		if String(c.get("op", &"")) == "DISCARD_INCLUDED_OWNER_ACTION_CARD" \
				and String(c.get("params", {}).get("action_type", &"")) == "辅助":
			e2a_aux = true
	if not e2a_aux:
		return "auto 应含 action_type=辅助 条件"
	if String(e2a.actions[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "auto 动作0 应 EXECUTE_GAIN_CARD"
	if String(e2a.actions[1].get("type", &"")) != "INCREMENT_VARIABLE":
		return "auto 动作1 应 INCREMENT_VARIABLE"
	var e2ainc: Dictionary = e2a.actions[1].get("params", {})
	if int(e2ainc.get("delta", 0)) != 2:
		return "auto INCREMENT delta 应 2"
	# apply 条件 = SELF_MECH_IS_ATTACKER（任意武器，无武器类型过滤）
	var e2b_ops: Array = []
	for c in e2b.conditions:
		e2b_ops.append(String(c.get("op", &"")))
	if not e2b_ops.has("SELF_MECH_IS_ATTACKER"):
		return "apply 应含 SELF_MECH_IS_ATTACKER"
	if e2b_ops.has("ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "apply 不应限定武器类型（任意武器生效）"
	if String(e2b.actions[0].get("type", &"")) != "APPLY_NEXT_ATTACK_BONUS":
		return "apply 动作应 APPLY_NEXT_ATTACK_BONUS"
	var e2bap: Dictionary = e2b.actions[0].get("params", {})
	if String(e2bap.get("might_key", &"")) != "var_p075_next_might":
		return "apply might_key 应 var_p075_next_might"
	# consume/turnend 动作 = SET_CARD_COUNTER
	if String(e2c.actions[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "consume 动作应 SET_CARD_COUNTER"
	if String(e2d.actions[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "turnend 动作应 SET_CARD_COUNTER"
	var e2d_ops: Array = []
	for c in e2d.conditions:
		e2d_ops.append(String(c.get("op", &"")))
	if not e2d_ops.has("IS_OWNER_TURN"):
		return "turnend 应含 IS_OWNER_TURN 条件"
	return true


# ═══════════════════════════════════════════
# 行为测试：弃置加成（效果2）
# ═══════════════════════════════════════════

## 测试2：完整流程——弃1张行动牌（非辅助）→ 弹窗 → 选抽1 → 手牌净回原数 + 弃牌入弃牌堆 + 威力不累积
func test_pilot_072_discard_non_support_popup_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_072_肯尼斯）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	# 清手牌，补1张攻击牌（非辅助）确保可弃且效果2弹窗
	var hand_before: int = player.action_hand.size()
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	if sel == &"":
		return "补行动牌失败"
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起（应弹选弃行动牌窗）"
	await _resume_discard(battle, ef, [sel])
	# 弃牌入弃牌堆 + 离手
	if not _in_action_discard(battle, sel):
		return "被弃行动牌应进行动弃牌堆"
	# 非辅助 → effect_02 弹 CHOOSE_ONE（抽1 / 威力+2）
	var bridge = battle.context.action_ui_bridge
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "弃非辅助牌后应弹 choose_one_effect，实=%s" % String(w.get("input_type", &""))
	# 选"抽1张行动牌"（选项0）
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})
	await _pump_frames(6)
	# 手牌 = hand_before+1（补1弃1再抽1，净+1）+ 牌堆少1 + 威力不累积
	if player.action_hand.size() != hand_before + 1:
		return "选抽1后手牌应=%d（弃1抽1净+1）实=%d" % [hand_before + 1, player.action_hand.size()]
	if _action_deck_size(battle) != deck_before - 1:
		return "选抽1后行动牌堆应少1 实=%d" % _action_deck_size(battle)
	if _counter(gs, s.pilot_card.instance_id) != 0:
		return "选抽1不应累积待发威力"
	# 无残留等待动作
	var waiting := _waiting_actions(battle.context)
	if not waiting.is_empty():
		return "效果后仍有动作等待: %s" % str(waiting)
	return true


## 测试3：弹窗选威力+2 可叠加（弃2次弹2次窗 -> 待发威力+4）。
## 效果1每回合限1次：第1次走效果1按钮弃牌；第2次直接 discard_cards（模拟其他弃牌来源，
## 如回合结束弃超限/效果弃牌），效果2照常弹窗叠加--同时覆盖「限1次后其他弃牌来源仍触发效果2」。
func test_pilot_072_popup_might_stack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var bridge = battle.context.action_ui_bridge
	for i in range(2):
		var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
		if i == 0:
			var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
			if ef == null:
				return "第1次 effect_01 未挂起"
			await _resume_discard(battle, ef, [sel])
		else:
			# 直接弃牌（非效果1按钮来源）：效果2照常监听 DISCARD_AFTER 弹窗叠加
			battle.context.deck_service.discard_cards([sel], &"p075_test_discard")
			await _pump_frames(6)
		var w: Dictionary = bridge.get_waiting_action_info()
		if String(w.get("input_type", &"")) != "choose_one_effect":
			return "第%d次弃牌后应弹 choose_one_effect，实=%s" % [(i + 1), String(w.get("input_type", &""))]
		bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
		await _pump_frames(6)
		var expect: int = (i + 1) * 2
		if _counter(gs, s.pilot_card.instance_id) != expect:
			return "第%d次后待发威力应=%d 实=%d" % [(i + 1), expect, _counter(gs, s.pilot_card.instance_id)]
	return true


## 测试3b：效果1每回合限1次--用过1次后再次发动不再挂起（条件拦截），牌不弃、次数不重置
func test_pilot_072_effect1_once_limit() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var bridge = battle.context.action_ui_bridge
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "第1次 effect_01 应挂起"
	await _resume_discard(battle, ef, [sel])
	# 处理掉效果2弹窗（取消：不抽不叠加；效果1计次已在弃牌确认时消耗）
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "弃牌后应弹 choose_one_effect，实=%s" % String(w.get("input_type", &""))
	bridge.on_ui_cancelled()
	await _pump_frames(6)
	# 补第2张牌，效果1再次发动应被 once_per_turn(max=1) 条件拦截（不挂起、不弃牌）
	var sel2: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef2 = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef2 != null:
		return "第2次 effect_01 不应挂起（每回合限1次）"
	if not player.action_hand.has(sel2):
		return "第2张牌不应被弃置"
	return true


## 测试3c：回合结束弃超限牌触发的效果2弹窗，在 end_turn 全流程走完后确认仍生效
## （cancel_all_actions 时机修复后时序：cancel 先于弃牌，弹窗挂起存活到玩家确认。
## 本测试在测试层固化 discard_cards -> end_turn -> 弹窗确认抽牌 完整链路）
func test_pilot_072_turn_end_discard_popup_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var bridge = battle.context.action_ui_bridge
	# 清初始手牌再补1张：手牌1张<=上限，end_turn 第5步不再弃超限牌——否则第5步弃到的
	# 辅助牌会触发效果2a「自动双执行」多抽1张，污染 deck 断言基数
	player.action_hand.clear()
	var hand_before: int = player.action_hand.size()
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var deck_before: int = _action_deck_size(battle)
	# 模拟回合结束弃超限牌（END_TURN_HAND_LIMIT 路径）：效果2弹窗挂起
	battle.context.deck_service.discard_cards([sel], &"END_TURN_HAND_LIMIT")
	await _pump_frames(6)
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "弃牌后应弹 choose_one_effect，实=%s" % String(w.get("input_type", &""))
	# end_turn 全流程走完（弹窗仍挂起，模拟切对手回合后才点弹窗）
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(6)
	# 选"抽1张行动牌"（选项0）--若弹窗动作已被杀则此确认无任何效果
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})
	await _pump_frames(6)
	if not _in_action_discard(battle, sel):
		return "被弃行动牌应进行动弃牌堆"
	if _action_deck_size(battle) != deck_before - 1:
		return "确认抽1后行动牌堆应少1 实=%d" % _action_deck_size(battle)
	if player.action_hand.size() != hand_before + 1:
		return "弃1抽1后手牌应=%d（净+1）实=%d" % [hand_before + 1, player.action_hand.size()]
	var waiting := _waiting_actions(battle.context)
	if not waiting.is_empty():
		return "确认后仍有动作等待: %s" % str(waiting)
	return true


## 测试4：弹窗取消 → 不抽不累加
func test_pilot_072_popup_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var bridge = battle.context.action_ui_bridge
	var hand_before: int = player.action_hand.size()
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel])
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "应弹 choose_one_effect，实=%s" % String(w.get("input_type", &""))
	bridge.on_ui_cancelled()
	await _pump_frames(6)
	if player.action_hand.size() != hand_before:
		return "取消不应抽牌（手牌应保持 %d 实=%d）" % [hand_before, player.action_hand.size()]
	if _counter(gs, s.pilot_card.instance_id) != 0:
		return "取消不应累积待发威力"
	var waiting := _waiting_actions(battle.context)
	if not waiting.is_empty():
		return "取消后仍有动作等待: %s" % str(waiting)
	return true


## 测试5：弃辅助牌 → 自动双效果（抽1 + 威力+2），不弹窗
func test_pilot_072_support_auto_both() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var bridge = battle.context.action_ui_bridge
	var hand_before: int = player.action_hand.size()
	var deck_before: int = _action_deck_size(battle)
	# 补1张辅助牌（维修）并弃置
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_013_维修", s.mech.mech_id)
	if sel == &"":
		return "补辅助牌失败"
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel])
	# 含辅助牌 → 自动双效果，无弹窗
	if not bridge.get_waiting_action_info().is_empty():
		return "弃辅助牌不应弹窗（自动双效果）实=%s" % str(bridge.get_waiting_action_info())
	# 抽1（手牌 = hand_before+1：补1弃1再抽1，净+1）+ 威力+2
	if player.action_hand.size() != hand_before + 1:
		return "弃辅助牌自动抽1后手牌应=%d（弃1抽1净+1）实=%d" % [hand_before + 1, player.action_hand.size()]
	if _action_deck_size(battle) != deck_before - 1:
		return "弃辅助牌自动抽1后牌堆应少1 实=%d" % _action_deck_size(battle)
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "弃辅助牌后待发威力应+2 实=%d" % _counter(gs, s.pilot_card.instance_id)
	var waiting := _waiting_actions(battle.context)
	if not waiting.is_empty():
		return "自动双效果后仍有动作等待: %s" % str(waiting)
	return true


# ═══════════════════════════════════════════
# 行为测试：待发威力应用/消耗/清空
# ═══════════════════════════════════════════

## 测试6：真实攻击（任意武器）——ATTACK_BEFORE 应用 extra_might+2，选目标前生效
func test_pilot_072_might_applies_any_weapon() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var ctx = battle.context
	# 弃1张非辅助 → 弹窗 → 选威力+2 → 待发威力=2
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel])
	var bridge = battle.context.action_ui_bridge
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "前置：应弹 choose_one_effect"
	bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
	await _pump_frames(6)
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "前置：待发威力应=2"
	# 布置相邻 + 发起真实攻击（近战武器亦可——任意武器生效）
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
	if int(atk_act.record.get("extra_might", 0)) != 2:
		return "攻击应含 extra_might=2 实=%d" % int(atk_act.record.get("extra_might", 0))
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "选目标阶段待发威力应仍为2（未消耗）"
	# 走完攻击（结算消耗由测试7验证；此处保证无卡死）
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


## 测试7：攻击完全结算（ATTACK_SETTLE）——待发威力清0
func test_pilot_072_settle_consumes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var ctx = battle.context
	# 累积 +2
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel])
	var bridge = battle.context.action_ui_bridge
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "前置：应弹 choose_one_effect"
	bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
	await _pump_frames(6)
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "前置：待发威力应=2"
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
	# 完全结算 -> 待发威力清0
	if _counter(gs, s.pilot_card.instance_id) != 0:
		return "攻击结算后待发威力应清0 实=%d" % _counter(gs, s.pilot_card.instance_id)
	return true


## 测试8：自己回合结束后（TURN_AFTER_END）——待发威力清空（本回合限定）
func test_pilot_072_turn_after_end_clear() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 累积 +2
	var sel: StringName = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var ef = await _fire_pilot_072_effect1(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel])
	var bridge = battle.context.action_ui_bridge
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "前置：应弹 choose_one_effect"
	bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
	await _pump_frames(6)
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "前置：待发威力应=2"
	# 回合结束后清空（"本回合"待发不带入下回合）
	_fire_turn_timing(battle, _TimingConst.TURN_AFTER_END)
	await _pump_frames(6)
	if _counter(gs, s.pilot_card.instance_id) != 0:
		return "回合结束后待发威力应清0 实=%d" % _counter(gs, s.pilot_card.instance_id)
	return true


# ═══════════════════════════════════════════
# 行为测试：弃置条件边界（合成 DISCARD_AFTER）
# ═══════════════════════════════════════════

## 测试9：弃置条件边界——非辅助弹窗 / 辅助自动 / 混合走自动 / 他人机甲不触发 / 临时区不触发
func test_pilot_072_discard_condition_boundaries() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenensi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var cdb = s.cdb
	var bridge = battle.context.action_ui_bridge
	var pid: StringName = &"player"
	var mid: StringName = s.mech.mech_id
	# 造真实实例：攻击牌（非辅助）+ 维修牌（辅助），mech_id 挂到 player 机甲
	var non_aux = _make_instance(gs, cdb, "action_001_进攻", pid)
	var aux = _make_instance(gs, cdb, "action_013_维修", pid)
	var other = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	non_aux.mech_id = mid
	aux.mech_id = mid
	other.mech_id = s.enemy_mech.mech_id
	# 场景a：非辅助行动牌从 action_hand 弃置 → effect_02 弹窗（不含辅助）
	var base_hand: int = gs.players.get(pid).action_hand.size()
	_fire_discard_after_mock(battle, [_snap(non_aux.instance_id, mid)])
	await _pump_frames(4)
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "场景a：非辅助应弹 choose_one_effect 实=%s" % String(w.get("input_type", &""))
	bridge.on_ui_cancelled()
	await _pump_frames(6)
	if _counter(gs, s.pilot_card.instance_id) != 0:
		return "场景a：取消后威力应不累积"
	# 场景b：辅助牌从 action_hand 弃置 → effect_02_auto 自动双效果（抽1+威力+2），无弹窗
	_fire_discard_after_mock(battle, [_snap(aux.instance_id, mid)])
	await _pump_frames(6)
	if not bridge.get_waiting_action_info().is_empty():
		return "场景b：弃辅助牌不应弹窗 实=%s" % str(bridge.get_waiting_action_info())
	if _counter(gs, s.pilot_card.instance_id) != 2:
		return "场景b：弃辅助牌后待发威力应+2 实=%d" % _counter(gs, s.pilot_card.instance_id)
	if gs.players.get(pid).action_hand.size() != base_hand + 1:
		return "场景b：弃辅助牌自动抽1后手牌应+1 实=%d" % (gs.players.get(pid).action_hand.size() - base_hand)
	# 场景c：混合（辅助+非辅助）弃置 → negate 拦截弹窗，走自动双效果
	_fire_discard_after_mock(battle, [_snap(non_aux.instance_id, mid), _snap(aux.instance_id, mid)])
	await _pump_frames(6)
	if not bridge.get_waiting_action_info().is_empty():
		return "场景c：混合含辅助不应弹窗 实=%s" % str(bridge.get_waiting_action_info())
	if _counter(gs, s.pilot_card.instance_id) != 4:
		return "场景c：混合含辅助后待发威力应+2（叠加至4）实=%d" % _counter(gs, s.pilot_card.instance_id)
	# 场景d：他人机甲的行动牌弃置不触发（from_mech_id 非持有者机甲）
	var hand_d: int = gs.players.get(pid).action_hand.size()
	_fire_discard_after_mock(battle, [_snap(other.instance_id, s.enemy_mech.mech_id)])
	await _pump_frames(6)
	if not bridge.get_waiting_action_info().is_empty():
		return "场景d：他人机甲弃牌不应弹窗 实=%s" % str(bridge.get_waiting_action_info())
	if _counter(gs, s.pilot_card.instance_id) != 4:
		return "场景d：他人机甲弃牌不应累积威力"
	if gs.players.get(pid).action_hand.size() != hand_d:
		return "场景d：他人机甲弃牌不应抽牌"
	# 场景e：自己的行动牌从临时区（转化）弃置不触发（from_zone 非 action_hand）
	var hand_e: int = gs.players.get(pid).action_hand.size()
	_fire_discard_after_mock(battle, [_snap(non_aux.instance_id, mid, "temp_zone")])
	await _pump_frames(6)
	if not bridge.get_waiting_action_info().is_empty():
		return "场景e：临时区弃牌不应弹窗 实=%s" % str(bridge.get_waiting_action_info())
	if _counter(gs, s.pilot_card.instance_id) != 4:
		return "场景e：临时区弃牌不应累积威力"
	if gs.players.get(pid).action_hand.size() != hand_e:
		return "场景e：临时区弃牌不应抽牌"
	return true
