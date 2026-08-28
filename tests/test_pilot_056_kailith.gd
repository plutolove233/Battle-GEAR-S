## test_pilot_056_kailith.gd - 铠厉（pilot_056，混乱 R）效果测试
##
## 铠厉 1 个被动效果（LISTEN ATTACK_SETTLE priority30）：
##   「若发动的攻击被响应，则可以抽2张装备牌，若不立即设置，则需要直接弃置并获得牌面记述数量的金币。」
##
## 通用链式模块 responded_equip_chain_*（不绑定机师）：
##   · GameState 存 responded_equip_queue（待处理触发）/ responded_equip_pending_confirm（当前待确认）/
##     responded_equip_chain（逐张处理链 {owner_player_id, owner_mech_id, card_ids, index}）。
##   · 我方发动的每次攻击（含迎击/反击/效果触发攻击/双连各fork）结算（ATTACK_SETTLE）时，
##     若本次攻击被响应（responded=true），登记钩子到该攻击动作；攻击动作完成后
##     （action_completed，deferred）入队 + 弹「发动/不发动」确认窗。
##   · 确认=抽2张装备牌（gain_card，发 GAIN_CARD 时点）→ 按抽到顺序逐张弹
##     「立即设置/弃置获金(cost)」面板（复用 immediate_set_equipment_panel：每张必须二选一，无跳过）；
##     设置=set_equipment 动作到合法槽；弃置=discard_card 动作 + 我方获得该牌面 cost 金币。
##   · 取消=无事发生。每次被响应都触发（无每回合次数限制）。
##
## 关键覆盖点：
##   1. 效果定义（MODE_LISTEN ATTACK_SETTLE priority30 + SELF_MECH_IS_ATTACKER +
##      ATTACK_WAS_RESPONDED(读 record.responded) + RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK）。
##   2. 主流程：玩家攻击→敌方用防御响应→攻击结算→攻击动作完成→弹确认→确认→抽2装备→逐张设置/弃置获金。
##   3. 设置分支：第1张设到合法槽（equipped_card 命中）。
##   4. 弃置获金分支：第2张弃置入装备弃牌堆 + 获牌面 cost 金币（非稀有度卖出价）。
##   5. 取消：不抽装备不进链不获金。
##   6. 未响应：敌方 pass→responded=false→不触发（无确认无队列无链）。
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
	battle.rng_seed = 90056
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


