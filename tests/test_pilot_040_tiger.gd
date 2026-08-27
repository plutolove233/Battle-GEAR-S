## test_pilot_040_tiger.gd - 泰格（pilot_040，帝国 R）效果测试
##
## pilot_040_effect_01 近战锁定（被动 LISTEN ATTACK_PRE priority30）：
##   「使用近战武器攻击时，可弃置1张行动牌对目标施加锁定效果（目标可以弃置1张正面设置的装备牌取消此效果）。」
##
## 合并式弹窗动作链（效果即组件，不拆通用件）：
##   ① CHOOSE_MANY_CARDS（OWNER_ACTION_HAND, min=max=1, store_result_key=pilot_040_discard_action）
##      选1张行动牌=确认发动；取消=不发动（store 路径 resume 经 _seq 续跑剩余动作）。
##   ② EXECUTE_DISCARD：弃置所选行动牌。
##   ③ FOR_EACH_TARGET（$payload.target_ids）：对攻击所有目标施加预判式锁定
##     （duration=1，source_card_id=泰格 pilot 卡实例，供弃装解锁按来源精确移除）。
##   ④ FOR_EACH_TARGET（$payload.target_ids）：逐目标弹窗——目标玩家可弃1张正面设置的
##     装备牌（face_up，含部件/武器；不含背面备用区/手牌/机师/事件牌）取消锁住自己的锁；
##     取消=不弃置=锁不被④移除。chooser_mech_id=$current_target.mech_id 把弹窗路由给目标玩家
##     （多目标各自独立弹窗，PvP/PvP3 任意数量人类玩家通用；AI 暂不处理）。
##
## 锁的终结（规则：锁定持续到目标被攻击命中时结束）：
##   泰格预判式锁定封锁本次攻击的响应窗口；本次攻击命中后锁即结束
##   （skip_clear_on_hit=false，ATTACK_AFTER 命中清除）。④取消/无装备只表示
##   「锁不被④移除」，不阻止命中清除。
##
## 关键覆盖点：
##   1. effect_01 定义结构（MODE_LISTEN/ATTACK_PRE/priority30/条件/4动作顺序/NO_TARGET）。
##   2. 主流程：真实近战攻击→弹①→弃行动牌→目标被锁→弹④→目标弃装备→解锁+槽位清空。
##   3. 取消①：不弃行动牌、不施加锁、攻击正常结算。
##   4. 取消④：装备不弃、锁不被④移除；本次攻击命中后锁结束。
##   5. 我方无行动牌（ATTACK_PRE 时手牌只剩已离手攻击牌）：条件不满足，不弹窗不锁。
##   6. 目标无正面装备：④无候选，不弹窗；本次攻击命中后锁结束。
##   7. 多目标（双连）：两目标各自锁定+各自独立弹窗解锁（确认/取消各一）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
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
	battle.rng_seed = 90040
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


## 设泰格为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_tiger(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_040_泰格", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建第 2 台敌方机甲（owner=enemy2），放指定位置，6 部件槽。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary, owner_pid: StringName = &"enemy2") -> _MechState:
	var gs = battle.context.game_state
	if not gs.players.has(owner_pid):
		var p := _PlayerState.new()
		p.player_id = owner_pid
		p.is_human = true  # 泰格④弹窗需目标玩家 is_human（AI 跳过）
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


## 清空机甲所有槽位装备（_auto_equip_enemy 预装备后需清空，保证④候选确定性）
func _clear_mech_slots(battle, mech) -> void:
	if mech == null:
		return
	for slot_id: StringName in mech.slots:
		var slot = mech.slots[slot_id]
		if slot != null and slot.equipped_card != null:
			slot.equipped_card = null


## 创建装备牌实例并设置到机甲槽位（正面），返回 instance_id
func _equip_card_on_slot(battle, mech_id: StringName, def_id: String, owner_pid: StringName, slot_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, owner_pid)
	if card == null:
		return &""
	gs.set_card_to_slot(card.instance_id, mech_id, slot_id, false)
	return card.instance_id


