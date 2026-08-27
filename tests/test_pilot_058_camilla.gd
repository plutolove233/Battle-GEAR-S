## test_pilot_058_camilla.gd - 卡米拉（pilot_058，R）效果测试
##
## pilot_058_effect_01 牌型展示加成（被动 LISTEN ATTACK_PRE priority30）：
##   「发动攻击时可以展示我方所有行动牌，其中每包含1种类型(攻击，迎击，辅助)，
##     则本次攻击威力+2；若包含3种类型，则本次攻击范围+2。」
##
## 通用组件（效果即模块，可复制改 params 复用，不绑机师）：
##   ① CHOOSE_ONE（optional=true，单选项）：确认=发动（展示+加成），取消=不发动。
##   ② handler PILOT_058_SHOW_COUNT_BONUS：展示我方所有行动牌（非阻塞浮窗，只弹给
##     其他玩家——自己不看自己的牌，参考美杜莎 p009 显示对象）、统计类型数（1~3）、
##     威力 += 类型数×might_per_type（写父攻击 record.extra_might；MODIFY_ATTACK_MIGHT
##     原子只接受静态 int 增量，动态值由 handler 直写）、若类型数 >= required_type_count
##     则范围 += range_bonus（写 extra_range）。
##
## 关键覆盖点：
##   1. effect_01 定义结构（MODE_LISTEN/ATTACK_PRE/priority30/条件/NO_TARGET/CHOOSE_ONE optional）。
##   2. 主流程·3种类型：确认发动 → 展示浮窗发出（3张牌）+ extra_might=6 + extra_range=2。
##   3. 2种类型：extra_might=4，无范围加成。
##   4. 1种类型：extra_might=2，无范围加成。
##   5. 取消：不展示、不加成，攻击正常结算。
##   6. 无行动牌（ATTACK_PRE 时手牌只剩已离手攻击牌）：条件不满足，不弹窗不加成。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


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
	battle.rng_seed = 90058
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


## 设卡米拉为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_pilot(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_058_卡米拉", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 清空玩家/敌方行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)


## 清空机甲所有槽位装备（_auto_equip_enemy 预装备后需清空，防敌方装备效果干扰）
func _clear_mech_slots(battle, mech) -> void:
	if mech == null:
		return
	for slot_id: StringName in mech.slots:
		var slot = mech.slots[slot_id]
		if slot != null and slot.equipped_card != null:
			slot.equipped_card = null


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


## 连接 action_completed，捕获攻击动作完成时的 record（deep copy）。
func _capture_attack_record(ctx) -> Array:
	var captured: Array = []
	ctx.action_engine.action_completed.connect(func(aid, atype, rec):
		if atype == &"attack":
			captured.append(rec.duplicate(true)))
	return captured


# ═══════════════════════════════════════════
# 输入驱动器（标准输入自动回填 + 卡米拉弹窗/展示记录）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	# 卡米拉 CHOOSE_ONE 确认窗（choose_one_effect）记录：每项 {action_id, input_type, input_params}
	var popups: Array = []
	# 卡米拉展示浮窗（pilot_058_show_display，非阻塞）记录：每项 {action_id, input_type, input_params}
	var displays: Array = []
	# 武器选择：一律第 1 把基础武器（振动匕首，近战，range 2）
	var weapon_id: StringName = &"frame_base_weapon_1"
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
		if input_type == &"choose_one_effect":
			# 卡米拉确认窗（不自动回填，记录供测试驱动）
			popups.append({"action_id": action_id, "input_type": input_type, "input_params": input_params})
		elif input_type == &"pilot_058_show_display":
			# 卡米拉展示浮窗（非阻塞，仅记录供断言）
			displays.append({"action_id": action_id, "input_type": input_type, "input_params": input_params})
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


## 标准布局：player(10,0) enemy(11,0)，玩家带卡米拉、双方手牌清空、敌方 is_human=true、
## 敌方槽位清空（防 _auto_equip_enemy 装备效果干扰）。
## 返回 {battle, driver, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_pilot(battle, &"player")
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
	var enemy_player = gs.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	_clear_mech_slots(battle, enemy_mech)
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	return {"battle": battle, "driver": driver, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "ctx": battle.context}


## 取出（并移除）第一个卡米拉确认窗；无则返回 {}
func _pop_pilot_058_popup(driver) -> Dictionary:
	for i in range(driver.popups.size()):
		if String(driver.popups[i].input_params.get("effect_id", &"")) == "pilot_058_effect_01":
			return driver.popups.pop_at(i)
	return {}


