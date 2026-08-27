## test_pilot_082_温斯顿.gd - 温斯顿（pilot_082，帝国 N，cost 3, attack_limit 0）效果测试
##
## 温斯顿 2 个按钮（效果1 主动 + 效果2 主动，被动部分隐藏监听，悬停看完整说明）：
##   effect_01（DIRECT 按钮1，每玩家回合1次）「交牌·联」：
##     我方回合1次，将任意张行动牌交给3格范围内1台其他机甲（选目标可取消，不消耗次数；
##     选牌窗不可取消，必须选≥1张）。令其下回合攻击次数+1；交出的行动牌打"联"标签（owner=温斯顿）。
##   unite_apply（LISTEN USE_ACTION_AT，隐藏）「联牌使用·联合」：
##     该机甲使用带"联"标签的行动牌时，对温斯顿施加 UNITE 状态（unite=出牌者机甲）。
##   effect_02（DIRECT 按钮2，无次数限制）「当作维修/推进」：
##     攻击牌当作维修（维修无有效目标时置灰）或推进使用（选型→攻击牌单选→virtual_transform）。
##   cover_extra（LISTEN COVER_WINDOW_EXTRA，隐藏）「温斯顿--掩护」：
##     掩护窗口复选框；选中后攻击牌多选（可多选/全选）→ 逐张当作掩护（as_use_action_card）。
##   thrust_extra（LISTEN THRUST_WINDOW_EXTRA，隐藏）「温斯顿--推进」：
##     推进窗口复选框；选中后攻击牌多选 → 逐张当作推进。
##
## 关键覆盖点：
##   1. 五效果定义 + JSON effect_ids（隐藏效果必须入 effect_ids 才注册监听器）+ hide_button。
##   2. effect_01 全流程：选目标 → 选多张牌 → 转移 + 打联标签 + 目标下回合攻击数+1 + 消耗次数。
##   3. effect_01 选目标取消：不消耗次数，可再次发动。
##   4. unite_apply：联牌被使用时对温斯顿施加 UNITE 状态（unite=出牌者机甲）。
##   5. effect_02 当作推进：攻击牌 virtual_transform 当作推进（+4动力、牌进弃牌堆）。
##   6. effect_02 当作维修：攻击牌 virtual_transform 当作维修（选目标 → 回复生命）。
##   7. cover_extra：掩护窗口多选2张攻击牌逐张当作掩护（均可转化、威力-5）。
##   8. thrust_extra：推进窗口选攻击牌当作推进（+4动力）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90082
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


## 设温斯顿为 owner_id 机甲机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_082(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_082_温斯顿", owner_id)
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


## 确保某张行动牌在指定玩家手里（从牌堆/弃牌堆找，注册 AVAILABILITY）。返回 cid 或 &""。
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


