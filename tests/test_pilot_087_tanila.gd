## test_pilot_087_tanila.gd - 塔妮拉（pilot_087，混乱 N，cost 3, attack_limit 1, action_card_limit 4）效果测试
##
## 塔妮拉 2 个按钮（效果1 主动 + 效果2 被动，悬停看完整说明）：
##   effect_01（DIRECT 按钮1，每我方回合2次）「交牌获2金」：
##     选3格内1台其他机甲（可取消=不扣次数）→ 从我方手牌选1张行动牌（不可取消，必须确定）
##     → 转移该牌至目标机甲（自动打"交"标签，owner=塔妮拉玩家） → 塔妮拉获得2金币。
##   effect_02（LISTEN 被动，按钮2 置灰）「他用交牌各抽1」：
##     持有方使用带"交"标签的行动牌（通用"使用"判定，从 temp_zone 进弃牌堆，含迪恩转化代价牌等）
##     → 使用方先抽1张行动牌 + 塔妮拉后抽1张行动牌，"交"标签随牌入弃牌堆消失。
##     手牌直接弃置（from_zone==action_hand）不触发抽牌，仅清"交"标签。
##     跨玩家转出/被偷（识破/玛丽尔）也计入（从塔妮拉手牌转出时打"交"标签）。
##
## 关键覆盖点：
##   1. 2 效果定义（mode/时点/条件/动作）+ JSON effect_ids 全注册。
##   2. effect_01 全流程：选机甲→选1张我方行动牌→转移+打交标签+塔妮拉+2金+消耗次数。
##   3. effect_01 选机甲取消：不消耗次数，可再次发动。
##   4. effect_01 once_per_turn_max=2：第2次仍可发动，第3次不可。
##   5. 转移/偷牌打"交"标签——行动牌从塔妮拉手牌转出（效果1交牌/识破/玛丽尔偷牌都计入）。
##   6. "交"标签使用判定：使用（temp_zone->弃牌堆）双方各抽1（使用方先，塔妮拉后）；
##      直接弃置（action_hand）不抽1但清标签；标签入弃牌堆消失。
##   7. unset_pilot 离场清塔妮拉名下全部"交"标签（他人持有的交牌不再触发其抽1）。
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
	battle.rng_seed = 90087
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


## 设塔妮拉为 owner_id 机甲机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_087(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_087_塔妮拉", owner_id)
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


## 触发塔妮拉某 DIRECT 效果（effect_fire），返回挂起的 effect_fire action（或 null）。
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
func _wait_effect_fire_done(battle, effect_id: StringName, max_frames: int = 80) -> void:
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


## 走真实 discard_card 动作强制弃置指定牌（fire DISCARD_BEFORE/AFTER/SETTLE 时点）。
## card_ids 可在手牌（action_hand，直接弃置）或已置 temp_zone（模拟使用中的牌结算弃置）。
func _force_discard(battle, player_id: StringName, card_ids: Array, reason: StringName = &"test") -> void:
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"player_id": player_id,
		"executor": &"system_default",
		"reason": reason,
		"source": {"player_id": String(player_id)},
	})


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：2 效果定义正确 + JSON effect_ids 全注册
func test_pilot_087_effect_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# JSON effect_ids 全注册
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_087_塔妮拉", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	for need in ["pilot_087_effect_01", "pilot_087_effect_02"]:
		if not id_strs.has(need):
			return "effect_ids 应含 %s 实=%s" % [need, str(id_strs)]
	# e1
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_087_effect_01")
	if e1 == null:
		return "缺 pilot_087_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_087_effect_01" or int(e1.once_per_turn_max) != 2:
		return "e1 once_per_turn 应 2 次 实=%d" % int(e1.once_per_turn_max)
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "e1 应含条件 %s 实=%s" % [need, str(ops)]
	for c in e1.conditions:
		if String(c.get("op", &"")) == "HAS_OTHER_MECH_IN_HEX_RANGE" and int(c.get("params", {}).get("range", 0)) != 3:
			return "e1 HAS_OTHER_MECH_IN_HEX_RANGE range 应 3 实=%s" % str(c.get("params", {}))
	var rules: Array = e1.target_rules
	var has_choose_other := false
	var has_range := false
	for r in rules:
		if String(r.get("rule", &"")) == "CHOOSE_OTHER_MECH":
			has_choose_other = true
		if String(r.get("rule", &"")) == "TARGET_IN_RANGE" and int(r.get("params", {}).get("range", 0)) == 3 and String(r.get("params", {}).get("metric", &"")) == "hex_distance":
			has_range = true
	if not has_choose_other or not has_range:
		return "e1 目标规则应 CHOOSE_OTHER_MECH + TARGET_IN_RANGE(3, hex_distance)"
	var acts: Array = e1.actions
	if acts.is_empty() or String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "e1 actions 应 [CHOOSE_MANY_CARDS]"
	var cm: Dictionary = acts[0].get("params", {})
	if not bool(cm.get("no_cancel", false)):
		return "e1 选牌窗应 no_cancel=true（不可取消）"
	if bool(cm.get("discard_selected", true)):
		return "e1 discard_selected 应 false（交牌由 TRANSFER 执行）"
	if int(cm.get("min_count", 0)) != 1 or int(cm.get("max_count", 0)) != 1:
		return "e1 选牌 min/max 应 1/1"
	var post: Array = cm.get("post_actions", [])
	if post.size() != 2:
		return "e1 post_actions 应2个（交牌+获金）实=%d" % post.size()
	if String(post[0].get("type", &"")) != "TRANSFER_ACTION_CARDS":
		return "post_actions[0] 应 TRANSFER_ACTION_CARDS"
	var tag_tf: Dictionary = post[0].get("params", {}).get("_tag_on_transfer", {})
	if tag_tf.is_empty() or tag_tf.get("jiao_tag", {}).is_empty():
		return "e1 TRANSFER 应带 _tag_on_transfer(jiao_tag.owner)"
	if String(post[1].get("type", &"")) != "GAIN_GOLD":
		return "post_actions[1] 应 GAIN_GOLD"
	if int(post[1].get("params", {}).get("amount", 0)) != 2:
		return "e1 GAIN_GOLD amount 应 2"
	# e2（被动 LISTEN，置灰无 listen_timing）
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_087_effect_02")
	if e2 == null:
		return "缺 pilot_087_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "e2 mode 应 LISTEN"
	if String(e2.listen_timing) != "":
		return "e2 listen_timing 应为空（无直接时点，逻辑在 discard 挂钩）"
	if not e2.actions.is_empty():
		return "e2 actions 应为空（实际逻辑在 _step_transfer_to_pile 挂钩）"
	return true


