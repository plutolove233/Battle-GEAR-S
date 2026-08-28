## test_pilot_024_lynn.gd - 琳（pilot_024，秩序 SR，cost 9）效果测试
##
## 琳 3 按钮 + RE 机制：
##   effect_01（DIRECT 按钮1，每玩家回合1次）「当作维修」：选1张行动牌当作维修使用。
##     复用坎得 pilot_023 模式：CHOOSE_MANY_CARDS OWNER_ACTION_HAND 选1 -> EXECUTE_USE_ACTION_CARD
##     virtual_transform 当作维修打出。按钮条件（自定义 PILOT_024_CAN_USE_EFFECT1）：
##     自己主阶段+有维修目标，或 维修窗口激活（被 RE 请求后窗口内按钮按回合重置可用）。
##   effect_02（LISTEN 按钮2 置灰+悬停）「维修后双方各抽2」：我方对其他机甲使用维修后，
##     我方与该机甲各抽2张行动牌（我方先抽、目标后抽，串行）。任意来源维修
##     （转化/实体牌/维修机械臂）都走 repair_direct，由 TimingEngine CHOOSE_ONE
##     repair_direct 挂钩 _append_pilot_024_repair_draws 统一追加抽牌。
##   effect_03（LISTEN 按钮3 置灰+悬停）「请求维修」：4格内其他机甲可在其回合内1次请求
##     我方对其使用1次无距离维修（RE 按钮）。RE 点击即消耗本回合次数（琳拒绝也不刷新）。
##   pilot_024_re_request（DIRECT RE 请求效果）：请求方点击 RE 触发，动作1 原子标记 RE 已用，
##     动作2 PILOT_024_RE_CONFIRM 弹确认窗给琳：琳确认->开维修窗口（阻塞请求方回合，
##     琳用维修牌/效果1维修请求方，目标锁定无距离豁免）；取消->无事发生（RE 已消耗）。
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
	battle.rng_seed = 90024
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
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