## 触发温斯顿某 DIRECT 效果（effect_fire），返回挂起的 effect_fire action（或 null）。
func _fire_pilot_082(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


## 构造合成攻击动作（供 fire_timing 测试）
func _make_attack(battle: BattleState, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 30)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 统计机甲上的 UNITE 状态列表（含 unite 字段）
func _unite_statuses(mech) -> Array:
	var out: Array = []
	if mech == null:
		return out
	for s in mech.statuses:
		if String(s.get("type", &"")) == "UNITE":
			out.append(s)
	return out


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：五效果定义正确 + JSON effect_ids 全注册 + hide_button
func test_pilot_082_effect_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# JSON effect_ids（隐藏监听效果必须入 effect_ids 才注册 permanent listener）
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_082_温斯顿", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	for need in ["pilot_082_effect_01", "pilot_082_effect_02", "pilot_082_unite_apply", "pilot_082_cover_extra", "pilot_082_thrust_extra"]:
		if not id_strs.has(need):
			return "effect_ids 应含 %s 实=%s" % [need, str(id_strs)]
	# e1
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_082_effect_01")
	if e1 == null:
		return "缺 pilot_082_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_082_effect_01" or int(e1.once_per_turn_max) != 1:
		return "e1 once_per_turn 应 1 次"
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "e1 应含条件 %s 实=%s" % [need, str(ops)]
	for c in e1.conditions:
		if String(c.get("op", &"")) == "HAS_OTHER_MECH_IN_HEX_RANGE" and int(c.get("params", {}).get("range", 0)) != 3:
			return "e1 HAS_OTHER_MECH_IN_HEX_RANGE range 应 3"
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
	var post: Array = cm.get("post_actions", [])
	if post.size() != 2:
		return "e1 post_actions 应2个（交牌+攻击数）实=%d" % post.size()
	if String(post[0].get("type", &"")) != "TRANSFER_ACTION_CARDS":
		return "post_actions[0] 应 TRANSFER_ACTION_CARDS"
	var tag_tf: Dictionary = post[0].get("params", {}).get("_tag_on_transfer", {})
	if tag_tf.is_empty() or tag_tf.get("lian_tag", {}).is_empty():
		return "e1 TRANSFER 应带 _tag_on_transfer(lian_tag.owner)"
	if String(post[1].get("type", &"")) != "APPLY_NEXT_OWNER_TURN_ATTACK_BONUS":
		return "post_actions[1] 应 APPLY_NEXT_OWNER_TURN_ATTACK_BONUS"
	# unite_apply
	var ue = _ActionPilotEffects.build_pilot_effects().get(&"pilot_082_unite_apply")
	if ue == null:
		return "缺 pilot_082_unite_apply"
	if ue.mode != _TimingConst.MODE_LISTEN or ue.listen_timing != _TimingConst.USE_ACTION_AT:
		return "unite_apply 应 LISTEN USE_ACTION_AT"
	if not bool(ue.hide_button):
		return "unite_apply 应 hide_button（隐藏监听，不渲染按钮）"
	var ue_conds: Array = ue.conditions
	var has_tag_cond := false
	for c in ue_conds:
		if String(c.get("op", &"")) == "USED_CARD_HAS_TAG_FROM_ME":
			has_tag_cond = true
	if not has_tag_cond:
		return "unite_apply 应含 USED_CARD_HAS_TAG_FROM_ME 条件"
	var ue_acts: Array = ue.actions
	if ue_acts.is_empty() or String(ue_acts[0].get("type", &"")) != "ADD_STATUS":
		return "unite_apply actions 应 [ADD_STATUS]"
	if String(ue_acts[0].get("params", {}).get("status_type", &"")) != "UNITE":
		return "unite_apply ADD_STATUS 应 UNITE"
	# e2
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_082_effect_02")
	if e2 == null:
		return "缺 pilot_082_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "e2 mode 应 DIRECT"
	var e2_conds: Array = e2.conditions
	var has_attack_hand := false
	for c in e2_conds:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_TYPE_IN_HAND" and String(c.get("params", {}).get("card_type", &"")) == "攻击":
			has_attack_hand = true
	if not has_attack_hand:
		return "e2 应含 HAS_ACTION_CARD_TYPE_IN_HAND 攻击 条件"
	var e2_acts: Array = e2.actions
	if e2_acts.is_empty() or String(e2_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "e2 actions 应 [CHOOSE_ONE]"
	var opts: Array = e2_acts[0].get("params", {}).get("options", [])
	if opts.size() != 2:
		return "e2 应 2 个选项（当作维修/当作推进）实=%d" % opts.size()
	if String(opts[0].get("label", "")) != "当作维修" or String(opts[1].get("label", "")) != "当作推进":
		return "e2 选项标签应 当作维修/当作推进"
	if opts[0].get("condition", []).is_empty():
		return "e2 当作维修 选项应带 REPAIR_HAS_VALID_TARGET 条件"
	# cover_extra
	var ce = _ActionPilotEffects.build_pilot_effects().get(&"pilot_082_cover_extra")
	if ce == null:
		return "缺 pilot_082_cover_extra"
	if ce.listen_timing != _TimingConst.COVER_WINDOW_EXTRA or not bool(ce.hide_button):
		return "cover_extra 应 LISTEN COVER_WINDOW_EXTRA + hide_button"
	var ce_acts: Array = ce.actions
	if ce_acts.is_empty() or String(ce_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "cover_extra actions 应 [CHOOSE_MANY_CARDS]"
	var ce_cm: Dictionary = ce_acts[0].get("params", {})
	if not bool(ce_cm.get("as_use_action_card", false)) or String(ce_cm.get("as_card_def_id", &"")) != "action_016_掩护":
		return "cover_extra 应 as_use_action_card + as_card_def_id=掩护"
	if String(ce_cm.get("card_type_filter", &"")) != "攻击":
		return "cover_extra 选牌应 card_type_filter=攻击"
	# thrust_extra
	var te2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_082_thrust_extra")
	if te2 == null:
		return "缺 pilot_082_thrust_extra"
	if te2.listen_timing != _TimingConst.THRUST_WINDOW_EXTRA or not bool(te2.hide_button):
		return "thrust_extra 应 LISTEN THRUST_WINDOW_EXTRA + hide_button"
	var te2_acts: Array = te2.actions
	if te2_acts.is_empty() or String(te2_acts[0].get("params", {}).get("as_card_def_id", &"")) != "action_015_推进":
		return "thrust_extra 应 as_card_def_id=推进"
	return true


# ═══════════════════════════════════════════
# effect_01 交牌·联
# ═══════════════════════════════════════════

## 标准场景：温斯顿(player) player(2,2) enemy(4,2)（hex 距离 2，3格内）+ 双方手牌清空
func _setup_standard_e1(battle) -> Dictionary:
	var s = _setup_pilot_082(battle, &"player")
	if s == null:
		return {}
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return {"pilot_card": s.card, "player_mech": s.mech, "enemy_mech": enemy_mech, "gs": gs}


## 测试2：effect_01 全流程——交2张攻击牌 -> 敌方收2张 + 打联标签(owner=player) + 攻击数+1 + 消耗次数
func test_pilot_082_effect01_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_082_温斯顿）"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var enemy = gs.players[&"enemy"]
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var enemy_hand_before: int = enemy.action_hand.size()

	var ef = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起（应弹选机甲窗）"
	# 选目标（敌机，3格内）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	# 选2张行动牌确认
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	# 交出的牌进敌方手牌
	for cid in hand:
		if not enemy.action_hand.has(cid):
			return "交出的牌 %s 应进入敌方手牌" % String(cid)
	if enemy.action_hand.size() != enemy_hand_before + 2:
		return "敌方应收2张 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	# 每张联标签 owner=player（温斯顿玩家）
	for cid in hand:
		var c = gs.get_card(cid)
		if c == null or not c.has_tag(_ActionPilotEffects.LIAN_TAG, &"player"):
			return "交出的牌 %s 应带联标签（owner=player）" % String(cid)
	# 目标下回合攻击次数 +1
	if enemy_mech.get_next_owner_turn_attack_bonus() != 1:
		return "目标下回合攻击数应+1 实=%d" % enemy_mech.get_next_owner_turn_attack_bonus()
	# 消耗次数：第二次触发不挂起
	var ef2 = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef2 != null:
		return "每回合1次 -- 第二次触发不应挂起"
	return true


## 测试3：effect_01 选目标取消 -> 不消耗次数，可再次发动
func test_pilot_082_effect01_target_cancel() -> Variant:
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
	var ef = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	# 次数未消耗：再次触发仍挂起
	var ef2 = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef2 == null:
		return "选目标取消不应消耗每回合1次，第二次应能再次挂起"
	# 收尾：第二次完整走完，验证消耗
	te.resume_pending_effect(ef2.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef2.action_id, {"selected_card_ids": gs.players[&"player"].action_hand.duplicate(), "cancelled": false})
	await _pump_frames(12)
	var ef3 = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef3 != null:
		return "第二次完整发动后应消耗每回合1次"
	return true


# ═══════════════════════════════════════════
# unite_apply：联牌使用 -> 联合状态
# ═══════════════════════════════════════════

## 测试4：联牌被使用时（USE_ACTION_AT）对温斯顿施加 UNITE 状态（unite=出牌者机甲）
func test_pilot_082_unite_apply() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard_e1(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	# 交1张牌给敌机（带联标签）
	var hand = _give_action_cards(battle, &"player", 1)
	if hand.is_empty():
		return "无法补行动牌"
	var te = battle.context.timing_engine
	var ef = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_01")
	if ef == null:
		return "effect_01 effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	var tagged_cid: StringName = hand[0]
	var tagged_card = gs.get_card(tagged_cid)
	if tagged_card == null or not tagged_card.has_tag(_ActionPilotEffects.LIAN_TAG, &"player"):
		return "前置：牌应带联标签"
	if not gs.players[&"enemy"].action_hand.has(tagged_cid):
		return "前置：联牌应在敌机手牌"
	# 模拟敌机使用这张联牌：构造 use_action_card record，fire USE_ACTION_AT
	var action := _Action.new()
	action.action_id = &"test_use_%d" % [randi() % 1000000]
	action.action_type = &"use_action_card"
	action.record = {
		"card_instance_id": tagged_cid,
		"source_mech_id": enemy_mech.mech_id,
		"mech_id": enemy_mech.mech_id,
		"player_id": &"enemy",
	}
	action.state = &"running"
	action.context = battle.context
	battle.context.action_registry.register(action)
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, action)
	await _pump_frames(6)
	# 温斯顿机甲应获得 UNITE 状态（unite=出牌者敌机）
	var unites: Array = _unite_statuses(player_mech)
	if unites.is_empty():
		return "温斯顿应获得 UNITE 状态（联牌被使用）"
	var found: bool = false
	for s in unites:
		if String(s.get("unite", &"")) == String(enemy_mech.mech_id):
			found = true
	if not found:
		return "UNITE 状态 unite 字段应为出牌者敌机，实=%s" % str(unites)
	return true


# ═══════════════════════════════════════════
# effect_02 当作维修/推进
# ═══════════════════════════════════════════

## 通用：把敌机放到相邻(3,2)并掉血（隔离自身满血，制造唯一维修目标使二选一可用）
func _make_repair_target(battle, gs, player_mech, enemy_mech) -> void:
	_place_mech(battle, player_mech.mech_id, 2, 2)
	# 敌机放玩家邻格（odd-q offset：neighbors(2,2) 含 (2,3)，(3,2) 距离=2 超维修范围1）
	_place_mech(battle, enemy_mech.mech_id, 2, 3)
	enemy_mech.current_hp = max(1, int(enemy_mech.current_hp) - 6)
	# 敌机加损伤（HP不满+有损伤 → 维修二选一两选项均可用 → 弹 choose_one_effect；仅有HP不满会自动回复不弹窗）
	for _sid in enemy_mech.slots:
		var _slot = enemy_mech.slots[_sid]
		if _slot != null:
			_slot.region_damage_tokens = 2
			break


## 测试5：effect_02 当作推进——选攻击牌 virtual_transform 当作推进（+4动力、牌进弃牌堆）
func test_pilot_082_effect02_thrust_transform() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_pilot_082(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup["gs"]
	var bridge = battle.context.action_ui_bridge
	var te = battle.context.timing_engine
	var player_mech = setup["mech"]
	var pilot_card = setup["card"]
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_make_repair_target(battle, gs, player_mech, enemy_mech)
	_clear_action_hand(battle, &"player")
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if attack_cid == &"":
		return "找不到攻击牌"
	var power_before: int = int(player_mech.power)
	var ef = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_02")
	if ef == null:
		return "effect_02 effect_fire 未挂起（应弹二选一）"
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != "choose_one_effect":
		return "effect_02 应弹 choose_one_effect，实际 %s" % String(w0.get("input_type", &""))
	# 选「当作推进」(option 1)
	bridge.on_ui_confirmed({"chosen_option_index": 1})
	await _pump_frames(5)
	# 选攻击牌（CHOOSE_MANY_CARDS）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_thrust_cards":
		return "当作推进应弹攻击牌单选窗 select_thrust_cards，实际 %s" % String(w1.get("input_type", &""))
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": [attack_cid]})
	await _pump_frames(12)
	# 转化当作推进：动力+4
	if int(player_mech.power) != power_before + 4:
		return "当作推进应动力+4（%d->%d），实际 %d" % [power_before, power_before + 4, int(player_mech.power)]
	# 素材牌应被消耗（进弃牌堆）+ 虚拟转化标记
	var tc = gs.get_card(attack_cid)
	if tc == null or String(tc.zone) != "discard":
		return "转化素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc else "null")
	if String(tc.counters.get("virtual_as_def_id", &"")) != "action_015_推进":
		return "转化素材牌应标注虚拟转化为推进，实=%s" % String(tc.counters.get("virtual_as_def_id", &""))
	return true


## 测试6：effect_02 当作维修——选攻击牌 virtual_transform 当作维修（选目标 -> 回复4生命）
func test_pilot_082_effect02_repair_transform() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_pilot_082(battle, &"player")
	if setup == null:
		return "setup 失败"
	var gs = setup["gs"]
	var bridge = battle.context.action_ui_bridge
	var te = battle.context.timing_engine
	var player_mech = setup["mech"]
	var pilot_card = setup["card"]
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_make_repair_target(battle, gs, player_mech, enemy_mech)
	var hp_target: int = int(enemy_mech.current_hp)
	_clear_action_hand(battle, &"player")
	var attack_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if attack_cid == &"":
		return "找不到攻击牌"
	var ef = await _fire_pilot_082(battle, pilot_card, player_mech, &"player", &"pilot_082_effect_02")
	if ef == null:
		return "effect_02 effect_fire 未挂起"
	# 选「当作维修」(option 0)
	bridge.on_ui_confirmed({"chosen_option_index": 0})
	await _pump_frames(5)
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_thrust_cards":
		return "当作维修应弹攻击牌单选窗，实际 %s" % String(w1.get("input_type", &""))
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": [attack_cid]})
	await _pump_frames(8)
	# 维修目标选择
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "select_repair_target":
		return "当作维修应弹 select_repair_target，实际 %s" % String(w2.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	var w3: Dictionary = bridge.get_waiting_action_info()
	if String(w3.get("input_type", &"")) != "choose_one_effect":
		return "维修应弹 choose_one_effect，实际 %s" % String(w3.get("input_type", &""))
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})
	await _pump_frames(6)
	if int(enemy_mech.current_hp) != hp_target + 4:
		return "当作维修应回复4生命：期望 %d 实际 %d" % [hp_target + 4, int(enemy_mech.current_hp)]
	# 素材牌进弃牌堆 + 虚拟转化标记
	var tc = gs.get_card(attack_cid)
	if tc == null or String(tc.zone) != "discard":
		return "维修素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc else "null")
	if String(tc.counters.get("virtual_as_def_id", &"")) != "action_013_维修":
		return "维修素材牌应标注虚拟转化为维修，实=%s" % String(tc.counters.get("virtual_as_def_id", &""))
	return true


# ═══════════════════════════════════════════
# 掩护/推进窗口附加选项
# ═══════════════════════════════════════════

## 标准布局：player(10,0) enemy(11,0)，温斯顿在 player，注册真实掩护 cover_effect1，
## 双方行动手牌清空。返回 {gs, player_mech, enemy_mech, player, pilot_card, bridge, te}。
func _setup_cover_window(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	for cid in player.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	# 温斯顿 -> player_mech
	var pilot_card = _make_instance(gs, cdb, "pilot_082_温斯顿", &"player")
	if pilot_card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	# 真实掩护牌实例 + cover_effect1 permanent listener（掩护窗口开启用）
	var cover_card = _make_instance(gs, cdb, "action_016_掩护", &"player")
	if cover_card == null:
		return {}
	cover_card.mech_id = player_mech.mech_id
	player.action_hand.append(cover_card.instance_id)
	cover_card.zone = &"action_hand"
	var cover_e1 = _GeneratedActionEffects.build_all_effects().get(&"cover_effect1")
	if cover_e1 == null:
		return {}
	battle.context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, cover_e1, {
		"card_instance_id": cover_card.instance_id,
		"player_id": &"player",
		"mech_id": player_mech.mech_id,
		"card_def_id": &"action_016_掩护",
		"slot_id": &"action_hand",
	})
	return {"gs": gs, "player_mech": player_mech, "enemy_mech": enemy_mech, "player": player, "pilot_card": pilot_card, "bridge": battle.context.action_ui_bridge, "te": battle.context.timing_engine}


## 测试7：掩护窗口「温斯顿--掩护」多选攻击牌逐张当作掩护（多选2张、均可转化、威力-5）
func test_pilot_082_cover_extra_multi() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup_cover_window(battle)
	if s.is_empty():
		return "标准布局失败"
	var gs = s.gs
	var player_mech = s.player_mech
	var enemy_mech = s.enemy_mech
	var te = s.te
	var bridge = s.bridge
	# 给温斯顿 2 张攻击牌（供当作掩护多选）
	var atk1: StringName = _ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if atk1 == &"":
		return "找不到第1张攻击牌"
	var atk2: StringName = _ensure_card_in_hand(battle, &"player", "action_003_猛击")
	if atk2 == &"":
		return "找不到第2张攻击牌"
	# enemy 攻击 player -> ATTACK_PRE -> 掩护窗口
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != "select_thrust_cards":
		return "应弹 select_thrust_cards（掩护窗口），实际: %s" % String(w0.get("input_type", &""))
	# 勾选温斯顿--掩护（不选真实掩护）
	te.resume_pending_effect(w0.get("action_id", &""), {"selected_card_ids": [], "selected_extra_ids": ["pilot_082_cover_extra"]})
	await _pump_frames(5)
	# 温斯顿转化：攻击牌多选窗
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_thrust_cards":
		return "温斯顿转化应弹攻击牌多选窗，实际: %s" % String(w1.get("input_type", &""))
	# 多选2张攻击牌确认 -> 逐张当作掩护
	te.resume_pending_effect(w1.get("action_id", &""), {"selected_card_ids": [atk1, atk2]})
	await _pump_frames(20)
	# 两张素材牌都应被当作掩护消耗（进弃牌堆 + 虚拟转化标记）
	for cid in [atk1, atk2]:
		var c = gs.get_card(cid)
		if c == null or String(c.zone) != "discard":
			return "当作掩护的素材牌 %s 应进弃牌堆，zone=%s" % [String(cid), String(c.zone if c else "null")]
		if String(c.counters.get("virtual_as_def_id", &"")) != "action_016_掩护":
			return "素材牌 %s 应标注虚拟转化为掩护，实=%s" % [String(cid), String(c.counters.get("virtual_as_def_id", &""))]
	# 掩护威力-5 已作用到攻击
	if int(attack.record.get("extra_might", 0)) >= 0:
		return "掩护应使攻击威力-5（extra_might<0），实际 %d" % int(attack.record.get("extra_might", 0))
	return true


## 测试8：推进窗口「温斯顿--推进」选攻击牌当作推进（+4动力）
## 流程：enemy 攻击 player -> player 防御响应 -> 防御 USE_ACTION_AT 弹推进窗 -> 勾选温斯顿--推进
##       -> 选攻击牌 -> 当作推进打出（+4动力、牌进弃牌堆）。
func test_pilot_082_thrust_extra() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	_make_cells_normal(gs, [{"q": 5, "r": 0}, {"q": 6, "r": 0}, {"q": 4, "r": 0}, {"q": 5, "r": -1}])
	# 温斯顿 -> player_mech
	var pilot_card = _make_instance(gs, cdb, "pilot_082_温斯顿", &"player")
	if pilot_card == null:
		return "缺 pilot_082_温斯顿"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	# enemy 攻击牌
	var atk_card_id: StringName = _ensure_card_in_hand(battle, &"enemy", "action_001_进攻")
	if atk_card_id == &"":
		return "敌方无攻击牌"
	# player 防御 + 真实推进（推进窗口开启条件）+ 攻击牌（供当作推进）
	var defend_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_009_防御")
	if defend_cid == &"":
		return "找不到 防御 牌"
	var real_thrust_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_015_推进")
	if real_thrust_cid == &"":
		return "找不到 推进 牌"
	var fuel_cid: StringName = _ensure_card_in_hand(battle, &"player", "action_003_猛击")
	if fuel_cid == &"":
		return "找不到攻击牌（当作推进素材）"
	var bridge = battle.context.action_ui_bridge
	var te = battle.context.timing_engine
	var power_before: int = int(player_mech.power)
	# 发起敌方攻击
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_ids[0], atk_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	# ① 掩护窗口先弹（ATTACK_PRE；宿主效果使无掩护牌也弹，此处仅温斯顿「当作掩护」附加选项）
	var wcov: Dictionary = bridge.get_waiting_action_info()
	if String(wcov.get("input_type", &"")) != "select_thrust_cards":
		return "应先弹掩护窗口，实际: %s" % String(wcov.get("input_type", &""))
	# 不使用掩护（取消）-> 攻击继续 -> ATTACK_AT 响应窗
	te.resume_pending_effect(wcov.get("action_id", &""), {"cancelled": true})
	await _pump_frames(3)
	var wait_info: Dictionary = bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != "respond_attack":
		return "应弹 respond_attack，实际: %s" % String(wait_info.get("input_type", &""))
	# 选防御响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"defend_availability",
		"card_instance_id": defend_cid,
		"availability_priority": 5,
	}]
	te.handle_response_selection(attack_action_id, sel)
	await _pump_frames(3)
	# 防御 USE_ACTION_AT -> 推进窗口
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_thrust_cards":
		return "防御响应后应弹 select_thrust_cards（推进窗口），实际: %s" % String(w1.get("input_type", &""))
	# 勾选温斯顿--推进（不选真实推进）
	te.resume_pending_effect(w1.get("action_id", &""), {"selected_card_ids": [], "selected_extra_ids": ["pilot_082_thrust_extra"]})
	await _pump_frames(5)
	# 温斯顿转化：攻击牌多选窗
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "select_thrust_cards":
		return "温斯顿转化应弹攻击牌多选窗，实际: %s" % String(w2.get("input_type", &""))
	te.resume_pending_effect(w2.get("action_id", &""), {"selected_card_ids": [fuel_cid]})
	await _pump_frames(15)
	# 当作推进：动力+4
	if int(player_mech.power) != power_before + 4:
		return "当作推进应动力+4（%d->%d），实际 %d" % [power_before, power_before + 4, int(player_mech.power)]
	var tc = gs.get_card(fuel_cid)
	if tc == null or String(tc.zone) != "discard":
		return "当作推进素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc else "null")
	if String(tc.counters.get("virtual_as_def_id", &"")) != "action_015_推进":
		return "当作推进素材牌应标注虚拟转化为推进，实=%s" % String(tc.counters.get("virtual_as_def_id", &""))
	return true
