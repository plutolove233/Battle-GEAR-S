## test_pilot_081_汀兰.gd - 汀兰（pilot_081，秩序 N，cost 2）效果测试
##
## 汀兰 1 按钮（被动展示+悬停）+ RE 请求回复机制：
##   effect_01（LISTEN 显示按钮，置灰+悬停）「绿格光环」：被动，光环按持有者位置实时派生，
##     不注册监听器。效果本身不执行动作（光环/折扣/RE 全由静态 helper + 调用点按需派生）。
##   pilot_081_re_request（DIRECT RE 请求效果，不在 effect_ids 里，单独注册虚拟时点）：
##     光环格上机甲（含持有者自身）在其自己回合内1次点 RE 请求持有者回复2生命+获2金。
##     动作1 PILOT_081_RE_MARK_USED 原子标记 RE 已用（点击即消耗，持有者拒绝也不刷新）；
##     动作2 PILOT_081_RE_CONFIRM 弹确认窗给持有者（按 binding.card_instance_id 精确定位，
##     多汀兰可区分）：同意->请求方回2血+获2金；取消->无事（RE 已消耗）。
##   折扣：持有者玩家机甲移动时全地图绿格耗1（含光环转化绿格）；敌方仍耗2。
##   光环：各存活持有者所在格+6邻居（红格除外）视为绿格（移动+UI），按位置实时派生。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90081
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
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


## 设汀兰为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_081(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_081_汀兰", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## pos 的任一相邻格（odd-q 真邻居，避免偏移坑）
func _adjacent_cell_to(pos: Dictionary) -> Dictionary:
	return _HexGrid.neighbors(pos)[0]


## reachable 数组中是否含某 hex
func _has_hex(arr: Array, hex: Dictionary) -> bool:
	for h in arr:
		if int(h.get("q", -999)) == int(hex.get("q", -998)) and int(h.get("r", -999)) == int(hex.get("r", -998)):
			return true
	return false


## 请求方点击 RE 触发 pilot_081_re_request，返回挂起确认窗的 effect_fire action。
func _fire_pilot_081_re_request(battle, requester_mech, holder_pilot_card, requester_pid: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": holder_pilot_card.instance_id,
		"mech_id": requester_mech.mech_id,
		"player_id": requester_pid,
		"effect_id": &"pilot_081_re_request",
	}
	battle.context.game_state.active_player_id = requester_pid
	battle.context.game_state.phase = &"MAIN"
	battle.context.game_state.turn_number = 1
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_081_re_request",
		"player_id": requester_pid,
		"source_mech_id": requester_mech.mech_id,
		"mech_id": requester_mech.mech_id,
		"card_instance_id": holder_pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.record.get("_waiting_for_p081_re_confirm", false):
			return a
	return null


## 设置 RE 标准场景：汀兰(player,2,2) 为持有者；敌机移到相邻格（光环内）+ HP 降低。
func _setup_re_scenario(battle):
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return null
	var gs = s.gs
	var holder_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	enemy_mech.position = _adjacent_cell_to(holder_mech.position)
	enemy_mech.current_hp = max(1, int(enemy_mech.max_hp) - 4)
	return {"holder_card": s.card, "holder_mech": holder_mech, "requester_mech": enemy_mech, "gs": gs, "bridge": battle.context.action_ui_bridge}


# ═══════════════════════════════════════════
# 定义 + helpers
# ═══════════════════════════════════════════

## 测试1：effect_01 + re_request 定义
func test_pilot_081_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_effect_01")
	if e1 == null:
		return "缺 pilot_081_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN（被动展示按钮），实=%s" % String(e1.mode)
	if e1.listen_timing != &"":
		return "effect_01 listen_timing 应空（光环按需派生，不注册监听器）"
	if e1.display_name == "":
		return "effect_01 应有 display_name"
	if e1.description == "":
		return "effect_01 应有 description"
	if not e1.actions.is_empty() or not e1.conditions.is_empty():
		return "effect_01 应无动作/条件（纯展示）"
	var re = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_re_request")
	if re == null or re.mode != _TimingConst.MODE_DIRECT:
		return "pilot_081_re_request 应 DIRECT"
	var re_ops: Array = []
	for c in re.conditions:
		re_ops.append(String(c.get("op", &"")))
	if not re_ops.has("PILOT_081_RE_AVAILABLE"):
		return "re_request 应含条件 PILOT_081_RE_AVAILABLE"
	var re_acts: Array = re.actions
	if re_acts.size() != 2:
		return "re_request actions 应 [PILOT_081_RE_MARK_USED, PILOT_081_RE_CONFIRM]"
	if String(re_acts[0].get("type", &"")) != "PILOT_081_RE_MARK_USED" or String(re_acts[1].get("type", &"")) != "PILOT_081_RE_CONFIRM":
		return "re_request actions 类型不符"
	return true


