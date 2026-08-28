## test_pilot_039_kaivey.gd - 铠威（pilot_039，联邦 R）效果测试
##
## 铠威 1 个被动效果（LISTEN ATTACK_SETTLE priority30）：
##   「若发动的攻击被响应，则此攻击结算后可以抽1张行动牌，之后再立即发动1次攻击。」
##
## 通用攻击窗口机制（attack_window_*，不绑定机师）：
##   · GameState 存 attack_window（激活窗口）/ attack_window_queue（待处理触发）/
##     attack_window_pending_prompt（当前待玩家确认）。
##   · 我方发动的每次攻击（含迎击/反击/效果触发攻击/双连各fork）结算（ATTACK_SETTLE）时，
##     若本次攻击被响应（responded=true），登记钩子到该攻击动作；攻击动作完成后
##     （action_completed，deferred）入队 + 弹「抽1张行动牌并立即发动1次攻击/取消」确认窗。
##   · 确认=抽1张行动牌（gain_card）+ 打开攻击窗口；取消=无事发生。
##   · 窗口期间只允许发动攻击（攻击牌/攻击类主动效果/投掷式飞弹），不检查/不消耗回合攻击数；
##     发起攻击即关闭窗口；被响应则递归（每轮弹窗确认=安全阀）。双连/多触发串行排队。
##
## 关键覆盖点：
##   1. 效果定义（MODE_LISTEN ATTACK_SETTLE priority30 + SELF_MECH_IS_ATTACKER +
##      ATTACK_WAS_RESPONDED(读 record.responded) + PILOT_039_SCHEDULE_AFTER_ATTACK）。
##   2. 主流程：玩家攻击→敌方用防御响应→攻击结算→攻击动作完成→弹确认→确认→抽1+开窗口。
##   3. 取消：不抽牌不开窗口。
##   4. 未响应：敌方 pass→responded=false→不触发（无弹窗无窗口）。
##   5. 窗口攻击数豁免：窗口激活时再打攻击牌不消耗回合攻击数；攻击完成后窗口关闭。
##   6. 递归：窗口攻击被响应→再次弹确认。
##   7. 窗口门控：攻击窗口期间非攻击类主动效果禁用、攻击类（EXECUTE_ATTACK /
##      PLAY_AS_NAMED 进攻 / EXECUTE_USE_ACTION_CARD 攻击牌）放行。
##   8. 多触发串行：连续两次被响应攻击→第一个弹确认、第二个入队，窗口关闭后依次处理。
##   9. 双连 fork：每台被响应目标各触发一次（独立 fork 攻击各自登记）。
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
	battle.rng_seed = 90039
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


## 设铠威为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_kaiwei(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_039_铠威", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建第 2 台敌方机甲（owner=enemy），放指定位置，6 部件槽。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary, owner_pid: StringName = &"enemy") -> _MechState:
	var gs = battle.context.game_state
	# 双连第二目标的响应牌按「持有者玩家→主机甲」绑定（register_hand_card_availability 用
	# get_mech_for_player 取持有者机甲）。若第二目标与第一目标同属一个玩家，防御牌会绑到
	# 主机甲，无法响应第二目标。故 owner_pid 需是独立玩家，缺玩家时自动创建。
	if not gs.players.has(owner_pid):
		var p := _PlayerState.new()
		p.player_id = owner_pid
		gs.players[owner_pid] = p
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = owner_pid
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


## 清空玩家/敌方行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里（注册 AVAILABILITY），返回 instance_id。
## force_new=true 时跳过「已在手牌」检查，强制从牌堆再抽一张新实例（双连两 fork 各自
## 需要独立防御牌；同名牌在手里时 _ensure 会复用同实例，fork1 用掉后 fork2 无法响应）。
func _ensure_card_in_player_hand(battle, player_id: StringName, card_def_id: String, force_new: bool = false) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	if not force_new:
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


## 当前待确认触发（attack_window_pending_prompt 非空即弹窗挂起中）
func _prompt(gs) -> Dictionary:
	var p = gs.get("attack_window_pending_prompt")
	if not (p is Dictionary):
		return {}
	return p


## 当前攻击窗口（激活即非空）
func _window(gs) -> Dictionary:
	return _ActionPilotEffects.attack_window_state(gs)