## 手牌按给定行动牌 def_id 列表确保持有（攻击牌另行传入），返回首个攻击牌 instance_id。
func _ensure_hand_cards(battle, pid: StringName, def_ids: Array) -> void:
	for d in def_ids:
		_ensure_card_in_player_hand(battle, pid, String(d))


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_058_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_058_effect_01")
	if e == null:
		return "缺 pilot_058_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e.mode)
	if int(e.priority) != 30:
		return "effect_01 priority 应 30 实=%d" % int(e.priority)
	if String(e.listen_timing) != String(_TimingConst.ATTACK_PRE):
		return "listen_timing 应 ATTACK_PRE 实=%s" % String(e.listen_timing)
	if String(e.listen_action_type) != "attack":
		return "listen_action_type 应 attack 实=%s" % String(e.listen_action_type)
	# conditions: SELF_MECH_IS_ATTACKER + HAS_ACTION_CARD_IN_HAND(count>=1)
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_01 应含条件 SELF_MECH_IS_ATTACKER"
	if not ops.has("HAS_ACTION_CARD_IN_HAND"):
		return "effect_01 应含条件 HAS_ACTION_CARD_IN_HAND"
	var has_hand_cond: bool = false
	for c in e.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("count", 0)) == 1:
				has_hand_cond = true
	if not has_hand_cond:
		return "HAS_ACTION_CARD_IN_HAND 条件 count 应 1"
	# target_rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	# actions: 仅1个 CHOOSE_ONE（optional=true），内含 PILOT_058_SHOW_COUNT_BONUS
	var acts = e.actions
	if acts.size() != 1:
		return "effect_01 actions 应 1 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "actions[0] 应 CHOOSE_ONE 实=%s" % String(acts[0].get("type", &""))
	var co_p: Dictionary = acts[0].get("params", {})
	if not bool(co_p.get("optional", false)):
		return "CHOOSE_ONE optional 应 true（可取消=不发动）"
	var opts: Array = co_p.get("options", [])
	if opts.size() != 1:
		return "CHOOSE_ONE options 应 1 个 实=%d" % opts.size()
	var opt: Dictionary = opts[0] if opts[0] is Dictionary else {}
	var opt_acts: Array = opt.get("actions", [])
	if opt_acts.size() != 1 or String(opt_acts[0].get("type", &"")) != "PILOT_058_SHOW_COUNT_BONUS":
		return "option actions[0] 应 PILOT_058_SHOW_COUNT_BONUS 实=%s" % str(opt_acts)
	var h_params: Dictionary = opt_acts[0].get("params", {})
	if int(h_params.get("might_per_type", 0)) != 2:
		return "might_per_type 应 2 实=%s" % str(h_params.get("might_per_type"))
	if int(h_params.get("range_bonus", 0)) != 2:
		return "range_bonus 应 2 实=%s" % str(h_params.get("range_bonus"))
	if int(h_params.get("required_type_count", 0)) != 3:
		return "required_type_count 应 3 实=%s" % str(h_params.get("required_type_count"))
	return true


## 测试2：主流程·3种类型（攻击/迎击/辅助）——确认发动 → 展示浮窗（3张牌）+ extra_might=6 + extra_range=2。
func test_pilot_058_three_types_might_and_range() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	# 手牌3种类型：攻击(强袭)/迎击(回避)/辅助(维修)
	_ensure_hand_cards(battle, &"player", ["action_002_强袭", "action_008_回避", "action_013_维修"])
	var captured := _capture_attack_record(ctx)

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "攻击应弹①卡米拉确认窗（driver.popups 空）"
	var popup: Dictionary = _pop_pilot_058_popup(driver)
	if popup.is_empty():
		return "①弹窗 effect_id 应 pilot_058_effect_01"
	if String(popup.input_params.get("player_id", &"")) != "player":
		return "①弹窗 player_id 应 player（攻击方）实=%s" % str(popup.input_params.get("player_id"))
	if not bool(popup.input_params.get("optional", false)):
		return "①弹窗 optional 应 true（可取消）"

	# 确认发动
	ctx.timing_engine.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	if driver.displays.is_empty():
		return "确认后应发出展示浮窗（pilot_058_show_display）"
	var disp: Dictionary = driver.displays[0].input_params
	if String(disp.get("owner_mech_id", &"")) != String(player_mech.mech_id):
		return "展示浮窗 owner_mech_id 应攻击方机甲 实=%s" % str(disp.get("owner_mech_id"))
	if String(disp.get("player_id", &"")) != "player":
		return "展示浮窗 player_id 应攻击方 实=%s" % str(disp.get("player_id"))
	var dcards: Array = disp.get("display_cards", [])
	if dcards.size() != 3:
		return "展示浮窗应含3张行动牌 实=%d" % dcards.size()
	# 加成：3类型 → 威力+6 范围+2
	if captured.is_empty():
		return "攻击动作未完成（action_completed 未捕获 attack record）"
	var rec: Dictionary = captured[0]
	if int(rec.get("extra_might", 0)) != 6:
		return "3种类型威力应+6 实=%s" % str(rec.get("extra_might"))
	if int(rec.get("extra_range", 0)) != 2:
		return "3种类型范围应+2 实=%s" % str(rec.get("extra_range"))
	if not _waiting_actions(ctx).is_empty():
		return "攻击结算后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true