## 测试2：helpers（find_holders/aura_cell_set/player_has_discount/covering/find_holder_for_instance/re_used/move_bfs_params）
func test_pilot_081_helpers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	# 无机师时
	if not _ActionPilotEffects.pilot_081_find_holders(gs).is_empty():
		return "无机师时 find_holders 应空"
	if int(battle.context.map_service.resolve_move_cost_params(&"player")["green_cost"]) != 2:
		return "无机师时移动参数 green_cost 应默认2"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_081_汀兰）"
	var holder_mech = s.mech
	var holders: Array = _ActionPilotEffects.pilot_081_find_holders(gs)
	if holders.size() != 1 or StringName(holders[0]) != holder_mech.mech_id:
		return "设汀兰后 find_holders 应返回持有者机甲"
	# 折扣（通用移动参数）：持有者玩家 green_cost=1，敌方=2
	if int(battle.context.map_service.resolve_move_cost_params(&"player")["green_cost"]) != 1:
		return "持有者玩家应有折扣（green_cost=1）"
	if int(battle.context.map_service.resolve_move_cost_params(&"enemy")["green_cost"]) != 2:
		return "敌方不应有折扣（green_cost=2）"
	# 光环格集合：持有者格 + 6 邻居
	var aura: Dictionary = battle.context.map_service.resolve_move_cost_params(&"player")["aura_cells"]
	if not aura.has(_HexGrid.key(holder_mech.position)):
		return "光环应含持有者所在格"
	var nbrs: Array = _HexGrid.neighbors(holder_mech.position)
	if nbrs.size() < 6:
		return "邻居数应≥6（边界可能少），实=%d" % nbrs.size()
	for n: Dictionary in nbrs:
		if not aura.has(_HexGrid.key(n)):
			return "光环应含持有者邻居 %s" % str(n)
	# 红格除外：把一个邻居设为 RED，光环应排除它
	var red_nbr: Dictionary = nbrs[0]
	var red_cell = gs.map_state.cells.get(_HexGrid.key(red_nbr))
	if red_cell == null:
		return "红格测试：邻居格不存在"
	var saved_terrain: StringName = red_cell.terrain
	red_cell.terrain = &"RED"
	var aura2: Dictionary = battle.context.map_service.resolve_move_cost_params(&"player")["aura_cells"]
	if aura2.has(_HexGrid.key(red_nbr)):
		return "光环应排除红格邻居"
	red_cell.terrain = saved_terrain  # 还原
	# covering：持有者自身在光环内（距离0）
	var cov_self: Array = _ActionPilotEffects.pilot_081_find_covering_holders(gs, holder_mech.mech_id)
	if cov_self.is_empty() or StringName(cov_self[0]) != holder_mech.mech_id:
		return "持有者自身应被自己覆盖（含自身）"
	# covering：相邻格上的机甲也被覆盖
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = _adjacent_cell_to(holder_mech.position)
	var cov_enemy: Array = _ActionPilotEffects.pilot_081_find_covering_holders(gs, enemy_mech.mech_id)
	if cov_enemy.is_empty() or StringName(cov_enemy[0]) != holder_mech.mech_id:
		return "相邻机甲应被持有者覆盖"
	# 远离后不覆盖
	enemy_mech.position = {"q": 20, "r": 2}
	if not _ActionPilotEffects.pilot_081_find_covering_holders(gs, enemy_mech.mech_id).is_empty():
		return "远离后不应被覆盖"
	# find_holder_for_pilot_instance：按实例 id 定位
	var found_mid: StringName = _ActionPilotEffects.pilot_081_find_holder_for_pilot_instance(gs, s.card.instance_id)
	if found_mid != holder_mech.mech_id:
		return "find_holder_for_pilot_instance 应返回持有者机甲"
	if _ActionPilotEffects.pilot_081_find_holder_for_pilot_instance(gs, &"nonexistent") != &"":
		return "未知实例应返回空"
	# re_used / mark_used：计数存请求方玩家 once_per_turn_used
	enemy_mech.position = _adjacent_cell_to(holder_mech.position)
	if _ActionPilotEffects.pilot_081_re_used_this_turn(gs, enemy_mech.mech_id):
		return "未请求过 re_used 应 false"
	_ActionPilotEffects.pilot_081_re_mark_used(gs, enemy_mech.mech_id)
	if not _ActionPilotEffects.pilot_081_re_used_this_turn(gs, enemy_mech.mech_id):
		return "标记后 re_used 应 true"
	# 通用移动参数：持有者玩家 green_cost=1，敌方=2，aura=光环格
	var bfs_p: Dictionary = battle.context.map_service.resolve_move_cost_params(&"player")
	if int(bfs_p["green_cost"]) != 1:
		return "持有者玩家移动参数 green_cost 应1"
	var bfs_e: Dictionary = battle.context.map_service.resolve_move_cost_params(&"enemy")
	if int(bfs_e["green_cost"]) != 2:
		return "敌方移动参数 green_cost 应2"
	if not (bfs_p["aura_cells"] is Dictionary) or (bfs_p["aura_cells"] as Dictionary).is_empty():
		return "移动参数 aura_cells 应非空"
	return true


