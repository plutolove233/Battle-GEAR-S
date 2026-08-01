## test_flash_counter_order.gd - 闪击+反击 效果执行顺序回归测试
##
## 验证：闪击的攻击A被反击响应后，A 的 ATTACK_SETTLE 时点反击效果2（counter_effect2，
## 优先级20）先于闪击效果2（flash_effect2，优先级10）执行--反击的反击攻击B 先创建结算，
## 闪击的弃牌再攻窗被暂存，等反击攻击B 结算后续跑。
##
## 背景：原 counter_effect2 优先级10 与 flash_effect2 相同，按注册序 flash_effect2 先触发，
## 其 optional 弃牌弹窗把 attack 置 waiting_timing 并在 fire_timing 首次循环 return，
## 丢弃排在后面的 counter_effect2（反击2 永不执行）。提至20 后 counter_effect2 走
## waiting_effect_action 路径（创建反击攻击子动作并暂存剩余监听器），先结算反击攻击，
## 之后再执行闪击效果2。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


## 推进若干帧，使 call_deferred 排入的恢复调用执行（动作父子链恢复靠 deferred）
func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


func _ensure_card_in_player_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 把指定牌塞入敌方手牌（并注册 availability），返回 card_instance_id
func _ensure_card_in_enemy_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 清空敌方手牌（注销监听器、牌移回行动牌堆），避免其它迎击牌/推进干扰反击响应
func _clear_enemy_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid: StringName in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
	enemy.action_hand.clear()


