## test_pilot_076_疾风.gd - 疾风（pilot_076）效果测试
##
## 疾风 2 个效果按钮（通用件，不绑机师）：
##   effect_01（LISTEN USE_ACTION_BEFORE priority30，迎击牌响应时强制消耗响应方/攻击方3动力）
##   effect_02（隐藏 LISTEN USE_ACTION_SETTLE priority30，迎击牌/攻击牌结算后自动获得该牌）
##
## 原文：「我方发动的攻击被迎击牌响应时，消耗响应方3动力，该迎击牌结算后获得该牌。
##        我方响应攻击牌发动的攻击时，消耗攻击方3动力，该攻击牌结算后获得该牌。」
##
## 通用件：COUNTER_POWER_DRAIN_TARGET（按 binding 角色返被消耗方 mech_id）/COUNTER_CLAIM_TRIGGERED
## （获牌A:迎击牌+attacker==self / 获牌B:攻击牌+responded+响应方==self）/CLAIM_RESOLVED_ATTACK_SOURCE_CARD
## （复用珀修斯 pilot_007 从弃牌堆回收）。转化迎击由 ATTACK_SOURCE_ACTION_CARD_TYPE_IS(迎击)读
## def.action_type 天然排除（转化牌保留原类型≠迎击，故 effect_01/02 均不触发；条件已存于 effect_01）。
##
## 关键覆盖点：
##   1. 效果定义（effect_01/02 的 mode/timing/conditions/target_rules/actions + 排除转化的迎击类型条件）。
##   2. 分支A：玩家攻击敌方->敌方迎击响应->消耗响应方(敌方)3动力->迎击牌结算后玩家获迎击牌。
##   3. 分支B：敌方攻击玩家->玩家迎击响应->消耗攻击方(敌方)3动力->攻击牌结算后玩家获攻击牌。
##   4. 未响应：不消耗动力、不获牌。
##   5. 动力<3：clamp 到 0（MODIFY_MECH_POWER min_value:0）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
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
	battle.rng_seed = 90076
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


## 设疾风为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_jifeng(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_076_疾风", owner_id)
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


## 收集所有残留 waiting 动作（卡死判定）
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


## 玩家手牌是否含某张牌实例
func _hand_has(gs, player_id: StringName, card_instance_id: StringName) -> bool:
	var p = gs.players.get(player_id)
	if p == null:
		return false
	for cid: StringName in p.action_hand:
		if cid == card_instance_id:
			return true
	return false