# ═══════════════════════════════════════════
# 光环随移动 + 移动折扣
# ═══════════════════════════════════════════

## 测试3：持有者移动后光环跟随（旧格消失，新格+邻居出现）
func test_pilot_081_aura_follows_move() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var old_pos: Dictionary = holder.position.duplicate()
	var old_aura: Dictionary = battle.context.map_service.resolve_move_cost_params(null)["aura_cells"]
	# 移到远处
	holder.position = {"q": 10, "r": 0}
	var new_aura: Dictionary = battle.context.map_service.resolve_move_cost_params(null)["aura_cells"]
	if new_aura.has(_HexGrid.key(old_pos)):
		return "移动后旧持有者格不应再在光环内"
	if not new_aura.has(_HexGrid.key(holder.position)):
		return "移动后新持有者格应在光环内"
	# 新光环应含新位置邻居，不含旧位置邻居
	for n: Dictionary in _HexGrid.neighbors(holder.position):
		if not new_aura.has(_HexGrid.key(n)):
			return "移动后新邻居应在光环内"
	# 旧位置的某邻居（非新位置共享）应已不在新光环内：取旧位置自身已在上一条排除，
	# 再取旧位置的一个邻居验证已移出（除非恰好与新位置邻居重叠）
	var old_nbr: Dictionary = _HexGrid.neighbors(old_pos)[0]
	if new_aura.has(_HexGrid.key(old_nbr)) and _HexGrid.key(old_nbr) != _HexGrid.key(holder.position):
		# 仅当旧邻居既非新中心也非新邻居才算异常
		var is_new_nbr := false
		for nn: Dictionary in _HexGrid.neighbors(holder.position):
			if _HexGrid.key(nn) == _HexGrid.key(old_nbr):
				is_new_nbr = true
				break
		if not is_new_nbr:
			return "移动后旧邻居不应在新光环内（除非与新位置重叠）"
	return true


## 测试4：移动折扣——持有者玩家绿格耗1（power1 可达 GREEN 邻居），敌方耗2（不可达）
func test_pilot_081_move_discount() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var cells: Dictionary = gs.map_state.cells
	# 选 holder 的一个邻居设为 GREEN（自然绿格）
	var nbr: Dictionary = _HexGrid.neighbors(holder.position)[0]
	var nbr_key: String = _HexGrid.key(nbr)
	var cell = cells.get(nbr_key)
	if cell == null:
		return "邻居格不存在"
	var saved_terrain: StringName = cell.terrain
	cell.terrain = &"GREEN"
	# 持有者玩家：折扣 green_cost=1 -> power 1 可达 GREEN 邻居（cost 1）
	var bfs_p: Dictionary = battle.context.map_service.resolve_move_cost_params(&"player")
	var reach_p: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(holder.position, 1, cells, int(bfs_p["green_cost"]), bfs_p["aura_cells"])
	if not _has_hex(reach_p, nbr):
		return "折扣下持有者 power1 应可达 GREEN 邻居（cost 1）"
	# 敌方：无折扣 green_cost=2 -> power 1 不可达 GREEN 邻居（cost 2）
	var bfs_e: Dictionary = battle.context.map_service.resolve_move_cost_params(&"enemy")
	var reach_e: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(holder.position, 1, cells, int(bfs_e["green_cost"]), bfs_e["aura_cells"])
	if _has_hex(reach_e, nbr):
		return "无折扣下敌方 power1 不应可达 GREEN 邻居（cost 2）"
	cell.terrain = saved_terrain  # 还原
	return true


