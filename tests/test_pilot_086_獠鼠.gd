## test_pilot_086_獠鼠.gd - 獠鼠（pilot_086，混乱 N，cost 5, attack_limit 2, action_card_limit 1）效果测试
##
## 1 个效果按钮（LISTEN 被动，悬停看完整说明）：
##   effect_01「骰子攻击」：我方指定目标攻击的 ATTACK_PRE（priority 40）弹「发动/取消」确认窗；
##     确认后掷 1d6，按点数分支（PILOT_086_DICE_BRANCH handler，_seq 动作链串行执行）：
##       1  → 我方机甲设置2损伤
##       2~3→ 我方抽2张行动牌
##       4~5→ 弃置目标2张行动牌（≤2张直接弃不弹窗；>2张逐目标弹未知选框）
##       6  → 对目标施加锁定（预判样式 duration=1，本攻击命中即清除）
##
## 关键覆盖点：
##   1. 效果定义 + JSON effect_ids + 按钮形态（LISTEN 被动 / ATTACK_PRE / PILOT_086_DICE_BRANCH / priority40）。
##   2. 主流程（骰子6）：真实攻击→弹确认窗→确认→掷骰→锁定施加（gs.log 验证）→命中清除（预判样式）→结算。
##   3. 取消确认：不掷骰、无任何分支、攻击正常结算。
##   4. 骰子1：我方机甲 +2 损伤（驱动放损伤面板）。
##   5. 骰子2~3：我方抽2张行动牌。
##   6. 骰子4~5（目标≤2张行动牌）：直接全部弃置不弹窗。
##   7. 骰子4~5（目标>2张行动牌）：逐目标弹弃牌选框，选定2张弃置。
##   8. 多目标（双连）：骰子4~5 逐目标弃牌（≤2自动弃 / >2弹选框）。
##
## 说明：战斗不启用 PvP 绿/红地形（全部 NORMAL），保证 (10,0)→(12,0) 距离2在多目标射程内。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
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
	battle.rng_seed = 90086
	# 不启用 PvP 绿/红地形：全部 NORMAL，保证 (10,0)→(12,0) 距离2在武器射程内，
	# 避免随机绿格（耗2动力）使多目标（双连）校验判 range 出界。
	battle.pvp_map_features = false
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	battle.context.action_ui_bridge.context = battle.context
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（阵营光环等），避免跨测试泄漏
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