## 收集所有残留的 waiting 动作（卡死判定）
func _waiting_actions(ctx) -> Array:
	var waiting: Array = []
	for aid: StringName in ctx.action_registry.get_active_ids():
		var a = ctx.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	return waiting


## 驱动输入循环直到 cond() 为真或全部动作完成；返回是否在完成前到达 cond。
func _drain_until(battle, driver, cond: Callable, max_steps: int = 300) -> bool:
	var ctx = battle.context
	var steps := 0
	while steps < max_steps:
		steps += 1
		driver.pump()
		await _frame()
		if cond.call():
			await _frame()
			return true
		if driver.pending.is_empty() and _waiting_actions(ctx).is_empty():
			await _frame()
			await _frame()
			if cond.call():
				return true
			return false
	return false


## 驱动输入循环直到所有动作完成（内部 flush deferred 钩子落地）。
func _drain_all(battle, driver, max_steps: int = 800) -> void:
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
# 输入驱动器（标准输入自动回填 + 泰格弹窗记录）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	# 泰格①②④弹窗（select_thrust_cards）记录：每项 {action_id, input_type, input_params}
	var popups: Array = []
	# 武器选择：一律第 1 把基础武器（振动匕首，近战，range 2）
	var weapon_id: StringName = &"frame_base_weapon_1"
	var respond_enemy: bool = true
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
		if input_type == &"select_thrust_cards":
			# 泰格弹窗（①选行动牌/④弃装备）不自动回填，记录供测试驱动
			popups.append({"action_id": action_id, "input_type": input_type, "input_params": input_params})
		elif _STD_INPUTS.has(input_type):
			pending[action_id] = {"input_type": input_type, "input_params": input_params}
		# 其他非标准输入忽略

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
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				context.timing_engine.handle_response_selection(action_id, [])
			&"place_damage_tokens":
				context.action_service.continue_action(action_id, {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true


## 是否有某个 player_id 的泰格弹窗在队列中
func _has_pop_for(driver, pid: String) -> bool:
	for p in driver.popups:
		if String(p.input_params.get("player_id", &"")) == pid:
			return true
	return false


## 取出（并移除）某个 player_id 的泰格弹窗；无则返回 {}
func _pop_for(driver, pid: String) -> Dictionary:
	for i in range(driver.popups.size()):
		if String(driver.popups[i].input_params.get("player_id", &"")) == pid:
			return driver.popups.pop_at(i)
	return {}


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_040_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_040_effect_01")
	if e == null:
		return "缺 pilot_040_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e.mode)
	if int(e.priority) != 30:
		return "effect_01 priority 应 30 实=%d" % int(e.priority)
	if String(e.listen_timing) != String(_TimingConst.ATTACK_PRE):
		return "listen_timing 应 ATTACK_PRE 实=%s" % String(e.listen_timing)
	if String(e.listen_action_type) != "attack":
		return "listen_action_type 应 attack 实=%s" % String(e.listen_action_type)
	# conditions: SELF_MECH_IS_ATTACKER + 近战武器 + 手牌>=1 行动牌
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_01 应含条件 SELF_MECH_IS_ATTACKER"
	if not ops.has("ATTACK_EFFECTIVE_WEAPON_KIND"):
		return "effect_01 应含条件 ATTACK_EFFECTIVE_WEAPON_KIND"
	if not ops.has("HAS_ACTION_CARD_IN_HAND"):
		return "effect_01 应含条件 HAS_ACTION_CARD_IN_HAND"
	# actions 顺序：①CHOOSE_MANY_CARDS ②EXECUTE_DISCARD ③FOR_EACH_TARGET(锁) ④FOR_EACH_TARGET(解锁)
	var acts = e.actions
	if acts.size() != 4:
		return "effect_01 actions 应 4 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "actions[0] 应 CHOOSE_MANY_CARDS 实=%s" % String(acts[0].get("type", &""))
	if String(acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "actions[1] 应 EXECUTE_DISCARD 实=%s" % String(acts[1].get("type", &""))
	if String(acts[2].get("type", &"")) != "FOR_EACH_TARGET":
		return "actions[2] 应 FOR_EACH_TARGET 实=%s" % String(acts[2].get("type", &""))
	if String(acts[3].get("type", &"")) != "FOR_EACH_TARGET":
		return "actions[3] 应 FOR_EACH_TARGET 实=%s" % String(acts[3].get("type", &""))
	# ① params：source=OWNER_ACTION_HAND, min=max=1, store_result_key
	var cm_p: Dictionary = acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_ACTION_HAND":
		return "① source 应 OWNER_ACTION_HAND 实=%s" % String(cm_p.get("source", &""))
	if int(cm_p.get("min_count", 0)) != 1 or int(cm_p.get("max_count", 0)) != 1:
		return "① min/max_count 应 1/1 实=%s/%s" % [str(cm_p.get("min_count")), str(cm_p.get("max_count"))]
	if String(cm_p.get("store_result_key", &"")) != "pilot_040_discard_action":
		return "① store_result_key 应 pilot_040_discard_action 实=%s" % String(cm_p.get("store_result_key", &""))
	# ③ params：targets=$payload.target_ids, APPLY_OR_CHECK_LOCKED apply duration=1
	var fet3_p: Dictionary = acts[2].get("params", {})
	if String(fet3_p.get("targets", &"")) != "$payload.target_ids":
		return "③ targets 应 $payload.target_ids 实=%s" % String(fet3_p.get("targets", &""))
	var lock_act: Dictionary = fet3_p.get("actions", [{}])[0]
	if String(lock_act.get("type", &"")) != "APPLY_OR_CHECK_LOCKED":
		return "③ actions[0] 应 APPLY_OR_CHECK_LOCKED 实=%s" % String(lock_act.get("type", &""))
	if int(lock_act.get("params", {}).get("duration", 0)) != 1:
		return "③ duration 应 1 实=%s" % str(lock_act.get("params", {}).get("duration"))
	# ④ params：source=ATTACK_TARGET_EQUIPMENT, chooser_mech_id=$current_target.mech_id,
	#   min=0 max=1, per_card_actions=REMOVE_STATUS(source_card_id=$binding_context.card_instance_id)
	var fet4_p: Dictionary = acts[3].get("params", {})
	var unlock_act: Dictionary = fet4_p.get("actions", [{}])[0]
	if String(unlock_act.get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "④ actions[0] 应 CHOOSE_MANY_CARDS 实=%s" % String(unlock_act.get("type", &""))
	var um_p: Dictionary = unlock_act.get("params", {})
	if String(um_p.get("source", &"")) != "ATTACK_TARGET_EQUIPMENT":
		return "④ source 应 ATTACK_TARGET_EQUIPMENT 实=%s" % String(um_p.get("source", &""))
	if String(um_p.get("chooser_mech_id", &"")) != "$current_target.mech_id":
		return "④ chooser_mech_id 应 $current_target.mech_id 实=%s" % String(um_p.get("chooser_mech_id", &""))
	var rem: Dictionary = um_p.get("per_card_actions", [{}])[0]
	if String(rem.get("type", &"")) != "REMOVE_STATUS":
		return "④ per_card_actions[0] 应 REMOVE_STATUS 实=%s" % String(rem.get("type", &""))
	if String(rem.get("params", {}).get("status_type", &"")) != "LOCKED":
		return "④ REMOVE_STATUS status_type 应 LOCKED 实=%s" % String(rem.get("params", {}).get("status_type", &""))
	# target_rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	return true


## 标准布局：player(10,0) enemy(11,0)，玩家带泰格、双方手牌清空、敌方 is_human=true。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_tiger(battle, &"player")
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
	# 泰格④弹窗路由给目标玩家，需 is_human（AI 跳过）
	var enemy_player = gs.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	return {"battle": battle, "driver": driver, "s": s, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "ctx": battle.context}


## 测试2：主流程——近战攻击→弹①→弃行动牌→目标被锁→弹④→目标弃装备→解锁+槽位清空。
func test_pilot_040_discard_lock_and_unlock() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var ctx = setup.ctx
	var te = ctx.timing_engine
	var enemy_mech = setup.enemy_mech
	# 敌方装备：清空 _auto_equip_enemy 预装备后设置 part_001（保证④候选唯一）
	_clear_mech_slots(battle, enemy_mech)
	var equip_cid := _equip_card_on_slot(battle, enemy_mech.mech_id, "part_001_量产装_头部", &"enemy", &"头部")
	if equip_cid == &"":
		return "缺 part_001_量产装_头部"
	# 玩家手牌：攻击牌 + 弃牌候选（维修，无手牌被动干扰）
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var discard_cid := _ensure_card_in_player_hand(battle, &"player", "action_013_维修")
	if discard_cid == &"":
		return "缺 action_013_维修"

	# 发起真实近战攻击（振动匕首=近战）
	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "近战攻击应弹①选行动牌窗（driver.popups 空）"
	var popup1: Dictionary = driver.popups.pop_front()
	if String(popup1.input_params.get("effect_id", &"")) != "pilot_040_effect_01":
		return "①弹窗 effect_id 应 pilot_040_effect_01 实=%s" % str(popup1.input_params.get("effect_id"))
	if String(popup1.input_params.get("player_id", &"")) != "player":
		return "①弹窗 player_id 应 player（攻击方）实=%s" % str(popup1.input_params.get("player_id"))
	var card_ids1: Array = popup1.input_params.get("card_ids", [])
	if card_ids1.size() != 1 or String(card_ids1[0]) != String(discard_cid):
		return "①候选应仅弃牌候选 实=%s" % str(card_ids1)

	# ① 确认（弃行动牌发动）
	te.resume_pending_effect(popup1.action_id, {"selected_card_ids": [discard_cid]})
	var got4 := await _drain_until(battle, driver, func(): return _has_pop_for(driver, "enemy"))
	if not got4:
		return "①确认后应弹④弃装备窗（enemy）"
	# 弃行动牌已离手 + 目标被锁
	var p_player = gs.players.get(&"player")
	if discard_cid in p_player.action_hand:
		return "①确认后行动牌应被弃置，仍在于手牌"
	if not enemy_mech.is_locked_by(&"player"):
		return "①确认后目标应被锁定（source=player）"
	# ④ 候选 = 目标正面设置装备
	var popup4: Dictionary = _pop_for(driver, "enemy")
	var card_ids4: Array = popup4.input_params.get("card_ids", [])
	if card_ids4.size() != 1 or String(card_ids4[0]) != String(equip_cid):
		return "④候选应仅目标装备牌 实=%s" % str(card_ids4)

	# ④ 确认（弃装备解锁）
	te.resume_pending_effect(popup4.action_id, {"selected_card_ids": [equip_cid]})
	await _drain_all(battle, driver)
	if enemy_mech.is_locked_by(&"player"):
		return "④确认弃装后应解锁"
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot != null and head_slot.equipped_card != null:
		return "④确认弃装后槽位应清空"
	if not _waiting_actions(ctx).is_empty():
		return "攻击结算后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true


## 测试3：取消①——不弃行动牌、不施加锁、攻击正常结算。
func test_pilot_040_cancel_discard_choice() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var te = setup.ctx.timing_engine
	var enemy_mech = setup.enemy_mech
	_clear_mech_slots(battle, enemy_mech)
	var equip_cid := _equip_card_on_slot(battle, enemy_mech.mech_id, "part_001_量产装_头部", &"enemy", &"头部")
	if equip_cid == &"":
		return "缺 part_001"
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var discard_cid := _ensure_card_in_player_hand(battle, &"player", "action_013_维修")
	if discard_cid == &"":
		return "缺 action_013_维修"

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "应弹①选行动牌窗"
	var popup1: Dictionary = driver.popups.pop_front()

	# 取消①：不弃牌不发动
	te.resume_pending_effect(popup1.action_id, {"cancelled": true})
	await _drain_all(battle, driver)
	var p_player = gs.players.get(&"player")
	if not (discard_cid in p_player.action_hand):
		return "取消①不应弃置行动牌"
	if enemy_mech.is_locked_by(&"player"):
		return "取消①不应施加锁"
	if _has_pop_for(driver, "enemy"):
		return "取消①不应弹④弃装备窗"
	return true


## 测试4：取消④——锁保留、装备不弃。
func test_pilot_040_cancel_equip_unlock() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.ctx.timing_engine
	var enemy_mech = setup.enemy_mech
	_clear_mech_slots(battle, enemy_mech)
	var equip_cid := _equip_card_on_slot(battle, enemy_mech.mech_id, "part_001_量产装_头部", &"enemy", &"头部")
	if equip_cid == &"":
		return "缺 part_001"
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var discard_cid := _ensure_card_in_player_hand(battle, &"player", "action_013_维修")
	if discard_cid == &"":
		return "缺 action_013_维修"

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "应弹①选行动牌窗"
	var popup1: Dictionary = driver.popups.pop_front()
	te.resume_pending_effect(popup1.action_id, {"selected_card_ids": [discard_cid]})
	var got4 := await _drain_until(battle, driver, func(): return _has_pop_for(driver, "enemy"))
	if not got4:
		return "①确认后应弹④弃装备窗"
	if not enemy_mech.is_locked_by(&"player"):
		return "前置失败：④弹窗前目标应被锁定"
	var popup4: Dictionary = _pop_for(driver, "enemy")

	# 取消④：不弃装，锁不被④移除；但本次攻击命中后锁结束（规则：锁持续到目标被攻击命中时结束）
	te.resume_pending_effect(popup4.action_id, {"cancelled": true})
	await _drain_all(battle, driver)
	if enemy_mech.is_locked_by(&"player"):
		return "取消④后锁应在本次攻击命中后结束"
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot == null or head_slot.equipped_card == null or String(head_slot.equipped_card.instance_id) != String(equip_cid):
		return "取消④后装备应未弃置"
	return true


## 测试5：我方无行动牌（ATTACK_PRE 时手牌只剩已离手攻击牌）→ 条件不满足，不弹窗不锁。
func test_pilot_040_no_action_card_no_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var enemy_mech = setup.enemy_mech
	# 手牌只有攻击牌：ATTACK_PRE 时攻击牌已在 temp_zone，手牌=0
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain_all(battle, driver)
	if not driver.popups.is_empty():
		return "无行动牌不应弹①"
	if enemy_mech.is_locked_by(&"player"):
		return "无行动牌不应施加锁"
	return true


## 测试6：目标无正面装备→④无候选不弹窗，锁保留。
func test_pilot_040_no_equipment_lock_kept() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.ctx.timing_engine
	var enemy_mech = setup.enemy_mech
	# 敌方无任何装备
	_clear_mech_slots(battle, enemy_mech)
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var discard_cid := _ensure_card_in_player_hand(battle, &"player", "action_013_维修")
	if discard_cid == &"":
		return "缺 action_013_维修"

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "应弹①选行动牌窗"
	var popup1: Dictionary = driver.popups.pop_front()
	te.resume_pending_effect(popup1.action_id, {"selected_card_ids": [discard_cid]})
	# 无装备：④无候选，不弹窗；本次攻击命中后锁结束（规则：锁持续到目标被攻击命中时结束）
	await _drain_all(battle, driver)
	if enemy_mech.is_locked_by(&"player"):
		return "目标无正面装备，④跳过；本次攻击命中后锁应结束"
	if _has_pop_for(driver, "enemy"):
		return "目标无正面装备不应弹④弃装备窗"
	return true


## 测试7：多目标（双连）——两目标各自锁定+各自独立弹窗解锁（enemy 确认解锁 / enemy2 取消锁保留）。
func test_pilot_040_dual_strike_multi_target() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var ctx = setup.ctx
	var te = ctx.timing_engine
	var enemy_mech = setup.enemy_mech
	# 第二台敌方机甲（独立玩家 enemy2），双连选 enemy+enemy2
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 12, "r": 0}, &"enemy2")
	if enemy2_mech == null:
		return "enemy2 创建失败"
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> Array:
		return [enemy_mech.mech_id, enemy2_mech.mech_id]
	# 两目标各设正面装备（enemy=part_001 头部 / enemy2=part_002 躯干）
	_clear_mech_slots(battle, enemy_mech)
	var equip_cid := _equip_card_on_slot(battle, enemy_mech.mech_id, "part_001_量产装_头部", &"enemy", &"头部")
	if equip_cid == &"":
		return "缺 part_001"
	var equip2_cid := _equip_card_on_slot(battle, enemy2_mech.mech_id, "part_002_量产装_躯干", &"enemy2", &"躯干")
	if equip2_cid == &"":
		return "缺 part_002"
	# 玩家手牌：双连牌 + 弃牌候选
	var dual_id := _ensure_card_in_player_hand(battle, &"player", "action_005_双连")
	if dual_id == &"":
		return "缺 action_005_双连"
	var discard_cid := _ensure_card_in_player_hand(battle, &"player", "action_013_维修")
	if discard_cid == &"":
		return "缺 action_013_维修"

	# 打出双连（近战：振动匕首 range 2，两目标均在内）
	battle.execute_use_action_card(&"player", dual_id)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "双连攻击应弹①选行动牌窗"
	var popup1: Dictionary = driver.popups.pop_front()
	var card_ids1: Array = popup1.input_params.get("card_ids", [])
	if card_ids1.size() != 1 or String(card_ids1[0]) != String(discard_cid):
		return "①候选应仅弃牌候选 实=%s" % str(card_ids1)

	# ① 确认 → 两目标均被锁，逐目标弹④（先 enemy）
	te.resume_pending_effect(popup1.action_id, {"selected_card_ids": [discard_cid]})
	var got4a := await _drain_until(battle, driver, func(): return _has_pop_for(driver, "enemy"))
	if not got4a:
		return "①确认后应弹第一个④弃装备窗（enemy）"
	if not enemy_mech.is_locked_by(&"player"):
		return "前置失败：enemy 应被锁定"
	if not enemy2_mech.is_locked_by(&"player"):
		return "前置失败：enemy2 应被锁定"
	var popup4a: Dictionary = _pop_for(driver, "enemy")

	# enemy 确认弃装 → enemy 解锁
	te.resume_pending_effect(popup4a.action_id, {"selected_card_ids": [equip_cid]})
	var got4b := await _drain_until(battle, driver, func(): return _has_pop_for(driver, "enemy2"))
	if not got4b:
		return "enemy ④确认后应弹第二个④弃装备窗（enemy2）"
	if enemy_mech.is_locked_by(&"player"):
		return "enemy ④确认弃装后应解锁"
	if not enemy2_mech.is_locked_by(&"player"):
		return "前置失败：enemy2 应仍被锁定"
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot != null and head_slot.equipped_card != null:
		return "enemy ④确认弃装后其槽位应清空"
	var popup4b: Dictionary = _pop_for(driver, "enemy2")
	var card_ids4b: Array = popup4b.input_params.get("card_ids", [])
	if card_ids4b.size() != 1 or String(card_ids4b[0]) != String(equip2_cid):
		return "enemy2 ④候选应仅其装备牌 实=%s" % str(card_ids4b)

	# enemy2 取消④ → 锁不被④移除、装备不弃；enemy2 被攻击命中后锁结束（规则）
	te.resume_pending_effect(popup4b.action_id, {"cancelled": true})
	await _drain_all(battle, driver)
	if enemy2_mech.is_locked_by(&"player"):
		return "enemy2 取消④后锁应在本次攻击命中后结束"
	var torso_slot = enemy2_mech.slots.get(&"躯干")
	if torso_slot == null or torso_slot.equipped_card == null or String(torso_slot.equipped_card.instance_id) != String(equip2_cid):
		return "enemy2 取消④后装备应未弃置"
	if not _waiting_actions(ctx).is_empty():
		return "双连结算后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true