## 测试4b：实扣动力落地--basic_move 动作层：持有者玩家自然绿格扣1；敌方进光环转化绿格
## （normal 地形+光环）视为绿格扣2（修复前实扣写死 terrain==GREEN->2 不认折扣/光环）。
func test_pilot_081_move_cost_deduction() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var enemy = gs.get_mech_for_player(&"enemy")
	holder.position = {"q": 5, "r": 2}
	# A1=自然绿格折扣测试目标；A2=光环转化绿格测试目标（保持 NORMAL 地形）
	var nbrs: Array[Dictionary] = _HexGrid.neighbors(holder.position)
	var a1: Dictionary = nbrs[0]
	var a2: Dictionary = nbrs[1]
	var cell_a1 = gs.map_state.cells.get(_HexGrid.key(a1))
	var cell_a2 = gs.map_state.cells.get(_HexGrid.key(a2))
	if cell_a1 == null or cell_a2 == null:
		return "邻居格不存在"
	# 找 A2 的相邻格 B（距持有者 2 格、光环外）作敌方起点
	var b_start: Dictionary = {}
	for nb: Dictionary in _HexGrid.neighbors(a2):
		if _HexGrid.distance(nb, holder.position) == 2 and gs.map_state.cells.has(_HexGrid.key(nb)):
			b_start = nb
			break
	if b_start.is_empty():
		return "找不到光环外的敌方起点格"
	enemy.position = b_start.duplicate()
	# 地形暂存：A1 设 GREEN（自然绿格），A2 保持/设 NORMAL（光环转化绿格）
	var saved_a1: StringName = cell_a1.terrain
	var saved_a2: StringName = cell_a2.terrain
	cell_a1.terrain = &"GREEN"
	cell_a2.terrain = &"NORMAL"
	# 敌方 power1 进光环格：视为绿格耗2 -> 动力不足不移动
	enemy.power = 1
	battle.context.action_service.execute(&"basic_move", {
		"mech_id": enemy.mech_id,
		"target_cell": StringName("%d,%d" % [int(a2.q), int(a2.r)]),
	})
	await _pump_frames(5)
	if _HexGrid.key(enemy.position) == _HexGrid.key(a2):
		cell_a1.terrain = saved_a1
		cell_a2.terrain = saved_a2
		return "敌方 power1 不应能进光环转化绿格（视为绿格耗2）"
	# 敌方 power2 进光环格：成功且扣2
	enemy.power = 2
	battle.context.action_service.execute(&"basic_move", {
		"mech_id": enemy.mech_id,
		"target_cell": StringName("%d,%d" % [int(a2.q), int(a2.r)]),
	})
	await _pump_frames(5)
	if _HexGrid.key(enemy.position) != _HexGrid.key(a2) or int(enemy.power) != 0:
		cell_a1.terrain = saved_a1
		cell_a2.terrain = saved_a2
		return "敌方 power2 进光环格应成功且扣2（实剩%d）" % int(enemy.power)
	# 持有者玩家 power1 进自然绿格：折扣生效扣1
	holder.power = 1
	battle.context.action_service.execute(&"basic_move", {
		"mech_id": holder.mech_id,
		"target_cell": StringName("%d,%d" % [int(a1.q), int(a1.r)]),
	})
	await _pump_frames(5)
	if _HexGrid.key(holder.position) != _HexGrid.key(a1) or int(holder.power) != 0:
		cell_a1.terrain = saved_a1
		cell_a2.terrain = saved_a2
		return "持有者 power1 进自然绿格应成功且扣1（实剩%d）" % int(holder.power)
	cell_a1.terrain = saved_a1
	cell_a2.terrain = saved_a2
	return true


# ═══════════════════════════════════════════
# RE 条件 gate
# ═══════════════════════════════════════════