# ═══════════════════════════════════════════
# 输入驱动器（标准输入自动回填）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	# 武器选择：一律第 1 把基础武器（全机甲统一虚拟ID frame_base_weapon_N）
	var weapon_id: StringName = &"frame_base_weapon_1"
	# 敌方迎击响应（分支A：玩家攻击敌方，敌方迎击）
	var enemy_mech_id: StringName = &""
	var enemy_defend_cid: StringName = &""     # 响应 target 为 enemy_mech_id 时使用的防御牌
	var respond_enemy: bool = true
	# 玩家迎击响应（分支B：敌方攻击玩家，玩家迎击）
	var player_mech_id: StringName = &""
	var player_defend_cid: StringName = &""    # 响应 target 为 player_mech_id 时使用的防御牌
	var respond_player: bool = true
	# 攻击目标选择回调：(action_id, input_params) -> StringName 或 Array（target_ids）
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

	## 推进一处标准输入。返回 true 表示推进了；false 表示无待处理。
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
				var target_count: int = int(input_params.get("target_count", 1))
				if target_count >= 2 and target_ids_provider.is_valid():
					context.action_service.continue_action(action_id, {"target_ids": target_ids_provider.call(action_id, input_params)})
				else:
					var tid: StringName = target_ids_provider.call(action_id, input_params)
					context.action_service.continue_action(action_id, {"target_id": tid})
			&"select_move_target":
				# 测试不移动（防御响应无移动；回避响应时取消）
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				var sel := _response_for(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
			&"place_damage_tokens":
				context.action_service.continue_action(action_id, {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true

	## 根据攻击目标决定用哪方防御牌响应。
	func _response_for(action_id: StringName) -> Array[Dictionary]:
		var act = context.action_registry.get_action(action_id)
		if act == null:
			return []
		var target: StringName = act.record.get("target_id", &"")
		# 分支B：玩家迎击响应敌方攻击（target==player_mech_id）
		if respond_player and player_mech_id != &"" and String(target) == String(player_mech_id) and player_defend_cid != &"":
			return [{"effect_id": &"defend_availability", "card_instance_id": player_defend_cid, "availability_priority": 5}]
		# 分支A：敌方迎击响应玩家攻击（target==enemy_mech_id）
		if respond_enemy and enemy_mech_id != &"" and String(target) == String(enemy_mech_id) and enemy_defend_cid != &"":
			return [{"effect_id": &"defend_availability", "card_instance_id": enemy_defend_cid, "availability_priority": 5}]
		return []


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 1. 效果定义：effect_01/02 结构 + 排除转化的迎击类型条件
func test_pilot_076_effect_definition() -> Variant:
	var battle := _new_battle()
	var s = _setup_jifeng(battle, &"player")
	if s.is_empty():
		return "setup 疾风失败"
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var e1 = all_effects.get(&"pilot_076_effect_01")
	if e1 == null:
		return "缺 pilot_076_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if int(e1.priority) != 30:
		return "effect_01 priority 应 30 实=%d" % int(e1.priority)
	if String(e1.listen_timing) != String(_TimingConst.USE_ACTION_BEFORE):
		return "effect_01 listen_timing 应 USE_ACTION_BEFORE 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "use_action_card":
		return "effect_01 listen_action_type 应 use_action_card 实=%s" % String(e1.listen_action_type)
	# conditions: ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD + ATTACK_SOURCE_ACTION_CARD_TYPE_IS(迎击)
	# + COUNTER_HAS_ATTACK_ACTION_ID（转化牌 def.action_type≠迎击，天然不匹配，排除转化迎击）
	var ops: Array = []
	var yingji_params_ok := false
	for c in e1.conditions:
		var cdict: Dictionary = c if c is Dictionary else {}
		ops.append(String(cdict.get("op", &"")))
		if String(cdict.get("op", &"")) == "ATTACK_SOURCE_ACTION_CARD_TYPE_IS":
			if String(cdict.get("params", {}).get("card_type", &"")) == "迎击":
				yingji_params_ok = true
	if not ops.has("ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"):
		return "effect_01 应含条件 ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"
	if not ops.has("ATTACK_SOURCE_ACTION_CARD_TYPE_IS"):
		return "effect_01 应含条件 ATTACK_SOURCE_ACTION_CARD_TYPE_IS（排除转化迎击）"
	if not yingji_params_ok:
		return "effect_01 ATTACK_SOURCE_ACTION_CARD_TYPE_IS params.card_type 应为 迎击"
	if not ops.has("COUNTER_HAS_ATTACK_ACTION_ID"):
		return "effect_01 应含条件 COUNTER_HAS_ATTACK_ACTION_ID"
	# target_rules: COUNTER_POWER_DRAIN_TARGET
	if e1.target_rules.is_empty() or String(e1.target_rules[0].get("rule", &"")) != "COUNTER_POWER_DRAIN_TARGET":
		return "effect_01 target_rules 应含 COUNTER_POWER_DRAIN_TARGET"
	# actions: FOR_EACH_TARGET -> MODIFY_MECH_POWER(delta=-3, min_value=0)
	if e1.actions.is_empty() or String(e1.actions[0].get("type", &"")) != "FOR_EACH_TARGET":
		return "effect_01 actions 应以 FOR_EACH_TARGET 开头"
	var fet_params: Dictionary = e1.actions[0].get("params", {}) if e1.actions[0] is Dictionary else {}
	var inner: Array = fet_params.get("actions", [])
	if inner.is_empty() or String(inner[0].get("type", &"")) != "MODIFY_MECH_POWER":
		return "effect_01 FOR_EACH_TARGET 内应 MODIFY_MECH_POWER"
	var mp_params: Dictionary = inner[0].get("params", {}) if inner[0] is Dictionary else {}
	if int(mp_params.get("delta", 0)) != -3:
		return "effect_01 MODIFY_MECH_POWER delta 应 -3 实=%d" % int(mp_params.get("delta", 0))
	if int(mp_params.get("min_value", -1)) != 0:
		return "effect_01 MODIFY_MECH_POWER min_value 应 0（clamp）实=%d" % int(mp_params.get("min_value", -1))

	var e2 = all_effects.get(&"pilot_076_effect_02")
	if e2 == null:
		return "缺 pilot_076_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 MODE_LISTEN 实=%s" % String(e2.mode)
	if String(e2.listen_timing) != String(_TimingConst.USE_ACTION_SETTLE):
		return "effect_02 listen_timing 应 USE_ACTION_SETTLE 实=%s" % String(e2.listen_timing)
	if String(e2.listen_action_type) != "use_action_card":
		return "effect_02 listen_action_type 应 use_action_card 实=%s" % String(e2.listen_action_type)
	if not bool(e2.hide_button):
		return "effect_02 应 hide_button=true（隐藏按钮，合并到 effect_01 悬停）"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1（合并到 effect_01 按钮）"
	# conditions: COUNTER_CLAIM_TRIGGERED（获牌A OR 获牌B）
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String((c if c is Dictionary else {}).get("op", &"")))
	if not e2_ops.has("COUNTER_CLAIM_TRIGGERED"):
		return "effect_02 应含条件 COUNTER_CLAIM_TRIGGERED"
	# actions: CLAIM_RESOLVED_ATTACK_SOURCE_CARD（自动获牌，无弹窗）
	if e2.actions.is_empty() or String(e2.actions[0].get("type", &"")) != "CLAIM_RESOLVED_ATTACK_SOURCE_CARD":
		return "effect_02 actions 应含 CLAIM_RESOLVED_ATTACK_SOURCE_CARD"
	return true


## 标准布局：player(10,0) enemy(11,0) 相邻，玩家带疾风、双方手牌清空、动力各 10。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}。
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_jifeng(battle, &"player")
	if s.is_empty():
		return {}
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return {}
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	player_mech.power = 10
	player_mech.max_power = 10
	enemy_mech.power = 10
	enemy_mech.max_power = 10
	player_mech.attack_count_this_turn = 0
	enemy_mech.attack_count_this_turn = 0
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.enemy_mech_id = enemy_mech.mech_id
	driver.player_mech_id = player_mech.mech_id
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	return {"battle": battle, "driver": driver, "s": s, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "ctx": battle.context}


## 2. 分支A：玩家攻击敌方->敌方迎击响应->消耗响应方(敌方)3动力->迎击牌结算后玩家获迎击牌
func test_pilot_076_branch_a_drain_responder_gain_counter() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var player_mech = std.player_mech
	var enemy_mech = std.enemy_mech
	# 玩家手牌：攻击牌；敌方手牌：防御牌（迎击）
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var defend_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if defend_cid == &"":
		return "缺 action_009_防御（敌方）"
	driver.enemy_defend_cid = defend_cid
	driver.respond_enemy = true
	driver.respond_player = false
	var enemy_power_before = int(enemy_mech.power)
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	# 验证：响应方（敌方）动力 -3
	if int(enemy_mech.power) != enemy_power_before - 3:
		return "分支A：敌方(响应方)动力应 %d 实 %d" % [enemy_power_before - 3, int(enemy_mech.power)]
	# 验证：玩家从弃牌堆获得该迎击牌（防御牌同一实例）
	if not _hand_has(gs, &"player", defend_cid):
		return "分支A：玩家应获迎击牌(action_009_防御 instance=%s)" % String(defend_cid)
	# 攻击牌已打出弃置，不应回到玩家手牌
	if _hand_has(gs, &"player", atk_cid):
		return "分支A：攻击牌不应回到玩家手牌"
	# 等待动作应清空（无卡死）
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "分支A：残留 waiting 动作 %s" % str(wait)
	return true


## 3. 分支B：敌方攻击玩家->玩家迎击响应->消耗攻击方(敌方)3动力->攻击牌结算后玩家获攻击牌
func test_pilot_076_branch_b_drain_attacker_gain_attack() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var player_mech = std.player_mech
	var enemy_mech = std.enemy_mech
	# 敌方手牌：攻击牌；玩家手牌：防御牌（迎击）
	var enemy_atk_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	if enemy_atk_cid == &"":
		return "缺 action_001_进攻（敌方）"
	var player_defend_cid := _ensure_card_in_player_hand(battle, &"player", "action_009_防御")
	if player_defend_cid == &"":
		return "缺 action_009_防御（玩家）"
	# 分支B：敌方攻击玩家 -> target=player_mech，玩家迎击响应
	driver.respond_enemy = false
	driver.respond_player = true
	driver.player_defend_cid = player_defend_cid
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return player_mech.mech_id
	var enemy_power_before = int(enemy_mech.power)
	battle.execute_use_action_card(&"enemy", enemy_atk_cid)
	await _drain(battle, driver)
	# 验证：攻击方（敌方）动力 -3
	if int(enemy_mech.power) != enemy_power_before - 3:
		return "分支B：敌方(攻击方)动力应 %d 实 %d" % [enemy_power_before - 3, int(enemy_mech.power)]
	# 验证：玩家从弃牌堆获得该攻击牌（进攻牌同一实例）
	if not _hand_has(gs, &"player", enemy_atk_cid):
		return "分支B：玩家应获攻击牌(action_001_进攻 instance=%s)" % String(enemy_atk_cid)
	# 玩家打出的防御牌已弃置，不应回到玩家手牌
	if _hand_has(gs, &"player", player_defend_cid):
		return "分支B：防御牌(玩家打出)不应回到玩家手牌"
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "分支B：残留 waiting 动作 %s" % str(wait)
	return true


## 4. 未响应：不消耗动力、不获牌
func test_pilot_076_unresponded_no_drain_no_gain() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var player_mech = std.player_mech
	var enemy_mech = std.enemy_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	# 敌方不响应（pass）
	driver.respond_enemy = false
	driver.respond_player = false
	var enemy_power_before = int(enemy_mech.power)
	var player_hand_before = (gs.players[&"player"].action_hand as Array).duplicate()
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	# 验证：未响应 -> 敌方动力不变
	if int(enemy_mech.power) != enemy_power_before:
		return "未响应：敌方动力不应变 实 %d（前 %d）" % [int(enemy_mech.power), enemy_power_before]
	# 验证：玩家未获牌（攻击牌打出弃置，无迎击牌可获；手牌数应 ≤ 打出前）
	var player_hand_after = gs.players[&"player"].action_hand as Array
	if player_hand_after.size() > player_hand_before.size():
		return "未响应：玩家不应获牌 实手牌数 %d（前 %d）" % [player_hand_after.size(), player_hand_before.size()]
	# 攻击牌打出后不应在手牌
	if _hand_has(gs, &"player", atk_cid):
		return "未响应：攻击牌打出后不应回到手牌"
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "未响应：残留 waiting 动作 %s" % str(wait)
	return true


## 5. 动力<3：clamp 到 0（MODIFY_MECH_POWER min_value:0）
func test_pilot_076_clamp_power_below_3() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var enemy_mech = std.enemy_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var defend_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if defend_cid == &"":
		return "缺 action_009_防御（敌方）"
	driver.enemy_defend_cid = defend_cid
	driver.respond_enemy = true
	driver.respond_player = false
	# 敌方动力 = 2（<3），消耗 3 应 clamp 到 0
	enemy_mech.power = 2
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	if int(enemy_mech.power) != 0:
		return "clamp：敌方动力 2 消耗 3 应 clamp 到 0 实 %d" % int(enemy_mech.power)
	# 仍应获迎击牌（消耗 clamp 不影响获牌）
	if not _hand_has(gs, &"player", defend_cid):
		return "clamp：玩家仍应获迎击牌(instance=%s)" % String(defend_cid)
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "clamp：残留 waiting 动作 %s" % str(wait)
	return true


## 复现用：为某玩家造一台额外机甲（无机师，纯靶子，复用 test_multi_target_attack 模式）
func _create_second_mech(battle, mech_id: StringName, owner_pid: StringName, pos: Dictionary):
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = owner_pid
	m.max_hp = 25
	m.current_hp = 25
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


## 复现6（B分支·双连fork）：敌方双连打2目标（含疾风机甲），疾风响应攻击牌，
## 应消耗攻击方（敌方）3动力。双连 fork 子攻击 record 若缺 attacker_id 则分支B解析失败。
func test_pilot_076_branch_b_multi_target_fork() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var player_mech = std.player_mech
	var enemy_mech = std.enemy_mech
	# 玩家侧第二台机甲（双连第2目标）
	var player_mech2 = _create_second_mech(battle, &"player_mech2", &"player", {"q": 9, "r": 0})
	# 敌方手牌：双连；玩家手牌：防御（迎击）
	var dual_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_005_双连")
	if dual_cid == &"":
		return "缺 action_005_双连（敌方）"
	var player_defend_cid := _ensure_card_in_player_hand(battle, &"player", "action_009_防御")
	if player_defend_cid == &"":
		return "缺 action_009_防御（玩家）"
	# 清地形避免射程干扰
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	# 双目标：疾风机甲 + 玩家侧第二机甲
	driver.respond_player = true
	driver.respond_enemy = false
	driver.player_defend_cid = player_defend_cid
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary):
		return [player_mech.mech_id, player_mech2.mech_id]
	var enemy_power_before = int(enemy_mech.power)
	battle.execute_use_action_card(&"enemy", dual_cid)
	await _drain(battle, driver)
	# 验证：攻击方（敌方）动力 -3
	if int(enemy_mech.power) != enemy_power_before - 3:
		return "复现6(双连)：敌方(攻击方)动力应 %d 实 %d" % [enemy_power_before - 3, int(enemy_mech.power)]
	# 验证：玩家从弃牌堆获得该攻击牌（双连同一实例）
	if not _hand_has(gs, &"player", dual_cid):
		return "复现6(双连)：玩家应获双连牌(instance=%s)" % String(dual_cid)
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "复现6(双连)：残留 waiting 动作 %s" % str(wait)
	return true


## 复现7（B分支·疾风在对侧）：疾风设到敌方机甲，玩家（攻击方）攻敌方，敌方(疾风)迎击响应，
## 应消耗攻击方（玩家）3动力。验证跨座位（非 player 位）响应分支B的 attacker 解析。
func test_pilot_076_branch_b_jifeng_on_enemy_side() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var s = _setup_jifeng(battle, &"enemy")
	if s.is_empty():
		return "setup(疾风在敌方) 失败"
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = s.mech
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	player_mech.power = 10
	player_mech.max_power = 10
	enemy_mech.power = 10
	enemy_mech.max_power = 10
	player_mech.attack_count_this_turn = 0
	enemy_mech.attack_count_this_turn = 0
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.enemy_mech_id = enemy_mech.mech_id
	driver.player_mech_id = player_mech.mech_id
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	# 玩家手牌：进攻；敌方手牌：防御（迎击）
	var player_atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if player_atk_cid == &"":
		return "缺 action_001_进攻（玩家）"
	var enemy_defend_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if enemy_defend_cid == &"":
		return "缺 action_009_防御（敌方）"
	driver.enemy_defend_cid = enemy_defend_cid
	driver.respond_enemy = true
	driver.respond_player = false
	var player_power_before = int(player_mech.power)
	battle.execute_use_action_card(&"player", player_atk_cid)
	await _drain(battle, driver)
	# 验证：攻击方（玩家）动力 -3
	if int(player_mech.power) != player_power_before - 3:
		return "复现7(疾风在对侧)：玩家(攻击方)动力应 %d 实 %d" % [player_power_before - 3, int(player_mech.power)]
	# 验证：敌方(疾风)获得该攻击牌（进攻牌同一实例）
	if not _hand_has(gs, &"enemy", player_atk_cid):
		return "复现7(疾风在对侧)：敌方应获进攻牌(instance=%s)" % String(player_atk_cid)
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "复现7(疾风在对侧)：残留 waiting 动作 %s" % str(wait)
	return true


## 复现8（B分支·用反击牌响应）：疾风用「反击」(action_010) 响应敌方攻击，
## 反击也走 handle_response_selection 的 use_action_card 路径（反击效果2绑定到原攻击动作）。
## 应消耗攻击方（敌方）3动力。覆盖真实对局常用迎击牌为反击而非防御的场景。
func test_pilot_076_branch_b_respond_counter_card() -> Variant:
	var battle := _new_battle()
	var std = _setup_standard(battle)
	if std.is_empty():
		return "setup 失败"
	var driver = std.driver
	var gs = std.gs
	var player_mech = std.player_mech
	var enemy_mech = std.enemy_mech
	# 敌方手牌：进攻；玩家手牌：反击（迎击）
	var enemy_atk_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	if enemy_atk_cid == &"":
		return "缺 action_001_进攻（敌方）"
	var player_counter_cid := _ensure_card_in_player_hand(battle, &"player", "action_010_反击")
	if player_counter_cid == &"":
		return "缺 action_010_反击（玩家）"
	driver.respond_enemy = false
	driver.respond_player = true
	driver.player_defend_cid = player_counter_cid
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return player_mech.mech_id
	var enemy_power_before = int(enemy_mech.power)
	battle.execute_use_action_card(&"enemy", enemy_atk_cid)
	await _drain(battle, driver)
	# 验证：攻击方（敌方）动力 -3
	if int(enemy_mech.power) != enemy_power_before - 3:
		return "复现8(反击)：敌方(攻击方)动力应 %d 实 %d" % [enemy_power_before - 3, int(enemy_mech.power)]
	var wait := _waiting_actions(battle.context)
	if not wait.is_empty():
		return "复现8(反击)：残留 waiting 动作 %s" % str(wait)
	return true
