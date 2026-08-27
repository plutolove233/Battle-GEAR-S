## test_attack_settle_priority_order.gd - ATTACK_SETTLE「结算后再攻击」类效果优先级对齐测试
##
## 优先级统一（用户裁定）：反击额外攻击=30、联合连携攻击=20、闪击再次攻击=10
## （30>20>10 串行，先到者完全结算后续跑下一个；迪恩 pilot_011_counter_strike 同 30）。
## 全部监听 ATTACK_SETTLE（不新增时点），靠 fire_timing 的 priority 排序+串行执行+
## 暂存补跑机制保证顺序、无丢失、无插队、无崩溃。
##
## 测试1：优先级数字断言（防回归：有人把数字改回去就红）。
## 测试2：三效果共存全链--一次攻击A 同时挂 反击效果2 + 联合连携 + 闪击效果2：
##   P(player) 打出闪击发起攻击A 目标 E(enemy)，E 用反击响应；
##   E 身上有联合状态（unite=P，Target=E）。
##   ATTACK_SETTLE 顺序断言：反击攻击B(30) 先创建并完全结算 ->
##   联合弹窗(20)（E 选攻击牌联合攻击C，独立顶层）-> 闪击弃牌再攻窗(10)（P 弃1再攻D）
##   -> 全部动作完成、联合状态清除、无孤儿挂起。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")
const _ActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


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


func _ensure_card_in_player_hand(battle: BattleState, card_def_id: String, exclude_ids: Array = []) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		if exclude_ids.has(cid):
			continue
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		if exclude_ids.has(cid):
			continue
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		if exclude_ids.has(cid):
			continue
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


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


## 直接对 target 施加联合状态（unite=unite_mech，同 test_unite_status_flow._apply_unite）
func _apply_unite(battle, target_mech_id: StringName, unite_mech_id: StringName) -> void:
	battle.context.game_actions.add_status({
		"target_id": target_mech_id,
		"status": {
			"type": &"UNITE",
			"duration": &"UNTIL_TURN_END",
			"unite": unite_mech_id,
			"source_player_id": &"player",
		},
	})


func _find_unite_status(mech, unite_mech_id: StringName) -> Dictionary:
	for s: Dictionary in mech.statuses:
		if s.get("type", &"") == &"UNITE" and String(s.get("unite", &"")) == String(unite_mech_id):
			return s
	return {}


## 驱动 attack 的损伤设置效果动作完成；遇到非损伤子动作（如反击攻击B）时停下交还调用方。
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


