## test_pilot_068_dan.gd - 丹（pilot_068，联邦 N）效果测试
##
## 丹 2 个效果（主动按钮 + 被动按钮，悬停显示说明）：
##   effect_01「当作双连」（主动 DIRECT，每玩家回合1次）：我方主阶段，可以将1张行动牌当作双连使用。
##     使用条件 = 普通双连行动牌（action_005_双连）：本回合可攻击（CAN_ACTIVE_ATTACK，凯威攻击窗口
##     期间豁免次数）+ 范围内有可攻击目标 + 手牌≥1张行动牌 + 每回合1次未用（EFFECT_ONCE_PER_TURN_AVAILABLE
##     + 确认后 MARK_EFFECT_ONCE_PER_TURN_USED，取消不计次数）。
##     点按弹我方行动牌单选框（必须选1张）→ 选中牌入临时区 → 当作双连（PLAY_AS_NAMED 虚拟转化，
##     双连为攻击牌，消耗1次攻击数）→ 链末入弃牌堆。
##   effect_02「双连加成」（被动 LISTEN，ATTACK_PRE 优先级-1，其后触发）：我方使用的双连若指定了
##     2个目标，则威力+3，命中额外产生1损伤。
##     「双连」判定 ATTACK_IS_NAMED_CARD(card_def_id=action_005_双连)：原版双连卡（def.card_id）/
##     转化双连（virtual_as_def_id，丹当作双连 PLAY_AS_NAMED 写入）都算；强袭/猛击/掩护等非双连不算。
##     2目标判定 ATTACK_TARGET_COUNT_AT_LEAST(count=2)：ATTACK_PRE 时 select_target handler 已先写
##     target_ids，故可读。
##     威力+3：MODIFY_ATTACK_MIGHT 写 record.extra_might，多目标 fork 深拷贝继承，每个复制攻击+3。
##     命中+1损伤：MODIFY_ATTACK_MARKERS fork_persist=true 写 record.fork_extra_markers，fork 深拷贝
##     保留（清 extra_markers 不清 fork_extra_markers），每个复制攻击命中时+1损伤（未命中不产生）。
##
## 关键覆盖点：
##   1. 效果定义（e1 DIRECT 条件+动作链；e2 LISTEN ATTACK_PRE priority-1 + 2 个 MODIFY）。
##   2. e1 条件门控：无手牌 / 攻击数用尽 / 额度用尽 -> 不可用；满足 -> 可用。
##   3. e1 凯威窗口豁免：攻击数0 + 窗口激活（归属机甲）-> 可用。
##   4. e1 主流程：选1张行动牌 -> 转化双连 -> 攻击结算 -> 燃料入弃牌堆、攻击数消耗、额度消耗。
##   5. e1 取消：不计次数（额度仍可用）。
##   6. e2 双连2目标：fire ATTACK_PRE -> extra_might+3、fork_extra_markers+1，fork 深拷贝继承。
##   7. e2 双连1目标：不触发（ATTACK_TARGET_COUNT_AT_LEAST 失败）。
##   8. e2 非双连（进攻）：不触发（ATTACK_IS_NAMED_CARD 失败）。
##   9. e2 转化双连（virtual_as_def_id=action_005_双连）：触发。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


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
	battle.rng_seed = 90067
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


## 设丹为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_dan(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_068_丹", owner_id)
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


## 创建第 2 台敌方机甲（敌方阵营），放在指定位置，6 部件槽（无装备，护甲=0）。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary) -> _MechState:
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


