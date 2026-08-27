## test_pilot_057_graham.gd - 格雷厄姆（pilot_057，混乱 R）效果测试
##
## 格雷厄姆 2 个主动效果按钮（DIRECT，机师槽可点按钮）：
##   effect_01「当作设陷」（每我方回合1次）：选1张行动牌（可取消=中止不计次），
##     移入临时区 -> ADD_STATUS SET_TRAP 2层（与实体设陷牌一致可叠加）
##     -> 链末 DISCARD_TEMP_ZONE_CARDS 燃料牌入弃牌堆（迪恩/布鲁克转化同款管线）。
##   effect_02「移陷」（每我方回合1次）：选4格内1个陷阱（可取消=中止不计次）
##     -> MARK 显式计次 -> 弃任意张行动牌（min=1 不限上限 no_cancel）
##     -> 从陷阱出发 BFS 连续移动 预算=4×弃牌数 的可选格（path 源：红格排除、
##        机甲格可作终点=落格引爆但不可穿过、绿格耗2，no_cancel）
##     -> MOVE_MAP_MARKER 迁移（落格有机甲=标准陷阱爆炸）。
##
## 通用机制（效果绑定不绑机师，后续可复用）：
##   · CHOOSE_MAP_CELL params.cells 通用候选格源（markers 标记格 / circle 范围圆 /
##     path 路径式BFS连续移动--预算、blocked 终点格）
##   · CHOOSE_MAP_CELL params.store_result_key（同链两次选格互不覆盖）
##   · CHOOSE_MAP_CELL 挂起 phase=map_cell_select：取消=中止不计次；确认=有 _seq 续序列
##   · MOVE_MAP_MARKER 通用标记迁移原子（explode_if_mech 落格有机甲标准爆炸）
##   · RangeCalculator.get_path_move_hexes（BFS 路径移动：blocked 可作终点不可穿过）
##   · ConditionChecker MAP_MARKER_IN_RANGE（范围内有指定类型标记，按钮门槛）
##   · ConditionChecker get_marker_cells_in_range（标记格收集，条件与选格共用）
##
## 关键覆盖点：
##   1. 两效果定义（DIRECT + 条件 + 动作链；e2 无自动 once_per_turn_key 走显式 MARK）。
##   2. e1 完整流程：选牌 -> 牌入弃牌堆 + SET_TRAP 2层 + 手牌-1。
##   3. e1 取消 -> 不弃牌不加状态不计次（可再触发）。
##   4. e1 每回合1次：用满后第2次不挂起。
##   5. e2 完整流程：选陷阱 -> 弃1张 -> 预算4内选空格 -> 陷阱迁移到该格。
##   6. e2 取消（选陷阱阶段）-> 不弃牌不计次（可再触发）。
##   7. e2 落格有机甲 -> 标准陷阱爆炸（陷阱消失、机甲HP下降）。
##   8. e2 路径源语义：get_path_move_hexes 单元（穿过阻断/绿耗2/红全禁/终点可达）
##      + 集成（预算=4×弃牌数、机甲格终点不可穿过=邻格全堵时仅6邻格、圆心不可选）。
##   9. e2 门槛：4格内无陷阱 / 无行动牌 -> 按钮不挂起。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90057
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


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