## 驱动一个攻击动作（选武器+选目标+损伤放置+结算）走到完成或非损伤挂起。
## 返回 {ok, msg}。attack 的损伤子动作自动放置。
func _drive_attack_to_completion(battle: BattleState, attack_id: StringName, weapon_id: StringName, target_mech_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while guard < 20:
		guard += 1
		match String(attack.state):
			&"waiting_input":
				if not attack.record.has("weapon_id"):
					ae.continue_action(attack_id, {"weapon_id": weapon_id})
				else:
					ae.continue_action(attack_id, {"target_id": target_mech_id})
				await _pump_frames(2)
			&"waiting_effect_action":
				var ret: Dictionary = _drive_damage_until_non_damage_sub(battle, attack_id)
				if not ret.get("ok", false):
					return ret
				await _pump_frames(2)
				# 损伤驱动后若仍是 waiting_effect_action 且有 attack 子动作，交还调用方（外层驱动）
				if String(attack.state) == &"waiting_effect_action":
					for cid: StringName in attack.pending_effect_action_ids:
						var sub = ar.get_action(cid)
						if sub != null and sub.action_type == &"attack":
							return {"ok": true, "msg": "sub_attack", "sub_attack_id": cid}
					return {"ok": false, "msg": "损伤驱动后卡在 waiting_effect_action: pending=%s" % str(attack.pending_effect_action_ids)}
			&"waiting_timing":
				# 响应窗口（联合攻击C 的 attackC' 目标是 P，P 无迎击牌自动跳过？不一定，等待外层处理）
				return {"ok": false, "msg": "attack %s 停在 waiting_timing（响应窗口），需外层驱动" % String(attack_id)}
			_:
				break
	await _pump_frames(4)
	return {"ok": true}


## 驱动攻击的选武器/选目标输入（waiting_input -> 注入 weapon_id/target_id 直到不再 waiting_input）
func _drive_attack_inputs(battle: BattleState, attack_id: StringName, weapon_id: StringName, target_mech_id: StringName) -> String:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack = ar.get_action(attack_id)
	if attack == null:
		return "找不到 attack %s" % String(attack_id)
	var guard: int = 0
	while String(attack.state) == &"waiting_input" and guard < 8:
		guard += 1
		# 注意：record 里 weapon_id 键可能存在但为空（创建时预填 &""），用取值判空而非 has()
		if String(attack.record.get("weapon_id", &"")) == "":
			ae.continue_action(attack_id, {"weapon_id": weapon_id})
		else:
			ae.continue_action(attack_id, {"target_id": target_mech_id})
		await _pump_frames(3)
	return ""


# ═══════════════════════════════════════════
# 测试1：优先级数字断言
# ═══════════════════════════════════════════

func test_settle_priorities_aligned() -> Variant:
	var all: Dictionary = _ActionEffects.build_all_effects()
	if all.is_empty():
		return "无法构建行动牌效果表"
	var counter = all.get(&"counter_effect2")
	var unite = all.get(&"unite_status_attack")
	var flash = all.get(&"flash_effect2")
	if counter == null or unite == null or flash == null:
		return "效果定义缺失 counter=%s unite=%s flash=%s" % [str(counter != null), str(unite != null), str(flash != null)]
	if int(counter.priority) != 30:
		return "counter_effect2 优先级应=30（反击额外攻击），实际 %d" % int(counter.priority)
	if int(unite.priority) != 20:
		return "unite_status_attack 优先级应=20（联合连携攻击），实际 %d" % int(unite.priority)
	if int(flash.priority) != 10:
		return "flash_effect2 优先级应=10（闪击再次攻击），实际 %d" % int(flash.priority)
	if String(counter.listen_timing) != String(_TimingConst.ATTACK_SETTLE):
		return "counter_effect2 时点应保持 ATTACK_SETTLE"
	if String(unite.listen_timing) != String(_TimingConst.ATTACK_SETTLE):
		return "unite_status_attack 时点应保持 ATTACK_SETTLE"
	if String(flash.listen_timing) != String(_TimingConst.ATTACK_SETTLE):
		return "flash_effect2 时点应保持 ATTACK_SETTLE"
	# 迪恩虚拟反击的反击攻击同 30
	var pilot_all: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var p011cs = pilot_all.get(&"pilot_011_counter_strike")
	if p011cs == null:
		return "pilot_011_counter_strike 定义缺失"
	if int(p011cs.priority) != 30:
		return "pilot_011_counter_strike 优先级应=30（与 counter_effect2 同级同序），实际 %d" % int(p011cs.priority)
	return true


# ═══════════════════════════════════════════
# 测试2：三效果共存（反击30 -> 联合20 -> 闪击10）串行全链
# ═══════════════════════════════════════════

func test_triple_effect_serial_order() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	gs.players.get(&"enemy").is_human = true
	gs.players.get(&"player").is_human = true

	# P 手牌：闪击 + 2张进攻（闪击弃牌 fodder；exclude 防两次查找返回同一实例）
	var flash_id = _ensure_card_in_player_hand(battle, "action_006_闪击")
	var fodder1 = _ensure_card_in_player_hand(battle, "action_001_进攻")
	var fodder2 = _ensure_card_in_player_hand(battle, "action_001_进攻", [fodder1])
	if flash_id == &"" or fodder1 == &"" or fodder2 == &"":
		return "无法准备闪击/弃牌 fodder"
	# E 手牌：反击（响应用）+ 1张进攻（联合连携用）
	_clear_enemy_hand(battle)
	var counter_id = _ensure_card_in_enemy_hand(battle, "action_010_反击")
	var unite_atk_id = _ensure_card_in_enemy_hand(battle, "action_001_进攻")
	if counter_id == &"" or unite_atk_id == &"":
		return "无法准备反击/联合攻击牌"

	# E 施加联合状态（unite=P，Target=E）：P 攻击结算时 E 可联合攻击
	_apply_unite(battle, enemy_mech.mech_id, player_mech.mech_id)
	if _find_unite_status(enemy_mech, player_mech.mech_id).is_empty():
		return "联合状态施加失败"

	var weapon_ids = player_mech.get_weapon_ids()
	var weapon_id = weapon_ids[0]
	var enemy_weapon_ids = enemy_mech.get_weapon_ids()
	if enemy_weapon_ids.is_empty():
		return "敌方机甲无武器"

	enemy_mech.position = {"q": 3, "r": 2}
	enemy_mech.power = 0  # counter_effect1 半动力移动 X=0：请求选格后取消结束
	enemy_mech.temp_armor_bonus = 999
	player_mech.temp_armor_bonus = 999

	battle.context.action_ui_bridge.context = battle.context

	# ── P 打出闪击 -> 攻击A ──
	var result: Dictionary = battle.execute_use_action_card(&"player", flash_id)
	if result.get("state", &"") != &"waiting_effect_action":
		return "use_action_card 应暂停（等攻击A 选武器），实际 state=%s" % String(result.get("state", &""))
	var attack_a_id: StringName = &""
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a_id = aid
			break
	if attack_a_id == &"":
		return "找不到攻击A"
	var attack_a = battle.context.action_registry.get_action(attack_a_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine

	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	await _pump_frames(2)
	if String(attack_a.state) == &"waiting_input":
		ae.continue_action(attack_a_id, {"target_id": enemy_mech.mech_id})
		await _pump_frames(2)
	if String(attack_a.state) != &"waiting_timing":
		return "攻击A 选目标后应在 ATTACK_AT waiting_timing（响应窗口），实际 state=%s" % String(attack_a.state)

	# ── E 响应窗口打出反击 ──
	var sel: Array[Dictionary] = [{
		"effect_id": &"counter_availability",
		"card_instance_id": counter_id,
		"availability_priority": 5,
	}]
	te.handle_response_selection(attack_a_id, sel)
	await _pump_frames(3)
	# counter_effect1 移动循环（power=0 首次仍请求选格）-> 取消结束
	battle.context.action_ui_bridge.on_ui_cancelled()
	await _pump_frames(8)
	# 攻击A 损伤驱动 -> ATTACK_SETTLE
	var drive_ret: Dictionary = _drive_damage_until_non_damage_sub(battle, attack_a_id)
	if not drive_ret.get("ok", false):
		return drive_ret
	await _pump_frames(3)

	# ── 断言①：counter_effect2(30) 最先执行--反击攻击B 已创建，攻击A waiting_effect_action ──
	var counter_b_id: StringName = &""
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			counter_b_id = aid
			break
	if counter_b_id == &"":
		return "断言①失败：反击攻击B 未创建（counter_effect2 未先执行）state=%s pending=%s" % [String(attack_a.state), str(attack_a.pending_effect_action_ids)]
	if String(attack_a.state) != &"waiting_effect_action":
		return "断言①失败：攻击A 应 waiting_effect_action（等反击攻击B），实际 state=%s" % String(attack_a.state)

	# ── 驱动反击攻击B（E 选武器 -> 目标 P）完全结算 ──
	var counter_b = ar.get_action(counter_b_id)
	var b_err: String = await _drive_attack_inputs(battle, counter_b_id, enemy_weapon_ids[0], player_mech.mech_id)
	if b_err != "":
		return "反击攻击B 驱动失败: %s" % b_err
	# B 目标是 P：ATTACK_AT 响应窗口（P 无迎击牌，空选择 pass 关闭窗口）
	var b_guard2: int = 0
	var b_empty_sel: Array[Dictionary] = []
	while String(counter_b.state) == &"waiting_timing" and b_guard2 < 5:
		b_guard2 += 1
		te.handle_response_selection(counter_b_id, b_empty_sel)
		await _pump_frames(4)
	_drive_damage_until_non_damage_sub(battle, counter_b_id)
	await _pump_frames(8)
	ae.notify_effect_action_completed(counter_b_id, attack_a_id)
	await _pump_frames(5)

	# ── 断言②：反击B 完成后下一个触发的是联合弹窗(20)，而非闪击弃牌窗(10) ──
	var pend2: Dictionary = te._pending_effect.get(attack_a_id, {})
	var pend2_phase: String = String(pend2.get("phase", &""))
	if pend2_phase != &"unite_attack_offer":
		return "断言②失败：反击B 结算后应弹联合弹窗（phase=unite_attack_offer，优先级20 先于闪击10），实际 phase=%s state=%s" % [pend2_phase, String(attack_a.state)]
	if String(attack_a.state) != &"waiting_timing":
		return "断言②失败：联合弹窗挂起时攻击A 应 waiting_timing，实际 state=%s" % String(attack_a.state)

	# ── E 确认联合攻击（打出进攻牌 -> 独立顶层 use_action_card C）──
	te.resume_pending_effect(attack_a_id, {"selected_card_id": unite_atk_id})
	await _pump_frames(4)
	# 联合攻击C 应为独立顶层 use_action_card（打出 unite_atk_id）
	var unite_c_id: StringName = &""
	for a2 in ar.get_actions_by_type(&"use_action_card"):
		if a2 != null and String(a2.record.get("card_instance_id", &"")) == String(unite_atk_id):
			unite_c_id = a2.action_id
			break
	if unite_c_id == &"":
		return "联合攻击C（use_action_card 打出进攻牌）未创建"
	if attack_a.pending_effect_action_ids.has(unite_c_id):
		return "联合攻击C 不应作为攻击A 子动作（独立顶层并行）"

	# ── 断言③：攻击A 恢复续跑 flash_effect2(10) -> 闪击弃牌弹窗挂起 ──
	var pend3: Dictionary = te._pending_effect.get(attack_a_id, {})
	var pend3_eff = pend3.get("effect")
	if pend3_eff == null or pend3_eff.effect_id != &"flash_effect2":
		return "断言③失败：联合确认后攻击A 应续跑 flash_effect2 挂起弃牌弹窗，实际 pending effect=%s" % (String(pend3_eff.effect_id) if pend3_eff else "null")
	if String(attack_a.state) != &"waiting_timing":
		return "断言③失败：闪击弃牌弹窗挂起时攻击A 应 waiting_timing，实际 state=%s" % String(attack_a.state)

	# ── P 确认闪击弃1张 fodder -> 再攻击D ──
	# optional 弃牌 resume 默认路径读 selected_action_card_ids（TimingEngine resume_pending_effect 默认分支）
	te.resume_pending_effect(attack_a_id, {"selected_action_card_ids": [fodder1]})
	await _pump_frames(4)
	# 攻击D（P 用攻击A 的武器再攻，选目标）应作为攻击A 的效果子动作创建
	var flash_d_id: StringName = &""
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			flash_d_id = aid
			break
	if flash_d_id == &"":
		# 也可能已完成（同步推进无损伤）；检查攻击A 是否完成
		if String(attack_a.state) != &"completed":
			return "闪击再攻击D 未创建且攻击A 未完成 state=%s pending=%s" % [String(attack_a.state), str(attack_a.pending_effect_action_ids)]
	else:
		var d_err: String = await _drive_attack_inputs(battle, flash_d_id, weapon_id, enemy_mech.mech_id)
		if d_err != "":
			return "闪击再攻击D 驱动失败: %s" % d_err
		_drive_damage_until_non_damage_sub(battle, flash_d_id)
		await _pump_frames(8)
		ae.notify_effect_action_completed(flash_d_id, attack_a_id)
		await _pump_frames(4)
	if String(attack_a.state) != &"completed":
		return "闪击链结束后攻击A 应完成，实际 state=%s" % String(attack_a.state)

	# ── 驱动联合攻击C（E 的 use_action_card：attackC' 选武器->目标P->关响应窗->损伤->SETTLE->REMOVE_STATUS）──
	var unite_c = ar.get_action(unite_c_id)
	var c_guard: int = 0
	while unite_c != null and String(unite_c.state) != &"completed" and String(unite_c.state) != &"cancelled" and c_guard < 25:
		c_guard += 1
		# 找 C 挂起的未完成 attack 子动作驱动
		var c_attack_id: StringName = &""
		for cid: StringName in unite_c.pending_effect_action_ids:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"attack" and sub.state != &"completed" and sub.state != &"cancelled":
				c_attack_id = cid
				break
		if c_attack_id != &"":
			var c_atk = ar.get_action(c_attack_id)
			var c_err: String = await _drive_attack_inputs(battle, c_attack_id, enemy_weapon_ids[0], player_mech.mech_id)
			if c_err != "":
				return "联合攻击C 的攻击驱动失败: %s" % c_err
			# attackC' 目标是 P（人类）：ATTACK_AT 响应窗口须空选择 pass 关闭（同反击B）
			var w_guard: int = 0
			var c_empty_sel: Array[Dictionary] = []
			while c_atk != null and String(c_atk.state) == &"waiting_timing" and w_guard < 5:
				w_guard += 1
				te.handle_response_selection(c_attack_id, c_empty_sel)
				await _pump_frames(4)
			_drive_damage_until_non_damage_sub(battle, c_attack_id)
			await _pump_frames(8)
			# 仅当攻击真正完成/取消才通知父动作（防误完成孤儿）
			if c_atk != null and (String(c_atk.state) == &"completed" or String(c_atk.state) == &"cancelled"):
				ae.notify_effect_action_completed(c_attack_id, unite_c_id)
				await _pump_frames(4)
			continue
		# C 自身 waiting_effect_action 非 attack 子动作（损伤等）：驱动
		if String(unite_c.state) == &"waiting_effect_action":
			var cret: Dictionary = _drive_damage_until_non_damage_sub(battle, unite_c_id)
			if not cret.get("ok", false):
				return cret
			await _pump_frames(3)
			continue
		await _pump_frames(3)
	if unite_c == null or String(unite_c.state) != &"completed":
		return "联合攻击C 未完成 state=%s" % (String(unite_c.state) if unite_c != null else "null")

	# ── 断言④：终态--无孤儿动作、联合状态已清、P 弃了1张 fodder ──
	var active_count: int = ar.get_active_count()
	if active_count != 0:
		var ids: Array = []
		for aid in ar.get_active_ids():
			var a3 = ar.get_action(aid)
			ids.append("%s(%s) state=%s record=%s source=%s" % [String(a3.action_id), String(a3.action_type), String(a3.state), str(a3.record).substr(0, 300), str(a3.source).substr(0, 200)])
		return "断言④失败：仍有 %d 个挂起动作（孤儿）：%s" % [active_count, str(ids)]
	if not _find_unite_status(enemy_mech, player_mech.mech_id).is_empty():
		return "断言④失败：联合攻击C 结算后联合状态应被 REMOVE_STATUS 清除"
	var p_hand: Array = gs.players.get(&"player").action_hand
	if p_hand.has(fodder1):
		return "断言④失败：闪击弃牌 fodder1 应已弃置"
	if not p_hand.has(fodder2):
		return "断言④失败：fodder2 不应被误弃"
	if gs.players.get(&"enemy").action_hand.has(unite_atk_id):
		return "断言④失败：联合攻击牌应已打出（不在手牌）"
	# 反击牌应已弃置（攻击A cleanup 弃置迎击牌）
	if gs.players.get(&"enemy").action_hand.has(counter_id):
		return "断言④失败：反击牌应在攻击A cleanup 后弃置"
	return true
