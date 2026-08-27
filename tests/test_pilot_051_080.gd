## test_pilot_051_080.gd - 李（pilot_051）/ 墨尘（pilot_080）效果测试
##
## 李 pilot_051（秩序 R，2 按钮：主动+被动合一，悬停说明）：
##   effect_01「抽设事件牌」（DIRECT，每我方回合1次）：抽事件牌堆顶1张直接设置到
##     我方机甲事件区域（无条件版，用户确认；事件牌无手牌区，「抽」即设置）。
##     事件牌堆耗尽按钮置灰（EVENT_DECK_HAS_CARDS）。
##   effect_02「拦截事件牌设置」（LISTEN EVENT_SET_BEFORE，本局1次）：任何一方设置
##     事件牌时（含我方自己设置，用户确认）弹三选一：弃置（效果不生效）/ 转设我方
##     （完整流程）/ 取消（不计次）。
##
## 墨尘 pilot_080（秩序 N，1 按钮）：
##   effect_01「相邻标记交互」（DIRECT，我方回合无次数限制）：相邻6格（不含自身格，
##     odd-q 偏移坐标须用 HexGrid.neighbors 计算）有标记才能点。选格（可取消）->
##     二选一：移去（整格全移除不触发）/ 移至该格（免费基础移动，移到后该格标记
##     再生效2次，两次独立；事件=再设置/金币=再掷/陷阱=再爆）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


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


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设机师到 owner_id 机甲，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot(battle, owner_id: StringName, def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 全图地形重置 NORMAL（pvp_map_features 随机绿/红格会阻挡移动/选格）
func _make_all_cells_normal(gs) -> void:
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"


## 机甲 (q,r) 的真实相邻格（odd-q 偏移坐标须走 HexGrid.neighbors，不能 ±1 硬算）。
## 取第一个存在于地图且不与任何机甲重叠的格，返回 {q,r,cell_id}；找不到返回 {}。
func _adjacent_cell(gs, from_hex: Dictionary) -> Dictionary:
	for n: Dictionary in _HexGrid.neighbors(from_hex):
		var cell_id: String = "%d,%d" % [int(n.q), int(n.r)]
		if not gs.map_state.cells.has(StringName(cell_id)):
			continue
		var occupied: bool = false
		for mid: StringName in gs.mechs:
			var m = gs.mechs[mid]
			if m != null and not m.destroyed and int(m.position.get("q", 0)) == int(n.q) and int(m.position.get("r", 0)) == int(n.r):
				occupied = true
				break
		if occupied:
			continue
		return {"q": int(n.q), "r": int(n.r), "cell_id": cell_id}
	return {}


## 从事件牌堆取指定 def 的1个实例（找不到返回 &""）
func _take_event_instance(gs, card_def_id: StringName) -> StringName:
	for cid: StringName in gs.deck_state.event_deck:
		var card = gs.cards.get(cid)
		if card != null and card.def != null and card.def.card_id == card_def_id:
			return cid
	return &""


## 把实例放到事件牌堆顶（李 e1「抽堆顶」/ 墨尘事件标记触发的确定性控制）
func _stack_event_deck_top(gs, cids: Array) -> void:
	for cid in cids:
		gs.deck_state.event_deck.erase(cid)
	for i in range(cids.size() - 1, -1, -1):
		gs.deck_state.event_deck.insert(0, cids[i])


## 触发机师 DIRECT 效果（effect_fire），返回挂起未完成的 effect_fire action（或 null）。
func _fire_effect(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


## 等待指定类型动作全部完成（或超时）
func _wait_type_done(battle, action_type: StringName, max_frames: int = 100) -> void:
	for i in range(max_frames):
		await _pump_frames(1)
		var has_live: bool = false
		for a in battle.context.action_registry.get_actions_by_type(action_type):
			if a.state != &"completed" and a.state != &"cancelled":
				has_live = true
				break
		if not has_live:
			return


## 等待指定 effect_id 的 effect_fire 动作完成
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


## 等待 effect_fire 完成，途中自动应答损伤放置（damage_change 挂 place_damage_tokens
## 时调 DamageTokenService 放置 + continue_action auto_placed，headless 无损伤面板）。
func _wait_effect_fire_done_auto_damage(battle, effect_id: StringName, max_frames: int = 200) -> void:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	for i in range(max_frames):
		await _pump_frames(1)
		var answered: bool = false
		for a in ar.get_actions_by_type(&"damage_change"):
			if a.state != &"waiting_input":
				continue
			var amount: int = int(a.record.get("value", 0))
			var mech_ids: Array = a.record.get("mech_ids", [])
			if dts != null and amount > 0:
				for mid: StringName in mech_ids:
					dts.place_damage_tokens({"mech_id": mid, "count": amount})
			ae.continue_action(a.action_id, {"auto_placed": true})
			answered = true
			break
		if answered:
			continue
		var has_live: bool = false
		for a in ar.get_actions_by_type(&"effect_fire"):
			if String(a.record.get("effect_id", &"")) != String(effect_id):
				continue
			if a.state != &"completed" and a.state != &"cancelled":
				has_live = true
				break
		if not has_live:
			return


## 统计 game_state.log 中指定事件条数（如 marker_trap_exploded）
func _count_log_events(gs, event_type: StringName) -> int:
	var n: int = 0
	for e: Dictionary in gs.log:
		if e.get("event", &"") == event_type:
			n += 1
	return n


## 找未完成的 set_event_card 动作（李 e2 拦截时挂起的就是它）
func _find_live_set_event(battle):
	for a in battle.context.action_registry.get_actions_by_type(&"set_event_card"):
		if a.state != &"completed" and a.state != &"cancelled":
			return a
	return null


## 给地图加测试标记
func _add_marker(gs, q: int, r: int, mtype: StringName, idx: int) -> void:
	gs.map_state.add_marker(StringName("test_marker_%d" % idx), q, r, mtype)


## 取机甲事件槽牌实例（无则 null）
func _event_slot_card(gs, mech):
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return null
	return slot.equipped_card


# ═══════════════════════════════════════════
# 李 pilot_051：定义
# ═══════════════════════════════════════════

func test_pilot_051_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var all: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var e1 = all.get(&"pilot_051_effect_01")
	if e1 == null:
		return "缺 pilot_051_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_051_effect_01" or int(e1.once_per_turn_max) != 1:
		return "e1 应每回合1次 实=%s/%d" % [String(e1.once_per_turn_key), int(e1.once_per_turn_max)]
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE") or not ops.has("EVENT_DECK_HAS_CARDS"):
		return "e1 条件应含 IS_OWNER_MAIN_PHASE+EVENT_DECK_HAS_CARDS 实=%s" % str(ops)
	var acts: Array = e1.actions
	if acts.size() != 2 or String(acts[0].get("type", &"")) != "MARK_EFFECT_ONCE_PER_TURN_USED" or String(acts[1].get("type", &"")) != "EXECUTE_SET_EVENT_CARD":
		return "e1 actions 应 [MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_SET_EVENT_CARD] 实=%s" % str(acts)
	var e2 = all.get(&"pilot_051_effect_02")
	if e2 == null:
		return "缺 pilot_051_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "e2 mode 应 LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.EVENT_SET_BEFORE:
		return "e2 应监听 EVENT_SET_BEFORE 实=%s" % String(e2.listen_timing)
	if e2.once_per_game_key != &"pilot_051_effect_02":
		return "e2 应本局1次 实=%s" % String(e2.once_per_game_key)
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("OWNER_IS_HUMAN"):
		return "e2 条件应含 OWNER_IS_HUMAN 实=%s" % str(ops2)
	if e2.actions.size() != 1 or String(e2.actions[0].get("type", &"")) != "PILOT_051_INTERCEPT_EVENT_SET":
		return "e2 actions 应 [PILOT_051_INTERCEPT_EVENT_SET]"
	return true


# ═══════════════════════════════════════════
# 李 e1：抽设事件牌（每回合1次）
# ═══════════════════════════════════════════

## e1：堆顶放拾荒(e005 延时牌，无instant弹窗) -> 触发 -> e2 拦截窗弹出（自己设置也触发）
## -> 取消（不计次）-> 设置完成：事件槽=堆顶牌、牌堆少1、本回合第2次不可再发动。
func test_pilot_051_e1_draw_set_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_051_李")
	if s == null:
		return "setup 失败（缺 pilot_051_李）"
	var gs = s.gs
	var te = battle.context.timing_engine
	var top_cid := _take_event_instance(gs, &"event_005")
	if top_cid == &"":
		return "事件牌堆缺 event_005"
	_stack_event_deck_top(gs, [top_cid])
	var deck_before: int = gs.deck_state.event_deck.size()

	var ef = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_051_effect_01")
	# e1 无输入环节；其 EXECUTE_SET_EVENT_CARD 子动作会在 EVENT_SET_BEFORE 被 e2 拦截弹窗挂起
	var set_a = _find_live_set_event(battle)
	if set_a == null:
		if ef != null:
			return "e1 应经 set_event_card 子动作设置（e2 弹窗或完成）"
		return "e1 未产生 set_event_card 子动作"
	# e2 拦截窗：取消（不消耗本局次数），设置照常完成
	te.resume_pending_effect(set_a.action_id, {"cancelled": true})
	await _wait_effect_fire_done(battle, &"pilot_051_effect_01", 100)
	var slot_card = _event_slot_card(gs, s.mech)
	if slot_card == null or slot_card.instance_id != top_cid:
		return "e1 应把堆顶事件牌设置到我方事件区域 实=%s" % String(slot_card.instance_id if slot_card != null else &"无")
	if gs.deck_state.event_deck.size() != deck_before - 1:
		return "事件牌堆应少1 实=%d->%d" % [deck_before, gs.deck_state.event_deck.size()]
	# 本回合第2次：once_per_turn 已消耗，不应再挂起/再设置
	var before2: int = gs.deck_state.event_deck.size()
	var ef2 = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_051_effect_01")
	if ef2 != null or _find_live_set_event(battle) != null:
		return "每回合1次耗尽后不应再发动"
	if gs.deck_state.event_deck.size() != before2:
		return "第2次不应抽牌"
	return true


## e1：事件牌堆耗尽 -> 条件不满足，不产生任何设置
func test_pilot_051_e1_deck_empty_blocked() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_051_李")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	gs.deck_state.event_deck.clear()
	var ef = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_051_effect_01")
	if ef != null or _find_live_set_event(battle) != null:
		return "事件牌堆耗尽时 e1 不应发动"
	if _event_slot_card(gs, s.mech) != null:
		return "事件牌堆耗尽时不应有牌入区"
	return true


# ═══════════════════════════════════════════
# 李 e2：拦截事件牌设置（本局1次）
# ═══════════════════════════════════════════

## 通用：敌方设置事件牌并返回挂起的 set_event_card 动作（e2 弹窗拦截中）
func _enemy_set_event_suspended(battle, s, card_def_id: StringName):
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var cid := _take_event_instance(gs, card_def_id)
	if cid == &"":
		return null
	gs.active_player_id = &"enemy"
	battle.context.action_service.execute(&"set_event_card", {
		"mech_id": enemy_mech.mech_id,
		"event_card_id": cid,
		"source": {"mech_id": enemy_mech.mech_id},
	})
	await _pump_frames(4)
	var a = _find_live_set_event(battle)
	if a == null:
		return null
	return {"action": a, "cid": cid, "enemy_mech": enemy_mech}


## e2 弃置分支：敌方设置 -> 弹窗 -> 选0（弃置）-> 槽清空、牌入弃牌堆、效果不生效、次数消耗
func test_pilot_051_e2_discard_branch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_051_李")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var ctx = await _enemy_set_event_suspended(battle, s, &"event_005")
	if ctx == null:
		return "敌方设置事件牌未挂起（e2 应拦截弹窗）"
	var a = ctx["action"]
	var cid: StringName = ctx["cid"]
	var enemy_mech = ctx["enemy_mech"]
	# 选0=弃置
	te.resume_pending_effect(a.action_id, {"chosen_option_index": 0})
	await _wait_type_done(battle, &"set_event_card", 100)
	if _event_slot_card(gs, enemy_mech) != null:
		return "弃置分支：敌方事件槽应清空"
	# 事件牌弃置走 zone=removed（离场，无事件弃牌堆）
	var dc = gs.get_card(cid)
	if dc == null or dc.zone != &"removed":
		return "弃置分支：牌应离场移除（zone=removed）实=%s" % String(dc.zone if dc != null else &"无")
	if _event_slot_card(gs, s.mech) != null:
		return "弃置分支：我方事件槽不应有牌"
	# 次数已消耗：再次设置不再弹窗（直接完成）
	var ctx2 = await _enemy_set_event_suspended(battle, s, &"event_005")
	if ctx2 != null:
		return "本局1次用尽后不应再拦截"
	var slot_card = _event_slot_card(gs, gs.get_mech_for_player(&"enemy"))
	if slot_card == null:
		return "用尽后敌方设置应正常完成"
	return true


## e2 转设分支：敌方设置 -> 弹窗 -> 选1（转设我方）-> 我方事件槽=该牌、敌方槽空
func test_pilot_051_e2_transfer_branch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_051_李")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var ctx = await _enemy_set_event_suspended(battle, s, &"event_005")
	if ctx == null:
		return "敌方设置事件牌未挂起"
	var a = ctx["action"]
	var cid: StringName = ctx["cid"]
	var enemy_mech = ctx["enemy_mech"]
	# 选1=转设我方
	te.resume_pending_effect(a.action_id, {"chosen_option_index": 1})
	await _wait_type_done(battle, &"set_event_card", 100)
	if _event_slot_card(gs, enemy_mech) != null:
		return "转设分支：敌方事件槽应清空"
	var mine = _event_slot_card(gs, s.mech)
	if mine == null or mine.instance_id != cid:
		return "转设分支：该牌应设置到我方事件区域 实=%s 期望=%s" % [String(mine.instance_id if mine != null else &"无"), String(cid)]
	return true


## e2 取消：不消耗本局次数；之后再次设置仍会弹窗
func test_pilot_051_e2_cancel_not_consumed() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_051_李")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var ctx = await _enemy_set_event_suspended(battle, s, &"event_005")
	if ctx == null:
		return "首次设置未挂起"
	var a = ctx["action"]
	var cid: StringName = ctx["cid"]
	var enemy_mech = ctx["enemy_mech"]
	# 取消=不发动不计次
	te.resume_pending_effect(a.action_id, {"cancelled": true})
	await _wait_type_done(battle, &"set_event_card", 100)
	var slot_card = _event_slot_card(gs, enemy_mech)
	if slot_card == null or slot_card.instance_id != cid:
		return "取消分支：原设置应照常完成（牌留在敌方事件槽）"
	# 次数未消耗：再次设置仍弹窗（用弃置收尾）
	var ctx2 = await _enemy_set_event_suspended(battle, s, &"event_005")
	if ctx2 == null:
		return "取消不消耗次数：第二次设置应再次弹窗"
	te.resume_pending_effect(ctx2["action"].action_id, {"chosen_option_index": 0})
	await _wait_type_done(battle, &"set_event_card", 100)
	return true


# ═══════════════════════════════════════════
# 墨尘 pilot_080：定义 + 门控
# ═══════════════════════════════════════════

func test_pilot_080_definition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var all: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var e1 = all.get(&"pilot_080_effect_01")
	if e1 == null:
		return "缺 pilot_080_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "e1 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"":
		return "e1 应无次数限制 实=%s" % String(e1.once_per_turn_key)
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE") or not ops.has("MAP_MARKER_IN_RANGE"):
		return "e1 条件应含 IS_OWNER_MAIN_PHASE+MAP_MARKER_IN_RANGE 实=%s" % str(ops)
	for c in e1.conditions:
		if String(c.get("op", &"")) == "MAP_MARKER_IN_RANGE":
			var p: Dictionary = c.get("params", {})
			if String(p.get("marker_type", &"")) != "ANY" or int(p.get("range", 0)) != 1 or int(p.get("min_distance", 0)) != 1:
				return "MAP_MARKER_IN_RANGE 应 ANY/range1/min_distance1 实=%s" % str(p)
	var acts: Array = e1.actions
	if acts.size() != 2 or String(acts[0].get("type", &"")) != "CHOOSE_MAP_CELL" or String(acts[1].get("type", &"")) != "PILOT_080_MARKER_INTERACT":
		return "e1 actions 应 [CHOOSE_MAP_CELL, PILOT_080_MARKER_INTERACT] 实=%s" % str(acts)
	return true


## 门控：无相邻标记 / 距离2的标记 / 仅自身格标记 -> 不发动
func test_pilot_080_gating() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	_place_mech(battle, s.mech.mech_id, 2, 2)
	_make_all_cells_normal(gs)
	var adj: Dictionary = _adjacent_cell(gs, {"q": 2, "r": 2})
	if adj.is_empty():
		return "找不到相邻空格"
	# ① 无任何标记
	var ef = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef != null:
		return "无标记时不应挂起"
	# ② 距离2的标记不算相邻（odd-q 下 (2,2)->(3,2) 恰为距离2）
	_add_marker(gs, 3, 2, &"GOLD", 1)
	var ef2 = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef2 != null:
		return "距离2的标记不应触发"
	gs.map_state.remove_marker(StringName("test_marker_1"))
	# ③ 仅自身格标记（min_distance=1 排除）不触发
	_add_marker(gs, 2, 2, &"GOLD", 2)
	var ef3 = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef3 != null:
		return "仅自身格标记不应触发（相邻=6邻格不含自身）"
	gs.map_state.remove_marker(StringName("test_marker_2"))
	return true


# ═══════════════════════════════════════════
# 墨尘：移去 / 移至（金币2掷 / 陷阱2爆 / 事件2设置）
# ═══════════════════════════════════════════

## 标准场景：墨尘(2,2)，敌机移远，全图 NORMAL；返回相邻格 {q,r,cell_id}。
func _setup_080_field(battle, s) -> Dictionary:
	var gs = s.gs
	_place_mech(battle, s.mech.mech_id, 2, 2)
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_place_mech(battle, enemy_mech.mech_id, 10, 10)
	_make_all_cells_normal(gs)
	return _adjacent_cell(gs, {"q": 2, "r": 2})


## 通用：相邻格放标记 -> 触发 -> 选格 -> 选分支，返回 effect_fire action；
## 走不到分支选择返回 null。
func _drive_to_choice(battle, s, mtype: StringName, choice: int):
	var gs = s.gs
	var te = battle.context.timing_engine
	var adj: Dictionary = _adjacent_cell(gs, s.mech.position)
	if adj.is_empty():
		return null
	_add_marker(gs, int(adj.q), int(adj.r), mtype, 1)
	var ef = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef == null:
		return null
	# ① 选格（相邻标记格）
	te.resume_pending_effect(ef.action_id, {"selected_cell_id": String(adj.cell_id)})
	await _pump_frames(4)
	# ② 二选一弹窗（挂起 phase=pilot_080_choice）
	var still_live := false
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if String(a.record.get("effect_id", &"")) == "pilot_080_effect_01" and a.state != &"completed" and a.state != &"cancelled":
			still_live = true
			break
	if not still_live:
		return null
	te.resume_pending_effect(ef.action_id, {"chosen_option_index": choice})
	return ef


## 移去分支：整格标记移除（不触发效果）、机甲不移动
func test_pilot_080_remove_branch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var adj: Dictionary = _setup_080_field(battle, s)
	if adj.is_empty():
		return "找不到相邻空格"
	var gold_before: int = gs.players[&"player"].gold
	var ef = await _drive_to_choice(battle, s, &"GOLD", 0)
	if ef == null:
		return "流程未挂起到选择分支"
	await _wait_effect_fire_done(battle, &"pilot_080_effect_01", 100)
	# 标记被移除、未触发（金币不变）、机甲未动
	if not gs.map_state.get_markers_at(int(adj.q), int(adj.r)).is_empty():
		return "移去分支：格上标记应全部移除"
	if gs.players[&"player"].gold != gold_before:
		return "移去分支：标记不应触发（金币不变）"
	if int(s.mech.position.get("q", 0)) != 2 or int(s.mech.position.get("r", 0)) != 2:
		return "移去分支：机甲不应移动"
	# 无次数限制：同回合可以再次发动（相邻再放1个标记）
	_add_marker(gs, int(adj.q), int(adj.r), &"GOLD", 2)
	var ef2 = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef2 == null:
		return "墨尘无次数限制，应可再次发动"
	te.resume_pending_effect(ef2.action_id, {"cancelled": true})
	await _pump_frames(4)
	return true


## 移至金币分支：免费移动到标记格 + 2次掷骰获金（第2次生效独立）
func test_pilot_080_move_gold_two_rolls() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var adj: Dictionary = _setup_080_field(battle, s)
	if adj.is_empty():
		return "找不到相邻空格"
	var gold_before: int = gs.players[&"player"].gold
	var power_before: int = s.mech.power
	var ef = await _drive_to_choice(battle, s, &"GOLD", 1)
	if ef == null:
		return "流程未挂起到选择分支"
	await _wait_effect_fire_done(battle, &"pilot_080_effect_01", 100)
	# 机甲已移至标记格（免费：动力未扣）
	if int(s.mech.position.get("q", 0)) != int(adj.q) or int(s.mech.position.get("r", 0)) != int(adj.r):
		return "移至分支：机甲应移到标记格 实=(%d,%d)" % [int(s.mech.position.get("q", 0)), int(s.mech.position.get("r", 0))]
	if s.mech.power != power_before:
		return "移至分支：免费移动不应扣动力 实=%d->%d" % [power_before, s.mech.power]
	if not gs.map_state.get_markers_at(int(adj.q), int(adj.r)).is_empty():
		return "移至分支：标记应被消耗"
	# 2次掷骰获金：金币增加且在 [6,12] 区间（每次掷骰 3~6 金）
	var gained: int = gs.players[&"player"].gold - gold_before
	if gained < 6 or gained > 12:
		return "金币标记应生效2次（+6~+12）实=+%d" % gained
	return true


## 移至陷阱分支：移动 + 2次独立爆炸（机甲在爆心，每次结算伤害）
func test_pilot_080_move_trap_two_explosions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var adj: Dictionary = _setup_080_field(battle, s)
	if adj.is_empty():
		return "找不到相邻空格"
	var hp_before: int = s.mech.current_hp
	var boom_before: int = _count_log_events(gs, &"marker_trap_exploded")
	var ef = await _drive_to_choice(battle, s, &"TRAP", 1)
	if ef == null:
		return "流程未挂起到选择分支"
	# 爆炸链含损伤放置面板挂起，自动应答直到 effect_fire 完成
	await _wait_effect_fire_done_auto_damage(battle, &"pilot_080_effect_01", 300)
	if int(s.mech.position.get("q", 0)) != int(adj.q) or int(s.mech.position.get("r", 0)) != int(adj.r):
		return "移至分支：机甲应移到标记格"
	# 2次独立爆炸：marker_trap_exploded 日志 +2（动作注册表完成即移除，不能数动作）
	var boom_count: int = _count_log_events(gs, &"marker_trap_exploded") - boom_before
	if boom_count < 2:
		return "陷阱标记应爆炸2次 实=%d" % boom_count
	# 每次爆炸对爆心机甲 2 HP（TRAP_BLAST_DAMAGE=2），2次共 4
	if s.mech.current_hp > hp_before - 4:
		return "2次爆炸应对爆心机甲造成伤害 %d->%d（期望-4）" % [hp_before, s.mech.current_hp]
	return true


## 移至事件分支：移动 + 2次设置事件牌（第2张顶掉第1张）
func test_pilot_080_move_event_two_sets() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var adj: Dictionary = _setup_080_field(battle, s)
	if adj.is_empty():
		return "找不到相邻空格"
	# 堆顶放2张延时事件牌（避免 instant 弹窗）
	var c1 := _take_event_instance(gs, &"event_005")
	var c2 := _take_event_instance(gs, &"event_009")
	if c1 == &"" or c2 == &"":
		return "事件牌堆缺延时牌（e005/e009）"
	_stack_event_deck_top(gs, [c1, c2])
	var deck_before: int = gs.deck_state.event_deck.size()
	var ef = await _drive_to_choice(battle, s, &"EVENT", 1)
	if ef == null:
		return "流程未挂起到选择分支"
	await _wait_effect_fire_done(battle, &"pilot_080_effect_01", 100)
	if int(s.mech.position.get("q", 0)) != int(adj.q) or int(s.mech.position.get("r", 0)) != int(adj.r):
		return "移至分支：机甲应移到标记格"
	# 2次设置：牌堆少2、槽上是第2张（c2 顶掉 c1、c1 入弃牌堆）
	if gs.deck_state.event_deck.size() != deck_before - 2:
		return "事件标记应设置2次（牌堆少2）实=%d->%d" % [deck_before, gs.deck_state.event_deck.size()]
	var slot_card = _event_slot_card(gs, s.mech)
	if slot_card == null or slot_card.instance_id != c2:
		return "第2次设置应顶掉第1张 槽=%s 期望=%s" % [String(slot_card.instance_id if slot_card != null else &"无"), String(c2)]
	# 被顶掉的第1张事件牌离场移除（zone=removed，事件牌无弃牌堆）
	var old_c1 = gs.get_card(c1)
	if old_c1 == null or old_c1.zone != &"removed":
		return "被顶掉的第1张应离场移除（zone=removed）实=%s" % String(old_c1.zone if old_c1 != null else &"无")
	return true


## 红格只有移去选项：弹窗 options 仅1项（移至不可行）
func test_pilot_080_red_cell_remove_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var adj: Dictionary = _setup_080_field(battle, s)
	if adj.is_empty():
		return "找不到相邻空格"
	gs.map_state.cells.get(StringName(String(adj.cell_id))).terrain = &"RED"
	_add_marker(gs, int(adj.q), int(adj.r), &"GOLD", 1)
	var ef = await _fire_effect(battle, s.card, s.mech, &"player", &"pilot_080_effect_01")
	if ef == null:
		return "相邻标记存在应可发动"
	te.resume_pending_effect(ef.action_id, {"selected_cell_id": String(adj.cell_id)})
	await _pump_frames(4)
	# 弹窗应只有1个选项（移去）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait.is_empty() or StringName(String(wait.get("input_type", &""))) != &"choose_one_effect":
		return "选格后应挂起弹选择窗"
	var params: Dictionary = wait.get("input_params", {})
	if params.get("options", []).size() != 1:
		return "红格应只有移去1个选项 实=%d" % int(params.get("options", []).size())
	# 选移去收尾
	te.resume_pending_effect(ef.action_id, {"chosen_option_index": 0})
	await _wait_effect_fire_done(battle, &"pilot_080_effect_01", 100)
	if not gs.map_state.get_markers_at(int(adj.q), int(adj.r)).is_empty():
		return "移去后标记应被移除"
	return true