## 驱动输入循环直到所有动作完成（内部 flush deferred 钩子落地）。
func _drain(battle, driver, max_steps: int = 800) -> void:
	var ctx = battle.context
	var steps := 0
	while steps < max_steps:
		steps += 1
		driver.pump()
		await _frame()
		if driver.pending.is_empty() and _waiting_actions(ctx).is_empty():
			# 额外 flush 2 帧让 deferred 的动作完成钩子（入队/弹确认）落地
			await _frame()
			await _frame()
			break


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
	# 武器选择：一律第 1 把基础武器
	var weapon_id: StringName = &"frame_base_weapon_1"
	# 敌方响应配置：目标机甲 -> 用防御响应（defend_availability）
	var enemy_defend_cid: StringName = &""     # 响应 target 为 enemy_mech_id 时使用的防御牌
	var respond_enemy: bool = true
	# 多目标（双连）第二目标响应配置
	var enemy2_defend_cid: StringName = &""
	var respond_enemy2: bool = true
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
		else:
			# 非标准输入（如攻击窗口确认弹窗在测试中不挂 input，直接查 GameState）
			pass

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

	## 根据攻击目标决定是否用防御响应。enemy_mech_id/enemy2_mech_id 经外部分配。
	var enemy_mech_id: StringName = &""
	var enemy2_mech_id: StringName = &""

	func _response_for(action_id: StringName) -> Array[Dictionary]:
		var act = context.action_registry.get_action(action_id)
		if act == null:
			return []
		var target: StringName = act.record.get("target_id", &"")
		if respond_enemy and enemy_mech_id != &"" and String(target) == String(enemy_mech_id) and enemy_defend_cid != &"":
			return [{"effect_id": &"defend_availability", "card_instance_id": enemy_defend_cid, "availability_priority": 5}]
		if respond_enemy2 and enemy2_mech_id != &"" and String(target) == String(enemy2_mech_id) and enemy2_defend_cid != &"":
			return [{"effect_id": &"defend_availability", "card_instance_id": enemy2_defend_cid, "availability_priority": 5}]
		return []


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_039_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_039_effect_01")
	if e == null:
		return "缺 pilot_039_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e.mode)
	if int(e.priority) != 30:
		return "effect_01 priority 应 30（先于反击 effect2(20)/闪击 effect2(10)） 实=%d" % int(e.priority)
	if String(e.listen_timing) != String(_TimingConst.ATTACK_SETTLE):
		return "listen_timing 应 ATTACK_SETTLE 实=%s" % String(e.listen_timing)
	if String(e.listen_action_type) != "attack":
		return "listen_action_type 应 attack 实=%s" % String(e.listen_action_type)
	# conditions: SELF_MECH_IS_ATTACKER + ATTACK_WAS_RESPONDED（读 attack.record.responded）
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_01 应含条件 SELF_MECH_IS_ATTACKER"
	if not ops.has("ATTACK_WAS_RESPONDED"):
		return "effect_01 应含条件 ATTACK_WAS_RESPONDED"
	# actions: PILOT_039_SCHEDULE_AFTER_ATTACK（非阻塞调度）
	var acts = e.actions
	if acts.size() != 1:
		return "effect_01 actions 应 1 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "PILOT_039_SCHEDULE_AFTER_ATTACK":
		return "actions[0] 应 PILOT_039_SCHEDULE_AFTER_ATTACK 实=%s" % String(acts[0].get("type", &""))
	# target_rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	return true


## 标准布局：player(10,0) enemy(11,0)，玩家带铠威、双方手牌清空。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_kaiwei(battle, &"player")
	if s.is_empty():
		return {}
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	player_mech.power = 10
	player_mech.attack_count_this_turn = 0
	enemy_mech.power = 0
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