## 设格雷厄姆为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_graham(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_057_格雷厄姆", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建独立玩家 third + 机甲（PVP3 多人），返回机甲；null 失败
func _create_third_player(battle) -> _MechState:
	var gs = battle.context.game_state
	var p = _PlayerState.new()
	p.player_id = &"third"
	p.gold = 15
	p.is_human = true
	gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = &"third_mech"
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = {"q": 6, "r": 2}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 给玩家行动手牌加一张行动牌，返回实例 id
func _add_action_to_hand(battle, pid: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 在指定格放1个陷阱标记，返回 marker_id
func _place_trap(battle, hex: Dictionary) -> StringName:
	var gs = battle.context.game_state
	var mid: StringName = gs.next_id(&"marker")
	gs.map_state.add_marker(mid, int(hex.get("q", 0)), int(hex.get("r", 0)), &"TRAP")
	return mid


## 触发 DIRECT 按钮（effect_fire）。挂起返回该 action；未挂起（条件不满足/无输入）返回 null。
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
		if a.state == &"waiting_timing" or a.state == &"waiting_input":
			return a
	return null


## resume 选格阶段：选中 cell_id（"q,r"）
func _resume_map_cell(battle, ef_action, cell_id: String) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_cell_id": cell_id})
	await _pump_frames(12)


## resume 选格阶段取消（中止，不消耗次数）
func _resume_cancel_map_cell(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(6)


## resume 选牌窗：选中牌确认
func _resume_select_cards(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(12)


## resume 选牌窗取消
func _resume_cancel_cards(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(6)


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


## 检查 cid 是否在行动牌弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


## 指定格上的陷阱标记数
func _traps_at(battle, hex: Dictionary) -> int:
	var n: int = 0
	for m in battle.context.game_state.map_state.get_markers_at(int(hex.get("q", 0)), int(hex.get("r", 0))):
		if m.get("type", &"") == &"TRAP":
			n += 1
	return n


## 距 from 指定 hex 距离、且存在于地图的一个空格（无机甲无标记，可选排除特定格）
func _find_cell_at_distance(battle, from: Dictionary, dist: int, exclude: Array = []) -> Dictionary:
	var gs = battle.context.game_state
	for key in gs.map_state.cells:
		var c = gs.map_state.cells[key]
		var hex: Dictionary = {"q": int(c.q), "r": int(c.r)}
		if _HexGrid.distance(from, hex) != dist:
			continue
		if hex in exclude:
			continue
		var occupied := false
		for mid: StringName in gs.mechs:
			var m = gs.mechs[mid]
			if m != null and not m.destroyed and _HexGrid.key(m.position) == _HexGrid.key(hex):
				occupied = true
				break
		if occupied:
			continue
		return hex
	return {}


## 将 center 周围 radius 格内（hex 距离）的地形全部置 NORMAL（BFS 路径测试确定性用）
func _normalize_terrain_around(battle, center: Dictionary, radius: int) -> void:
	var gs = battle.context.game_state
	for key in gs.map_state.cells:
		var c = gs.map_state.cells[key]
		var hex: Dictionary = {"q": int(c.q), "r": int(c.r)}
		if _HexGrid.distance(center, hex) <= radius:
			c.terrain = &"NORMAL"


## 创建占位机甲（仅位置/存活参与 BFS blocked 计算；不挂槽位不入回合序）。
## owner=enemy：落格引爆时损伤放置对 AI 自动结算，不弹面板挂起测试。
func _create_dummy_mech(battle, mech_id: String, pos: Dictionary) -> void:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = StringName(mech_id)
	m.owner_player_id = &"enemy"
	m.max_hp = 10
	m.current_hp = 10
	m.position = pos
	gs.mechs[m.mech_id] = m


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：两效果定义正确
func test_pilot_057_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_057_effect_01")
	if e1 == null:
		return "缺 pilot_057_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT"
	if e1.once_per_turn_key != &"pilot_057_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_057_effect_01（store 路径确认即计次）"
	if int(e1.once_per_turn_max) != 1:
		return "effect_01 once_per_turn_max 应1"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	var e1_acts = e1.actions
	if e1_acts.size() != 4:
		return "effect_01 应有4个动作 实=%d" % e1_acts.size()
	var expect_types := ["CHOOSE_MANY_CARDS", "MOVE_ACTION_CARDS_TO_TEMP_ZONE", "ADD_STATUS", "DISCARD_TEMP_ZONE_CARDS"]
	for i in range(expect_types.size()):
		if String(e1_acts[i].get("type", &"")) != expect_types[i]:
			return "effect_01 动作%d 应 %s 实=%s" % [i, expect_types[i], String(e1_acts[i].get("type", &""))]
	var e1_status: Dictionary = e1_acts[2].get("params", {})
	if String(e1_status.get("status_type", &"")) != "SET_TRAP" or int(e1_status.get("stacks", 0)) != 2:
		return "effect_01 ADD_STATUS 应 SET_TRAP 2层（与实体设陷牌一致）"

	var e2 = effects.get(&"pilot_057_effect_02")
	if e2 == null:
		return "缺 pilot_057_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "effect_02 mode 应 MODE_DIRECT"
	if e2.once_per_turn_key != &"":
		return "effect_02 不应设自动 once_per_turn_key（显式 MARK 计次，防重跑双计）"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "MAP_MARKER_IN_RANGE", "EFFECT_ONCE_PER_TURN_AVAILABLE"]:
		if not e2_ops.has(need):
			return "effect_02 应含条件 %s" % need
	for c in e2.conditions:
		if String(c.get("op", &"")) == "MAP_MARKER_IN_RANGE":
			var mp: Dictionary = c.get("params", {})
			if String(mp.get("marker_type", &"")) != "TRAP" or int(mp.get("range", 0)) != 4:
				return "effect_02 MAP_MARKER_IN_RANGE 应 TRAP range4"
	var e2_acts = e2.actions
	if e2_acts.size() != 6:
		return "effect_02 应有6个动作 实=%d" % e2_acts.size()
	var expect2 := ["CHOOSE_MAP_CELL", "MARK_EFFECT_ONCE_PER_TURN_USED", "CHOOSE_MANY_CARDS", "EXECUTE_DISCARD", "CHOOSE_MAP_CELL", "MOVE_MAP_MARKER"]
	for i in range(expect2.size()):
		if String(e2_acts[i].get("type", &"")) != expect2[i]:
			return "effect_02 动作%d 应 %s 实=%s" % [i, expect2[i], String(e2_acts[i].get("type", &""))]
	# 两次选格 store_result_key 不同（互不覆盖）
	if String(e2_acts[0].get("params", {}).get("store_result_key", &"")) == String(e2_acts[4].get("params", {}).get("store_result_key", &"")):
		return "effect_02 两次 CHOOSE_MAP_CELL store_result_key 应不同"
	# 目的地路径源：per_count_key 预算叠加（每弃1张移4格）
	var path_spec: Dictionary = e2_acts[4].get("params", {}).get("cells", {}).get("path", {})
	if int(path_spec.get("per", 0)) != 4:
		return "effect_02 目的地路径源 per 应4（每弃1张移4格）"
	if bool(e2_acts[4].get("params", {}).get("no_cancel", false)) != true:
		return "effect_02 目的地选格应 no_cancel（弃牌已付出）"
	var mmp: Dictionary = e2_acts[5].get("params", {})
	if bool(mmp.get("explode_if_mech", false)) != true:
		return "effect_02 MOVE_MAP_MARKER 应 explode_if_mech=true"
	return true


# ═══════════════════════════════════════════
# 效果1 行为测试
# ═══════════════════════════════════════════

## 测试2：e1 完整流程--选1张行动牌 -> 临时区 -> SET_TRAP 2层 -> 牌入弃牌堆
func test_pilot_057_e1_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef == null:
		return "effect_01 未挂起（应弹选牌窗）"
	await _resume_select_cards(battle, ef, [c1])
	var st: Dictionary = s.mech.get_status(&"SET_TRAP")
	if st.is_empty() or int(st.get("stacks", 0)) != 2:
		return "应获得2层设陷状态 实=%s" % str(st)
	if not _in_action_discard(battle, c1):
		return "被转化行动牌应最终入弃牌堆"
	if _action_hand_size(battle, &"player") != 1:
		return "转化后行动手牌应剩1张 实=%d" % _action_hand_size(battle, &"player")
	if _in_action_discard(battle, c2):
		return "未选择的牌不应被弃置"
	return true


## 测试3：e1 取消 -> 不弃牌不加状态不计次（可再触发）
func test_pilot_057_e1_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_003_猛击")
	if c1 == &"":
		return "行动牌设置失败"
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel_cards(battle, ef)
	if not s.mech.get_status(&"SET_TRAP").is_empty():
		return "取消不应加设陷状态"
	if _in_action_discard(battle, c1):
		return "取消不应弃牌"
	# 次数未消耗：可再触发
	var ef2 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef2 == null:
		return "取消后应可再触发"
	await _resume_select_cards(battle, ef2, [c1])
	if not _in_action_discard(battle, c1):
		return "再触发选中后应弃置"
	return true


## 测试4：e1 每回合1次用满 -> 第2次不挂起
func test_pilot_057_e1_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	var ef1 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select_cards(battle, ef1, [c1])
	var st: Dictionary = s.mech.get_status(&"SET_TRAP")
	if int(st.get("stacks", 0)) != 2:
		return "第1次后应2层 实=%s" % str(st)
	# 第2次：用满 -> 不挂起
	var ef2 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef2 != null:
		return "第2次不应挂起（每回合1次已用满）"
	if _in_action_discard(battle, c2):
		return "用满后不应再弃牌"
	return true


## 测试5：e1 无行动牌 -> 按钮不挂起
func test_pilot_057_e1_no_card_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_01")
	if ef != null:
		return "无行动牌时 effect_01 不应挂起"
	return true


# ═══════════════════════════════════════════
# 效果2 行为测试
# ═══════════════════════════════════════════

## 测试6：e2 完整流程--选陷阱 -> 弃1张 -> 半径4圆选空格 -> 陷阱迁移
func test_pilot_057_e2_full_flow_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	# 陷阱放距机甲2格处（4格内）
	var trap_hex := _find_cell_at_distance(battle, s.mech.position, 2)
	if trap_hex.is_empty():
		return "找不到距机甲2格的空格"
	_place_trap(battle, trap_hex)
	_normalize_terrain_around(battle, trap_hex, 5)
	# 弃1张 -> 预算4；目的地取「全部机甲阻挡下 BFS 预算4 可达（绿格算1）」的距陷阱3格空格（路径确定可达）
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"":
		return "行动牌设置失败"
	var mech_blocked: Dictionary = {}
	for mid: StringName in gs.mechs:
		var mm = gs.mechs[mid]
		if mm != null and not mm.destroyed:
			mech_blocked[_HexGrid.key(mm.position)] = true
	var dest_hex: Dictionary = {}
	for hx: Dictionary in _RangeCalculator.get_path_move_hexes(trap_hex, 4, gs.map_state.cells, mech_blocked, 1):
		if _HexGrid.distance(trap_hex, hx) == 3 and not mech_blocked.has(_HexGrid.key(hx)):
			dest_hex = hx
			break
	if dest_hex.is_empty():
		return "找不到距陷阱3格且预算4可达的目的格"
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef == null:
		return "effect_02 未挂起（应选陷阱格）"
	# 阶段①：选陷阱格
	await _resume_map_cell(battle, ef, "%d,%d" % [int(trap_hex.q), int(trap_hex.r)])
	# 阶段③：弃1张
	await _resume_select_cards(battle, ef, [c1])
	if not _in_action_discard(battle, c1):
		return "弃置的行动牌应入弃牌堆"
	# 阶段⑤：选目的地
	await _resume_map_cell(battle, ef, "%d,%d" % [int(dest_hex.q), int(dest_hex.r)])
	# 陷阱已迁移
	if _traps_at(battle, trap_hex) != 0:
		return "原格陷阱应已移走"
	if _traps_at(battle, dest_hex) != 1:
		return "目的格应有1个陷阱 实=%d" % _traps_at(battle, dest_hex)
	return true


## 测试7：e2 选陷阱阶段取消 -> 不弃牌不计次（可再触发）
func test_pilot_057_e2_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var trap_hex := _find_cell_at_distance(battle, s.mech.position, 1)
	if trap_hex.is_empty():
		return "找不到相邻空格"
	_place_trap(battle, trap_hex)
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef == null:
		return "effect_02 未挂起"
	await _resume_cancel_map_cell(battle, ef)
	if _in_action_discard(battle, c1):
		return "取消不应弃牌"
	if _traps_at(battle, trap_hex) != 1:
		return "取消后陷阱应留在原位"
	# 次数未消耗：可再触发
	var ef2 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef2 == null:
		return "取消后应可再触发"
	return true


## 测试8：e2 落格有机甲 -> 标准陷阱爆炸（陷阱消失、机甲HP下降）
func test_pilot_057_e2_explode_on_mech() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	# 陷阱放距机甲2格处；把敌方机甲摆到距陷阱2格的空格（引爆后波及不到我方机甲更佳）
	var trap_hex := _find_cell_at_distance(battle, s.mech.position, 2)
	if trap_hex.is_empty():
		return "找不到距机甲2格的空格"
	_place_trap(battle, trap_hex)
	_normalize_terrain_around(battle, trap_hex, 5)
	# 目的格=距陷阱2格空格（我方机甲阻挡下预算4确定可达；再摆敌方机甲上去落格引爆）
	var blocked_a: Dictionary = {_HexGrid.key(s.mech.position): true}
	var dest_hex: Dictionary = {}
	for hx: Dictionary in _RangeCalculator.get_path_move_hexes(trap_hex, 4, gs.map_state.cells, blocked_a, 1):
		if _HexGrid.distance(trap_hex, hx) == 2 and not blocked_a.has(_HexGrid.key(hx)) \
				and _HexGrid.distance(hx, s.mech.position) > 1:
			dest_hex = hx
			break
	if dest_hex.is_empty():
		return "找不到距陷阱2格的目的格"
	enemy_mech.position = {"q": int(dest_hex.q), "r": int(dest_hex.r)}
	var hp_before: int = enemy_mech.current_hp
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef == null:
		return "effect_02 未挂起"
	await _resume_map_cell(battle, ef, "%d,%d" % [int(trap_hex.q), int(trap_hex.r)])
	await _resume_select_cards(battle, ef, [c1])
	await _resume_map_cell(battle, ef, "%d,%d" % [int(dest_hex.q), int(dest_hex.r)])
	await _pump_frames(8)
	# 爆炸消耗陷阱（不落格）
	if _traps_at(battle, dest_hex) != 0:
		return "落格有机甲应引爆不落格 实=%d" % _traps_at(battle, dest_hex)
	if _traps_at(battle, trap_hex) != 0:
		return "原格陷阱应已移走"
	if enemy_mech.current_hp >= hp_before:
		return "敌方机甲应受陷阱爆炸伤害（前%d 后%d）" % [hp_before, enemy_mech.current_hp]
	return true


## 测试9：e2 路径源语义（预算=4×弃牌数；BFS 连续移动：blocked 终点可达不可穿过/绿格由
## green_cost 决定（p057 移陷=1 与普通格一视同仁，函数默认=2）/红全禁/圆心排除）
func test_pilot_057_e2_path_range() -> Variant:
	# ── 单元部分：手造4格走廊（沿真实邻居链，odd-q offset 下轴向直线非链）验证 get_path_move_hexes ──
	var chain: Array = [{"q": 0, "r": 0}]
	while chain.size() < 4:
		var last: Dictionary = chain.back()
		var next_hex: Dictionary = {}
		for nb: Dictionary in _HexGrid.neighbors(last):
			var taken := false
			for c: Dictionary in chain:
				if _HexGrid.key(c) == _HexGrid.key(nb):
					taken = true
					break
			if not taken:
				next_hex = nb
				break
		if next_hex.is_empty():
			return "走廊构建失败"
		chain.append(next_hex)
	var corridor: Dictionary = {}
	for c: Dictionary in chain:
		var ckey: String = _HexGrid.key(c)
		corridor[ckey] = _MapCellState.new(ckey, int(c.q), int(c.r), &"NORMAL")
	var origin: Dictionary = chain[0]
	var no_block: Dictionary = {}
	var reach := _RangeCalculator.get_path_move_hexes(origin, 4, corridor, no_block)
	if reach.size() != 3:
		return "走廊无阻挡预算4应达其余3格 实=%s" % [str(reach)]
	# blocked 格：可作终点、不可穿过
	var blk: Dictionary = {_HexGrid.key(chain[1]): true}
	reach = _RangeCalculator.get_path_move_hexes(origin, 4, corridor, blk)
	if reach.size() != 1 or _HexGrid.key(reach[0]) != _HexGrid.key(chain[1]):
		return "blocked(chain[1]) 只应到该格（终点可达不可穿过）实=%s" % [str(reach)]
	# 绿格耗2（函数默认语义）：chain[1] 置 GREEN 后预算2只到 chain[1]
	corridor[_HexGrid.key(chain[1])].terrain = &"GREEN"
	reach = _RangeCalculator.get_path_move_hexes(origin, 2, corridor, no_block)
	if reach.size() != 1 or _HexGrid.key(reach[0]) != _HexGrid.key(chain[1]):
		return "绿格耗2（默认）：预算2应只到chain[1] 实=%s" % [str(reach)]
	# p057 移陷语义（green_cost=1）：绿格与普通格一视同仁，预算2应到 chain[1]+chain[2]
	reach = _RangeCalculator.get_path_move_hexes(origin, 2, corridor, no_block, 1)
	if reach.size() != 2:
		return "绿格算1格（p057）：预算2应到chain[1]+chain[2] 实=%s" % [str(reach)]
	reach = _RangeCalculator.get_path_move_hexes(origin, 1, corridor, no_block, 1)
	if reach.size() != 1 or _HexGrid.key(reach[0]) != _HexGrid.key(chain[1]):
		return "绿格算1格（p057）：预算1应只到chain[1] 实=%s" % [str(reach)]
	# 红格全禁：不可作终点也不可穿过
	corridor[_HexGrid.key(chain[1])].terrain = &"RED"
	reach = _RangeCalculator.get_path_move_hexes(origin, 4, corridor, no_block)
	if reach.size() != 0:
		return "红格应全禁（不可终点不可穿过）实=%s" % [str(reach)]
	# 圆心（origin）不含
	corridor[_HexGrid.key(chain[1])].terrain = &"NORMAL"
	reach = _RangeCalculator.get_path_move_hexes(origin, 4, corridor, no_block)
	for hx: Dictionary in reach:
		if _HexGrid.key(hx) == _HexGrid.key(origin):
			return "origin 自身不应在结果中"

	# ── 集成A：6占位机甲围陷阱 -> 仅6邻格可选（机甲格=可作终点、不可穿过）──
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	# 找距我方机甲2格、6邻格全在地图内的陷阱格
	var trap_hex: Dictionary = {}
	for key in gs.map_state.cells:
		var c = gs.map_state.cells[key]
		var hx: Dictionary = {"q": int(c.q), "r": int(c.r)}
		if _HexGrid.distance(s.mech.position, hx) != 2:
			continue
		var full := true
		for nb: Dictionary in _HexGrid.neighbors(hx):
			if not gs.map_state.cells.has(_HexGrid.key(nb)):
				full = false
				break
		if full:
			trap_hex = hx
			break
	if trap_hex.is_empty():
		return "找不到6邻格齐全的陷阱格"
	_place_trap(battle, trap_hex)
	_normalize_terrain_around(battle, trap_hex, 2)
	var neighbor_ids: Array = []
	for nb: Dictionary in _HexGrid.neighbors(trap_hex):
		neighbor_ids.append(_HexGrid.key(nb))
		_create_dummy_mech(battle, "dummy_%d_%d" % [int(nb.q), int(nb.r)], nb)
	var captured: Array = []
	battle.context.timing_engine.action_needs_input.connect(
		func(_aid, itype, iparams): captured.append({"type": String(itype), "params": iparams})
	)
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef == null:
		return "effect_02 未挂起"
	await _resume_map_cell(battle, ef, "%d,%d" % [int(trap_hex.q), int(trap_hex.r)])
	await _resume_select_cards(battle, ef, [c1])
	var dest_params: Dictionary = {}
	for cap in captured:
		if cap.get("type", "") == "select_map_cell" and String(cap.get("params", {}).get("label", "")).find("移动到的格子") >= 0:
			dest_params = cap.get("params", {})
	if dest_params.is_empty():
		return "未捕获目的地选格 params（captured=%d）" % captured.size()
	var valid_a: Array = []
	for cell in dest_params.get("valid_cells", []):
		valid_a.append(String(cell.get("cell_id", "")))
	if valid_a.size() != neighbor_ids.size():
		return "6机甲围堵应仅6邻格可选 实=%d %s" % [valid_a.size(), str(valid_a)]
	for nid: String in neighbor_ids:
		if not valid_a.has(nid):
			return "邻格 %s 应可选" % nid
	if valid_a.has(_HexGrid.key(trap_hex)):
		return "圆心（陷阱原位）不应可选"
	# 收尾：选1个距我方机甲≥2的邻格（避免爆炸波及人类机甲弹损伤面板）-> 落格有占位机甲 -> 标准爆炸
	var pick_id: String = ""
	for vid: String in valid_a:
		var vp := vid.split(",")
		var vhex := {"q": int(vp[0]), "r": int(vp[1])}
		if _HexGrid.distance(vhex, s.mech.position) > 1:
			pick_id = vid
			break
	if pick_id == "":
		return "找不到距我方机甲≥2的邻格"
	await _resume_map_cell(battle, ef, pick_id)
	await _pump_frames(8)
	if _traps_at(battle, trap_hex) != 0:
		return "原格陷阱应已移走"
	var pick_parts := pick_id.split(",")
	var pick_hex := {"q": int(pick_parts[0]), "r": int(pick_parts[1])}
	if _traps_at(battle, pick_hex) != 0:
		return "落格有占位机甲应引爆（陷阱消失）"

	# ── 集成B：弃2张预算8，与 get_path_move_hexes 直接结果全等（接线校验）──
	var battle2 := _new_battle()
	if battle2 == null or battle2.context == null:
		return "battle2 初始化失败"
	var s2 = _setup_graham(battle2, &"player")
	if s2.is_empty():
		return "battle2 setup 失败"
	battle2.context.action_ui_bridge.context = battle2.context
	var gs2 = s2.gs
	var trap_hex2 := _find_cell_at_distance(battle2, s2.mech.position, 2)
	if trap_hex2.is_empty():
		return "找不到距机甲2格的空格"
	_place_trap(battle2, trap_hex2)
	var captured2: Array = []
	battle2.context.timing_engine.action_needs_input.connect(
		func(_aid, itype, iparams): captured2.append({"type": String(itype), "params": iparams})
	)
	_clear_action_hand(battle2, &"player")
	var b1 = _add_action_to_hand(battle2, &"player", "action_001_进攻")
	var b2 = _add_action_to_hand(battle2, &"player", "action_002_强袭")
	var ef2 = await _fire_effect(battle2, s2.pilot_card, s2.mech, &"player", &"pilot_057_effect_02")
	if ef2 == null:
		return "effect_02 未挂起（集成B）"
	await _resume_map_cell(battle2, ef2, "%d,%d" % [int(trap_hex2.q), int(trap_hex2.r)])
	await _resume_select_cards(battle2, ef2, [b1, b2])
	var dest_params2: Dictionary = {}
	for cap in captured2:
		if cap.get("type", "") == "select_map_cell" and String(cap.get("params", {}).get("label", "")).find("移动到的格子") >= 0:
			dest_params2 = cap.get("params", {})
	if dest_params2.is_empty():
		return "未捕获目的地选格 params（集成B captured=%d）" % captured2.size()
	var valid_b: Array = []
	for cell in dest_params2.get("valid_cells", []):
		valid_b.append(String(cell.get("cell_id", "")))
	# 直接调用（与引擎同源参数：陷阱格/预算8/全部机甲 blocked/绿格算1）
	var mech_blocked2: Dictionary = {}
	for mid: StringName in gs2.mechs:
		var mm = gs2.mechs[mid]
		if mm != null and not mm.destroyed:
			mech_blocked2[_HexGrid.key(mm.position)] = true
	var direct: Dictionary = {}
	for hx: Dictionary in _RangeCalculator.get_path_move_hexes(trap_hex2, 8, gs2.map_state.cells, mech_blocked2, 1):
		direct[_HexGrid.key(hx)] = true
	if valid_b.size() != direct.size():
		return "弃2张预算8应与直接BFS全等 实=%d 期望=%d" % [valid_b.size(), direct.size()]
	for vid: String in valid_b:
		if not direct.has(vid):
			return "引擎结果含直接BFS没有的格 %s" % vid
	for did: String in direct:
		if not valid_b.has(did):
			return "直接BFS含引擎结果没有的格 %s" % did
	if valid_b.has(_HexGrid.key(trap_hex2)):
		return "圆心（陷阱原位）不应可选（集成B）"
	# 收尾：选1个无机甲的可达格完成迁移
	var free_id: String = ""
	for vid: String in valid_b:
		if not mech_blocked2.has(vid):
			free_id = vid
			break
	if free_id == "":
		return "找不到无机甲的可达格"
	await _resume_map_cell(battle2, ef2, free_id)
	var free_parts := free_id.split(",")
	var free_hex := {"q": int(free_parts[0]), "r": int(free_parts[1])}
	if _traps_at(battle2, trap_hex2) != 0 or _traps_at(battle2, free_hex) != 1:
		return "陷阱应迁移到所选格"
	return true


## 测试10：e2 门槛--4格内无陷阱 / 无行动牌 -> 不挂起
func test_pilot_057_e2_gating() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_graham(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	# 无陷阱 -> 不挂起
	var ef1 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef1 != null:
		return "4格内无陷阱时 effect_02 不应挂起"
	# 陷阱在5格外 -> 不挂起
	var far_trap := _find_cell_at_distance(battle, s.mech.position, 5)
	if far_trap.is_empty():
		return "找不到距机甲5格的空格"
	_place_trap(battle, far_trap)
	var ef2 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef2 != null:
		return "陷阱在5格外时 effect_02 不应挂起"
	# 陷阱在4格内但无行动牌 -> 不挂起
	var near_trap := _find_cell_at_distance(battle, s.mech.position, 4, [far_trap])
	if near_trap.is_empty():
		return "找不到距机甲4格的空格"
	_place_trap(battle, near_trap)
	_clear_action_hand(battle, &"player")
	var ef3 = await _fire_effect(battle, s.pilot_card, s.mech, &"player", &"pilot_057_effect_02")
	if ef3 != null:
		return "无行动牌时 effect_02 不应挂起"
	return true


## 测试11：e2 每回合1次--完整发动后第2次不挂起（PVP3 third 玩家通用）
func test_pilot_057_e2_once_per_turn_and_third() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_graham(battle, &"third")
	if s.is_empty():
		return "third setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var trap_hex := _find_cell_at_distance(battle, third_mech.position, 1)
	if trap_hex.is_empty():
		return "找不到 third 相邻空格"
	_place_trap(battle, trap_hex)
	_normalize_terrain_around(battle, trap_hex, 3)
	# 目的格=距陷阱1格（邻格地形已 NORMAL 化；全部机甲阻挡下预算4确定可达）
	var gs = battle.context.game_state
	var blocked_t: Dictionary = {}
	for mid: StringName in gs.mechs:
		var mm = gs.mechs[mid]
		if mm != null and not mm.destroyed:
			blocked_t[_HexGrid.key(mm.position)] = true
	var dest_hex: Dictionary = {}
	for hx: Dictionary in _RangeCalculator.get_path_move_hexes(trap_hex, 4, gs.map_state.cells, blocked_t, 1):
		if _HexGrid.distance(trap_hex, hx) == 1 and not blocked_t.has(_HexGrid.key(hx)):
			dest_hex = hx
			break
	if dest_hex.is_empty():
		return "找不到距陷阱1格的目的格"
	# player 加1张行动牌（不应被 third 效果触及）
	var p1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"third")
	var t1 = _add_action_to_hand(battle, &"third", "action_002_强袭")
	var ef = await _fire_effect(battle, s.pilot_card, s.mech, &"third", &"pilot_057_effect_02")
	if ef == null:
		return "third 触发 effect_02 未挂起"
	await _resume_map_cell(battle, ef, "%d,%d" % [int(trap_hex.q), int(trap_hex.r)])
	await _resume_select_cards(battle, ef, [t1])
	await _resume_map_cell(battle, ef, "%d,%d" % [int(dest_hex.q), int(dest_hex.r)])
	if not _in_action_discard(battle, t1):
		return "third 被弃行动牌应在弃牌堆"
	if _in_action_discard(battle, p1):
		return "player 的行动牌不应被弃置"
	if _traps_at(battle, dest_hex) != 1:
		return "third 陷阱应迁移到目的格"
	# 每回合1次：用满 -> 第2次不挂起
	var ef2 = await _fire_effect(battle, s.pilot_card, s.mech, &"third", &"pilot_057_effect_02")
	if ef2 != null:
		return "third 每回合1次用满后不应再挂起"
	return true
