## test_pilot_064_butchel.gd - 布彻尔（pilot_064，联邦 N）效果测试
##
## 布彻尔 2 个效果（主动按钮 + 被动按钮，悬停显示说明）：
##   effect_01「当作进攻」（主动 DIRECT，每玩家回合1次）：我方主阶段，可以将1张行动牌当作进攻使用。
##     使用条件 = 普通进攻行动牌：本回合可攻击（CAN_ACTIVE_ATTACK，凯威攻击窗口期间豁免次数）+
##     范围内有可攻击目标 + 手牌≥1张行动牌 + 每回合1次未用（EFFECT_ONCE_PER_TURN_AVAILABLE +
##     确认后 MARK_EFFECT_ONCE_PER_TURN_USED，取消不计次数）。
##     点按弹我方行动牌单选框（必须选1张）→ 选中牌入临时区 → 当作进攻（PLAY_AS_NAMED 虚拟转化，
##     消耗1次攻击数）→ 链末入弃牌堆。
##   effect_02「进攻加成」（被动 LISTEN，ATTACK_AT 优先级-1，响应判定后发动）：我方使用的进攻
##     获得以下效果：本次攻击被响应则我方抽2张行动牌，未被响应则弃置目标2张行动牌（目标行动牌
##     总数≤2 时不弹窗直接全部弃置）。
##     「进攻类」判定 ATTACK_IS_ASSAULT_CLASS：原版进攻牌 / 转化进攻（virtual_as_def_id）/
##     诺拉视为纯进攻（_effect_flags）都算；强袭/猛击/掩护等非进攻不算。
##
## 关键覆盖点：
##   1. 效果定义（e1 DIRECT 条件+动作链；e2 LISTEN ATTACK_AT priority-1 + CONDITIONAL_ACTIONS）。
##   2. e1 条件门控：无手牌 / 攻击数用尽 / 额度用尽 -> 不可用；满足 -> 可用。
##   3. e1 凯威窗口豁免：攻击数0 + 窗口激活（归属机甲）-> 可用。
##   4. e1 主流程：选1张行动牌 -> 转化进攻 -> 攻击结算 -> 燃料入弃牌堆、攻击数消耗、额度消耗。
##   5. e1 取消：不计次数（额度仍可用）。
##   6. e2 被响应：进攻被响应 -> 我方抽2张行动牌。
##   7. e2 未响应：进攻未响应 -> 弹目标暗牌选框弃2张（我方选）。
##   8. e2 目标≤2张：自动全部弃置不弹窗。
##   9. e2 非进攻（强袭）：不触发。
##   10. e2 转化进攻：e1 转化进攻被响应 -> 同样触发抽2。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _frame() -> void:
	var ml := Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


func _pump_frames(n: int) -> void:
	for i in range(n):
		await _frame()


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90063
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设布彻尔为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_butcher(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_064_布彻尔", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里（注册 AVAILABILITY），返回 instance_id。
func _ensure_card_in_player_hand(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id) == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id) == card_def_id:
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
		if c and c.def and String(c.def.card_id) == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 收集所有残留的 waiting 动作（卡死判定）
func _waiting_actions(ctx) -> Array:
	var waiting: Array = []
	for aid: StringName in ctx.action_registry.get_active_ids():
		var a = ctx.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	return waiting


## 驱动输入循环直到所有动作完成（内部 flush deferred 钩子落地）。
func _drain(battle, driver, max_steps: int = 800) -> void:
	var ctx = battle.context
	var steps := 0
	while steps < max_steps:
		steps += 1
		driver.pump()
		await _frame()
		if driver.pending.is_empty() and _waiting_actions(ctx).is_empty():
			await _frame()
			await _frame()
			break