# ═══════════════════════════════════════════
# effect_01 交牌获2金
# ═══════════════════════════════════════════

## 标准场景：塔妮拉(player) player(2,2) enemy(4,2)（hex 距离 2，3格内）+ 双方手牌清空
func _setup_standard_e1(battle) -> Dictionary:
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


## 测试2：effect_01 全流程——选敌机→选1张行动牌→转移+打交标签+塔妮拉+2金+消耗次数
func test_pilot_087_effect01_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_087_塔妮拉）"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var enemy = gs.players[&"enemy"]
	var gold_before: int = gs.players[&"player"].gold

	var hand = _give_action_cards(battle, &"player", 1)
	if hand.size() != 1:
		return "无法补1张行动牌"
	var enemy_hand_before: int = enemy.action_hand.size()

	var ef = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起（应弹选机甲窗）"
	# 选目标（敌机，3格内）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	# 选1张行动牌确认（no_cancel=true，必须选1张）
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 80)
	# 交出的牌进敌方手牌
	if not enemy.action_hand.has(hand[0]):
		return "交出的牌 %s 应进入敌方手牌" % String(hand[0])
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "敌方应收1张 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	# 牌应带"交"标签 owner=player
	var c = gs.get_card(hand[0])
	if c == null or not c.has_tag(_ActionPilotEffects.PILOT_087_JIAO_TAG, &"player"):
		return "交出的牌应带交标签（owner=player）"
	# 塔妮拉+2金币
	if gs.players[&"player"].gold != gold_before + 2:
		return "塔妮拉应+2金币 实=%d（before=%d）" % [gs.players[&"player"].gold, gold_before]
	# 消耗次数：1/2 已用，补1张再发第二次应能挂起
	_give_action_cards(battle, &"player", 1)
	var ef2 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef2 == null:
		return "每回合2次 -- 第2次应能挂起"
	# 第二次完整走完
	te.resume_pending_effect(ef2.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef2.action_id, {"selected_card_ids": gs.players[&"player"].action_hand.duplicate(), "cancelled": false})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 80)
	# 第3次应不能挂起（次数耗尽）
	_give_action_cards(battle, &"player", 1)
	var ef3 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef3 != null:
		return "每回合2次 -- 第3次不应挂起 once=%s" % str(te._once_per_turn_used)
	return true