## 测试5：RE 请求条件 PILOT_081_RE_AVAILABLE（己方回合/在光环格/未请求；含自我请求）
func test_pilot_081_re_available_condition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	enemy_mech.position = _adjacent_cell_to(holder.position)  # 光环内
	gs.turn_number = 1
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_re_request")
	# 请求方=enemy，binding.mech_id=enemy
	var req_bind: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": enemy_mech.mech_id,
		"player_id": &"enemy",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_081_汀兰",
	}
	# 己方回合 + 在光环内 + 未用 -> 可用
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(re_eff, req_bind):
		return "己方回合+光环内+未用应可用"
	# 非己方回合 -> 不可用
	gs.active_player_id = &"player"
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "非己方回合不应可用"
	# 回己方回合；本回合已请求过 -> 不可用
	gs.active_player_id = &"enemy"
	_ActionPilotEffects.pilot_081_re_mark_used(gs, enemy_mech.mech_id)
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "本回合已请求过不应可用"
	# 清标记；敌机移出光环 -> 不可用
	enemy_mech.position = {"q": 20, "r": 2}
	# once_per_turn_used 清零模拟下回合（TURN_START 清）
	gs.players.get(&"enemy").once_per_turn_used.clear()
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "离开光环格不应可用"
	# 自我请求：持有者自身在光环内（含自身），己方回合+未用 -> 可用
	enemy_mech.position = _adjacent_cell_to(holder.position)  # 还原到光环内（不影响下条）
	var self_bind: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": holder.mech_id,
		"player_id": &"player",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_081_汀兰",
	}
	gs.active_player_id = &"player"
	if not te.can_trigger_active_effect(re_eff, self_bind):
		return "持有者自身在光环内+己方回合应可自我请求"
	return true


# ═══════════════════════════════════════════
# RE 确认/拒绝
# ═══════════════════════════════════════════

## 测试6：RE 请求 -> 持有者同意 -> 请求方回2血+获2金，RE 已消耗，动作完成
func test_pilot_081_re_confirm_heal_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var req = sc.requester_mech
	var hp_before: int = int(req.current_hp)
	var gold_before: int = int(gs.players.get(req.owner_player_id).gold)
	var re_action = await _fire_pilot_081_re_request(battle, req, sc.holder_card, req.owner_player_id)
	if re_action == null:
		return "RE 请求应挂起确认窗（未挂起）"
	# 点击即消耗
	if not _ActionPilotEffects.pilot_081_re_used_this_turn(gs, req.mech_id):
		return "RE 点击后应已标记使用（点击即消耗）"
	# 确认弹窗路由到持有者玩家（player）
	var w: Dictionary = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "应弹 choose_one_effect（RE 确认窗），实际 %s" % String(w.get("input_type", &""))
	var ip: Dictionary = w.get("input_params", {})
	if String(ip.get("effect_id", &"")) != "pilot_081_re_request":
		return "确认窗 effect_id 应 pilot_081_re_request"
	if String(ip.get("player_id", &"")) != "player":
		return "确认窗应路由到持有者玩家(player)，实际 %s" % String(ip.get("player_id", &""))
	var opts: Array = ip.get("options", [])
	if opts.size() != 1 or String(opts[0].get("label", "")) != "同意回复":
		return "确认窗应只有'同意回复'选项，实=%s" % str(opts)
	if String(ip.get("source_label", "")).find("回复2生命") < 0:
		return "确认窗应含请求方信息（source_label），实=%s" % String(ip.get("source_label", ""))
	# 持有者同意 -> 回2血+获2金
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {})
	await _pump_frames(6)
	if int(req.current_hp) != hp_before + 2:
		return "同意后请求方应回2血，期望 %d 实际 %d" % [hp_before + 2, int(req.current_hp)]
	if int(gs.players.get(req.owner_player_id).gold) != gold_before + 2:
		return "同意后请求方玩家应获2金，期望 %d 实际 %d" % [gold_before + 2, int(gs.players.get(req.owner_player_id).gold)]
	if re_action.state != &"completed":
		return "RE 动作应完成（不阻塞），实际 %s" % String(re_action.state)
	if not _ActionPilotEffects.pilot_081_re_used_this_turn(gs, req.mech_id):
		return "RE 应已消耗"
	return true


