## test_pilot_087_conquer.gd - 征服（pilot_087，混乱 N，cost 3, attack_limit 1, action_card_limit 3）效果测试
##
## 征服 1 个按钮（DIRECT 主动，每我方回合1次，主动与被动合一的单一按钮，悬框做效果说明）：
##   effect_01「征服-宣言弃置」：
##     我方回合1次，宣言1种行动牌类型（攻击/迎击/辅助），并展示3格范围内1台其他机甲的
##     1张随机行动牌。若该牌类型与宣言相同，则弃置该机甲其余未展示的牌；否则弃置该展示的牌。
##
## 详细流程（用户确认的决策）：
##   ① 主阶段点击按钮（无次数 / 3格内无持有行动牌的其他机甲则置灰不可点，
##      OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE range3）→ 弹选3格内持有行动牌的其他机甲
##      UI（select_mech_target，valid_mech_ids 过滤；取消=不计次数不消耗）。
##   ② 选定目标即消耗本回合1次（_mark_once_per_turn_used，用户决策"选择好目标后消耗"）
##      → 弹三选一类型（攻击/迎击/辅助，单选确定不能取消）→ 记录宣言类型。
##   ③ synced_shuffle 目标手牌随机取1张 → 非阻塞浮窗（所有玩家端显示宣言类型+随机展示的牌）
##      → 类型匹配：相同→弃目标除展示牌外全部行动牌；不同→弃展示牌（EXECUTE_DISCARD card_ids
##      显式，走完整 discard 时点）。
##
## 关键覆盖点：
##   1. p088e1 定义（DIRECT / once_per_turn_max=1 / 条件 / PILOT_088_CONQUER 动作）。
##   2. 匹配分支：目标手牌全为攻击、宣言攻击 → 必展示攻击 → 弃除展示牌外全部 → 手牌清空。
##   3. 不匹配分支：目标手牌全为辅助、宣言攻击 → 必展示辅助 → 弃展示牌1张 → 手牌减1。
##   4. 选目标取消：不消耗次数，可再次发动。
##   5. 次数耗尽：完整走完1次后第2次不可发动。
##   6. 3格范围过滤：范围内无持有行动牌的其他机甲（距离>3 / 无牌）→ 条件不满足，effect_fire 不挂起。
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
	battle.rng_seed = 90088
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	battle.context.action_ui_bridge.context = battle.context
	return battle


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


## 设征服为 owner_id 机甲机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_087(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_087_征服", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 放机甲到指定坐标
func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 把指定坐标格子的地形重置为 NORMAL（pvp_map_features 随机绿/红格会阻挡 hex 距离/武器范围 BFS）
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
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 按 card_def_id 从牌堆取出并直接塞进 owner_id 手牌（供指定类型/张数），返回 [cid,...]
func _give_action_cards_of_type(battle, owner_id: StringName, card_def_id: String, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	var out: Array = []
	for i in range(count):
		var cid: StringName = gs.next_id(&"card")
		var cdef = battle.context.card_database.get_card(StringName(card_def_id))
		if cdef == null:
			return []
		var c = _CardInstance.new(cid, cdef)
		c.owner_player_id = owner_id
		c.zone = &"action_hand"
		gs.cards[cid] = c
		player.action_hand.append(cid)
		out.append(cid)
	return out


## 触发征服效果（effect_fire），返回挂起的 effect_fire action（或 null）。
func _fire_pilot_087(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


## 等待 effect_fire 动作完成（state=completed 或 cancelled）或超时。
func _wait_effect_fire_done(battle, effect_id: StringName, max_frames: int = 100) -> void:
	for i in range(max_frames):
		await _pump_frames(1)
		var has_live: bool = false
		for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
			if String(a.record.get("effect_id", &"")) != String(effect_id):
				continue
			if a.state != &"completed" and a.state != &"cancelled":
				has_live = true
				break
		if not has_live:
			return


## 标准场景：征服(player) player(2,2) enemy(4,2)（hex 距离 2，3格内）+ 双方手牌清空
func _setup_standard(battle) -> Dictionary:
	var s = _setup_pilot_087(battle, &"player")
	if s == null:
		return {}
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_make_cells_normal(gs, [{"q": 2, "r": 2}, {"q": 3, "r": 2}, {"q": 4, "r": 2}])
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return {"pilot_card": s.card, "player_mech": s.mech, "enemy_mech": enemy_mech, "gs": gs}


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：p088e1 定义正确（DIRECT + once_per_turn_max=1 + 条件 + PILOT_088_CONQUER 动作）
func test_pilot_087_effect_definition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_087_征服", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	if not id_strs.has("pilot_087_effect_01"):
		return "effect_ids 应含 pilot_087_effect_01 实=%s" % str(id_strs)
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_087_effect_01")
	if e1 == null:
		return "缺 pilot_087_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_087_effect_01" or int(e1.once_per_turn_max) != 1:
		return "e1 once_per_turn 应 1 次 实=%d" % int(e1.once_per_turn_max)
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "e1 应含条件 %s 实=%s" % [need, str(ops)]
	for c in e1.conditions:
		if String(c.get("op", &"")) == "OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE" and int(c.get("params", {}).get("range", 0)) != 3:
			return "e1 OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE range 应 3 实=%s" % str(c.get("params", {}))
	for c in e1.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE" and int(c.get("params", {}).get("once_per_turn_max", 0)) != 1:
			return "e1 EFFECT_ONCE_PER_TURN_AVAILABLE max 应 1"
	var acts: Array = e1.actions
	if acts.is_empty() or String(acts[0].get("type", &"")) != "PILOT_088_CONQUER":
		return "e1 actions 应 [PILOT_088_CONQUER]"
	return true


# ═══════════════════════════════════════════
# 匹配分支：宣言类型 == 展示牌类型 → 弃目标其余未展示牌
# ═══════════════════════════════════════════

## 测试2：目标手牌全攻击、宣言攻击 → 必展示攻击（同类型）→ 弃除展示牌外全部 → 保留展示牌（3张→1），
## 次数消耗
func test_pilot_087_match_discard_rest() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_087_征服）"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var enemy = gs.players[&"enemy"]

	# 目标手牌：3 张全为攻击（action_001_进攻）
	var hand = _give_action_cards_of_type(battle, &"enemy", "action_001_进攻", 3)
	if hand.size() != 3:
		return "补3张攻击牌失败"
	var ef = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起（应弹选机甲窗）"
	# 选目标（敌机，3格内）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	# 宣言"攻击"（三选一确定，不可取消）
	te.resume_pending_effect(ef.action_id, {"pilot_087_declared_type": "攻击"})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 100)
	# 3张全攻击，随机展示必为攻击 → 弃除展示牌外全部（2张）→ 保留展示的1张 → 手牌剩 1
	if enemy.action_hand.size() != 1:
		return "匹配分支应弃除展示牌外全部并保留展示牌（3张→1）实=%d" % enemy.action_hand.size()
	# 保留的应是攻击牌（展示牌未弃）
	var kept_c = gs.get_card(enemy.action_hand[0])
	if kept_c == null or kept_c.def == null or String(kept_c.def.action_type) != "攻击":
		return "保留的展示牌应为攻击牌 实=%s" % String(kept_c.def.action_type if kept_c != null and kept_c.def != null else "?")
	# 次数已消耗：再触发不应挂起（once_per_turn_max=1）
	var ef2 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef2 != null:
		return "走完1次后第2次不应挂起 once=%s" % str(te._once_per_turn_used)
	return true


# ═══════════════════════════════════════════
# 不匹配分支：宣言类型 != 展示牌类型 → 弃展示牌
# ═══════════════════════════════════════════

## 测试3：目标手牌全辅助、宣言攻击 → 必展示辅助（不同）→ 弃展示牌1张 → 手牌减1
func test_pilot_087_mismatch_discard_shown() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var enemy = gs.players[&"enemy"]

	# 目标手牌：3 张全为辅助（action_013_维修）
	var hand = _give_action_cards_of_type(battle, &"enemy", "action_013_维修", 3)
	if hand.size() != 3:
		return "补3张辅助牌失败"
	var ef = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"pilot_087_declared_type": "攻击"})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 100)
	# 3张全辅助，随机展示必为辅助（与宣言"攻击"不同）→ 弃展示牌1张 → 手牌剩 2
	if enemy.action_hand.size() != 2:
		return "不匹配分支应弃展示牌1张（3张→2）实=%d" % enemy.action_hand.size()
	return true