## 测试2：主流程——玩家攻击→敌方防御响应→攻击结算后弹确认→确认→抽1张行动牌+打开攻击窗口。
func test_pilot_039_responded_accept_draw_and_window() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var enemy_mech = setup.enemy_mech
	# 玩家攻击牌 + 敌方防御牌
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺 action_009_防御"
	var deck_before: int = gs.deck_state.action_deck.size()

	# 发起攻击
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	# 等待延迟确认钩子（若 drain 提前 break）
	await _pump_frames(6)

	# 铠威触发：攻击被响应（responded=true）→ 攻击动作完成后弹确认
	var p := _prompt(gs)
	if p.is_empty():
		return "被响应攻击结算后应弹铠威确认窗（pending_prompt 为空）"
	if String(p.get("player_id", &"")) != "player" or String(p.get("mech_id", &"")) != String(player_mech.mech_id):
		return "pending_prompt 应归属 player/%s 实=%s" % [String(player_mech.mech_id), str(p)]
	# 窗口此时未激活（确认前）
	if not _window(gs).is_empty():
		return "确认前攻击窗口不应激活"
	# 攻击计数 +1（第一张普通攻击牌）
	if int(player_mech.attack_count_this_turn) != 1:
		return "首攻后攻击计数应1 实=%d" % int(player_mech.attack_count_this_turn)

	# 确认（此时攻击牌已消耗，确认前手牌=0）
	var hand_before_confirm: int = gs.players.get(&"player").action_hand.size()
	_ActionPilotEffects.attack_window_confirm(ctx, &"player", player_mech.mech_id, true)
	await _pump_frames(4)

	# 确认后 +1（抽1张行动牌）+ 窗口激活
	if gs.players.get(&"player").action_hand.size() != hand_before_confirm + 1:
		return "确认后应抽1张行动牌 实=%d（前=%d）" % [gs.players.get(&"player").action_hand.size(), hand_before_confirm]
	if gs.deck_state.action_deck.size() != deck_before - 1:
		return "行动牌堆应-1 前=%d 后=%d" % [deck_before, gs.deck_state.action_deck.size()]
	if _window(gs).is_empty():
		return "确认后攻击窗口应激活"
	if String(_window(gs).get("owner_mech_id", &"")) != String(player_mech.mech_id):
		return "窗口归属机甲应 player_mech"
	# pending_prompt 已消费
	if not _prompt(gs).is_empty():
		return "确认后 pending_prompt 应清空"
	# 无残留等待动作
	if not _waiting_actions(ctx).is_empty():
		return "确认后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true


## 测试3：取消——不抽牌不开窗口，可再次触发。
func test_pilot_039_responded_cancel_no_draw() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺 action_009_防御"

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(6)
	if _prompt(gs).is_empty():
		return "前置失败：应弹铠威确认窗"

	# 取消前手牌=0（攻击牌已消耗）
	var hand_before_confirm: int = gs.players.get(&"player").action_hand.size()
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, false)
	await _pump_frames(4)

	if gs.players.get(&"player").action_hand.size() != hand_before_confirm:
		return "取消不应抽牌 实=%d（前=%d）" % [gs.players.get(&"player").action_hand.size(), hand_before_confirm]
	if not _window(gs).is_empty():
		return "取消不应打开攻击窗口"
	if not _prompt(gs).is_empty():
		return "取消后 pending_prompt 应清空"
	return true


## 测试4：未响应——敌方 pass→responded=false→不触发（无弹窗无窗口）。
func test_pilot_039_not_responded_no_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	# 敌方无响应牌 → pass
	driver.enemy_defend_cid = &""
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(6)

	if not _prompt(gs).is_empty():
		return "未响应攻击不应弹铠威确认窗"
	if not _window(gs).is_empty():
		return "未响应攻击不应打开攻击窗口"
	# 攻击计数仍 +1（普通攻击牌）
	if int(player_mech.attack_count_this_turn) != 1:
		return "普通攻击牌应消耗攻击数 实=%d" % int(player_mech.attack_count_this_turn)
	# 无残留等待动作
	if not _waiting_actions(battle.context).is_empty():
		return "未响应攻击后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试5：窗口攻击数豁免——窗口激活时再打攻击牌不消耗回合攻击数，攻击完成后窗口关闭。