## 设铠厉为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_kaili(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_056_铠厉", owner_id)
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
# 输入驱动器（标准输入自动回填）
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class InputDriver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	var weapon_id: StringName = &"frame_base_weapon_1"
	var enemy_defend_cid: StringName = &""
	var enemy2_defend_cid: StringName = &""
	var respond_enemy: bool = true
	var respond_enemy2: bool = true
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
			pass

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
				var sel := _response_for(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
			&"place_damage_tokens":
				context.action_service.continue_action(action_id, {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true

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
func test_pilot_056_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_056_effect_01")
	if e == null:
		return "缺 pilot_056_effect_01"
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
	# actions: RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK（非阻塞调度）
	var acts = e.actions
	if acts.size() != 1:
		return "effect_01 actions 应 1 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK":
		return "actions[0] 应 RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK 实=%s" % String(acts[0].get("type", &""))
	# target_rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	return true


## 标准布局：player(10,0) enemy(11,0)，玩家带铠厉、双方行动手牌清空。
## 返回 {battle, driver, s, player_mech, enemy_mech, gs, ctx}；失败返回 {}
func _setup_standard(battle) -> Dictionary:
	if battle == null or battle.context == null:
		return {}
	var gs = battle.context.game_state
	var s = _setup_kaili(battle, &"player")
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


## 标准「被响应攻击」前置：玩家攻击→敌方防御响应→攻击结算后弹确认。
## 返回 chain 待处理前状态（pending_confirm 已弹）。失败返回错误串（非 Dictionary）。
func _attack_and_expect_prompt(setup) -> Variant:
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺 action_009_防御"
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(6)
	var p = gs.responded_equip_pending_confirm
	if p.is_empty():
		return "被响应攻击结算后应弹铠厉确认（pending_confirm 为空）"
	if String(p.get("player_id", &"")) != "player":
		return "pending_confirm 应归属 player 实=%s" % str(p)
	return p


## 测试2：主流程——攻击被响应→确认→抽2张装备牌→第1张设置到合法槽、第2张弃置获金(cost)。
func test_pilot_056_responded_accept_draw2_set_and_discard() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var gs = setup.gs
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	if gs.deck_state.equipment_deck.size() < 2:
		return "装备牌堆不足2张 实=%d" % gs.deck_state.equipment_deck.size()
	var gold_before: int = gs.players.get(&"player").gold
	var equip_hand_before: int = gs.players.get(&"player").equipment_hand.size()
	var eq_deck_before: int = gs.deck_state.equipment_deck.size()

	var p = await _attack_and_expect_prompt(setup)
	if p is String:
		return p
	if String(p.get("mech_id", &"")) != String(player_mech.mech_id):
		return "pending_confirm 归属机甲应 player_mech 实=%s" % str(p)

	# 确认：抽2张装备牌 + 进入逐张链
	_ActionPilotEffects.responded_equip_confirm(ctx, &"player", player_mech.mech_id, true)
	await _pump_frames(4)

	# 抽了2张装备牌
	if gs.players.get(&"player").equipment_hand.size() != equip_hand_before + 2:
		return "确认后应抽2张装备牌 实=%d（前=%d）" % [gs.players.get(&"player").equipment_hand.size(), equip_hand_before]
	if gs.deck_state.equipment_deck.size() != eq_deck_before - 2:
		return "装备牌堆应-2 前=%d 后=%d" % [eq_deck_before, gs.deck_state.equipment_deck.size()]
	var chain: Dictionary = gs.responded_equip_chain
	if chain.is_empty():
		return "确认后应进入逐张处理链（chain 为空）"
	if String(chain.get("owner_player_id", &"")) != "player" or String(chain.get("owner_mech_id", &"")) != String(player_mech.mech_id):
		return "chain 归属应 player/%s 实=%s" % [String(player_mech.mech_id), str(chain)]
	var card_ids: Array = chain.get("card_ids", [])
	if card_ids.size() != 2:
		return "chain.card_ids 应2张 实=%d" % card_ids.size()
	if int(chain.get("index", 0)) != 0:
		return "chain.index 应从0开始 实=%d" % int(chain.get("index", 0))
	if not gs.responded_equip_pending_confirm.is_empty():
		return "确认后 pending_confirm 应清空"

	# 第1张：设置到首合法槽（每张必须二选一：设置 / 弃置获金）
	var card1: StringName = card_ids[0]
	var c1 = gs.get_card(card1)
	if c1 == null or c1.def == null:
		return "第1张装备实例缺失"
	var slots1: Array = _ActionPilotEffects.responded_equip_valid_slots(player_mech, c1)
	if slots1.is_empty():
		return "第1张装备无合法设置槽 卡=%s" % String(card1)
	var slot1: StringName = slots1[0]
	for _sid in slots1:
		var _sl = player_mech.slots[_sid] if player_mech.slots.has(_sid) else null
		if _sl != null and _sl.equipped_card == null:
			slot1 = _sid
			break
	_ActionPilotEffects.responded_equip_card_resume(ctx, &"player", player_mech.mech_id, card1, {"slot_id": slot1})
	await _pump_frames(8)
	var set_slot = player_mech.slots[slot1] if player_mech.slots.has(slot1) else null
	if set_slot == null or set_slot.equipped_card == null or String(set_slot.equipped_card.instance_id) != String(card1):
		return "第1张应设置到 %s 实装备=%s" % [String(slot1), str(set_slot.equipped_card.instance_id if set_slot != null and set_slot.equipped_card != null else &"")]
	if int(gs.responded_equip_chain.get("index", 0)) != 1:
		return "第1张设置后链应推进到 index=1 实=%d" % int(gs.responded_equip_chain.get("index", 0))

	# 第2张：弃置获金（牌面 cost，非稀有度卖出价）
	var card2: StringName = card_ids[1]
	var c2 = gs.get_card(card2)
	var cost2: int = _ActionPilotEffects.responded_equip_card_cost(c2)
	if cost2 <= 0:
		return "第2张装备应含牌面 cost 实=%d" % cost2
	_ActionPilotEffects.responded_equip_card_resume(ctx, &"player", player_mech.mech_id, card2, {"action": "discard"})
	await _pump_frames(8)
	if not gs.deck_state.equipment_discard_pile.has(card2):
		return "第2张应弃置入装备弃牌堆 实缺 %s" % String(card2)
	if gs.players.get(&"player").gold != gold_before + cost2:
		return "弃置第2张应获金 %d 实增 %d（前=%d 后=%d）" % [cost2, gs.players.get(&"player").gold - gold_before, gold_before, gs.players.get(&"player").gold]
	# 链已清空（全部处理完）+ 无残留等待动作
	if not gs.responded_equip_chain.is_empty():
		return "全部处理完链应清空 实=%s" % str(gs.responded_equip_chain)
	if not _waiting_actions(ctx).is_empty():
		return "全流程后仍有动作等待: %s" % str(_waiting_actions(ctx))
	return true


## 测试3：取消——不抽装备、不进链、不获金，pending 清空。
func test_pilot_056_cancel_no_draw() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var gs = setup.gs
	var player_mech = setup.player_mech
	var p = await _attack_and_expect_prompt(setup)
	if p is String:
		return p
	var equip_hand_before: int = gs.players.get(&"player").equipment_hand.size()
	var gold_before: int = gs.players.get(&"player").gold

	_ActionPilotEffects.responded_equip_confirm(battle.context, &"player", player_mech.mech_id, false)
	await _pump_frames(4)

	if gs.players.get(&"player").equipment_hand.size() != equip_hand_before:
		return "取消不应抽装备 实=%d（前=%d）" % [gs.players.get(&"player").equipment_hand.size(), equip_hand_before]
	if not gs.responded_equip_chain.is_empty():
		return "取消不应进入逐张链"
	if gs.players.get(&"player").gold != gold_before:
		return "取消不应获金 前=%d 后=%d" % [gold_before, gs.players.get(&"player").gold]
	if not gs.responded_equip_pending_confirm.is_empty():
		return "取消后 pending_confirm 应清空"
	return true


## 测试4：未响应——敌方 pass→responded=false→不触发（无确认无队列无链）。
func test_pilot_056_not_responded_no_trigger() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	# 敌方无响应牌 → pass
	driver.enemy_defend_cid = &""
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "缺 action_001_进攻"
	battle.execute_use_action_card(&"player", atk_cid)
	await _drain(battle, driver)
	await _pump_frames(6)

	if not gs.responded_equip_pending_confirm.is_empty():
		return "未响应攻击不应弹铠厉确认窗"
	if not gs.responded_equip_queue.is_empty():
		return "未响应攻击不应入队 实=%s" % str(gs.responded_equip_queue)
	if not gs.responded_equip_chain.is_empty():
		return "未响应攻击不应进入逐张链"
	if not _waiting_actions(battle.context).is_empty():
		return "未响应攻击后仍有动作等待: %s" % str(_waiting_actions(battle.context))
	return true


## 测试5：双连 fork——两台目标各自被响应→触发2次（队列串行：第一个弹确认、第二个入队）。
## 第1次确认抽2并逐张处理后，队列第2个触发再弹确认（链与队列互斥串行）。
func test_pilot_056_dual_strike_queue_serial() -> Variant:
	var setup := _setup_standard(_new_battle())
	if setup.is_empty():
		return "setup 失败"
	var battle = setup.battle
	var driver = setup.driver
	var gs = setup.gs
	var ctx = setup.ctx
	var player_mech = setup.player_mech
	var enemy_mech = setup.enemy_mech
	# 第二台敌方机甲（独立玩家，响应牌绑 enemy2）
	var enemy2_mech = null
	enemy2_mech = _create_second_enemy(battle, &"enemy2_mech", {"q": 12, "r": 0}, &"enemy2")
	if enemy2_mech == null:
		return "enemy2 创建失败"
	driver.enemy2_mech_id = enemy2_mech.mech_id
	driver.target_ids_provider = func(_aid: StringName, _p: Dictionary) -> Array:
		return [enemy_mech.mech_id, enemy2_mech.mech_id]
	var dual_id := _ensure_card_in_player_hand(battle, &"player", "action_005_双连")
	if dual_id == &"":
		return "缺 action_005_双连"
	driver.enemy_defend_cid = _ensure_card_in_player_hand(battle, &"enemy", "action_009_防御")
	if driver.enemy_defend_cid == &"":
		return "缺防御牌"
	driver.enemy2_defend_cid = _ensure_card_in_player_hand(battle, &"enemy2", "action_009_防御")
	if driver.enemy2_defend_cid == &"" or driver.enemy2_defend_cid == driver.enemy_defend_cid:
		return "缺第二张独立防御牌"

	battle.execute_use_action_card(&"player", dual_id)
	await _drain(battle, driver)
	await _pump_frames(8)

	# 双连两 fork 均被响应 → 触发2次：第一个弹确认、第二个入队
	var p = gs.responded_equip_pending_confirm
	if p.is_empty():
		return "双连两 fork 被响应后应弹第1个确认窗"
	if String(p.get("mech_id", &"")) != String(player_mech.mech_id):
		return "确认窗归属机甲应 player_mech 实=%s" % str(p)
	if gs.responded_equip_queue.size() != 1:
		return "第2个 fork 触发应入队（queue=1） 实=%d" % gs.responded_equip_queue.size()

	# 第1次确认：抽2装备并逐张处理（第1张设置、第2张弃置获金）
	_ActionPilotEffects.responded_equip_confirm(ctx, &"player", player_mech.mech_id, true)
	await _pump_frames(4)
	var chain: Dictionary = gs.responded_equip_chain
	if chain.is_empty():
		return "第1次确认后应进入链"
	var cids: Array = chain.get("card_ids", [])
	if cids.size() != 2:
		return "第1次确认应抽2张 实=%d" % cids.size()
	var c0 = gs.get_card(cids[0])
	var slots: Array = _ActionPilotEffects.responded_equip_valid_slots(player_mech, c0)
	if slots.is_empty():
		return "第1张无合法槽"
	var slot0: StringName = slots[0]
	for _sid2 in slots:
		var _sl2 = player_mech.slots[_sid2] if player_mech.slots.has(_sid2) else null
		if _sl2 != null and _sl2.equipped_card == null:
			slot0 = _sid2
			break
	_ActionPilotEffects.responded_equip_card_resume(ctx, &"player", player_mech.mech_id, cids[0], {"slot_id": slot0})
	await _pump_frames(8)
	var c1 = gs.get_card(cids[1])
	_ActionPilotEffects.responded_equip_card_resume(ctx, &"player", player_mech.mech_id, cids[1], {"action": "discard"})
	await _pump_frames(8)
	if not gs.responded_equip_chain.is_empty():
		return "第1次链全部处理完应清空 实=%s" % str(gs.responded_equip_chain)

	# 队列第2个触发 → process_next 弹第2个确认窗
	var p2 = gs.responded_equip_pending_confirm
	if p2.is_empty():
		return "第1次链结束后应处理队列→弹第2个确认窗"
	if gs.responded_equip_queue.size() != 0:
		return "第2个确认弹出后队列应清空 实=%d" % gs.responded_equip_queue.size()
	# 取消第2个（安全阀，只验证队列串行）
	_ActionPilotEffects.responded_equip_confirm(ctx, &"player", player_mech.mech_id, false)
	await _pump_frames(4)
	if not gs.responded_equip_pending_confirm.is_empty():
		return "取消第2个确认后 pending_confirm 应清空"
	return true


## 创建第 2 台敌方机甲（owner=enemy2），放指定位置，6 部件槽。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary, owner_pid: StringName = &"enemy2") -> _MechState:
	var gs = battle.context.game_state
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