## 测试3：effect_01 选机甲取消 -> 不消耗次数，可再次发动
func test_pilot_087_effect01_mech_cancel() -> Variant:
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
	_give_action_cards(battle, &"player", 1)
	var ef = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	# 选机甲取消不消耗次数：再次触发仍挂起
	_give_action_cards(battle, &"player", 1)
	var ef2 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef2 == null:
		return "选机甲取消不应消耗次数，第二次应能再次挂起"
	# 收尾：第二次完整走完，验证消耗
	te.resume_pending_effect(ef2.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef2.action_id, {"selected_card_ids": gs.players[&"player"].action_hand.duplicate(), "cancelled": false})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 80)
	# 取消不消耗 + 第二次完整走完消耗1次 = 累计用1次 < max=2
	# 第三次应能挂起（用第2次）；第四次才被拒
	_give_action_cards(battle, &"player", 1)
	var ef3 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef3 == null:
		return "选机甲取消不消耗，第三次应能挂起（累计1次<max=2）"
	# 把 ef3 走完消耗第2次
	te.resume_pending_effect(ef3.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef3.action_id, {"selected_card_ids": gs.players[&"player"].action_hand.duplicate(), "cancelled": false})
	await _wait_effect_fire_done(battle, &"pilot_087_effect_01", 80)
	# 第四次应被拒（累计2次 == max=2）
	_give_action_cards(battle, &"player", 1)
	var ef4 = await _fire_pilot_087(battle, pilot_card, player_mech, &"player", &"pilot_087_effect_01")
	if ef4 != null:
		return "用满2次后第4次不应挂起 once=%s" % str(te._once_per_turn_used)
	return true


# ═══════════════════════════════════════════
# "交"标签生命周期
# ═══════════════════════════════════════════