## 测试7：RE 请求 -> 持有者拒绝 -> 无回血/获金，RE 仍已消耗，动作完成，且不可再次请求
func test_pilot_081_re_refuse_consumed() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var req = sc.requester_mech
	var hp_before: int = int(req.current_hp)
	var gold_before: int = int(gs.players.get(req.owner_player_id).gold)
	var re_action = await _fire_pilot_081_re_request(battle, req, sc.holder_card, req.owner_player_id)
	if re_action == null:
		return "RE 请求应挂起确认窗（未挂起）"
	# 持有者拒绝
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"cancelled": true})
	await _pump_frames(6)
	if int(req.current_hp) != hp_before:
		return "拒绝后不应回血，期望 %d 实际 %d" % [hp_before, int(req.current_hp)]
	if int(gs.players.get(req.owner_player_id).gold) != gold_before:
		return "拒绝后不应获金，期望 %d 实际 %d" % [gold_before, int(gs.players.get(req.owner_player_id).gold)]
	if re_action.state != &"completed":
		return "拒绝后 RE 动作应完成，实际 %s" % String(re_action.state)
	if not _ActionPilotEffects.pilot_081_re_used_this_turn(gs, req.mech_id):
		return "拒绝不应刷新 RE 次数（点击即消耗）"
	# 再次请求：条件应不可用（本回合已用）
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_re_request")
	var req_bind: Dictionary = {
		"card_instance_id": sc.holder_card.instance_id,
		"mech_id": req.mech_id,
		"player_id": req.owner_player_id,
		"slot_id": &"pilot",
		"card_def_id": &"pilot_081_汀兰",
	}
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "拒绝后本回合不应可再次请求"
	return true


## 测试8：自我请求——持有者在自己光环格上请求自己，同意后自身回2血+获2金
func test_pilot_081_self_request() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	battle.context.action_ui_bridge.context = battle.context
	holder.current_hp = max(1, int(holder.max_hp) - 4)
	var hp_before: int = int(holder.current_hp)
	var gold_before: int = int(gs.players.get(&"player").gold)
	# 持有者请求自己（requester=holder，holder_card=自身汀兰实例）
	var re_action = await _fire_pilot_081_re_request(battle, holder, s.card, &"player")
	if re_action == null:
		return "自我请求应挂起确认窗（未挂起）"
	# 确认窗路由到持有者=player（自我请求 holder==requester owner）
	var w: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "应弹 choose_one_effect"
	if String(w.get("input_params", {}).get("player_id", &"")) != "player":
		return "自我请求确认窗应路由到 player"
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {})
	await _pump_frames(6)
	if int(holder.current_hp) != hp_before + 2:
		return "自我请求同意后应回2血，期望 %d 实际 %d" % [hp_before + 2, int(holder.current_hp)]
	if int(gs.players.get(&"player").gold) != gold_before + 2:
		return "自我请求同意后应获2金，期望 %d 实际 %d" % [gold_before + 2, int(gs.players.get(&"player").gold)]
	if re_action.state != &"completed":
		return "自我请求 RE 动作应完成，实际 %s" % String(re_action.state)
	return true


## 测试9：多持有者拒绝 H1 后 H2 本回合亦不可用（计数请求方作用域，非持有者）
func test_pilot_081_multi_holder_refuse_blocks() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 汀兰设给 player（2,2）与 enemy（移到 player 相邻格）
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup player 失败"
	var gs = s.gs
	var holder_p = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = _adjacent_cell_to(holder_p.position)
	# 给 enemy 也设汀兰（第二持有者 H2）
	var card_e = _make_instance(gs, battle.context.card_database, "pilot_081_汀兰", &"enemy")
	if card_e == null:
		return "setup enemy 汀兰失败"
	battle.context.game_setup_service.set_pilot(enemy_mech.mech_id, card_e)
	battle.context.action_ui_bridge.context = battle.context
	gs.turn_number = 1
	# 请求方 = holder_p（player 机甲），被 H1(player汀兰) 与 H2(enemy汀兰) 共同覆盖
	# （holder_p 自身=H1 距离0；enemy 汀兰相邻=H2 距离1）
	var cov: Array = _ActionPilotEffects.pilot_081_find_covering_holders(gs, holder_p.mech_id)
	if cov.size() < 2:
		return "前置：holder_p 应被 H1+H2 同时覆盖，实=%d" % cov.size()
	# 经 H1 发起 RE -> 拒绝（点击即消耗，存请求方 holder_p 玩家 once_per_turn_used）
	var re_action = await _fire_pilot_081_re_request(battle, holder_p, s.card, &"player")
	if re_action == null:
		return "H1 RE 请求应挂起确认窗"
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"cancelled": true})
	await _pump_frames(6)
	if not _ActionPilotEffects.pilot_081_re_used_this_turn(gs, holder_p.mech_id):
		return "H1 拒绝后请求方应已消耗"
	# H2 的条件（请求方仍=holder_p）应不可用：计数是请求方作用域，拒绝 H1 即阻断 H2
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_re_request")
	var h2_bind: Dictionary = {
		"card_instance_id": card_e.instance_id,  # H2 的汀兰实例
		"mech_id": holder_p.mech_id,  # 请求方仍是 holder_p
		"player_id": &"player",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_081_汀兰",
	}
	if te.can_trigger_active_effect(re_eff, h2_bind):
		return "拒绝 H1 后 H2 本回合亦不应可用（计数请求方作用域）"
	return true