## 测试3：2种类型（攻击/辅助）——extra_might=4，无范围加成。
func test_pilot_058_two_types_might_only() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	_ensure_hand_cards(battle, &"player", ["action_002_强袭", "action_013_维修"])
	var captured := _capture_attack_record(ctx)

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got:
		return "攻击应弹①确认窗"
	var popup: Dictionary = _pop_pilot_058_popup(driver)
	if popup.is_empty():
		return "①弹窗 effect_id 应 pilot_058_effect_01"
	ctx.timing_engine.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	if driver.displays.is_empty():
		return "确认后应发出展示浮窗"
	var dcards: Array = driver.displays[0].input_params.get("display_cards", [])
	if dcards.size() != 2:
		return "2种类型应展示2张牌 实=%d" % dcards.size()
	if captured.is_empty():
		return "攻击动作未完成"
	var rec: Dictionary = captured[0]
	if int(rec.get("extra_might", 0)) != 4:
		return "2种类型威力应+4 实=%s" % str(rec.get("extra_might"))
	if int(rec.get("extra_range", 0)) != 0:
		return "2种类型不应加范围 实=%s" % str(rec.get("extra_range"))
	return true


## 测试4：1种类型（仅辅助）——extra_might=2，无范围加成。
func test_pilot_058_one_type_might_only() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	_ensure_hand_cards(battle, &"player", ["action_013_维修"])
	var captured := _capture_attack_record(ctx)

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got:
		return "攻击应弹①确认窗"
	var popup: Dictionary = _pop_pilot_058_popup(driver)
	if popup.is_empty():
		return "①弹窗 effect_id 应 pilot_058_effect_01"
	ctx.timing_engine.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	if driver.displays.is_empty():
		return "确认后应发出展示浮窗"
	var dcards: Array = driver.displays[0].input_params.get("display_cards", [])
	if dcards.size() != 1:
		return "1种类型应展示1张牌 实=%d" % dcards.size()
	if captured.is_empty():
		return "攻击动作未完成"
	var rec: Dictionary = captured[0]
	if int(rec.get("extra_might", 0)) != 2:
		return "1种类型威力应+2 实=%s" % str(rec.get("extra_might"))
	if int(rec.get("extra_range", 0)) != 0:
		return "1种类型不应加范围 实=%s" % str(rec.get("extra_range"))
	return true


## 测试5：取消①——不展示、不加成，攻击正常结算。
func test_pilot_058_cancel_no_bonus() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var ctx = setup.ctx
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	_ensure_hand_cards(battle, &"player", ["action_002_强袭", "action_013_维修"])
	var captured := _capture_attack_record(ctx)

	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got:
		return "攻击应弹①确认窗"
	var popup: Dictionary = _pop_pilot_058_popup(driver)
	if popup.is_empty():
		return "①弹窗 effect_id 应 pilot_058_effect_01"
	# 取消：不展示、不加成
	ctx.timing_engine.resume_pending_effect(popup.action_id, {"cancelled": true})
	await _drain_all(battle, driver)
	if not driver.displays.is_empty():
		return "取消后不应发出展示浮窗"
	if captured.is_empty():
		return "攻击动作未完成"
	var rec: Dictionary = captured[0]
	if int(rec.get("extra_might", 0)) != 0:
		return "取消后不应加威力 实=%s" % str(rec.get("extra_might"))
	if int(rec.get("extra_range", 0)) != 0:
		return "取消后不应加范围 实=%s" % str(rec.get("extra_range"))
	return true


## 测试6：无行动牌（ATTACK_PRE 时手牌只剩已离手攻击牌）→ 条件不满足，不弹窗不加成。
func test_pilot_058_no_action_card_no_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var ctx = setup.ctx
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	var captured := _capture_attack_record(ctx)

	battle.execute_use_action_card(&"player", atk_cid)
	await _drain_all(battle, driver)
	if not driver.popups.is_empty():
		return "无行动牌不应弹①确认窗"
	if not driver.displays.is_empty():
		return "无行动牌不应发出展示浮窗"
	if captured.is_empty():
		return "攻击动作未完成"
	var rec: Dictionary = captured[0]
	if int(rec.get("extra_might", 0)) != 0:
		return "无行动牌不应加威力 实=%s" % str(rec.get("extra_might"))
	if int(rec.get("extra_range", 0)) != 0:
		return "无行动牌不应加范围 实=%s" % str(rec.get("extra_range"))
	return true