## 设琳为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_024(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_024_琳", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 给 owner_id 玩家行动手牌加一张行动牌（从 action_deck 找或直接构造），返回实例 id
func _add_action_card(battle, owner_id: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player = gs.players.get(owner_id)
	# 先在 action_deck 找同名牌
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c != null and c.def != null and String(c.def.card_id) == def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = owner_id
			return cid
	# 找不到则构造新实例
	var card = _make_instance(gs, cdb, def_id, owner_id)
	if card == null:
		return &""
	card.zone = &"action_hand"
	player.action_hand.append(card.instance_id)
	return card.instance_id


## 机甲满血 + 清空所有区域/装备牌损伤
func _set_mech_full(mech) -> void:
	mech.current_hp = mech.max_hp
	if mech.slots == null:
		return
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		slot.region_damage_tokens = 0
		if slot.equipped_card != null:
			slot.equipped_card.damage_tokens = 0


## 给机甲某已装备槽设 N 损伤，返回 slot_id
func _set_damage_on_slot(mech, amount: int) -> StringName:
	if mech.slots == null:
		return &""
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null and slot.equipped_card != null:
			slot.region_damage_tokens = amount
			return sid
	# 兜底：任意槽
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			slot.region_damage_tokens = amount
			return sid
	return &""


## 统计机甲某槽的损伤
func _slot_damage(mech, slot_id: StringName) -> int:
	if mech.slots == null or not mech.slots.has(slot_id):
		return 0
	return int(mech.slots[slot_id].region_damage_tokens)


## 触发琳 effect_01（DIRECT 按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_024_effect1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_024_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_024_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 效果1 CHOOSE_MANY_CARDS 选行动牌确认
func _resume_select_action_card(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(8)


## 请求方（requester_mech）点击 RE 触发 pilot_024_re_request，返回挂起的 effect_fire action。
## 前提：己方回合 + 琳在场存活 + 可维修 + 4格内 + 未请求过。
func _fire_pilot_024_re_request(battle, requester_mech, lin_pilot_card, requester_pid: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": lin_pilot_card.instance_id,
		"mech_id": requester_mech.mech_id,
		"player_id": requester_pid,
		"effect_id": &"pilot_024_re_request",
	}
	battle.context.game_state.active_player_id = requester_pid
	battle.context.game_state.phase = &"MAIN"
	battle.context.game_state.turn_number = 1
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_024_re_request",
		"player_id": requester_pid,
		"source_mech_id": requester_mech.mech_id,
		"mech_id": requester_mech.mech_id,
		"card_instance_id": lin_pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.record.get("_waiting_for_p024_re_confirm", false):
			return a
	return null


## 设置琳（player）+ 请求方（enemy，4格内 + 有损伤 + 满血）标准 RE 场景。
## 返回 {lin_card, lin_mech, enemy_mech, gs, bridge}；失败返回 null。
func _setup_re_scenario(battle):
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return null
	var gs = s.gs
	var lin_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 琳自身满血无损伤（隔离自身，避免自身成为维修目标干扰）
	_set_mech_full(lin_mech)
	# 敌机移到琳相邻格（距离1，且绝对在4格内）+ 满血有损伤（可维修，且只走"移除损伤"分支）
	enemy_mech.position = _adjacent_cell()
	_set_mech_full(enemy_mech)
	_set_damage_on_slot(enemy_mech, 2)
	return {"lin_card": s.card, "lin_mech": lin_mech, "enemy_mech": enemy_mech, "gs": gs, "bridge": battle.context.action_ui_bridge}


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：effect_01/02/03 + re_request 定义
func test_pilot_024_effect_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_effect_01")
	if e1 == null:
		return "缺 pilot_024_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_024_effect_01":
		return "once_per_turn_key 应 pilot_024_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（每玩家回合1次）"
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["PILOT_024_CAN_USE_EFFECT1", "HAS_ACTION_CARD_IN_HAND"]:
		if not ops.has(need):
			return "effect_01 应含条件 %s" % need
	var acts = e1.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 actions 应 [CHOOSE_MANY_CARDS]"
	var cm = acts[0].get("params", {})
	if cm.get("source", &"") != &"OWNER_ACTION_HAND":
		return "CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND"
	if int(cm.get("min_count", 0)) != 1 or int(cm.get("max_count", 0)) != 1:
		return "CHOOSE_MANY_CARDS min/max 应1"
	if bool(cm.get("discard_selected", true)):
		return "discard_selected 应 false（原牌由 use_action_card 结算弃置）"
	var pca: Array = cm.get("per_card_actions", [])
	if pca.size() != 1 or String(pca[0].get("type", &"")) != "EXECUTE_USE_ACTION_CARD":
		return "per_card_actions 应 [EXECUTE_USE_ACTION_CARD]"
	var ua = pca[0].get("params", {})
	if ua.get("as_card_def_id", &"") != &"action_013_维修":
		return "应转化当作 action_013_维修"
	if not bool(ua.get("virtual_transform", false)) or not bool(ua.get("consume_original_card", false)):
		return "virtual_transform/consume_original_card 应 true"
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_effect_02")
	if e2 == null or e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 应 LISTEN（按钮2置灰）"
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_effect_03")
	if e3 == null or e3.mode != _TimingConst.MODE_LISTEN:
		return "effect_03 应 LISTEN（按钮3置灰）"
	var re = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_re_request")
	if re == null or re.mode != _TimingConst.MODE_DIRECT:
		return "pilot_024_re_request 应 DIRECT"
	var re_ops: Array = []
	for c in re.conditions:
		re_ops.append(String(c.get("op", &"")))
	if not re_ops.has("PILOT_024_RE_AVAILABLE"):
		return "re_request 应含条件 PILOT_024_RE_AVAILABLE"
	var re_acts: Array = re.actions
	if re_acts.size() != 2:
		return "re_request actions 应 [PILOT_024_RE_MARK_USED, PILOT_024_RE_CONFIRM]"
	if String(re_acts[0].get("type", &"")) != "PILOT_024_RE_MARK_USED" or String(re_acts[1].get("type", &"")) != "PILOT_024_RE_CONFIRM":
		return "re_request actions 类型不符"
	return true


## 测试2：helpers（find_lin/is_lin/repairable/窗口/re_used）
func test_pilot_024_helpers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	if not _ActionPilotEffects.pilot_024_find_lin_mech(gs) == &"":
		return "无机师时 find_lin_mech 应空"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_024_琳）"
	var lin_mid: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(gs)
	if lin_mid == &"":
		return "设琳后 find_lin_mech 应返回琳机甲"
	if not _ActionPilotEffects.pilot_024_is_lin(gs, lin_mid):
		return "is_lin(琳) 应 true"
	if _ActionPilotEffects.pilot_024_is_lin(gs, &"enemy_mech"):
		return "is_lin(非琳) 应 false"
	# 窗口 helpers
	if _ActionPilotEffects.pilot_024_window_active(gs):
		return "初始不应有窗口"
	# 给琳设1损伤，验证可维修
	var lin_mech = gs.mechs.get(lin_mid)
	var lin_dmg_slot := _set_damage_on_slot(lin_mech, 1)
	if lin_dmg_slot == &"":
		return "找不到可设损伤槽位"
	if not _ActionPilotEffects.pilot_024_mech_repairable(gs, lin_mid):
		return "有损伤的琳应可维修"
	# 清回损伤（避免干扰后续）
	lin_mech.slots[lin_dmg_slot].region_damage_tokens = 0
	# RE 计数（未用）
	if _ActionPilotEffects.pilot_024_re_used_this_round(gs, lin_mid):
		return "未请求过 re_used 应 false"
	_ActionPilotEffects.pilot_024_re_mark_used(gs, lin_mid)
	if not _ActionPilotEffects.pilot_024_re_used_this_round(gs, lin_mid):
		return "标记后 re_used 应 true"
	# 距离 helper：琳(2,2) 敌相邻格 距离1
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = _adjacent_cell()
	if not _ActionPilotEffects.pilot_024_requester_in_range(gs, enemy_mech.mech_id, lin_mid, 4):
		return "距离1 应在4格内"
	enemy_mech.position = {"q": 7, "r": 2}
	if _ActionPilotEffects.pilot_024_requester_in_range(gs, enemy_mech.mech_id, lin_mid, 4):
		return "距离6(odd-q (2,2)->(7,2)) 不应在4格内"
	return true


## 测试3：effect_02 抽牌玩家序列 helper（琳对他人维修 -> [琳玩家, 目标玩家]；对己维修 -> 空）
func test_pilot_024_draw_players_helper() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var lin_mid = s.mech.mech_id
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 对他人维修
	var arr: Array = _ActionPilotEffects.pilot_024_draw_players_after_repair(gs, lin_mid, enemy_mech.mech_id)
	if arr.size() != 2 or String(arr[0]) != "player" or String(arr[1]) != "enemy":
		return "对他人维修应返回 [player, enemy]（我方先抽、目标后抽），实=%s" % str(arr)
	# 对自己维修（无抽牌）
	if not _ActionPilotEffects.pilot_024_draw_players_after_repair(gs, lin_mid, lin_mid).is_empty():
		return "对己维修不应抽牌"
	# 非琳来源维修（无抽牌）
	if not _ActionPilotEffects.pilot_024_draw_players_after_repair(gs, enemy_mech.mech_id, lin_mid).is_empty():
		return "非琳来源维修不应抽牌"
	return true


# ═══════════════════════════════════════════
# 效果1 当作维修
# ═══════════════════════════════════════════

## 测试4：效果1全流程 - 满血有损伤2，转化1张行动牌当作维修，自动选"移除损伤"移除2
func test_pilot_024_effect1_transform_repair_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_set_mech_full(mech)  # 满血（隔离回复分支）
	var dmg_slot := _set_damage_on_slot(mech, 2)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	# 触发 -> CHOOSE_MANY_CARDS 挂起（选行动牌）
	var ef = await _fire_pilot_024_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹行动牌多选窗）"
	var bridge = battle.context.action_ui_bridge
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != "select_thrust_cards":
		return "应弹 select_thrust_cards，实际 %s" % String(w0.get("input_type", &""))
	# 选行动牌 -> use_action_card 挂起维修目标选择
	await _resume_select_action_card(battle, ef, [transform_card])
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应弹 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	# 满血有损伤 -> 自动选"移除损伤"（琳无 repair_boost，移除2）-> place_damage_tokens
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "满血有损伤应自动选移除并挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 0:
		return "移除2损伤未生效，剩余 %d" % _slot_damage(mech, dmg_slot)
	# 转化素材牌应被当作维修消耗（zone=discard）
	var tc = gs.get_card(transform_card)
	if tc == null or String(tc.zone) != "discard":
		return "转化素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc != null else "?")
	return true


## 测试5：效果1每玩家回合1次 - 第1次可用，第2次（同回合）被 once_per_turn_max=1 拦截
func test_pilot_024_effect1_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_set_mech_full(mech)
	var dmg_slot := _set_damage_on_slot(mech, 2)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var tc1 := _add_action_card(battle, &"player", "action_001_进攻")
	var tc2 := _add_action_card(battle, &"player", "action_001_进攻")
	if tc1 == &"" or tc2 == &"":
		return "补行动牌失败"
	# 第1次
	var ef1 = await _fire_pilot_024_effect1(battle, s.card, mech, &"player")
	if ef1 == null:
		return "第1次 effect_fire 未挂起"
	var bridge = battle.context.action_ui_bridge
	await _resume_select_action_card(battle, ef1, [tc1])
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "place_damage_tokens":
		return "第1次应挂起 place_damage_tokens，实际 %s" % String(w1.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 0:
		return "第1次移除2未生效，剩余 %d" % _slot_damage(mech, dmg_slot)
	# 第2次（同回合）：once_per_turn_max=1 用满 -> effect_fire 不挂起（按钮禁用）
	var ef2 = await _fire_pilot_024_effect1(battle, s.card, mech, &"player")
	if ef2 != null:
		return "第2次 effect_fire 应因 once_per_turn_max=1 用满而跳过（不挂起）"
	return true


# ═══════════════════════════════════════════
# 效果2 维修后双方各抽2
# ═══════════════════════════════════════════

## 测试6：琳对他人使用维修牌 -> 双方各抽2（我方先抽、目标后抽），维修牌本身被消耗
func test_pilot_024_effect2_repair_enemy_draws() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_set_mech_full(mech)  # 琳自身满血无损伤（隔离自身，避免干扰维修目标列表）
	# 敌机移到1格内（琳无 repair_boost，维修范围1）+ 满血有损伤2（走"移除损伤"分支）
	enemy_mech.position = _adjacent_cell()
	_set_mech_full(enemy_mech)
	var dmg_slot := _set_damage_on_slot(enemy_mech, 2)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var repair_id := _add_action_card(battle, &"player", "action_013_维修")
	if repair_id == &"":
		return "找不到维修牌"
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var enemy_hand_before: int = gs.players.get(&"enemy").action_hand.size()
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", repair_id)
	await _pump_frames(3)
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应挂起 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": enemy_mech.mech_id})
	await _pump_frames(4)
	# 满血有损伤 -> 自动选移除2 -> place_damage_tokens
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "应挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": enemy_mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(8)
	if _slot_damage(enemy_mech, dmg_slot) != 0:
		return "移除2损伤未生效，剩余 %d" % _slot_damage(enemy_mech, dmg_slot)
	# 效果2：双方各抽2（玩家 -1 维修牌 +2 抽牌 = +1；敌机 +2）
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 1:
		return "琳玩家应净+1（-1维修牌+2抽牌），期望 %d 实际 %d" % [player_hand_before + 1, gs.players.get(&"player").action_hand.size()]
	if gs.players.get(&"enemy").action_hand.size() != enemy_hand_before + 2:
		return "敌机应+2（目标后抽），期望 %d 实际 %d" % [enemy_hand_before + 2, gs.players.get(&"enemy").action_hand.size()]
	return true


## 测试7：琳对自己维修（效果1转化或维修牌）不触发效果2（无抽牌）——已在测试4/5 覆盖，
## 此处显式验证：对己维修 draw_players 为空且手牌不增长。
func test_pilot_024_effect2_self_repair_no_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_set_mech_full(mech)
	var dmg_slot := _set_damage_on_slot(mech, 2)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var repair_id := _add_action_card(battle, &"player", "action_013_维修")
	if repair_id == &"":
		return "找不到维修牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", repair_id)
	await _pump_frames(3)
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "应挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(8)
	if _slot_damage(mech, dmg_slot) != 0:
		return "移除2损伤未生效，剩余 %d" % _slot_damage(mech, dmg_slot)
	# 对己维修不触发效果2：手牌净变化 = -1（维修牌消耗）
	if gs.players.get(&"player").action_hand.size() != hand_before - 1:
		return "对己维修不应抽牌，期望 %d（-1维修牌）实际 %d" % [hand_before - 1, gs.players.get(&"player").action_hand.size()]
	return true


# ═══════════════════════════════════════════
# RE 请求维修
# ═══════════════════════════════════════════

## 测试8：RE 请求 -> 琳确认 -> 维修窗口开启（请求方回合阻塞）+ RE 已消耗
func test_pilot_024_re_request_confirm_opens_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var enemy_mech = sc.enemy_mech
	# 请求方点击 RE
	var re_action = await _fire_pilot_024_re_request(battle, enemy_mech, sc.lin_card, &"enemy")
	if re_action == null:
		return "RE 请求应挂起确认窗（未挂起）"
	# 点击即消耗（即使琳拒绝也不刷新）
	if not _ActionPilotEffects.pilot_024_re_used_this_round(gs, enemy_mech.mech_id):
		return "RE 点击后应已标记使用（点击即消耗）"
	# 确认弹窗应路由到琳玩家（player_id=player）+ 单选项"确认维修" + 请求方信息
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != "choose_one_effect":
		return "应弹 choose_one_effect（RE 确认窗），实际 %s" % String(w0.get("input_type", &""))
	var ip: Dictionary = w0.get("input_params", {})
	if String(ip.get("effect_id", &"")) != "pilot_024_re_request":
		return "确认窗 effect_id 应 pilot_024_re_request，实际 %s" % String(ip.get("effect_id", &""))
	if String(ip.get("player_id", &"")) != "player":
		return "确认窗应路由到琳玩家，实际 %s" % String(ip.get("player_id", &""))
	var opts: Array = ip.get("options", [])
	if opts.size() != 1 or String(opts[0].get("label", "")) != "确认维修":
		return "确认窗应只有'确认维修'选项，实=%s" % str(opts)
	if String(ip.get("source_label", "")).find("请求维修") < 0:
		return "确认窗应含请求方信息（source_label），实=%s" % String(ip.get("source_label", ""))
	# 琳确认 -> 窗口开启
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {})
	await _pump_frames(4)
	if not _ActionPilotEffects.pilot_024_window_active(gs):
		return "琳确认后维修窗口应开启"
	var w: Dictionary = _ActionPilotEffects.pilot_024_repair_window(gs)
	if String(w.get("lin_mech_id", &"")) != String(sc.lin_mech.mech_id):
		return "窗口 lin_mech_id 应琳机甲"
	if String(w.get("requester_mech_id", &"")) != String(enemy_mech.mech_id):
		return "窗口 requester_mech_id 应请求方机甲"
	if String(w.get("action_id", &"")) != String(re_action.action_id):
		return "窗口 action_id 应被阻塞的 RE 动作"
	# RE 动作保持挂起（waiting_timing，请求方回合被阻塞）
	if re_action.state != &"waiting_timing":
		return "RE 动作应保持 waiting_timing（请求方回合阻塞），实际 %s" % String(re_action.state)
	return true


## 测试9：RE 请求 -> 琳取消 -> 窗口不开启 + RE 仍已消耗（点击即消耗，拒绝不刷新）
func test_pilot_024_re_request_reject_no_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var enemy_mech = sc.enemy_mech
	var re_action = await _fire_pilot_024_re_request(battle, enemy_mech, sc.lin_card, &"enemy")
	if re_action == null:
		return "RE 请求应挂起确认窗（未挂起）"
	if not _ActionPilotEffects.pilot_024_re_used_this_round(gs, enemy_mech.mech_id):
		return "RE 点击后应已标记使用"
	# 琳取消 -> 无事发生
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"cancelled": true})
	await _pump_frames(6)
	if _ActionPilotEffects.pilot_024_window_active(gs):
		return "琳取消后不应开启维修窗口"
	if not _ActionPilotEffects.pilot_024_re_used_this_round(gs, enemy_mech.mech_id):
		return "琳取消不应刷新 RE 次数（点击即消耗）"
	if re_action.state != &"completed":
		return "琳取消后 RE 动作应完成，实际 %s" % String(re_action.state)
	return true