## 构造 attack action（fire ATTACK_PRE 用）。attack_card_id 指定来源行动牌实例（e2 判定用）。
func _make_attack(battle, attacker_id: StringName, attacker_pid: StringName, attack_card_cid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p067_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	if attack_card_cid != &"":
		attack.record["attack_card_id"] = attack_card_cid
	battle.context.action_registry.register(attack)
	return attack


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


## 标准布局：player(10,0) enemy(11,0)，玩家带丹、双方行动手牌清空。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_dan(battle, &"player")
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
func _fire_dan_e1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_068_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_068_effect_01",
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
func test_pilot_068_effect_definition() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_01")
	if e1 == null:
		return "缺 pilot_068_effect_01"
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
	if String(pan_p.get("as_card_def_id", &"")) != "action_005_双连":
		return "PLAY_AS_NAMED 应 as_card_def_id=action_005_双连 实=%s" % String(pan_p.get("as_card_def_id", &""))
	if not bool(pan_p.get("attack_is_active", false)):
		return "PLAY_AS_NAMED 应 attack_is_active=true（双连为攻击牌消耗攻击数）"
	if String(acts1[4].get("type", &"")) != "DISCARD_TEMP_ZONE_CARDS":
		return "actions[4] 应 DISCARD_TEMP_ZONE_CARDS 实=%s" % String(acts1[4].get("type", &""))
	# 不设 effect 级 once_per_turn_key（额度走显式 MARK 通用件）
	if e1.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（额度走显式 MARK 通用件）"

	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_02")
	if e2 == null:
		return "缺 pilot_068_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 MODE_LISTEN 实=%s" % String(e2.mode)
	if int(e2.priority) != -1:
		return "effect_02 priority 应 -1（最低优先级，其他效果之后触发） 实=%d" % int(e2.priority)
	if String(e2.listen_timing) != String(_TimingConst.ATTACK_PRE):
		return "listen_timing 应 ATTACK_PRE 实=%s" % String(e2.listen_timing)
	if String(e2.listen_action_type) != "attack":
		return "listen_action_type 应 attack 实=%s" % String(e2.listen_action_type)
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("SELF_MECH_IS_ATTACKER"):
		return "effect_02 应含条件 SELF_MECH_IS_ATTACKER"
	if not ops2.has("ATTACK_IS_NAMED_CARD"):
		return "effect_02 应含条件 ATTACK_IS_NAMED_CARD（双连判定）"
	if not ops2.has("ATTACK_TARGET_COUNT_AT_LEAST"):
		return "effect_02 应含条件 ATTACK_TARGET_COUNT_AT_LEAST（2目标判定）"
	var anc = null
	var atc = null
	for c in e2.conditions:
		if String(c.get("op", &"")) == "ATTACK_IS_NAMED_CARD":
			anc = c
		if String(c.get("op", &"")) == "ATTACK_TARGET_COUNT_AT_LEAST":
			atc = c
	if String(anc.get("params", {}).get("card_def_id", &"")) != "action_005_双连":
		return "ATTACK_IS_NAMED_CARD 应 card_def_id=action_005_双连 实=%s" % String(anc.get("params", {}).get("card_def_id", &""))
	if int(atc.get("params", {}).get("count", 0)) != 2:
		return "ATTACK_TARGET_COUNT_AT_LEAST count 应 2 实=%d" % int(atc.get("params", {}).get("count", 0))
	# actions: MODIFY_ATTACK_MIGHT delta3 + MODIFY_ATTACK_MARKERS delta1 fork_persist
	var acts2 = e2.actions
	if acts2.size() != 2:
		return "effect_02 actions 应 2 个 实=%d" % acts2.size()
	if String(acts2[0].get("type", &"")) != "MODIFY_ATTACK_MIGHT":
		return "actions[0] 应 MODIFY_ATTACK_MIGHT 实=%s" % String(acts2[0].get("type", &""))
	if int(acts2[0].get("params", {}).get("delta", 0)) != 3:
		return "MODIFY_ATTACK_MIGHT delta 应 3 实=%d" % int(acts2[0].get("params", {}).get("delta", 0))
	if String(acts2[1].get("type", &"")) != "MODIFY_ATTACK_MARKERS":
		return "actions[1] 应 MODIFY_ATTACK_MARKERS 实=%s" % String(acts2[1].get("type", &""))
	if int(acts2[1].get("params", {}).get("delta", 0)) != 1:
		return "MODIFY_ATTACK_MARKERS delta 应 1 实=%d" % int(acts2[1].get("params", {}).get("delta", 0))
	if not bool(acts2[1].get("params", {}).get("fork_persist", false)):
		return "MODIFY_ATTACK_MARKERS 应 fork_persist=true（双连每个复制攻击都继承）"
	return true


## 测试2：e1 条件门控——无手牌/攻击数用尽/额度用尽不可用；满足可用。
func test_pilot_068_e1_gate_conditions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_068_丹）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	var te = battle.context.timing_engine
	var eff1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_01")
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
	te.mark_once_per_turn_key_used(&"pilot_068_effect_01", s.pilot_card.instance_id)
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "每回合1次额度用尽时 e1 应不可用（EFFECT_ONCE_PER_TURN_AVAILABLE=false）"
	return true


## 测试3：e1 凯威攻击窗口豁免——攻击数0（已用尽）+ 窗口激活（归属机甲）-> 可用。
func test_pilot_068_e1_window_exempt() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
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
	var eff1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_01")
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
	# 打开攻击窗口（归属丹机甲）-> 豁免次数
	_ActionPilotEffects.attack_window_open(gs, &"player", mech.mech_id)
	if not te.can_trigger_active_effect(eff1, bind_ctx):
		return "凯威攻击窗口激活期间 e1 应可用（CAN_ACTIVE_ATTACK 豁免次数）"
	_ActionPilotEffects.attack_window_close(battle.context)
	# 窗口归属其他机甲 -> 不豁免
	_ActionPilotEffects.attack_window_open(gs, &"enemy", enemy_mech.mech_id)
	if te.can_trigger_active_effect(eff1, bind_ctx):
		return "窗口归属其他机甲时 e1 不应可用"
	return true


## 测试4：e1 主流程——选1张行动牌 -> 转化双连 -> 攻击结算。
## 验证：燃料牌入弃牌堆、攻击数+1、每回合额度消耗。
func test_pilot_068_e1_transform_dual_strike() -> Variant:
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

	var ef = await _fire_dan_e1(battle, setup.s.pilot_card, player_mech, &"player")
	if ef == null:
		return "e1 触发后应挂起 CHOOSE_MANY_CARDS（effect_fire waiting_timing）"
	# 选燃料牌（选中后入临时区 -> 当作双连 -> 攻击）
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": [fuel], "cancelled": false})
	await _drain(battle, setup.driver)
	await _pump_frames(8)

	# 攻击数消耗
	if int(player_mech.attack_count_this_turn) != atk_before + 1:
		return "转化双连应消耗1次攻击数 前=%d 后=%d" % [atk_before, int(player_mech.attack_count_this_turn)]
	# 每回合额度消耗
	var cid: StringName = setup.s.pilot_card.instance_id
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_068_effect_01", cid, 1):
		return "发动后每回合额度应已消耗"
	# 燃料牌入弃牌堆（临时区链末）
	var fuel_card = gs.get_card(fuel)
	if fuel_card == null or String(fuel_card.zone) != "discard":
		return "燃料牌链末应入弃牌堆 实=%s" % (String(fuel_card.zone) if fuel_card != null else "null")
	# 手牌：燃料 -1（无抽牌，非响应路径）
	if gs.players.get(&"player").action_hand.size() != hand_before - 1:
		return "手牌应仅消耗燃料牌 前=%d 后=%d" % [hand_before, gs.players.get(&"player").action_hand.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "e1 转化双连后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试5：e1 取消——不计次数（额度仍可用），可再触发。
func test_pilot_068_e1_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
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
	if not te.is_once_per_turn_key_available(&"pilot_068_effect_01", cid, 1):
		return "前置：额度应可用"

	var ef = await _fire_dan_e1(battle, s.pilot_card, mech, &"player")
	if ef == null:
		return "e1 触发后应挂起 CHOOSE_MANY_CARDS"
	# 取消选择 -> 不消耗次数、手牌不变
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	if not te.is_once_per_turn_key_available(&"pilot_068_effect_01", cid, 1):
		return "取消选择不应消耗每回合额度"
	if gs.players.get(&"player").action_hand.size() != hand_before:
		return "取消选择手牌不应变化 前=%d 后=%d" % [hand_before, gs.players.get(&"player").action_hand.size()]
	if not _waiting_actions(battle.context).is_empty():
		return "取消后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试6：e2 双连2目标——fire ATTACK_PRE -> extra_might+3、fork_extra_markers+1，fork 深拷贝继承。
func test_pilot_068_e2_dual_strike_2_targets_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech_p067", {"q": 2, "r": 3})
	# 真实双连卡实例作为攻击来源
	var dual_cid = _make_instance(gs, s.cdb, "action_005_双连", &"player")
	if dual_cid == null:
		return "缺 action_005_双连 卡定义"

	# ── 主攻击：2 个目标 + 来源双连卡，fire ATTACK_PRE ──
	var main_attack := _make_attack(battle, mech.mech_id, &"player", dual_cid.instance_id)
	main_attack.record["target_ids"] = [enemy_mech.mech_id, enemy2_mech.mech_id]
	main_attack.record["target_count"] = 2
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, main_attack)
	await _pump_frames(6)

	# e2 应触发：extra_might+3、fork_extra_markers+1
	if int(main_attack.record.get("extra_might", 0)) != 3:
		return "双连2目标 e2 应写 extra_might=3 实=%d" % int(main_attack.record.get("extra_might", 0))
	if int(main_attack.record.get("fork_extra_markers", 0)) != 1:
		return "双连2目标 e2 应写 fork_extra_markers=1 实=%d" % int(main_attack.record.get("fork_extra_markers", 0))

	# ── 模拟 fork：深拷贝主攻击 record（仿 attack_action._create_fork_sub_action）──
	var fork_record: Dictionary = main_attack.record.duplicate(true)
	fork_record["target_id"] = enemy_mech.mech_id
	fork_record["target_ids"] = [enemy_mech.mech_id]
	fork_record["target_count"] = 1
	fork_record["hit"] = true
	fork_record["markers"] = 0
	fork_record.erase("extra_markers")  # fork 清 extra_markers，保留 fork_extra_markers
	# 继承校验
	if int(fork_record.get("extra_might", 0)) != 3:
		return "fork 应继承 extra_might=3 实=%d" % int(fork_record.get("extra_might", 0))
	if int(fork_record.get("fork_extra_markers", 0)) != 1:
		return "fork 应继承 fork_extra_markers=1 实=%d" % int(fork_record.get("fork_extra_markers", 0))
	# 命中损伤合并（仿 attack_action._step_apply_damage line569）：
	# markers = max(0, markers + extra_markers + fork_extra_markers) -> 0+0+1=1
	var merged: int = max(0, int(fork_record.get("markers", 0)) + int(fork_record.get("extra_markers", 0)) + int(fork_record.get("fork_extra_markers", 0)))
	if merged != 1:
		return "fork 命中损伤应+1 实=%d" % merged
	return true


## 测试7：e2 双连1目标——不触发（ATTACK_TARGET_COUNT_AT_LEAST 失败）。
func test_pilot_068_e2_single_target_no_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var dual_cid = _make_instance(gs, s.cdb, "action_005_双连", &"player")
	if dual_cid == null:
		return "缺 action_005_双连 卡定义"

	var attack := _make_attack(battle, mech.mech_id, &"player", dual_cid.instance_id)
	attack.record["target_ids"] = [enemy_mech.mech_id]
	attack.record["target_count"] = 1
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(6)
	if int(attack.record.get("extra_might", 0)) != 0:
		return "双连1目标 e2 不应写 extra_might 实=%d" % int(attack.record.get("extra_might", 0))
	if int(attack.record.get("fork_extra_markers", 0)) != 0:
		return "双连1目标 e2 不应写 fork_extra_markers 实=%d" % int(attack.record.get("fork_extra_markers", 0))
	return true


## 测试8：e2 非双连（进攻）——不触发（ATTACK_IS_NAMED_CARD 失败）。
func test_pilot_068_e2_non_dual_strike_no_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech_p067b", {"q": 2, "r": 3})
	var atk_cid = _make_instance(gs, s.cdb, "action_001_进攻", &"player")
	if atk_cid == null:
		return "缺 action_001_进攻 卡定义"

	var attack := _make_attack(battle, mech.mech_id, &"player", atk_cid.instance_id)
	attack.record["target_ids"] = [enemy_mech.mech_id, enemy2_mech.mech_id]
	attack.record["target_count"] = 2
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(6)
	if int(attack.record.get("extra_might", 0)) != 0:
		return "进攻（非双连）e2 不应写 extra_might 实=%d" % int(attack.record.get("extra_might", 0))
	if int(attack.record.get("fork_extra_markers", 0)) != 0:
		return "进攻（非双连）e2 不应写 fork_extra_markers 实=%d" % int(attack.record.get("fork_extra_markers", 0))
	return true


## 测试9：e2 转化双连（virtual_as_def_id=action_005_双连）——触发。
func test_pilot_068_e2_transform_dual_strike_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_dan(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech_p067c", {"q": 2, "r": 3})
	# 燃料牌（进攻）经 PLAY_AS_NAMED 转化为双连：counters.virtual_as_def_id=action_005_双连
	var fuel = _make_instance(gs, s.cdb, "action_001_进攻", &"player")
	if fuel == null:
		return "缺燃料卡定义"
	fuel.counters["virtual_as_def_id"] = &"action_005_双连"

	var attack := _make_attack(battle, mech.mech_id, &"player", fuel.instance_id)
	attack.record["target_ids"] = [enemy_mech.mech_id, enemy2_mech.mech_id]
	attack.record["target_count"] = 2
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(6)
	if int(attack.record.get("extra_might", 0)) != 3:
		return "转化双连（virtual_as_def_id）e2 应写 extra_might=3 实=%d" % int(attack.record.get("extra_might", 0))
	if int(attack.record.get("fork_extra_markers", 0)) != 1:
		return "转化双连（virtual_as_def_id）e2 应写 fork_extra_markers=1 实=%d" % int(attack.record.get("fork_extra_markers", 0))
	return true