func test_pilot_039_window_attack_exempt_and_close() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	# 第一张攻击牌（敌方响应）→ 确认 → 窗口打开、攻击计数=1
	var atk1 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk1 == &"":
		return "缺第一张 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺防御牌"
	battle.execute_use_action_card(&"player", atk1)
	await _drain(battle, driver)
	await _pump_frames(6)
	if _prompt(gs).is_empty():
		return "前置失败：应弹确认窗"
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, true)
	await _pump_frames(4)
	if _window(gs).is_empty():
		return "前置失败：窗口应激活"
	if int(player_mech.attack_count_this_turn) != 1:
		return "前置失败：首攻后攻击计数应1 实=%d" % int(player_mech.attack_count_this_turn)

	# 窗口攻击：敌方 pass（不响应，避免递归）
	driver.respond_enemy = false
	var atk2 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk2 == &"":
		return "缺第二张 action_001_进攻"
	var count_before: int = int(player_mech.attack_count_this_turn)
	battle.execute_use_action_card(&"player", atk2)
	await _drain(battle, driver)
	await _pump_frames(6)

	# 攻击计数不消耗（窗口攻击豁免）
	if int(player_mech.attack_count_this_turn) != count_before:
		return "窗口攻击不应消耗回合攻击数 前=%d 后=%d" % [count_before, int(player_mech.attack_count_this_turn)]
	# 窗口已关闭（发起攻击即关闭）
	if not _window(gs).is_empty():
		return "发起窗口攻击后窗口应关闭"
	# 敌方 pass → 不触发（无新确认窗）
	if not _prompt(gs).is_empty():
		return "窗口攻击未响应不应再弹确认窗"
	return true


## 测试6：递归——窗口攻击被响应→再次弹确认窗。
func test_pilot_039_recursion_window_attack_responded() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	# 第一张攻击牌（敌方响应）→ 确认 → 窗口打开
	var atk1 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk1 == &"":
		return "缺第一张 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺防御牌"
	battle.execute_use_action_card(&"player", atk1)
	await _drain(battle, driver)
	await _pump_frames(6)
	if _prompt(gs).is_empty():
		return "前置失败：应弹确认窗"
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, true)
	await _pump_frames(4)
	if _window(gs).is_empty():
		return "前置失败：窗口应激活"

	# 窗口攻击：敌方再次响应（递归）——需另一张防御牌
	var atk2 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk2 == &"":
		return "缺第二张 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺第二张防御牌"
	battle.execute_use_action_card(&"player", atk2)
	await _drain(battle, driver)
	await _pump_frames(6)

	# 递归：窗口攻击被响应→再次弹确认
	var p := _prompt(gs)
	if p.is_empty():
		return "窗口攻击被响应后应再次弹铠威确认窗（递归）"
	if String(p.get("mech_id", &"")) != String(player_mech.mech_id):
		return "递归确认窗归属机甲应 player_mech 实=%s" % str(p)
	# 窗口已关闭（攻击发起即关），队列空
	if not _window(gs).is_empty():
		return "窗口攻击后窗口应关闭"
	# 取消递归确认（安全阀）
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, false)
	await _pump_frames(4)
	if not _prompt(gs).is_empty():
		return "取消递归确认后 pending_prompt 应清空"
	if not _window(gs).is_empty():
		return "取消递归确认不应开窗口"
	return true