## 测试10：窗口内维修 - 琳用维修牌，目标自动锁定请求方（无目标选择窗），
## 维修完成后双方各抽2 + 窗口关闭 + RE 动作完成（请求方回合恢复）。
func test_pilot_024_window_repair_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var enemy_mech = sc.enemy_mech
	# RE 请求 -> 琳确认 -> 窗口开启
	var re_action = await _fire_pilot_024_re_request(battle, enemy_mech, sc.lin_card, &"enemy")
	if re_action == null:
		return "RE 请求应挂起确认窗（未挂起）"
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {})
	await _pump_frames(4)
	if not _ActionPilotEffects.pilot_024_window_active(gs):
		return "窗口应已开启"
	# 窗口期间：琳（player）打维修牌，目标自动锁定请求方（无需选目标）
	var repair_id := _add_action_card(battle, &"player", "action_013_维修")
	if repair_id == &"":
		return "找不到维修牌"
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var enemy_hand_before: int = gs.players.get(&"enemy").action_hand.size()
	battle.execute_use_action_card(&"player", repair_id)
	await _pump_frames(3)
	# 不应弹目标选择窗：窗口锁定目标=请求方（无距离豁免，无需选择）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "place_damage_tokens":
		return "窗口内维修应跳过目标选择直接 place_damage_tokens，实际 %s" % String(w1.get("input_type", &""))
	# 移除请求方损伤
	battle.context.game_actions.remove_damage_tokens({"mech_id": enemy_mech.mech_id, "slot_id": _slot_damage_target(enemy_mech), "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(10)
	# 请求方损伤已移除
	if _slot_damage(enemy_mech, _slot_damage_target(enemy_mech)) != 0:
		return "窗口维修应移除请求方损伤，剩余 %d" % _slot_damage(enemy_mech, _slot_damage_target(enemy_mech))
	# 效果2：双方各抽2（玩家 -1维修牌 +2 = +1；请求方 +2）
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 1:
		return "窗口维修后琳玩家应净+1，期望 %d 实际 %d" % [player_hand_before + 1, gs.players.get(&"player").action_hand.size()]
	if gs.players.get(&"enemy").action_hand.size() != enemy_hand_before + 2:
		return "窗口维修后请求方应+2，期望 %d 实际 %d" % [enemy_hand_before + 2, gs.players.get(&"enemy").action_hand.size()]
	# 窗口关闭 + RE 动作完成（请求方回合恢复）
	if _ActionPilotEffects.pilot_024_window_active(gs):
		return "第1次维修完成后窗口应关闭"
	if re_action.state != &"completed":
		return "RE 动作应完成（请求方回合恢复），实际 %s" % String(re_action.state)
	return true


## 请求方当前带损伤的槽位（helper：找 region_damage_tokens>0 的槽）
func _slot_damage_target(mech) -> StringName:
	if mech.slots == null:
		return &""
	for sid: StringName in mech.slots:
		var slot = mech.slots[sid]
		if slot != null and int(slot.get("region_damage_tokens")) > 0:
			return sid
	return &""


## 玩家机甲 (2,2) 的任一相邻格（odd-q 网格保证 distance==1）。
## 琳无 repair_boost（维修范围1），维修目标必须在1格内；
## 直接指定坐标易踩 odd-q 偏移坑（如 (3,2) 实际距离2），故用 neighbors() 取真邻居。
func _adjacent_cell() -> Dictionary:
	return _HexGrid.neighbors({"q": 2, "r": 2})[0]


# ═══════════════════════════════════════════
# 条件 gate
# ═══════════════════════════════════════════

## 测试11：effect_01 按钮条件 PILOT_024_CAN_USE_EFFECT1（主阶段+己方+有目标；窗口激活时任意阶段可用）
func test_pilot_024_effect1_condition_gates() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_set_mech_full(mech)
	_set_damage_on_slot(mech, 1)  # 自身可维修（维修目标）
	# 找 effect_01 permanent listener（bind_ctx）
	var te = battle.context.timing_engine
	var eff_01 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_effect_01")
	var bind_ctx: Dictionary = {}
	var found: bool = false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == "pilot_024_effect_01":
				bind_ctx = entry.get("binding_context", {})
				found = true
				break
		if found:
			break
	if not found:
		return "effect_01 应已注册 permanent listener（pilot_024_effect_01 虚拟时点）"
	# 正常主阶段 + 己方回合 -> 可用
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(eff_01, bind_ctx):
		return "主阶段+己方回合+有目标应可用"
	# 非己方回合（敌方回合）-> 不可用
	gs.active_player_id = &"enemy"
	if te.can_trigger_active_effect(eff_01, bind_ctx):
		return "非己方回合不应可用"
	# 维修窗口激活 -> 任意阶段/回合都可用（窗口内按钮按回合重置）
	gs.pilot_024_repair_window = {"lin_mech_id": mech.mech_id, "requester_mech_id": &"enemy_mech", "action_id": &"re_test"}
	if not te.can_trigger_active_effect(eff_01, bind_ctx):
		return "窗口激活时应可用（无论阶段）"
	gs.pilot_024_repair_window = {}
	return true


## 测试12：RE 请求条件 PILOT_024_RE_AVAILABLE（己方回合/非琳/琳在场/可维修/未请求/4格内）
func test_pilot_024_re_available_condition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_024(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_set_mech_full(mech)
	# 敌机在4格内（相邻格距离1）+ 满血有损伤（可维修）
	enemy_mech.position = _adjacent_cell()
	_set_mech_full(enemy_mech)
	_set_damage_on_slot(enemy_mech, 1)
	gs.turn_number = 1
	# re_request 的 binding_context：请求方=enemy
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_re_request")
	var req_bind: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": enemy_mech.mech_id,
		"player_id": &"enemy",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_024_琳",
	}
	# 己方回合 -> 可用
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(re_eff, req_bind):
		return "己方回合+4格内+可维修应可用"
	# 非己方回合 -> 不可用
	gs.active_player_id = &"player"
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "非己方回合不应可用"
	# 回己方回合；满状态（满血无损伤）-> 不可用
	gs.active_player_id = &"enemy"
	_set_mech_full(enemy_mech)
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "满状态不应可用"
	# 恢复损伤；本回合已请求过 -> 不可用（点击即消耗）
	_set_damage_on_slot(enemy_mech, 1)
	_ActionPilotEffects.pilot_024_re_mark_used(gs, enemy_mech.mech_id)
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "本回合已请求过不应可用"
	# 清标记；敌机移出4格 -> 不可用
	_ActionPilotEffects.pilot_024_lin_pilot_card(gs).counters.clear()
	enemy_mech.position = {"q": 7, "r": 2}
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "离开4格外不应可用"
	return true