# ═══════════════════════════════════════════
# 攻击射程受光环影响（光环格视为绿格、耗2射程预算，全场无折扣）
# ═══════════════════════════════════════════

## 构造最小 cells 字典 {key: {"q","r","terrain"}}（_terrain_of 接受纯字典）
func _cell_dict(q: int, r: int, terrain: StringName) -> Dictionary:
	return {"q": q, "r": r, "terrain": terrain}


## 测试10：RangeCalculator 武器射程 BFS 受 aura_green_cells 影响（单元级）
## 光环格视为绿格、耗2射程预算；天然绿格照旧耗2；红格阻挡；无 aura 参数时向后兼容。
func test_pilot_081_attack_aura_unit() -> Variant:
	# 用 _HexGrid.neighbors 取真实邻居（flat-top odd-q offset 坐标，非纯轴向）
	var origin: Dictionary = {"q": 0, "r": 0}
	var nbrs: Array[Dictionary] = _HexGrid.neighbors(origin)
	var n1: Dictionary = nbrs[0]
	var n1_key: String = _HexGrid.key(n1)
	# n2 = n1 的邻居中非 origin 邻居者（距 origin 2，唯一路径经 n1）
	var nbrs_set: Dictionary = {}
	for nb in nbrs:
		nbrs_set[_HexGrid.key(nb)] = true
	var n2: Dictionary = {}
	for nb in _HexGrid.neighbors(n1):
		var nb_key: String = _HexGrid.key(nb)
		if nb_key != _HexGrid.key(origin) and not nbrs_set.has(nb_key):
			n2 = nb
			break
	if n2.is_empty():
		return "无法构造距 origin 2 的 n2"
	var n2_key: String = _HexGrid.key(n2)
	# 一条 NORMAL 格链：origin - n1 - n2
	var cells: Dictionary = {
		_HexGrid.key(origin): _cell_dict(int(origin.q), int(origin.r), &"NORMAL"),
		n1_key: _cell_dict(int(n1.q), int(n1.r), &"NORMAL"),
		n2_key: _cell_dict(int(n2.q), int(n2.r), &"NORMAL"),
	}
	# 向后兼容：不传 aura（默认 {}）-> 邻居 n1 在 range1 内（cost 1）
	if not _RangeCalculator.is_in_weapon_range(origin, n1, 1, cells):
		return "无光环：邻居 n1 应在 range1 内（cost 1）"
	# 光环格 n1：range1 不可达（cost 2 > 1），range2 可达（cost 2 ≤ 2）
	if _RangeCalculator.is_in_weapon_range(origin, n1, 1, cells, {n1_key: true}):
		return "光环：邻居 n1 在 range1 内应不可达（光环格 cost 2 > 1）"
	if not _RangeCalculator.is_in_weapon_range(origin, n1, 2, cells, {n1_key: true}):
		return "光环：邻居 n1 在 range2 内应可达（cost 2 ≤ 2）"
	# n2 距离2：无光环可达（路径 1+1=2）；光环下唯一路径经 n1 cost 2+1=3 > 2 不可达
	if not _RangeCalculator.is_in_weapon_range(origin, n2, 2, cells):
		return "无光环：n2 在 range2 内应可达（1+1=2）"
	if _RangeCalculator.is_in_weapon_range(origin, n2, 2, cells, {n1_key: true}):
		return "光环：n2 在 range2 内应不可达（唯一路径经光环格 2+1=3 > 2）"
	# get_weapon_reachable_hexes：range2 无光环含 n1 与 n2；光环下含 n1 不含 n2
	var reach_no_aura: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(origin, 2, cells)
	if not _has_hex(reach_no_aura, n1) or not _has_hex(reach_no_aura, n2):
		return "无光环 range2 可达应含 n1 与 n2，实=%s" % str(reach_no_aura)
	var reach_aura: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(origin, 2, cells, {n1_key: true})
	if not _has_hex(reach_aura, n1):
		return "光环 range2 可达应含 n1（cost 2 ≤ 2）"
	if _has_hex(reach_aura, n2):
		return "光环 range2 可达不应含 n2（经光环格 3 > 2）"
	# 天然绿格照旧耗2（无 aura 参数时也耗2）
	var green_cells: Dictionary = {_HexGrid.key(origin): _cell_dict(int(origin.q), int(origin.r), &"NORMAL"), n1_key: _cell_dict(int(n1.q), int(n1.r), &"GREEN")}
	if _RangeCalculator.is_in_weapon_range(origin, n1, 1, green_cells):
		return "天然绿格 range1 应不可达（cost 2 > 1）"
	if not _RangeCalculator.is_in_weapon_range(origin, n1, 2, green_cells):
		return "天然绿格 range2 应可达（cost 2 ≤ 2）"
	# 红格阻挡（光环不覆盖红格）
	var red_cells: Dictionary = {_HexGrid.key(origin): _cell_dict(int(origin.q), int(origin.r), &"NORMAL"), n1_key: _cell_dict(int(n1.q), int(n1.r), &"RED")}
	if _RangeCalculator.is_in_weapon_range(origin, n1, 3, red_cells, {n1_key: true}):
		return "红格应阻挡（光环不覆盖红格）"
	return true