## 驱动 attack 的损伤设置效果动作完成；遇到非损伤子动作（如反击攻击B）时停下交还调用方。
## 同步 flush 已完成的非攻击子动作（hp_change 等，其 call_deferred 通知在测试同步模式不 flush）。
func _drive_damage_until_non_damage_sub(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while guard < 30:
		guard += 1
		if attack.state != &"waiting_effect_action":
			break
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id != &"":
			var dc = ar.get_action(dc_id)
			var amount: int = int(dc.record.get("value", 0))
			var mech_ids: Array = dc.record.get("mech_ids", [])
			if dts != null and amount > 0:
				for mid: StringName in mech_ids:
					dts.place_damage_tokens({"mech_id": mid, "count": amount})
			ae.continue_action(dc_id, {"auto_placed": true})
			ae.notify_effect_action_completed(dc_id, attack_id)
			continue
		var flushed: bool = false
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type != &"attack" and (sub.state == &"completed" or sub.state == &"cancelled"):
				ae.notify_effect_action_completed(cid, attack_id)
				flushed = true
				break
		if flushed:
			continue
		break
	return {"ok": true}


## 构造到“闪击攻击A 被反击响应、ATTACK_SETTLE 触发后”的状态（异步：需 pump deferred）。
## 返回 {ok, msg, battle, attack_a_id}。此时反击效果2 应已先触发：反击攻击B 子动作 pending，
## attack A waiting_effect_action，flash_effect2 暂存到 _pending_regular_listeners。
func _setup_to_attack_settle() -> Dictionary:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return {"ok": false, "msg": "battle 初始化失败"}
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return {"ok": false, "msg": "找不到玩家/敌方机甲"}

	# 教程默认敌方为 AI：ATTACK_AT 响应窗口会被 ActionUIBridge._auto_respond 自动替敌方打出反击。
	# 本测试聚焦 PvP 人类玩家逻辑，把敌方也设为人类，响应窗口与移动交还手动驱动。
	gs.players.get(&"enemy").is_human = true
	gs.players.get(&"player").is_human = true

	# 玩家手牌：闪击 + 2张进攻（弃牌 fodder，满足 flash_effect2 的 HAS_ACTION_CARD_IN_HAND）
	var flash_id = _ensure_card_in_player_hand(battle, "action_006_闪击")
	if flash_id == &"":
		return {"ok": false, "msg": "牌堆/弃牌堆中找不到 闪击"}
	var fodder1 = _ensure_card_in_player_hand(battle, "action_001_进攻")
	var fodder2 = _ensure_card_in_player_hand(battle, "action_001_进攻")
	if fodder1 == &"" or fodder2 == &"":
		return {"ok": false, "msg": "无法塞入足够进攻牌作为弃牌 fodder"}

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return {"ok": false, "msg": "玩家机甲无武器"}
	var weapon_id = weapon_ids[0]

	# 让敌方在玩家武器射程内（与 test_flash_real_flow 一致）
	enemy_mech.position = {"q": 3, "r": 2}

	# 清空敌方手牌后只留反击牌（避免其它迎击牌/推进干扰反击响应）
	_clear_enemy_hand(battle)
	var counter_id = _ensure_card_in_enemy_hand(battle, "action_010_反击")
	if counter_id == &"":
		return {"ok": false, "msg": "牌堆/弃牌堆中找不到 反击"}

	# 反击方（敌方）动力清零：counter_effect1 半动力移动 X=0；首次仍会请求选格，用取消结束循环
	enemy_mech.power = 0
	# 双方高额临时护甲：闪击攻击A 与反击攻击B 伤害均为0（不产生损伤设置子动作、避免机甲死亡），
	# 使两条攻击链都直接走到 ATTACK_SETTLE，测试聚焦效果执行顺序而非损伤设置 UI 驱动
	enemy_mech.temp_armor_bonus = 999
	player_mech.temp_armor_bonus = 999

	battle.context.action_ui_bridge.context = battle.context

	# 真实打出闪击牌
	var result: Dictionary = battle.execute_use_action_card(&"player", flash_id)
	if result.get("state", &"") != &"waiting_effect_action":
		return {"ok": false, "msg": "use_action_card 应暂停 waiting_effect_action（等 attack A 选武器），实际 state=%s" % String(result.get("state", &""))}

	# 找到 attack A
	var attack_a_id: StringName = &""
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a_id = aid
			break
	if attack_a_id == &"":
		return {"ok": false, "msg": "找不到 attack A 效果动作"}
	var attack_a = battle.context.action_registry.get_action(attack_a_id)

	# 驱动选武器
	battle.context.action_engine.continue_action(attack_a_id, {"weapon_id": weapon_id})
	await _pump_frames(2)
	# 选目标
	if String(attack_a.state) == &"waiting_input":
		battle.context.action_engine.continue_action(attack_a_id, {"target_id": enemy_mech.mech_id})
		await _pump_frames(2)

	# 选完目标后 attack A 走到 ATTACK_AT 响应窗口（敌方人类反击牌）-> waiting_timing
	if String(attack_a.state) != &"waiting_timing":
		return {"ok": false, "msg": "attack A 选目标后应在 ATTACK_AT waiting_timing，实际 state=%s" % String(attack_a.state)}

	# 敌方选反击响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"counter_availability",
		"card_instance_id": counter_id,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_a_id, sel)
	await _pump_frames(3)

	# counter_effect1 发起 single_move 循环（即使 power=0 首次仍请求选格）-> 取消结束移动循环
	# 取消后 U_counter 完成、attack A 恢复推进到 ATTACK_AFTER(0伤害)->ATTACK_SETTLE->反击效果2
	battle.context.action_ui_bridge.on_ui_cancelled()
	await _pump_frames(8)

	# 驱动攻击A 的损伤设置（markers=attack_power/5 与护甲无关，仍会产生 damage_change 需放置损伤）
	var drive_ret: Dictionary = _drive_damage_until_non_damage_sub(battle, attack_a_id)
	if not drive_ret.get("ok", false):
		return drive_ret
	await _pump_frames(3)

	return {"ok": true, "battle": battle, "attack_a_id": attack_a_id}