## 设獠鼠为 owner_id 机甲机师，返回 {card, mech, gs, cdb, player}；失败返回 null。
func _setup_pilot_086(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_086_獠鼠", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb, "player": gs.players.get(owner_id)}


## 清空玩家/敌方行动手牌（含监听器）
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


## 创建第 2 台敌方机甲（owner=enemy2），放指定位置，6 部件槽。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary, owner_pid: StringName = &"enemy2") -> _MechState:
	var gs = battle.context.game_state
	if not gs.players.has(owner_pid):
		var p := _PlayerState.new()
		p.player_id = owner_pid
		p.is_human = true
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


## 统计机甲总损伤（region_damage_tokens 累加）
func _count_damage_tokens(mech) -> int:
	if mech == null:
		return 0
	var total: int = 0
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			total += int(slot.region_damage_tokens)
	return total


## 检查 gs.log 中是否有 status_added LOCKED 记录（验证锁定曾被施加）。
## resume_pending_effect 同步结算：骰子6施加的锁定在本攻击命中后已被清除（预判样式），
## 中间锁定状态不可观测，只能经持久日志确认曾施加过。
func _log_has_locked_added(gs, mech_id: StringName) -> bool:
	for entry in gs.log:
		if String(entry.get("event", "")) == "status_added" \
				and String(entry.get("status_type", "")) == "LOCKED" \
				and String(entry.get("target_id", "")) == String(mech_id):
			return true
	return false


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


## 驱动输入循环直到所有动作完成。
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
# 输入驱动器（标准输入自动回填 + 獠鼠确认/弃牌弹窗记录）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}（标准输入）
	var popups: Array = []        # choose_one_effect 弹窗（獠鼠确认）记录
	var discard_popups: Array = []  # select_discard_cards 弹窗（分支4~5）记录
	var weapon_id: StringName = &"frame_base_weapon_1"
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
			popups.append({"action_id": action_id, "input_type": input_type, "input_params": input_params})
		elif input_type == &"select_discard_cards":
			discard_popups.append({"action_id": action_id, "input_type": input_type, "input_params": input_params})
		elif _STD_INPUTS.has(input_type):
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
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				context.timing_engine.handle_response_selection(action_id, [])
			&"place_damage_tokens":
				# 真正放置损伤：auto_placed 只是跳过面板，不会实际放点。
				# 按 test_defend_real_flow 的驱动方式：对每个 mech_id 放置 amount 点，再回填 auto_placed。
				var amount_t: int = int(input_params.get("amount", 0))
				var mech_ids_t: Array = input_params.get("mech_ids", [])
				for mid_t in mech_ids_t:
					context.damage_token_service.place_damage_tokens({"mech_id": mid_t, "count": amount_t})
				context.action_service.continue_action(action_id, {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true


## 取出獠鼠确认弹窗（choose_one_effect，effect_id=pilot_086_effect_01）；无则返回 {}。
func _pop_086_confirm(driver) -> Dictionary:
	for i in range(driver.popups.size()):
		var p: Dictionary = driver.popups[i]
		if String(p.input_params.get("effect_id", &"")) == "pilot_086_effect_01":
			return driver.popups.pop_at(i)
	return {}


## 取出弃牌弹窗（select_discard_cards，discard_player_id==pid）；无则返回 {}。
func _pop_discard_for(driver, pid: String) -> Dictionary:
	for i in range(driver.discard_popups.size()):
		var p: Dictionary = driver.discard_popups[i]
		if String(p.input_params.get("discard_player_id", &"")) == pid:
			return driver.discard_popups.pop_at(i)
	return {}


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确 + JSON effect_ids 注册 + 按钮形态（LISTEN 被动 / ATTACK_PRE / PILOT_086_DICE_BRANCH）
func test_pilot_086_effect_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_086_獠鼠", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	if not id_strs.has("pilot_086_effect_01"):
		return "effect_ids 应含 pilot_086_effect_01 实=%s" % str(id_strs)
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_086_effect_01")
	if e1 == null:
		return "缺 pilot_086_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "e1 mode 应 LISTEN 实=%s" % String(e1.mode)
	if int(e1.priority) != 40:
		return "e1 priority 应 40 实=%d" % int(e1.priority)
	if e1.listen_timing != _TimingConst.ATTACK_PRE:
		return "e1 listen_timing 应 ATTACK_PRE 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "attack":
		return "e1 listen_action_type 应 attack 实=%s" % String(e1.listen_action_type)
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "e1 应含条件 SELF_MECH_IS_ATTACKER 实=%s" % str(ops)
	var acts: Array = e1.actions
	if acts.is_empty() or String(acts[0].get("type", &"")) != "PILOT_086_DICE_BRANCH":
		return "e1 actions 应 [PILOT_086_DICE_BRANCH] 实=%s" % str(acts)
	if e1.target_rules.is_empty() or String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "e1 target_rule 应 NO_TARGET"
	# 新权威 effect_text
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var pdef = cdb.get_card(&"pilot_086_獠鼠")
	if pdef == null:
		return "缺 pilot_086_獠鼠 CardDef"
	if not String(pdef.effect_text).contains("我方机甲设置2损伤"):
		return "effect_text 应含「我方机甲设置2损伤」实=%s" % String(pdef.effect_text)
	if not String(pdef.effect_text).contains("弃置目标2张行动牌"):
		return "effect_text 应含「弃置目标2张行动牌」实=%s" % String(pdef.effect_text)
	return true


## 标准布局：player(10,0) enemy(11,0)，玩家带獠鼠、双方手牌清空、敌方 is_human=true。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx, te}；失败返回 {}。
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_pilot_086(battle, &"player")
	if s == null:
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
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	return {"battle": battle, "driver": driver, "s": s, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "ctx": battle.context, "te": battle.context.timing_engine}


## 发起攻击并等待獠鼠确认弹窗出现。返回弹窗 Dictionary；失败返回 {}。
func _attack_and_wait_confirm(setup: Dictionary) -> Dictionary:
	var battle = setup.battle
	var driver = setup.driver
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return {}
	battle.execute_use_action_card(&"player", atk_cid)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return {}
	return _pop_086_confirm(driver)


## 测试2：主流程——攻击→弹确认窗→确认（掷骰6）→目标被锁定（预判样式，命中即清除）→攻击正常结算。
func test_pilot_086_confirm_lock_branch() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败（缺 pilot_086_獠鼠）"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var enemy_mech = setup.enemy_mech
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗（popups 空）"
	if String(popup.input_params.get("player_id", &"")) != "player":
		return "确认弹窗 player_id 应 player 实=%s" % str(popup.input_params.get("player_id"))
	# 注入骰子=6，确认发动（choose_one_effect resume 读 chosen_option_index）
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 6
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	# 分支锁同步施加（APPLY_OR_CHECK_LOCKED 原子即时生效），随后本攻击继续命中结算清除锁定
	# （预判样式 skip_clear_on_hit=false）。resume 返回时攻击已整条同步结算，中间锁定状态
	# 不可观测，改为经 gs.log status_added LOCKED 验证锁定曾被施加 + 结算后无残留锁定。
	await _drain_all(battle, driver)
	if not _log_has_locked_added(gs, enemy_mech.mech_id):
		return "骰子6应施加锁定（gs.log 无 status_added LOCKED）"
	if enemy_mech.is_locked_by(&"player"):
		return "骰子6预判样式：攻击命中后锁定应清除"
	if not _waiting_actions(battle.context).is_empty():
		return "攻击结算后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试3：取消确认——不掷骰、无任何分支（目标无锁定/无弃牌/我方无损伤/无抽牌）、攻击正常结算。
func test_pilot_086_cancel_no_branch() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var player_mech = setup.player_mech
	var enemy_mech = setup.enemy_mech
	# 敌方3张行动牌（验证取消后不弃）
	var c1 := _ensure_card_in_player_hand(battle, &"enemy", "action_013_维修")
	var c2 := _ensure_card_in_player_hand(battle, &"enemy", "action_014_聚能")
	var c3 := _ensure_card_in_player_hand(battle, &"enemy", "action_015_推进")
	if c1 == &"" or c2 == &"" or c3 == &"":
		return "缺敌方行动牌"
	var hand_before: int = gs.players.get(&"enemy").action_hand.size()
	var dmg_before: int = _count_damage_tokens(player_mech)
	var draw_before: int = gs.players.get(&"player").action_hand.size()
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗"
	# 取消（选「取消」选项 chosen_option_index=1）
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 1})
	await _drain_all(battle, driver)
	if enemy_mech.is_locked_by(&"player"):
		return "取消不应施加锁定"
	if gs.players.get(&"enemy").action_hand.size() != hand_before:
		return "取消不应弃敌方行动牌"
	if _count_damage_tokens(player_mech) != dmg_before:
		return "取消不应设置我方损伤"
	if gs.players.get(&"player").action_hand.size() != draw_before:
		return "取消不应抽牌"
	if not _waiting_actions(battle.context).is_empty():
		return "攻击结算后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试4：骰子1——我方机甲 +2 损伤。
func test_pilot_086_dice1_self_damage() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var player_mech = setup.player_mech
	var dmg_before: int = _count_damage_tokens(player_mech)
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗"
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 1
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	var dmg_after: int = _count_damage_tokens(player_mech)
	if dmg_after != dmg_before + 2:
		return "骰子1应设置2损伤：期望 %d 实际 %d" % [dmg_before + 2, dmg_after]
	return true


## 测试5：骰子2~3——我方抽2张行动牌。
func test_pilot_086_dice2_3_draw() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var player = gs.players.get(&"player")
	# 给玩家补一张手牌作攻击牌（_ensure 会从牌堆取），手牌数作为基线
	var draw_before: int = player.action_hand.size()
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗"
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 2
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	# 攻击牌已离手（temp_zone 使用中），骰子2抽2 → 手牌 = 基线 - 1(攻击牌离手) + 2 = 基线 + 2
	var draw_after: int = player.action_hand.size()
	if draw_after != draw_before + 2:
		return "骰子2~3应抽2张行动牌（攻击牌已离手-1）：期望 %d 实际 %d" % [draw_before + 2, draw_after]
	return true


## 测试6：骰子4~5（目标≤2张行动牌）——直接全部弃置不弹窗。
func test_pilot_086_dice4_5_auto_discard() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var c1 := _ensure_card_in_player_hand(battle, &"enemy", "action_013_维修")
	var c2 := _ensure_card_in_player_hand(battle, &"enemy", "action_014_聚能")
	if c1 == &"" or c2 == &"":
		return "缺敌方行动牌"
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗"
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 4
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	await _drain_all(battle, driver)
	var enemy_hand: Array = gs.players.get(&"enemy").action_hand
	if not enemy_hand.is_empty():
		return "目标≤2张行动牌应直接全部弃置，剩余: %s" % str(enemy_hand)
	if not driver.discard_popups.is_empty():
		return "≤2张行动牌不应弹弃牌选框"
	return true


## 测试7：骰子4~5（目标>2张行动牌）——逐目标弹弃牌选框，选定2张弃置。
func test_pilot_086_dice4_5_choose_discard() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var c1 := _ensure_card_in_player_hand(battle, &"enemy", "action_013_维修")
	var c2 := _ensure_card_in_player_hand(battle, &"enemy", "action_014_聚能")
	var c3 := _ensure_card_in_player_hand(battle, &"enemy", "action_015_推进")
	if c1 == &"" or c2 == &"" or c3 == &"":
		return "缺敌方行动牌"
	var popup := await _attack_and_wait_confirm(setup)
	if popup.is_empty():
		return "攻击应弹獠鼠确认窗"
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 5
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	# 目标>2张行动牌 → 弹弃牌选框（discard_player_id=enemy），选2张
	var got := await _drain_until(battle, driver, func(): return not driver.discard_popups.is_empty())
	if not got:
		return "目标>2张行动牌应弹弃牌选框"
	var dpopup: Dictionary = _pop_discard_for(driver, "enemy")
	if dpopup.is_empty():
		return "弃牌选框 discard_player_id 应 enemy"
	# 攻击方（player）选敌方2张暗牌弃置
	battle.context.action_service.continue_action(dpopup.action_id, {"determined_card_ids": [c1, c2]})
	await _drain_all(battle, driver)
	var enemy_hand: Array = gs.players.get(&"enemy").action_hand
	if enemy_hand.size() != 1 or String(enemy_hand[0]) != String(c3):
		return "选定2张应弃置，剩余1张=%s 实=%s" % [str(c3), str(enemy_hand)]
	if not _waiting_actions(battle.context).is_empty():
		return "攻击结算后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试8：多目标（双连）——骰子6 所有目标被锁定；骰子4~5 逐目标弃牌。
func test_pilot_086_dual_strike_targets() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var te = setup.te
	var gs = setup.gs
	var enemy_mech = setup.enemy_mech
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 12, "r": 0}, &"enemy2")
	if enemy2_mech == null:
		return "enemy2 创建失败"
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> Array:
		return [enemy_mech.mech_id, enemy2_mech.mech_id]
	# enemy 2张行动牌（自动弃置），enemy2 3张行动牌（弹选框）
	var c1 := _ensure_card_in_player_hand(battle, &"enemy", "action_013_维修")
	var c2 := _ensure_card_in_player_hand(battle, &"enemy", "action_014_聚能")
	var e2c1 := _ensure_card_in_player_hand(battle, &"enemy2", "action_013_维修")
	var e2c2 := _ensure_card_in_player_hand(battle, &"enemy2", "action_014_聚能")
	var e2c3 := _ensure_card_in_player_hand(battle, &"enemy2", "action_015_推进")
	if c1 == &"" or c2 == &"" or e2c1 == &"" or e2c2 == &"" or e2c3 == &"":
		return "缺目标行动牌"
	# 打出双连（振动匕首 range 2，两目标均在内）
	var dual_id := _ensure_card_in_player_hand(battle, &"player", "action_005_双连")
	if dual_id == &"":
		return "缺 action_005_双连"
	battle.execute_use_action_card(&"player", dual_id)
	var got := await _drain_until(battle, driver, func(): return not driver.popups.is_empty())
	if not got or driver.popups.is_empty():
		return "双连攻击应弹獠鼠确认窗"
	var popup := _pop_086_confirm(driver)
	if popup.is_empty():
		return "确认弹窗应 effect_id=pilot_086_effect_01"
	# 骰子=4：逐目标弃2张（enemy 自动弃2；enemy2 弹选框选2）
	te._pending_effect[popup.action_id]["payload"]["pilot_086_forced_dice"] = 4
	te.resume_pending_effect(popup.action_id, {"chosen_option_index": 0})
	# enemy（2张）自动弃置不弹窗；enemy2（3张）弹选框
	var got2 := await _drain_until(battle, driver, func(): return not driver.discard_popups.is_empty())
	if not got2:
		return "enemy2 应弹弃牌选框"
	var dpopup: Dictionary = _pop_discard_for(driver, "enemy2")
	if dpopup.is_empty():
		return "弃牌选框 discard_player_id 应 enemy2"
	battle.context.action_service.continue_action(dpopup.action_id, {"determined_card_ids": [e2c1, e2c2]})
	await _drain_all(battle, driver)
	var enemy_hand: Array = gs.players.get(&"enemy").action_hand
	var enemy2_hand: Array = gs.players.get(&"enemy2").action_hand
	if not enemy_hand.is_empty():
		return "enemy(2张) 应自动弃置完毕，剩余: %s" % str(enemy_hand)
	if enemy2_hand.size() != 1 or String(enemy2_hand[0]) != String(e2c3):
		return "enemy2 应弃2留1：剩余=%s 实=%s" % [str(e2c3), str(enemy2_hand)]
	return true