## 测试11：get_attack_aura_cells 集成--汀兰在场时光环格在攻击射程中耗2（含持有者自己）；
## 汀兰不在场时 get_attack_aura_cells 返回 {}（向后兼容）。
func test_pilot_081_attack_aura_integration() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 无汀兰：get_attack_aura_cells 返回 {}
	if not (battle.context.map_service.get_attack_aura_cells() as Dictionary).is_empty():
		return "无汀兰时 get_attack_aura_cells 应返回空字典"
	var s = _setup_pilot_081(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var cells: Dictionary = gs.map_state.cells
	# get_attack_aura_cells 与 resolve_move_cost_params(null) 的 aura 一致（全局、无折扣）
	var aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
	if aura.is_empty():
		return "汀兰在场时光环应非空"
	if aura != battle.context.map_service.resolve_move_cost_params(null)["aura_cells"]:
		return "get_attack_aura_cells 应等于 resolve_move_cost_params(null).aura_cells"
	if not aura.has(_HexGrid.key(holder.position)):
		return "光环应含持有者自身所在格"
	# 取持有者的一个邻居，确保地形 NORMAL（排除天然绿格干扰）
	var nbr: Dictionary = _HexGrid.neighbors(holder.position)[0]
	var nbr_key: String = _HexGrid.key(nbr)
	var cell = cells.get(nbr_key)
	if cell == null:
		return "邻居格不存在"
	var saved_terrain: StringName = cell.terrain
	cell.terrain = &"NORMAL"
	# 邻居在光环内：range1 不可达（光环格 cost 2 > 1）--含持有者自己攻击亦无折扣
	if _RangeCalculator.is_in_weapon_range(holder.position, nbr, 1, cells, aura):
		cell.terrain = saved_terrain
		return "光环邻居 range1 应不可达（光环格耗2，持有者自己攻击无折扣）"
	# 同一邻居，不传 aura（无光环视角）-> range1 可达（NORMAL cost 1）
	if not _RangeCalculator.is_in_weapon_range(holder.position, nbr, 1, cells, {}):
		cell.terrain = saved_terrain
		return "NORMAL 邻居无光环时 range1 应可达（cost 1）"
	# range2 光环邻居可达（cost 2 ≤ 2）
	if not _RangeCalculator.is_in_weapon_range(holder.position, nbr, 2, cells, aura):
		cell.terrain = saved_terrain
		return "光环邻居 range2 应可达（cost 2 ≤ 2）"
	cell.terrain = saved_terrain  # 还原
	return true