## 测试4：匹配分支随机命中已展示牌后弃全部其余（2张攻击1张辅助，宣言攻击）
## 该场景随机性：展示可能为攻击（→弃其余2张→手牌空）或辅助（→弃展示1张→手牌2）。
## 用确定性全同/全异分支（测试2/3）已覆盖两条路径，此处改为验证「展示牌保留」断言不适用随机场景，
## 故只测全同/全异。此测试省略。

# ═══════════════════════════════════════════
# 取消 / 次数 / 范围
# ═══════════════════════════════════════════

## 测试5：选目标取消 -> 不消耗次数，可再次发动
func test_pilot_087_target_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var enemy = gs.players[&"enemy"]
	_give_action_cards_of_type(battle, &"enemy", "action_001_进攻", 3)

	var ef = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	# 选目标取消（不计次不消耗）
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	# 再次触发仍应挂起（次数未消耗）
	var ef2 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef2 == null:
		return "选目标取消不应消耗次数，第二次应能再次挂起"
	# 收尾：第二次完整走完
	te.resume_pending_effect(ef2.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef2.action_id, {"pilot_087_declared_type": "攻击"})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 100)
	return true


## 测试6：范围/目标过滤——3格外有牌 or 3格内有牌机甲为空（无候选）→ 条件不满足，effect_fire 不挂起
func test_pilot_087_no_candidate() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_087(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 敌机放 3 格外（距离 4）但仍持有行动牌 → 无候选（3格内无持有行动牌的其他机甲）
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_place_mech(battle, enemy_mech.mech_id, 6, 2)
	_make_cells_normal(gs, [{"q": 2, "r": 2}, {"q": 3, "r": 2}, {"q": 4, "r": 2}, {"q": 5, "r": 2}, {"q": 6, "r": 2}])
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	_give_action_cards_of_type(battle, &"enemy", "action_001_进攻", 3)
	var ef = await _fire_pilot_087(battle, s.card, s.mech, &"player", &"pilot_087_effect_01")
	if ef != null:
		return "3格外（距离4）有牌不应满足范围条件，effect_fire 不应挂起"

	# 敌机在3格内但无行动牌 → 也无候选
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"enemy")
	var ef2 = await _fire_pilot_087(battle, s.card, s.mech, &"player", &"pilot_087_effect_01")
	if ef2 != null:
		return "3格内无持有行动牌的其他机甲不应满足条件，effect_fire 不应挂起"
	return true