## 测试7：窗口门控——攻击窗口期间非攻击类主动效果禁用、攻击类（EXECUTE_ATTACK /
## PLAY_AS_NAMED 进攻 / EXECUTE_USE_ACTION_CARD 攻击牌）放行。
func test_pilot_039_window_gates_active_effects() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var gs = setup.gs
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var te = ctx.timing_engine
	var bind_ctx: Dictionary = {"mech_id": player_mech.mech_id, "player_id": &"player"}
	# 构造测试效果（与真实效果结构一致）
	var non_attack := ActionEffect.new()
	non_attack.effect_id = &"__test_non_attack__"
	non_attack.actions = [{"type": &"EXECUTE_GAIN_CARD", "params": {"count": 1}}]
	var exe_attack := ActionEffect.new()
	exe_attack.effect_id = &"__test_exe_attack__"
	exe_attack.actions = [{"type": &"EXECUTE_ATTACK", "params": {}}]
	var play_as_named := ActionEffect.new()
	play_as_named.effect_id = &"__test_play_as_named__"
	play_as_named.actions = [{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_001_进攻", "attack_is_active": true}}]
	var play_as_defense := ActionEffect.new()
	play_as_defense.effect_id = &"__test_play_as_defense__"
	play_as_defense.actions = [{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_013_维修", "attack_is_active": false}}]
	var use_action_attack := ActionEffect.new()
	use_action_attack.effect_id = &"__test_use_action_attack__"
	use_action_attack.actions = [{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"card_id": &"action_001_进攻"}}]

	# 窗口未激活时：全部可用（无条件/额度限制）
	if not te.can_trigger_active_effect(non_attack, bind_ctx):
		return "窗口未激活时非攻击效果应可用"
	if not te.can_trigger_active_effect(exe_attack, bind_ctx):
		return "窗口未激活时 EXECUTE_ATTACK 效果应可用"

	# 打开攻击窗口
	_ActionPilotEffects.attack_window_open(gs, &"player", player_mech.mech_id)
	if not _ActionPilotEffects.attack_window_active(gs):
		return "前置失败：窗口应激活"

	# 非攻击类 → 禁用
	if te.can_trigger_active_effect(non_attack, bind_ctx):
		return "攻击窗口期间非攻击类效果（EXECUTE_GAIN_CARD）应禁用"
	if te.can_trigger_active_effect(play_as_defense, bind_ctx):
		return "攻击窗口期间防御转化（PLAY_AS_NAMED attack_is_active=false）应禁用"
	# 攻击类 → 放行
	if not te.can_trigger_active_effect(exe_attack, bind_ctx):
		return "攻击窗口期间 EXECUTE_ATTACK 效果应可用"
	if not te.can_trigger_active_effect(play_as_named, bind_ctx):
		return "攻击窗口期间攻击转化（PLAY_AS_NAMED 进攻）应可用"
	if not te.can_trigger_active_effect(use_action_attack, bind_ctx):
		return "攻击窗口期间使用攻击牌效果（EXECUTE_USE_ACTION_CARD 攻击）应可用"

	# 非归属机甲 bind_ctx：窗口不影响其他机甲
	var other_bind: Dictionary = {"mech_id": &"enemy_mech", "player_id": &"enemy"}
	if not te.can_trigger_active_effect(non_attack, other_bind):
		return "非窗口归属机甲的主动效果不应被窗口禁用"
	_ActionPilotEffects.attack_window_close(ctx)
	return true


## 测试8：多触发串行——两次被响应攻击（确认前连续发动）→第一个弹确认、第二个入队，
## 确认第一个（开窗口）后队列保留，窗口关闭→处理队列→弹第二个确认。
func test_pilot_039_dual_trigger_queue_serial() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	# 攻击1：敌方响应 → 触发1 弹确认
	var atk1 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk1 == &"":
		return "缺第一张攻击牌"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺防御牌"
	battle.execute_use_action_card(&"player", atk1)
	await _drain(battle, driver)
	await _pump_frames(6)
	if _prompt(gs).is_empty():
		return "前置失败：攻击1应弹确认窗"
	# 窗口未激活（尚未确认）
	if not _window(gs).is_empty():
		return "前置失败：确认前窗口不应激活"

	# 攻击2：确认攻击1之前再发动，敌方再响应（第二张防御牌）→ 触发2 入队。
	# 测试场景是「确认前连续两次被响应攻击」：attack_limit=1 已用（atk1），这里重置攻击次数
	# 模拟第二次攻击机会（队列串行机制测试，不测攻击数规则本身）。
	player_mech.attack_count_this_turn = 0
	var atk2 := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk2 == &"":
		return "缺第二张攻击牌"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺第二张防御牌"
	battle.execute_use_action_card(&"player", atk2)
	await _drain(battle, driver)
	await _pump_frames(6)

	# 触发1仍在 pending（不被覆盖），触发2 入队
	if _prompt(gs).is_empty():
		return "攻击1确认窗应仍在 pending"
	if String(_prompt(gs).get("mech_id", &"")) != String(player_mech.mech_id):
		return "pending 归属机甲应 player_mech"
	if gs.attack_window_queue.size() != 1:
		return "攻击2响应应入队（queue=1） 实=%d" % gs.attack_window_queue.size()
	var q0: Dictionary = gs.attack_window_queue[0]
	if String(q0.get("player_id", &"")) != "player" or String(q0.get("mech_id", &"")) != String(player_mech.mech_id):
		return "队列条目应归属 player/%s 实=%s" % [String(player_mech.mech_id), str(q0)]

	# 确认触发1 → 抽1+开窗口；队列第2个保留（窗口激活不动队列）
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, true)
	await _pump_frames(4)
	if gs.players.get(&"player").action_hand.size() != hand_before + 1:
		return "触发1确认应抽1张行动牌 实=%d（前=%d）" % [gs.players.get(&"player").action_hand.size(), hand_before]
	if _window(gs).is_empty():
		return "触发1确认后窗口应激活"
	if gs.attack_window_queue.size() != 1:
		return "窗口激活时队列第2个触发应保留 实=%d" % gs.attack_window_queue.size()

	# 关闭窗口 → 处理队列 → 弹触发2 确认窗
	_ActionPilotEffects.attack_window_close(battle.context)
	await _pump_frames(4)
	var p2 := _prompt(gs)
	if p2.is_empty():
		return "关闭窗口后应处理队列→弹触发2确认窗"
	if String(p2.get("mech_id", &"")) != String(player_mech.mech_id):
		return "触发2确认窗归属机甲应 player_mech"
	if gs.attack_window_queue.size() != 0:
		return "触发2确认弹出后队列应清空 实=%d" % gs.attack_window_queue.size()
	# 取消触发2确认
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, false)
	await _pump_frames(4)
	if not _prompt(gs).is_empty():
		return "取消触发2确认后 pending_prompt 应清空"
	return true


## 测试9：双连 fork——两台目标各自被响应→各触发一次（队列串行）。
func test_pilot_039_dual_strike_forks_each_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var player_mech = setup.player_mech
	var enemy_mech = setup.enemy_mech
	# 第二台敌方机甲放在玩家另一侧（12,0），双连选 enemy+enemy2。
	# enemy2 必须独立玩家：响应牌按持有者玩家→主机甲绑定（register_hand_card_availability），
	# 若 enemy2 也归 "enemy" 玩家，防御牌绑到 enemy_mech，fork2（target=enemy2_mech）无响应牌。
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 12, "r": 0}, &"enemy2")
	if enemy2_mech == null:
		return "enemy2 创建失败"
	driver.enemy2_mech_id = enemy2_mech.mech_id
	# 双连目标选择回调：返回 [enemy, enemy2]
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> Array:
		return [enemy_mech.mech_id, enemy2_mech.mech_id]
	# 双连牌 + 敌方两张防御牌（fork1 绑 enemy_mech，fork2 绑 enemy2_mech，各自独立实例响应）
	var dual_id := _ensure_card_in_player_hand(battle, &"player", "action_005_双连")
	if dual_id == &"":
		return "缺 action_005_双连"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺防御牌"
	driver.enemy2_defend_cid = _ensure_card_in_player_hand(battle, &"enemy2", "action_009_防御")
	if driver.enemy2_defend_cid == &"" or driver.enemy2_defend_cid == driver.enemy_defend_cid:
		return "缺第二张独立防御牌"

	# 打出双连
	battle.execute_use_action_card(&"player", dual_id)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 双连两 fork 均被响应 → 触发2次：第一个弹确认、第二个入队
	var p := _prompt(gs)
	if p.is_empty():
		return "双连两 fork 被响应后应弹第1个确认窗（pending_prompt 为空）"
	if String(p.get("mech_id", &"")) != String(player_mech.mech_id):
		return "确认窗归属机甲应 player_mech 实=%s" % str(p)
	if gs.attack_window_queue.size() != 1:
		return "第2个 fork 触发应入队（queue=1） 实=%d" % gs.attack_window_queue.size()
	if not _waiting_actions(battle.context).is_empty():
		return "双连结算后仍有动作等待: %s" % str(_waiting_actions(battle.context))

	# 确认第1个 → 抽1+窗口
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, true)
	await _pump_frames(4)
	if gs.players.get(&"player").action_hand.size() != hand_before + 1:
		return "第1次确认应抽1张行动牌 实=%d（前=%d）" % [gs.players.get(&"player").action_hand.size(), hand_before]
	if _window(gs).is_empty():
		return "第1次确认后窗口应激活"
	# 队列第2个保留（窗口激活 → process_next 不动队列）
	if gs.attack_window_queue.size() != 1:
		return "窗口激活时队列第2个触发应保留 实=%d" % gs.attack_window_queue.size()

	# 关闭窗口 → 处理队列 → 第2个确认窗
	_ActionPilotEffects.attack_window_close(battle.context)
	await _pump_frames(4)
	if _prompt(gs).is_empty():
		return "关闭窗口后应弹第2个确认窗"
	if gs.attack_window_queue.size() != 0:
		return "第2个确认弹出后队列应清空 实=%d" % gs.attack_window_queue.size()
	# 取消第2个（安全阀）
	_ActionPilotEffects.attack_window_confirm(battle.context, &"player", player_mech.mech_id, false)
	await _pump_frames(4)
	if not _prompt(gs).is_empty():
		return "取消第2个确认后 pending_prompt 应清空"
	return true