## 测试1：ATTACK_SETTLE 后反击效果2 先于闪击效果2 执行（反击攻击B 创建，flash_effect2 暂存）
func test_counter_effect2_fires_before_flash_effect2():
	var s := await _setup_to_attack_settle()
	if not s.get("ok", false):
		return s.get("msg", "setup 失败")
	var battle: BattleState = s["battle"]
	var attack_a_id: StringName = s["attack_a_id"]
	var attack_a = battle.context.action_registry.get_action(attack_a_id)

	# counter_effect2（优先级20）先执行：创建反击攻击B 子动作，attack A pending 含 attack 子动作
	var has_counter_attack_sub: bool = false
	var _pend_types: Array = []
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = battle.context.action_registry.get_action(aid)
		if sub != null:
			_pend_types.append("%s:%s" % [String(sub.action_type), String(sub.state)])
			if sub.action_type == &"attack":
				has_counter_attack_sub = true
	if not has_counter_attack_sub:
		return "ATTACK_SETTLE 后反击攻击B 子动作未创建（counter_effect2 被跳过）- state=%s pending=%s" % [String(attack_a.state), str(_pend_types)]

	# attack A 应停在 waiting_effect_action（等反击攻击B），而非 waiting_timing（闪击弃牌弹窗）
	if String(attack_a.state) != &"waiting_effect_action":
		return "反击应先于闪击执行：attack A 应 waiting_effect_action（等反击攻击B），实际 state=%s" % String(attack_a.state)

	# flash_effect2 应被暂存到 _pending_regular_listeners（待反击攻击B 结算后续跑）
	var flash_deferred: bool = false
	for le: Dictionary in attack_a._pending_regular_listeners:
		var eff = le.get("effect")
		if eff and eff.effect_id == &"flash_effect2":
			flash_deferred = true
			break
	if not flash_deferred:
		return "flash_effect2 应暂存到 _pending_regular_listeners 待反击攻击结算后续跑，实际=%s" % str(attack_a._pending_regular_listeners)
	return true


## 测试2：反击攻击B 结算完成后，闪击效果2 才弹弃牌再攻窗（反击先于闪击的端到端顺序）
func test_flash_effect2_popup_after_counter_resolved():
	var s := await _setup_to_attack_settle()
	if not s.get("ok", false):
		return s.get("msg", "setup 失败")
	var battle: BattleState = s["battle"]
	var attack_a_id: StringName = s["attack_a_id"]
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a = ar.get_action(attack_a_id)

	# 找到反击攻击B 子动作
	var counter_b_id: StringName = &""
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			counter_b_id = aid
			break
	if counter_b_id == &"":
		return "未找到反击攻击B 子动作"
	var counter_b = ar.get_action(counter_b_id)
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 驱动反击攻击B：选武器（敌方武器）-> 选目标（玩家机甲）
	var enemy_weapon_ids = enemy_mech.get_weapon_ids()
	if enemy_weapon_ids.is_empty():
		return "敌方机甲无武器（反击攻击B 无法发动）"
	# 反击攻击B 可能停在 select_weapon 或 select_target；用 record 是否已有 weapon_id 区分
	var guard: int = 0
	while String(counter_b.state) == &"waiting_input" and guard < 8:
		guard += 1
		if not counter_b.record.has("weapon_id"):
			ae.continue_action(counter_b_id, {"weapon_id": enemy_weapon_ids[0]})
		else:
			ae.continue_action(counter_b_id, {"target_id": player_mech.mech_id})
		await _pump_frames(3)
	# 反击攻击B 0伤害（玩家高额护甲），应同步走到 ATTACK_SETTLE 并完成
	await _pump_frames(8)

	# 反击攻击B 完成：其 call_deferred 通知在测试同步模式不 flush，手动通知 attack A
	ae.notify_effect_action_completed(counter_b_id, attack_a_id)
	await _pump_frames(5)

	# 反击攻击B 结算完成后，attack A 恢复 -> _run_pending_regular_listeners 续跑 flash_effect2
	# -> flash_effect2 optional 弃牌弹窗 -> attack A waiting_timing + _pending_effect
	if String(attack_a.state) != &"waiting_timing":
		return "反击攻击B 结算后应弹闪击弃牌再攻窗（waiting_timing），实际 state=%s" % String(attack_a.state)
	if not battle.context.timing_engine._pending_effect.has(attack_a_id):
		return "反击攻击B 结算后 flash_effect2 应挂起 _pending_effect（弃牌弹窗），实际未挂起"
	var pend: Dictionary = battle.context.timing_engine._pending_effect.get(attack_a_id, {})
	var pend_eff = pend.get("effect")
	if pend_eff == null or pend_eff.effect_id != &"flash_effect2":
		return "挂起的效果应为 flash_effect2，实际=%s" % (String(pend_eff.effect_id) if pend_eff else "null")
	return true