# ═══════════════════════════════════════════
# 输入驱动器（标准输入自动回填 + 弃牌自动选前N张）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens", &"select_discard_cards",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	var weapon_id: StringName = &"frame_base_weapon_1"
	var enemy_defend_cid: StringName = &""
	var respond_enemy: bool = true
	var target_ids_provider: Callable = Callable()

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
				context.action_service.continue_action(action_id, {"weapon_id": weapon_id})
			&"select_attack_target":
				var tid: StringName = target_ids_provider.call(action_id, input_params)
				context.action_service.continue_action(action_id, {"target_id": tid})
			&"select_move_target":
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				var sel := _response_for(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
			&"place_damage_tokens":
				context.action_service.continue_action(action_id, {"auto_placed": true})
			&"select_discard_cards":
				var dd_count: int = int(input_params.get("count", 1))
				var dd_pid: StringName = StringName(input_params.get("discard_player_id", &""))
				var dd_chosen: Array = []
				var dd_player = context.game_state.players.get(dd_pid) if (dd_pid != &"" and context != null and context.game_state != null) else null
				if dd_player != null:
					dd_chosen = dd_player.action_hand.slice(0, dd_count)
				context.action_service.continue_action(action_id, {"determined_card_ids": dd_chosen})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true

	var enemy_mech_id: StringName = &""

	func _response_for(action_id: StringName) -> Array[Dictionary]:
		var act = context.action_registry.get_action(action_id)
		if act == null:
			return []
		var target: StringName = act.record.get("target_id", &"")
		if respond_enemy and enemy_mech_id != &"" and String(target) == String(enemy_mech_id) and enemy_defend_cid != &"":
			return [{"effect_id": &"defend_availability", "card_instance_id": enemy_defend_cid, "availability_priority": 5}]
		return []


## 找 effect 的 permanent listener binding_context（skill_bar/equipment_panel 按钮用）。
func _find_bind_ctx(te, effect_id: StringName) -> Dictionary:
	var bind_ctx: Dictionary = {}
	var found: bool = false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == String(effect_id):
				bind_ctx = entry.get("binding_context", {})
				found = true
				break
		if found:
			break
	return bind_ctx


## 标准布局：player(10,0) enemy(11,0)，玩家带布彻尔、双方行动手牌清空。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_butcher(battle, &"player")
	if s.is_empty():
		return {}
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	player_mech.attack_count_this_turn = 0
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.enemy_mech_id = enemy_mech.mech_id
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	return {"battle": battle, "driver": driver, "s": s, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "ctx": battle.context}


## 触发 e1（DIRECT 主动）：返回挂起的 effect_fire action（CHOOSE_MANY_CARDS 等待）；null 失败。
func _fire_butcher_e1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_064_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_064_effect_01",
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


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：effect_01 / effect_02 定义正确
func test_pilot_064_effect_definition() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_064_effect_01")
	if e1 == null:
		return "缺 pilot_064_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	# conditions: IS_OWNER_MAIN_PHASE + EFFECT_ONCE_PER_TURN_AVAILABLE + HAS_ACTION_CARD_IN_HAND +
	# HAS_ATTACK_TARGET_IN_RANGE + CAN_ACTIVE_ATTACK
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "HAS_ACTION_CARD_IN_HAND", "HAS_ATTACK_TARGET_IN_RANGE", "CAN_ACTIVE_ATTACK"]:
		if not ops1.has(need):
			return "effect_01 应含条件 %s" % need
	# actions: CHOOSE_MANY_CARDS → MOVE_ACTION_CARDS_TO_TEMP_ZONE → MARK → PLAY_AS_NAMED → DISCARD_TEMP_ZONE_CARDS
	var acts1 = e1.actions
	if acts1.size() != 5:
		return "effect_01 actions 应 5 个 实=%d" % acts1.size()
	if String(acts1[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "actions[0] 应 CHOOSE_MANY_CARDS 实=%s" % String(acts1[0].get("type", &""))
	if String(acts1[1].get("type", &"")) != "MOVE_ACTION_CARDS_TO_TEMP_ZONE":
		return "actions[1] 应 MOVE_ACTION_CARDS_TO_TEMP_ZONE 实=%s" % String(acts1[1].get("type", &""))
	if String(acts1[2].get("type", &"")) != "MARK_EFFECT_ONCE_PER_TURN_USED":
		return "actions[2] 应 MARK_EFFECT_ONCE_PER_TURN_USED 实=%s" % String(acts1[2].get("type", &""))
	if String(acts1[3].get("type", &"")) != "PLAY_AS_NAMED":
		return "actions[3] 应 PLAY_AS_NAMED 实=%s" % String(acts1[3].get("type", &""))
	var pan_p: Dictionary = acts1[3].get("params", {})
	if String(pan_p.get("as_card_def_id", &"")) != "action_001_进攻":
		return "PLAY_AS_NAMED 应 as_card_def_id=action_001_进攻 实=%s" % String(pan_p.get("as_card_def_id", &""))
	if not bool(pan_p.get("attack_is_active", false)):
		return "PLAY_AS_NAMED 应 attack_is_active=true"
	if String(acts1[4].get("type", &"")) != "DISCARD_TEMP_ZONE_CARDS":
		return "actions[4] 应 DISCARD_TEMP_ZONE_CARDS 实=%s" % String(acts1[4].get("type", &""))
	# 不设 effect 级 once_per_turn_key（额度走显式 MARK 通用件）
	if e1.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（额度走显式 MARK 通用件）"

	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_064_effect_02")
	if e2 == null:
		return "缺 pilot_064_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 MODE_LISTEN 实=%s" % String(e2.mode)
	if int(e2.priority) != -1:
		return "effect_02 priority 应 -1（响应窗口关闭后发动，强袭 e2 同模式） 实=%d" % int(e2.priority)
	if String(e2.listen_timing) != String(_TimingConst.ATTACK_AT):
		return "listen_timing 应 ATTACK_AT 实=%s" % String(e2.listen_timing)
	if String(e2.listen_action_type) != "attack":
		return "listen_action_type 应 attack 实=%s" % String(e2.listen_action_type)
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("SELF_MECH_IS_ATTACKER"):
		return "effect_02 应含条件 SELF_MECH_IS_ATTACKER"
	if not ops2.has("ATTACK_IS_ASSAULT_CLASS"):
		return "effect_02 应含条件 ATTACK_IS_ASSAULT_CLASS（进攻类判定）"
	if e2.actions.size() != 1 or String(e2.actions[0].get("type", &"")) != "CONDITIONAL_ACTIONS":
		return "effect_02 actions 应 1 个 CONDITIONAL_ACTIONS"
	var ca_p: Dictionary = e2.actions[0].get("params", {})
	if String(ca_p.get("conditions", [{}])[0].get("op", &"")) != "ATTACK_WAS_RESPONDED":
		return "CONDITIONAL_ACTIONS 条件应 ATTACK_WAS_RESPONDED"
	var if_true: Array = ca_p.get("if_true_actions", [])
	var if_false: Array = ca_p.get("if_false_actions", [])
	if if_true.size() != 1 or String(if_true[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "if_true 应 EXECUTE_GAIN_CARD（被响应抽2）"
	if int(if_true[0].get("params", {}).get("count", 0)) != 2:
		return "if_true 抽牌 count 应 2"
	if if_false.size() != 1 or String(if_false[0].get("type", &"")) != "EXECUTE_DISCARD":
		return "if_false 应 EXECUTE_DISCARD（未响应弃目标2）"
	var fd_p: Dictionary = if_false[0].get("params", {})
	if not bool(fd_p.get("from_target", false)):
		return "if_false 应 from_target=true（弃攻击目标手牌）"
	if int(fd_p.get("count", 0)) != 2:
		return "if_false 弃牌 count 应 2"
	if not bool(fd_p.get("choose", false)):
		return "if_false 应 choose=true（我方选暗牌）"
	if bool(fd_p.get("face_up", true)):
		return "if_false 应 face_up=false（暗牌）"
	if not bool(fd_p.get("auto_discard_all_if_covered", false)):
		return "if_false 应 auto_discard_all_if_covered=true（目标≤2张直接全弃）"
	return true


## 测试2：e1 条件门控——无手牌/攻击数用尽/额度用尽不可用；满足可用。
func test_pilot_064_e1_gate_conditions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_butcher(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_064_布彻尔）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	var te = battle.context.timing_engine
	var eff1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_064_effect_01")
	# 构造触发按钮的 binding_context（skill_bar/equipment_panel 按钮同构：
	# card_instance_id + mech_id + player_id + slot_id）
	var bind_ctx: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"slot_id": &"",
	}

	# 无行动牌 -> 不可用
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "无行动牌时 e1 应不可用"
	# 给1张行动牌 + 攻击数0（可攻击）-> 可用
	var fuel := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if fuel == &"":
		return "无法补1张行动牌"
	if not te.can_trigger_active_effect(eff1, bind_ctx):
		return "手牌≥1 + 可攻击 + 范围有目标 + 额度可用 时 e1 应可用"
	# 攻击数用尽（本回合已攻击1次）-> 不可用
	mech.attack_count_this_turn = mech.max_attacks_per_turn
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "攻击数用尽（非窗口）时 e1 应不可用（CAN_ACTIVE_ATTACK=false）"
	# 恢复攻击数 + 每回合额度用掉 -> 不可用
	mech.attack_count_this_turn = 0
	te.mark_once_per_turn_key_used(&"pilot_064_effect_01", s.pilot_card.instance_id)
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "每回合1次额度用尽时 e1 应不可用（EFFECT_ONCE_PER_TURN_AVAILABLE=false）"
	return true


## 测试3：e1 凯威攻击窗口豁免——攻击数0（已用尽）+ 窗口激活（归属机甲）-> 可用。
func test_pilot_064_e1_window_exempt() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_butcher(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	_ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	var te = battle.context.timing_engine
	var eff1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_064_effect_01")
	var bind_ctx: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"slot_id": &"",
	}
	# 攻击数用尽
	mech.attack_count_this_turn = mech.max_attacks_per_turn
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "前置：非窗口时攻击数用尽应不可用"
	# 打开攻击窗口（归属布彻尔机甲）-> 豁免次数
	_ActionPilotEffects.attack_window_open(gs, &"player", mech.mech_id)
	if not te.can_trigger_active_effect(eff1, bind_ctx):
		return "凯威攻击窗口激活期间 e1 应可用（CAN_ACTIVE_ATTACK 豁免次数）"
	_ActionPilotEffects.attack_window_close(battle.context)
	# 窗口归属其他机甲 -> 不豁免
	_ActionPilotEffects.attack_window_open(gs, &"enemy", enemy_mech.mech_id)
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "窗口归属其他机甲时 e1 不应可用"
	return true


## 测试4：e1 主流程——选1张行动牌 -> 转化进攻 -> 攻击结算。
## 验证：燃料牌入弃牌堆、攻击数+1、每回合额度消耗。
func test_pilot_064_e1_transform_attack() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var gs = setup.gs
	var player_mech = setup.player_mech
	var fuel := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if fuel == &"":
		return "无法补燃料行动牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	var atk_before: int = int(player_mech.attack_count_this_turn)

	var ef = await _fire_butcher_e1(battle, setup.s.pilot_card, player_mech, &"player")
	if ef == null:
		return "e1 触发后应挂起 CHOOSE_MANY_CARDS（effect_fire waiting_timing）"
	# 选燃料牌（选中后入临时区 -> 当作进攻 -> 攻击）
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": [fuel], "cancelled": false})
	await _drain(battle, setup.driver)
	await _pump_frames(8)

	# 攻击数消耗
	if int(player_mech.attack_count_this_turn) != atk_before + 1:
		return "转化进攻应消耗1次攻击数 前=%d 后=%d" % [atk_before, int(player_mech.attack_count_this_turn)]
	# 每回合额度消耗
	var cid: StringName = setup.s.pilot_card.instance_id
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_064_effect_01", cid, 1):
		return "发动后每回合额度应已消耗"
	# 燃料牌入弃牌堆（临时区链末）
	var fuel_card = gs.get_card(fuel)
	if fuel_card == null or String(fuel_card.zone) != "discard":
		return "燃料牌链末应入弃牌堆 实=%s" % (String(fuel_card.zone) if fuel_card != null else "null")
	# 手牌：燃料 -1（无抽牌，非响应路径）
	if gs.players.get(&"player").action_hand.size() != hand_before - 1:
		return "手牌应仅消耗燃料牌 前=%d 后=%d" % [hand_before, gs.players.get(&"player").action_hand.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "e1 转化进攻后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试5：e1 取消——不计次数（额度仍可用），可再触发。
func test_pilot_064_e1_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_butcher(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	_ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	var cid: StringName = s.pilot_card.instance_id
	var te = battle.context.timing_engine
	if not te.is_once_per_turn_key_available(&"pilot_064_effect_01", cid, 1):
		return "前置：额度应可用"

	var ef = await _fire_butcher_e1(battle, s.pilot_card, mech, &"player")
	if ef == null:
		return "e1 触发后应挂起 CHOOSE_MANY_CARDS"
	# 取消选择 -> 不消耗次数、手牌不变
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	if not te.is_once_per_turn_key_available(&"pilot_064_effect_01", cid, 1):
		return "取消选择不应消耗每回合额度"
	if gs.players.get(&"player").action_hand.size() != hand_before:
		return "取消选择手牌不应变化 前=%d 后=%d" % [hand_before, gs.players.get(&"player").action_hand.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "取消后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试6：e2 被响应——进攻被响应 -> 我方抽2张行动牌。
func test_pilot_064_e2_responded_draw2() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺 action_009_防御"
	var deck_before: int = gs.deck_state.action_deck.size()
	var enemy_hand_before: int = gs.players.get(&"enemy").action_hand.size()

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 被响应 -> e2 抽2：牌堆-2、enemy 手牌不变（防御牌被使用后不在手牌）
	if gs.deck_state.action_deck.size() != deck_before - 2:
		return "进攻被响应后 e2 应抽2张行动牌（牌堆-2） 前=%d 后=%d" % [deck_before, gs.deck_state.action_deck.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "e2 被响应抽牌后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试7：e2 未响应——进攻未响应 -> 弹目标暗牌选框弃2张（我方选，enemy 手牌-2）。
func test_pilot_064_e2_not_responded_discard_target() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	# enemy 手牌塞2张行动牌、无响应牌（pass）
	var e1 := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	var e2 := _ensure_card_in_player_hand(battle, &"enemy", "action_002_强袭")
	if e1 == &"" or e2 == &"":
		return "无法给 enemy 补2张行动牌"
	driver.enemy_defend_cid = &""
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 player 进攻牌"
	var enemy_hand_before: int = gs.players.get(&"enemy").action_hand.size()

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 未响应 -> e2 弃目标2张（我方选）：enemy 手牌-2
	if gs.players.get(&"enemy").action_hand.size() != enemy_hand_before - 2:
		return "进攻未响应后 e2 应弃目标2张行动牌 前=%d 后=%d" % [enemy_hand_before, gs.players.get(&"enemy").action_hand.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "e2 未响应弃牌后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试8：e2 未响应且目标≤2张——不弹窗直接全部弃置。
func test_pilot_064_e2_auto_discard_all() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	# enemy 手牌仅1张行动牌、无响应牌
	var e1 := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	if e1 == &"":
		return "无法给 enemy 补1张行动牌"
	driver.enemy_defend_cid = &""
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 player 进攻牌"

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 目标仅1张（≤2）-> 自动全部弃置，enemy 手牌归零、不弹窗
	if gs.players.get(&"enemy").action_hand.size() != 0:
		return "目标≤2张应自动全部弃置（enemy 手牌应0） 实=%d" % gs.players.get(&"enemy").action_hand.size()
	if not _waiting_actions(battle.context).is_empty():
		return "e2 自动全弃后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试9：e2 非进攻（强袭）不触发——enemy 手牌不变、我方不抽。
func test_pilot_064_e2_non_assault_no_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var e1 := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	var e2 := _ensure_card_in_player_hand(battle, &"enemy", "action_002_强袭")
	if e1 == &"" or e2 == &"":
		return "无法给 enemy 补2张行动牌"
	driver.enemy_defend_cid = &""
	var smash_cid := _ensure_card_in_player_hand(battle, &"player", "action_002_强袭")
	if smash_cid == &"":
		return "缺 player 强袭牌"
	var enemy_hand_before: int = gs.players.get(&"enemy").action_hand.size()
	var deck_before: int = gs.deck_state.action_deck.size()

	battle.execute_use_action_card(&"player", smash_cid)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 非进攻（强袭）-> e2 不触发：enemy 手牌不变、牌堆不变（不抽）
	if gs.players.get(&"enemy").action_hand.size() != enemy_hand_before:
		return "强袭（非进攻）e2 不应弃目标手牌 前=%d 后=%d" % [enemy_hand_before, gs.players.get(&"enemy").action_hand.size()]
	if gs.deck_state.action_deck.size() != deck_before:
		return "强袭（非进攻）e2 不应抽牌（牌堆-0） 前=%d 后=%d" % [deck_before, gs.deck_state.action_deck.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "强袭攻击后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试10：e2 转化进攻——e1 转化进攻被响应 -> 同样触发抽2。
func test_pilot_064_e2_transform_assault_triggers() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	# enemy 用防御响应转化进攻
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺 action_009_防御"
	var fuel := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if fuel == &"":
		return "无法补燃料行动牌"
	var deck_before: int = gs.deck_state.action_deck.size()

	var ef = await _fire_butcher_e1(battle, setup.s.pilot_card, player_mech, &"player")
	if ef == null:
		return "e1 触发后应挂起 CHOOSE_MANY_CARDS"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": [fuel], "cancelled": false})
	await _drain(battle, driver)
	await _pump_frames(10)

	# 转化进攻被响应 -> e2 抽2：牌堆-2
	if gs.deck_state.action_deck.size() != deck_before - 2:
		return "转化进攻被响应后 e2 应抽2张行动牌（牌堆-2） 前=%d 后=%d" % [deck_before, gs.deck_state.action_deck.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "转化进攻被响应后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true