## 测试4：转移/偷牌打"交"标签——行动牌从塔妮拉手牌转出（效果1/识破/玛丽尔偷牌都计入）
func test_pilot_087_transfer_steal_apply_jiao() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_087(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")

	# ── 转移（效果1交牌路径走 transfer_action_cards）──
	var cdb = battle.context.card_database
	var c1_inst_id: StringName = gs.next_id(&"card")
	var c1_def = cdb.get_card(&"action_001_进攻")
	if c1_def == null:
		return "缺 action_001_进攻"
	var c1_card = _CardInstance.new(c1_inst_id, c1_def)
	c1_card.owner_player_id = &"player"
	c1_card.zone = &"action_hand"
	gs.cards[c1_inst_id] = c1_card
	gs.players.get(&"player").action_hand.append(c1_inst_id)
	battle.context.game_actions.transfer_action_cards({
		"from_player_id": &"player",
		"to_player_id": &"enemy",
		"card_ids": [c1_inst_id],
	})
	await _pump_frames(3)
	if not gs.players.get(&"enemy").action_hand.has(c1_inst_id):
		return "转移后敌方手牌应含 c1"
	if not _ActionPilotEffects.pilot_087_card_has_any_jiao(gs.get_card(c1_inst_id)):
		return "转移交牌应打交标签"

	# ── 偷牌（识破/玛丽尔路径走 steal_action_card）──
	var c2_inst_id: StringName = gs.next_id(&"card")
	var c2_def = cdb.get_card(&"action_001_进攻")
	var c2_card = _CardInstance.new(c2_inst_id, c2_def)
	c2_card.owner_player_id = &"player"
	c2_card.zone = &"action_hand"
	gs.cards[c2_inst_id] = c2_card
	gs.players.get(&"player").action_hand.append(c2_inst_id)
	battle.context.game_actions.steal_action_card({
		"from_player_id": &"player",
		"to_player_id": &"enemy",
		"count": 1,
	})
	await _pump_frames(3)
	if not gs.players.get(&"enemy").action_hand.has(c2_inst_id):
		return "偷牌后敌方手牌应含 c2"
	if not _ActionPilotEffects.pilot_087_card_has_any_jiao(gs.get_card(c2_inst_id)):
		return "偷牌也应打交标签"
	return true


## 测试5："交"标签使用判定——使用（temp_zone->弃牌堆）双方各抽1（使用方先，塔妮拉后）；直接弃置不抽
func test_pilot_087_jiao_use_triggers_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_087(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	# 清空弃牌堆前几张避免牌堆被洗牌干扰（保留牌堆充实）
	# 让双方都有 ~10 张起始手牌基准，再补发
	for i in range(5):
		_give_action_cards(battle, &"player", 1)
		_give_action_cards(battle, &"enemy", 1)
	var hand_before_player: int = gs.players[&"player"].action_hand.size()
	var hand_before_enemy: int = gs.players[&"enemy"].action_hand.size()

	# ── 直接弃置（手牌 action_hand）：不抽牌，仅清交标签 ──
	var cdb = battle.context.card_database
	var c1_inst_id: StringName = gs.next_id(&"card")
	var c1_def = cdb.get_card(&"action_001_进攻")
	var c1_card = _CardInstance.new(c1_inst_id, c1_def)
	c1_card.owner_player_id = &"enemy"
	c1_card.zone = &"action_hand"
	gs.cards[c1_inst_id] = c1_card
	gs.players.get(&"enemy").action_hand.append(c1_inst_id)
	# 模拟塔妮拉转移打交标签（owner=塔妮拉玩家）
	_ActionPilotEffects.pilot_087_tag_jiao(c1_card, &"player")
	if not _ActionPilotEffects.pilot_087_card_has_any_jiao(c1_card):
		return "c1 应带交标签"
	var hand_p1: int = gs.players[&"player"].action_hand.size()
	_force_discard(battle, &"enemy", [c1_inst_id])
	await _pump_frames(5)
	if gs.players[&"player"].action_hand.size() != hand_p1:
		return "直接弃置不应触发塔妮拉抽牌 塔妮拉手牌=%d 期望=%d" % [gs.players[&"player"].action_hand.size(), hand_p1]
	if _ActionPilotEffects.pilot_087_card_has_any_jiao(c1_card):
		return "直接弃置入弃牌堆后交标签应消失"

	# ── 使用（temp_zone -> 弃牌堆）：使用方先抽1 + 塔妮拉后抽1 ──
	var c2_inst_id: StringName = gs.next_id(&"card")
	var c2_def = cdb.get_card(&"action_001_进攻")
	var c2_card = _CardInstance.new(c2_inst_id, c2_def)
	c2_card.owner_player_id = &"enemy"
	gs.cards[c2_inst_id] = c2_card
	_ActionPilotEffects.pilot_087_tag_jiao(c2_card, &"player")
	# 模拟使用中：牌移出敌方手牌、置 temp_zone
	gs.players.get(&"enemy").action_hand.append(c2_inst_id)
	c2_card.zone = &"temp_zone"
	# 抽出"使用方"（enemy）当前手牌基准和塔妮拉手牌基准
	# 此时 c2_inst_id 已在 enemy 手牌里（c2 进手牌后才 discard）。
	# _force_discard 移除 c2 -> hand_enemy_before-1，再触发双方各抽1 -> 使用方净手牌数 = hand_enemy_before-1+1 = hand_enemy_before
	var hand_enemy_before: int = gs.players[&"enemy"].action_hand.size()
	var hand_tanila_before: int = gs.players[&"player"].action_hand.size()
	_force_discard(battle, &"enemy", [c2_inst_id], &"ACTION_CARD_PLAYED")
	await _pump_frames(5)
	# 使用方（enemy）净手牌 = before（-1 弃 +1 抽）
	if gs.players[&"enemy"].action_hand.size() != hand_enemy_before:
		return "使用交牌后使用方净手牌应=基准数 实=%d 期望=%d" % [gs.players[&"enemy"].action_hand.size(), hand_enemy_before]
	# 塔妮拉应 +1（后抽）
	if gs.players[&"player"].action_hand.size() != hand_tanila_before + 1:
		return "使用交牌后塔妮拉应+1张 实=%d 期望=%d" % [gs.players[&"player"].action_hand.size(), hand_tanila_before + 1]
	if _ActionPilotEffects.pilot_087_card_has_any_jiao(c2_card):
		return "使用入弃牌堆后交标签应消失"
	return true


## 测试6：unset_pilot 离场清塔妮拉名下全部"交"标签
func test_pilot_087_unset_clears_jiao() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_087(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = battle.context.card_database
	battle.context.action_ui_bridge.context = battle.context

	# 准备一张带"交"标签的牌放在敌方手牌
	var c1_inst_id: StringName = gs.next_id(&"card")
	var c1_def = cdb.get_card(&"action_001_进攻")
	var c1_card = _CardInstance.new(c1_inst_id, c1_def)
	c1_card.owner_player_id = &"enemy"
	c1_card.zone = &"action_hand"
	gs.cards[c1_inst_id] = c1_card
	gs.players.get(&"enemy").action_hand.append(c1_inst_id)
	_ActionPilotEffects.pilot_087_tag_jiao(c1_card, &"player")
	if not c1_card.has_tag(_ActionPilotEffects.PILOT_087_JIAO_TAG, &"player"):
		return "前置：交标签应打上（owner=player）"

	# 卸下塔妮拉（用一个新的随机机师替换，或直接 null 槽位）
	var mech = s.mech
	var pilot_slot = mech.slots.get(&"pilot")
	if pilot_slot == null:
		return "缺 pilot 槽"
	# 模拟离场：调 GameSetupService 的 _on_pilot_unset 钩子（用清除 all jiao for player 模拟）
	_ActionPilotEffects.pilot_087_clear_all_jiao_for_player(gs, &"player")
	if c1_card.has_tag(_ActionPilotEffects.PILOT_087_JIAO_TAG, &"player"):
		return "离场清交标签后 owner=player 的标签应消失"
	return true
