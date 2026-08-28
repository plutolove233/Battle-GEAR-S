## test_pilot_084_莎菲雅.gd - 莎菲雅（pilot_084，混乱 N，cost 3, attack_limit 1, action_card_limit 4）效果测试
##
## 2 个按钮（效果1 主动 + 效果2 被动，悬停看完整说明）：
##   effect_01（DIRECT 按钮1，我方回合2次）「当作联合」：
##     我方回合2次，可以将2张行动牌当作联合使用，之后抽2张行动牌。
##   effect_02（LISTEN 按钮2，被动置灰+悬停）「联合获金」：
##     其他机甲因联合的效果使用攻击牌后，我方获得2金币。
##
## 关键覆盖点：
##   1. 两效果定义 + JSON effect_ids + 按钮形态（DIRECT 主动 / LISTEN 被动）。
##   2. effect_01 全流程：选2张行动牌 -> 当作联合（选联合目标施加 UNITE 状态）-> 抽2 -> 燃料牌进弃牌堆。
##   3. effect_01 取消选牌：不计次数，可再次发动。
##   4. effect_01 联合目标取消：照常消耗+仍抽2（用户确认的设计）。
##   5. effect_01 每回合2次：两次成功后第三次不挂起。
##   6. effect_02 被动：其他机甲因联合使用攻击牌（_unite_attack_origin）-> 我方+2金。
##   7. effect_02 非联合来源（正常用攻击牌）-> 不获金。
##   8. effect_02 莎菲雅自己因联合用攻击牌 -> 不获金（出牌机甲=持有机甲）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90084
	battle.pvp_map_features = true
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


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设莎菲雅为 owner_id 机甲机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_084(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_084_莎菲雅", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 放机甲到指定坐标
func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 把指定坐标格子的地形重置为 NORMAL（pvp_map_features 随机绿/红格会阻挡武器范围 BFS，
## 固定坐标测试需保证机甲占据格及路径可通行）。
func _make_cells_normal(gs, positions: Array) -> void:
	for pos in positions:
		var key: String = _HexGrid.key(pos)
		var cell = gs.map_state.cells.get(key)
		if cell == null:
			continue
		if cell is Dictionary:
			cell["terrain"] = &"NORMAL"
		elif cell.get("terrain") != null:
			cell.terrain = &"NORMAL"


## 给 owner_id 玩家补 N 张行动牌（从牌堆顶抽），返回 [cid,...]
func _give_action_cards(battle, owner_id: StringName, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"action_hand"
			c.owner_player_id = owner_id
		out.append(cid)
	return out


## 清空 owner_id 行动手牌（移回牌堆顶，测试用占位）
func _clear_action_hand(battle, owner_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 确保某张行动牌在指定玩家手里（从牌堆/弃牌堆找）。返回 cid 或 &""。
func _ensure_card_in_hand(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id) == card_def_id:
			return cid
	for pile_name in [&"action_deck", &"action_discard_pile"]:
		var pile: Array = gs.deck_state.get(pile_name)
		if pile == null:
			continue
		for i in range(pile.size()):
			var cid: StringName = pile[i]
			var c = gs.get_card(cid)
			if c and c.def and String(c.def.card_id) == card_def_id:
				pile.remove_at(i)
				player.action_hand.append(cid)
				c.zone = &"action_hand"
				c.owner_player_id = player_id
				c.mech_id = &""
				battle.context.register_hand_card_availability(cid)
				return cid
	return &""


## 触发莎菲雅某 DIRECT 效果（effect_fire），返回挂起的 effect_fire action（或 null）。
func _fire_pilot_084(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": effect_id,
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": effect_id,
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if String(a.record.get("effect_id", &"")) == String(effect_id) and a.state != &"completed" and a.state != &"cancelled":
			return a
	return null


## 从 bridge 取当前等待输入的动作 id（嵌套子动作弹窗用），无则返回 &""。
func _waiting_action_id(battle) -> StringName:
	var info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	return info.get("action_id", &"") if not info.is_empty() else &""


## 统计机甲上的 UNITE 状态列表（含 unite 字段）
func _unite_statuses(mech) -> Array:
	var out: Array = []
	if mech == null:
		return out
	for s in mech.statuses:
		if String(s.get("type", &"")) == "UNITE":
			out.append(s)
	return out


## ── 输入驱动器：收集 action_needs_input 信号，按 input_type 自动回填（真实攻击链用）──
## select_unite_attack_card 不在此处理（记录到 unite_action_id，由测试断言后接管）。
class InputDriver:
	var context = null
	var pending: Dictionary = {}
	var unite_action_id: StringName = &""   # 捕获到的联合攻击弹窗所属动作
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		context.action_engine.action_needs_input.connect(_on_need)
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, _input_params: Dictionary) -> void:
		if input_type == &"select_unite_attack_card":
			unite_action_id = action_id
			return  # 不入 pending，由测试在断言后取消清理
		pending[action_id] = {"input_type": input_type, "input_params": _input_params}

	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		var input_data = _resolve(action_id, input_type, input_params)
		if input_data == null:
			return true
		context.action_service.continue_action(action_id, input_data)
		return true

	func _resolve(action_id: StringName, input_type: StringName, input_params: Dictionary):
		match input_type:
			&"select_weapon":
				return {"weapon_id": weapon_for.call(action_id)}
			&"select_attack_target":
				return {"target_id": target_for.call(action_id, input_params)}
			&"respond_attack":
				var sel: Array[Dictionary] = response_for.call(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
				return null
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				if d.is_empty():
					return {"auto_placed": true}
				return d
			_:
				return {"auto": true}


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：两效果定义正确 + JSON effect_ids 全注册 + 按钮形态（DIRECT 主动 / LISTEN 被动）
func test_pilot_084_effect_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_084_莎菲雅", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	for need in ["pilot_084_effect_01", "pilot_084_effect_02"]:
		if not id_strs.has(need):
			return "effect_ids 应含 %s 实=%s" % [need, str(id_strs)]
	# e1
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_084_effect_01")
	if e1 == null:
		return "缺 pilot_084_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	# 每回合2次通过 EFFECT_ONCE_PER_TURN_AVAILABLE 条件 params 实现（丹 pilot_068 同款），
	# 效果级 once_per_turn_key 不设（设了会在 TimingEngine 1403 双重计次）。
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "HAS_ACTION_CARD_IN_HAND"]:
		if not ops.has(need):
			return "e1 应含条件 %s 实=%s" % [need, str(ops)]
	for c in e1.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE" and int(c.get("params", {}).get("once_per_turn_max", 0)) != 2:
			return "e1 EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_max 应 2"
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND" and int(c.get("params", {}).get("minimum", 0)) != 2:
			return "e1 HAS_ACTION_CARD_IN_HAND minimum 应 2"
	var acts: Array = e1.actions
	var types: Array = []
	for a in acts:
		types.append(String(a.get("type", &"")))
	var need_types := ["CHOOSE_MANY_CARDS", "MOVE_ACTION_CARDS_TO_TEMP_ZONE", "MARK_EFFECT_ONCE_PER_TURN_USED", "PLAY_AS_NAMED", "EXECUTE_GAIN_CARD", "DISCARD_TEMP_ZONE_CARDS"]
	for nt in need_types:
		if not types.has(nt):
			return "e1 actions 应含 %s 实=%s" % [nt, str(types)]
	var cm: Dictionary = acts[0].get("params", {})
	if int(cm.get("min_count", 0)) != 2 or int(cm.get("max_count", 0)) != 2:
		return "e1 选牌应 min=max=2 实=min%d/max%d" % [int(cm.get("min_count", 0)), int(cm.get("max_count", 0))]
	var pan: Dictionary = acts[3].get("params", {})
	if String(pan.get("as_card_def_id", &"")) != "action_018_联合":
		return "e1 PLAY_AS_NAMED as_card_def_id 应 action_018_联合 实=%s" % String(pan.get("as_card_def_id", &""))
	if bool(pan.get("attack_is_active", true)):
		return "e1 PLAY_AS_NAMED attack_is_active 应 false（辅助不耗攻击数）"
	var gcd: Dictionary = acts[4].get("params", {})
	if int(gcd.get("count", 0)) != 2 or String(gcd.get("card_kind", &"")) != "action":
		return "e1 EXECUTE_GAIN_CARD 应抽2张行动牌 实=%s" % str(gcd)
	# e2
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_084_effect_02")
	if e2 == null:
		return "缺 pilot_084_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "e2 mode 应 LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.USE_ACTION_AT:
		return "e2 listen_timing 应 USE_ACTION_AT 实=%s" % String(e2.listen_timing)
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	for need in ["USE_ACTION_IS_UNITE_ORIGIN", "USED_CARD_TYPE_IS", "USE_ACTION_BY_OTHER_MECH"]:
		if not e2_ops.has(need):
			return "e2 应含条件 %s 实=%s" % [need, str(e2_ops)]
	for c in e2.conditions:
		if String(c.get("op", &"")) == "USED_CARD_TYPE_IS" and String(c.get("card_type", &"")) != "攻击":
			return "e2 USED_CARD_TYPE_IS card_type 应 攻击"
	var e2_acts: Array = e2.actions
	if e2_acts.is_empty() or String(e2_acts[0].get("type", &"")) != "GAIN_GOLD":
		return "e2 actions 应 [GAIN_GOLD]"
	if int(e2_acts[0].get("params", {}).get("amount", 0)) != 2:
		return "e2 GAIN_GOLD amount 应 2 实=%d" % int(e2_acts[0].get("params", {}).get("amount", 0))
	return true


# ═══════════════════════════════════════════
# effect_01 当作联合
# ═══════════════════════════════════════════

## 标准布局：莎菲雅在 player(2,2)，敌机 enemy(4,2)，双方手牌清空。
func _setup_standard_e1(battle) -> Dictionary:
	var s = _setup_pilot_084(battle, &"player")
	if s == null:
		return {}
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return {"pilot_card": s.card, "player_mech": s.mech, "enemy_mech": enemy_mech, "gs": gs}


## 完整走一遍当作联合：选2张牌 -> 确认 -> 选联合目标 -> 等待全部结算。
## 返回 {} 失败或 {"player_hand_before": n} 供上层校验；由测试自行做断言前。返回字符串=错误。
func _run_unite_flow(battle, setup, fuel_ids: Array, select_target: bool = true, cancel_target: bool = false) -> Variant:
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var ef = await _fire_pilot_084(battle, pilot_card, player_mech, &"player", &"pilot_084_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起（应弹选牌窗）"
	# ① 选2张行动牌确认
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": fuel_ids, "cancelled": false})
	await _pump_frames(8)
	# ② 联合目标选择（unite_effect1 CHOOSE_OTHER_MECH）
	var w: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if w.is_empty():
		# 可能已同步完成（无弹窗则说明未走到选目标，报错）
		return "联合目标选择未弹出，等待信息为空"
	var tgt_action_id: StringName = w.get("action_id", &"")
	if cancel_target:
		te.resume_pending_effect(tgt_action_id, {"cancelled": true})
	elif select_target:
		te.resume_pending_effect(tgt_action_id, {"target_id": enemy_mech.mech_id})
	else:
		return "select_target/cancel_target 都为空"
	await _pump_frames(15)
	return {"gs": gs}


## 测试2：effect_01 全流程——选2张行动牌当作联合（选目标施加UNITE）-> 抽2 -> 燃料牌进弃牌堆 + 消耗1/2额度
func test_pilot_084_effect01_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_084_莎菲雅）"
	var gs = setup["gs"]
	var player = gs.players[&"player"]
	var enemy_mech = setup["enemy_mech"]
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var hand_before: int = player.action_hand.size()
	var r = await _run_unite_flow(battle, setup, hand, true, false)
	if r is String:
		return r
	# 燃料牌应被当作联合消耗：进弃牌堆（不是留在手牌）
	for cid in hand:
		var c = gs.get_card(cid)
		if c == null or String(c.zone) != "discard":
			return "当作联合的燃料牌 %s 应进弃牌堆，zone=%s" % [String(cid), String(c.zone if c else "null")]
	# 抽2张行动牌：手牌 = 之前留下的 + 抽的2张（燃料牌已移出）
	if player.action_hand.size() != hand_before - 2 + 2:
		return "之后应抽2张行动牌，手牌=%d（before=%d）" % [player.action_hand.size(), hand_before]
	# 敌机应获得 UNITE 状态（unite=莎菲雅持有机甲）
	var unites: Array = _unite_statuses(enemy_mech)
	if unites.is_empty():
		return "联合目标应获得 UNITE 状态"
	return true


## 测试3：effect_01 取消选牌 -> 不计次数，可再次发动
func test_pilot_084_effect01_cancel_card_select() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var ef = await _fire_pilot_084(battle, pilot_card, player_mech, &"player", &"pilot_084_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	# 取消选牌窗
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": [], "cancelled": true})
	await _pump_frames(6)
	# 次数未消耗 + 手牌未动：再次触发仍挂起
	var ef2 = await _fire_pilot_084(battle, pilot_card, player_mech, &"player", &"pilot_084_effect_01")
	if ef2 == null:
		return "取消选牌不应消耗额度，第二次应能再次挂起"
	# 收尾：第二次完整走完，验证消耗
	te.resume_pending_effect(ef2.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(8)
	var w: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if w.is_empty():
		return "第二次走完后联合目标选择未弹出"
	te.resume_pending_effect(w.get("action_id", &""), {"target_id": enemy_mech.mech_id})
	await _pump_frames(15)
	return true


## 测试4：effect_01 确认2张牌后取消联合目标 -> 照常消耗+仍抽2（用户确认的设计）
func test_pilot_084_effect01_unite_target_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player = gs.players[&"player"]
	var enemy_mech = setup["enemy_mech"]
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var hand_before: int = player.action_hand.size()
	var r = await _run_unite_flow(battle, setup, hand, true, true)
	if r is String:
		return r
	# 燃料牌照常被消耗进弃牌堆
	for cid in hand:
		var c = gs.get_card(cid)
		if c == null or String(c.zone) != "discard":
			return "取消联合目标后燃料牌 %s 仍应进弃牌堆，zone=%s" % [String(cid), String(c.zone if c else "null")]
	# 仍抽2张行动牌
	if player.action_hand.size() != hand_before - 2 + 2:
		return "取消联合目标后仍应抽2张行动牌，手牌=%d（before=%d）" % [player.action_hand.size(), hand_before]
	# 未施加 UNITE 状态（目标选择被取消）
	if not _unite_statuses(enemy_mech).is_empty():
		return "取消联合目标不应施加 UNITE 状态"
	# 额度应已消耗1次（取消联合目标=照常计次，用户确认的设计）：此时额度 1/2。
	# 再完整走1次（用光额度到 2/2），第三次触发才不应挂起——若取消不计次，
	# 则第二走后额度仅 1/2，第三次会挂起，测试即失败，从而区分"取消计次"。
	var hand2: Array = player.action_hand.duplicate()
	if hand2.size() < 2:
		return "取消后应仍抽2张足以再走1次，实际手牌=%d" % hand2.size()
	var r2 = await _run_unite_flow(battle, setup, [hand2[0], hand2[1]], true, false)
	if r2 is String:
		return "第二走失败: %s" % r2
	var pilot_card = setup["pilot_card"]
	var player_mech = setup["player_mech"]
	var ef3 = await _fire_pilot_084(battle, pilot_card, player_mech, &"player", &"pilot_084_effect_01")
	if ef3 != null:
		return "取消联合目标后额度应已消耗，第三次触发不应挂起"
	return true


## 测试5：effect_01 每回合2次——两次成功发动后第三次不挂起
func test_pilot_084_effect01_twice_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var enemy_mech = setup["enemy_mech"]
	var hand = _give_action_cards(battle, &"player", 4)
	if hand.size() != 4:
		return "无法补4张行动牌"
	# 第一次完整发动
	var r1 = await _run_unite_flow(battle, setup, [hand[0], hand[1]], true, false)
	if r1 is String:
		return "第一次发动失败: %s" % r1
	# 第二次完整发动（用剩下的2张）
	var r2 = await _run_unite_flow(battle, setup, [hand[2], hand[3]], true, false)
	if r2 is String:
		return "第二次发动失败: %s" % r2
	# 第三次不应挂起（每回合2次已用满）
	var pilot_card = setup["pilot_card"]
	var player_mech = setup["player_mech"]
	var ef3 = await _fire_pilot_084(battle, pilot_card, player_mech, &"player", &"pilot_084_effect_01")
	if ef3 != null:
		return "每回合2次已用满，第三次触发不应挂起"
	return true


## 测试9：当作联合后，莎菲雅打攻击牌走真实攻击链 → ATTACK_SETTLE → 联合攻击弹窗（select_unite_attack_card）
## 回归保障：bug#4「联合状态不触发」——确认为非产品 bug（此前测试假象：目标置于 RED 格致
## BFS no_target_in_range 取消攻击，联合窗永不触发）。此测试用相邻 NORMAL 布局固化完整真实链路。
func test_pilot_084_effect01_unite_attack_offer() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_084(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_084_莎菲雅）"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var pilot_card = s.card
	# 相邻布局（test_unite 验证过 (5,0)/(6,0) 区域无 RED 格），并重置地形防 BFS 范围失败
	_place_mech(battle, player_mech.mech_id, 5, 0)
	_place_mech(battle, enemy_mech.mech_id, 6, 0)
	_make_cells_normal(gs, [{"q": 5, "r": 0}, {"q": 6, "r": 0}])
	player_mech.power = 10
	enemy_mech.power = 10
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	# ① 当作联合：选2张燃料牌 -> 选 enemy 为联合目标 -> 施加 UNITE
	var fuel = _give_action_cards(battle, &"player", 2)
	if fuel.size() != 2:
		return "无法补2张燃料行动牌"
	var setup := {"pilot_card": pilot_card, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs}
	var r = await _run_unite_flow(battle, setup, fuel, true, false)
	if r is String:
		return r
	if _unite_statuses(enemy_mech).is_empty():
		return "UNITE 状态未施加到 enemy"
	# ② 准备攻击牌：player 打攻击牌（莎菲雅），enemy 留攻击牌（联合攻击候选）
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if attack_cid == &"":
		return "找不到 player 攻击牌"
	var unite_cid: StringName = _ensure_card_in_hand(battle, &"enemy", "action_001_进攻")
	if unite_cid == &"":
		return "找不到 enemy 攻击牌（联合攻击需 Target 手牌有攻击牌）"
	# ③ 驱动莎菲雅打出攻击牌，走真实攻击链到联合弹窗
	var driver := InputDriver.new()
	driver.attach(battle.context)
	var ar = battle.context.action_registry
	driver.weapon_for = func(_aid: StringName) -> StringName: return &"frame_base_weapon_1"
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = ar.get_action(aid)
		if act == null:
			return &""
		return enemy_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		var empty_resp: Array[Dictionary] = []
		return empty_resp
	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary: return {"auto_placed": true}
	var res := battle.execute_use_action_card(&"player", attack_cid)
	if String(res.get("state", &"")) == &"error":
		return "player use_action_card 发起失败: %s" % str(res)
	# 驱动直到联合弹窗挂起（select_unite_attack_card 被拦截）
	var guard := 0
	while guard < 500:
		guard += 1
		var progressed: bool = driver.pump()
		await _pump_frames(1)
		var progressed2: bool = driver.pump()
		await _pump_frames(1)
		if driver.unite_action_id != &"":
			break
		if not progressed and not progressed2 and driver.pending.is_empty():
			break
	if driver.unite_action_id == &"":
		# 诊断：列出活跃动作
		var st := []
		for aid: StringName in ar.get_active_ids():
			var a = ar.get_action(aid)
			if a:
				st.append("%s:%s:%s" % [String(aid), String(a.action_type), String(a.state)])
		return "未捕获联合弹窗。活跃动作: %s" % str(st)
	# ④ 清理：取消联合攻击子树，避免残留
	battle.context.action_engine.cancel_action(driver.unite_action_id)
	for i in range(8):
		await _pump_frames(1)
	return true


# ═══════════════════════════════════════════
# effect_02 联合获金（被动）
# ═══════════════════════════════════════════

## 标准被动布局：莎菲雅在 player(2,2)，敌机 enemy(4,2)，双方手牌清空，返回 setup。
func _setup_standard_e2(battle) -> Dictionary:
	var s = _setup_pilot_084(battle, &"player")
	if s == null:
		return {}
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return {"pilot_card": s.card, "player_mech": s.mech, "enemy_mech": enemy_mech, "gs": gs}


## 模拟 use_action_card 动作 fire USE_ACTION_AT（record 可带 _unite_attack_origin）。
## 返回 true；无法构造返回错误字符串。
func _fire_use_action_at(battle, cid: StringName, use_mech, player_id: StringName, unite_origin: bool) -> Variant:
	var action := _Action.new()
	action.action_id = &"test_use_%d" % [randi() % 1000000]
	action.action_type = &"use_action_card"
	action.record = {
		"card_instance_id": cid,
		"source_mech_id": use_mech.mech_id,
		"mech_id": use_mech.mech_id,
		"player_id": player_id,
	}
	if unite_origin:
		action.record["_unite_attack_origin"] = true
	action.state = &"running"
	action.context = battle.context
	battle.context.action_registry.register(action)
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, action)
	await _pump_frames(6)
	return true


## 测试6：effect_02 被动——其他机甲因联合使用攻击牌 -> 莎菲雅玩家 +2金币
func test_pilot_084_effect02_passive_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e2(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player = gs.players[&"player"]
	var enemy_mech = setup["enemy_mech"]
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"enemy", "action_001_进攻")
	if attack_cid == &"":
		return "找不到敌方攻击牌"
	var gold_before: int = int(player.gold)
	var r = await _fire_use_action_at(battle, attack_cid, enemy_mech, &"enemy", true)
	if r is String:
		return r
	if int(player.gold) != gold_before + 2:
		return "因联合使用攻击牌应获2金币：期望 %d 实际 %d" % [gold_before + 2, int(player.gold)]
	return true


## 测试7：effect_02 非联合来源（普通用攻击牌，无 _unite_attack_origin）-> 不获金
func test_pilot_084_effect02_not_unite_origin() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e2(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player = gs.players[&"player"]
	var enemy_mech = setup["enemy_mech"]
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"enemy", "action_001_进攻")
	if attack_cid == &"":
		return "找不到敌方攻击牌"
	var gold_before: int = int(player.gold)
	var r = await _fire_use_action_at(battle, attack_cid, enemy_mech, &"enemy", false)
	if r is String:
		return r
	if int(player.gold) != gold_before:
		return "非联合来源使用攻击牌不应获金：期望 %d 实际 %d" % [gold_before, int(player.gold)]
	return true


## 测试8：effect_02 莎菲雅自己因联合使用攻击牌 -> 不获金（出牌机甲=持有机甲）
func test_pilot_084_effect02_self_use() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e2(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player = gs.players[&"player"]
	var player_mech = setup["player_mech"]
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if attack_cid == &"":
		return "找不到莎菲雅玩家攻击牌"
	var gold_before: int = int(player.gold)
	var r = await _fire_use_action_at(battle, attack_cid, player_mech, &"player", true)
	if r is String:
		return r
	if int(player.gold) != gold_before:
		return "莎菲雅自己因联合使用攻击牌不应获金：期望 %d 实际 %d" % [gold_before, int(player.gold)]
	return true
