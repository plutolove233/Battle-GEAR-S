## test_map_markers.gd - 地图格子与地图标记测试
##
## 验证 PvP 模式下：
## - 绿/红格子配置（数量、红格不可通行、绿格耗2动力）
## - 标记点（金币8/事件8，不在红格上、避开起始格及邻居）
## - 标记触发（金币投骰按映射给金币并移除；事件/陷阱文本占位）
## - 事件标记重生（全部消失后在空闲点重生，被占据点一次性跳过）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _RangeCalc = preload("res://scripts/battle/RangeCalculator.gd")


## UI 脚本编译检查（headless 测试不加载 battle_board/message_log，单独验证改动可编译）
func test_ui_scripts_compile():
	var bb = load("res://scripts/ui/battle_board.gd")
	if bb == null:
		return "battle_board.gd 编译失败"
	var bml = load("res://scripts/ui/battle_message_log.gd")
	if bml == null:
		return "battle_message_log.gd 编译失败"
	return true


func _new_battle(pvp: bool = false) -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.pvp_map_features = pvp
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## PvP 布局：绿/红格数 + 标记点数符合配置
func test_pvp_map_features_configured():
	var battle := _new_battle(true)
	var gs = battle.context.game_state
	var green := 0
	var red := 0
	for key in gs.map_state.cells:
		var t = gs.map_state.cells[key].terrain
		if t == &"GREEN":
			green += 1
		elif t == &"RED":
			red += 1
	if green != _GameConfig.GREEN_TILE_COUNT:
		return "绿格数应=%d 实际%d" % [_GameConfig.GREEN_TILE_COUNT, green]
	if red != _GameConfig.RED_TILE_COUNT:
		return "红格数应=%d 实际%d" % [_GameConfig.RED_TILE_COUNT, red]
	var gold_pts := 0
	var event_pts := 0
	for p in gs.map_state.marker_points:
		if p.get("type", &"") == &"GOLD":
			gold_pts += 1
		elif p.get("type", &"") == &"EVENT":
			event_pts += 1
	if gold_pts != _GameConfig.GOLD_MARKER_POINT_COUNT:
		return "金币点应=%d 实际%d" % [_GameConfig.GOLD_MARKER_POINT_COUNT, gold_pts]
	if event_pts != _GameConfig.EVENT_MARKER_POINT_COUNT:
		return "事件点应=%d 实际%d" % [_GameConfig.EVENT_MARKER_POINT_COUNT, event_pts]
	# 初始标记一对一：金币标记数=金币点数，事件标记数=事件点数
	var gold_mk := 0
	var event_mk := 0
	for m in gs.map_state.markers:
		if m.get("type", &"") == &"GOLD":
			gold_mk += 1
		elif m.get("type", &"") == &"EVENT":
			event_mk += 1
	if gold_mk != gold_pts:
		return "初始金币标记应=%d 实际%d" % [gold_pts, gold_mk]
	if event_mk != event_pts:
		return "初始事件标记应=%d 实际%d" % [event_pts, event_mk]
	return true


## 教学/测试不配置地图特征（避免影响既有测试与固定布局）
func test_tutorial_no_map_features():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	for key in gs.map_state.cells:
		if gs.map_state.cells[key].terrain != &"NORMAL":
			return "教学战斗不应有特殊地形格，发现 %s" % String(gs.map_state.cells[key].terrain)
	if not gs.map_state.marker_points.is_empty():
		return "教学战斗不应有标记点"
	if not gs.map_state.markers.is_empty():
		return "教学战斗不应有标记"
	return true


## 标记点不在红格上 + 避开起始格及邻居
func test_marker_points_avoid_red_and_start():
	var battle := _new_battle(true)
	var gs = battle.context.game_state
	var forbidden: Dictionary = {}
	for pid in gs.players:
		var m = gs.get_mech_for_player(pid)
		if m != null and not m.position.is_empty():
			forbidden[_HexGrid.key(m.position)] = true
			for n in _HexGrid.neighbors(m.position):
				if gs.map_state.has_cell(n):
					forbidden[_HexGrid.key(n)] = true
	for p in gs.map_state.marker_points:
		var cell = gs.map_state.get_cell_state({"q": int(p.get("q", 0)), "r": int(p.get("r", 0))})
		if cell == null:
			return "标记点 (%d,%d) 不在地图上" % [int(p.get("q", 0)), int(p.get("r", 0))]
		if cell.terrain == &"RED":
			return "标记点 (%d,%d) 不应在红格上" % [int(p.get("q", 0)), int(p.get("r", 0))]
		var k := "%s,%s" % [int(p.get("q", 0)), int(p.get("r", 0))]
		if forbidden.has(k):
			return "标记点 (%d,%d) 落在起始格/邻居禁区上" % [int(p.get("q", 0)), int(p.get("r", 0))]
	return true


## 红格不可通行（攻击/移动范围绕行）；绿格耗2动力
func test_red_impassable_green_costs_two():
	var battle := _new_battle(true)
	var gs = battle.context.game_state
	# 找一个红格
	var red_hex: Dictionary = {}
	var green_hex: Dictionary = {}
	for key in gs.map_state.cells:
		var c = gs.map_state.cells[key]
		if c.terrain == &"RED" and red_hex.is_empty():
			red_hex = {"q": c.q, "r": c.r}
		elif c.terrain == &"GREEN" and green_hex.is_empty():
			green_hex = {"q": c.q, "r": c.r}
	if red_hex.is_empty():
		return "未找到红格（布局异常）"
	if green_hex.is_empty():
		return "未找到绿格（布局异常）"
	# 红格 is_passable=false
	var red_cell = gs.map_state.get_cell_state(red_hex)
	if red_cell.is_passable():
		return "红格应不可通行"
	if red_cell.get_move_cost() != -1:
		return "红格 move_cost 应=-1 实际%d" % red_cell.get_move_cost()
	# 绿格 move_cost=2
	var green_cell = gs.map_state.get_cell_state(green_hex)
	if green_cell.get_move_cost() != 2:
		return "绿格 move_cost 应=2 实际%d" % green_cell.get_move_cost()
	# 武器范围 BFS 不应把红格列入可达
	var origin := _HexGrid.neighbors(red_hex)[0]
	var reachable := _RangeCalc.get_weapon_reachable_hexes(origin, 3, gs.map_state.cells)
	for h in reachable:
		if int(h.get("q", 0)) == int(red_hex.get("q", 0)) and int(h.get("r", 0)) == int(red_hex.get("r", 0)):
			return "红格不应出现在武器可达范围内"
	return true


## 金币标记触发：投骰按映射给金币（3/4/6）并移除标记
func test_gold_marker_trigger_payout_and_removal():
	var battle := _new_battle(false)  # 干净地图，手动放标记
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players[&"player"]
	# 验证映射函数
	if _GameConfig.gold_marker_payout(1) != 3 or _GameConfig.gold_marker_payout(3) != 3:
		return "骰1-3应得3金币"
	if _GameConfig.gold_marker_payout(4) != 4 or _GameConfig.gold_marker_payout(5) != 4:
		return "骰4-5应得4金币"
	if _GameConfig.gold_marker_payout(6) != 6:
		return "骰6应得6金币"
	var target := _HexGrid.neighbors(player_mech.position)[0]
	gs.map_state.add_marker(gs.next_id(&"marker"), int(target.q), int(target.r), &"GOLD")
	var gold_before: int = player.gold
	battle.context.map_service._check_map_markers(player_mech, target)
	if not gs.map_state.get_markers_at(int(target.q), int(target.r)).is_empty():
		return "金币标记触发后应被移除"
	var gained: int = player.gold - gold_before
	if gained != 3 and gained != 4 and gained != 6:
		return "金币收益应=3/4/6 实际%d" % gained
	return true


## 事件标记触发：发起 set_event_card 动作，事件牌堆顶牌设置到机甲事件区域（标记移除）
func test_event_marker_sets_event_card():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var target := _HexGrid.neighbors(player_mech.position)[0]
	gs.map_state.add_marker(gs.next_id(&"marker"), int(target.q), int(target.r), &"EVENT")
	battle.context.map_service._check_map_markers(player_mech, target)
	if not gs.map_state.get_markers_at(int(target.q), int(target.r)).is_empty():
		return "事件标记触发后应被移除"
	# set_event_card 动作应已执行（教学战斗事件牌堆非空 -> 事件槽有牌）
	var slot = player_mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return "事件标记触发应设置事件牌到事件区域"
	if slot.equipped_card.def == null or String(slot.equipped_card.def.card_kind) != "event":
		return "事件区域应是事件牌"
	return true


## 驱动 trap_explosion 动作完成（damage_change 暂停在 place_damage_tokens 时自动放置损伤）
func _drive_trap_explosion_damage(battle, trap_expl_id: StringName) -> String:
	var ctx = battle.context
	var ae = ctx.action_engine
	var ar = ctx.action_registry
	var dts = ctx.damage_token_service
	var guard: int = 0
	while guard < 20:
		guard += 1
		var trap_expl = ar.get_action(trap_expl_id)
		if trap_expl == null:
			return ""
		if trap_expl.state == &"completed" or trap_expl.state == &"cancelled":
			return ""
		if trap_expl.state != &"waiting_effect_action":
			return "trap_explosion 异常状态: %s" % String(trap_expl.state)
		var pending: Array = trap_expl.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			ae.continue_action(trap_expl_id, {})
			continue
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
			ae.notify_effect_action_completed(dc_id, trap_expl_id)
		else:
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, trap_expl_id)
	return "trap_explosion 未完成"


## 陷阱标记触发：爆炸。机甲在范围内受2HP伤害+2损伤，陷阱被移除。
func test_trap_marker_explosion():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	# 陷阱放在机甲相邻格（距离1 -> 在爆炸范围内）
	var target := _HexGrid.neighbors(player_mech.position)[0]
	gs.map_state.add_marker(gs.next_id(&"marker"), int(target.q), int(target.r), &"TRAP")
	var hp_before: int = player_mech.current_hp
	# 触发：_check_map_markers 移除陷阱并发起 trap_explosion 动作
	ctx.map_service._check_map_markers(player_mech, target)
	if not gs.map_state.get_markers_at(int(target.q), int(target.r)).is_empty():
		return "陷阱触发后应被移除"
	var trap_expls: Array = ctx.action_registry.get_actions_by_type(&"trap_explosion")
	if trap_expls.is_empty():
		return "陷阱应发起 trap_explosion 动作"
	var trap_expl = trap_expls[0]
	var err: String = _drive_trap_explosion_damage(battle, trap_expl.action_id)
	if err != "":
		return err
	if player_mech.current_hp != hp_before - 2:
		return "陷阱爆炸应使机甲HP-2（前%d 后%d）" % [hp_before, player_mech.current_hp]
	return true


## 陷阱连锁爆炸：相邻陷阱递归扩散。机甲同时被2个陷阱覆盖 -> 累计4HP+4损伤（一次结算）。
func test_trap_chain_explosion():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	# 两个相邻陷阱，都在机甲相邻格（机甲同时被二者覆盖）
	var n := _HexGrid.neighbors(player_mech.position)
	var cell_a: Dictionary = n[0]
	var cell_b: Dictionary = n[1]
	gs.map_state.add_marker(gs.next_id(&"marker"), int(cell_a.q), int(cell_a.r), &"TRAP")
	gs.map_state.add_marker(gs.next_id(&"marker"), int(cell_b.q), int(cell_b.r), &"TRAP")
	var hp_before: int = player_mech.current_hp
	# 触发 A：洪水扩散到 B（A、B相邻），二者都覆盖机甲 -> 累计
	ctx.map_service._check_map_markers(player_mech, cell_a)
	if not gs.map_state.get_markers_at(int(cell_b.q), int(cell_b.r)).is_empty():
		return "连锁爆炸应移除相邻陷阱B"
	var trap_expls: Array = ctx.action_registry.get_actions_by_type(&"trap_explosion")
	if trap_expls.is_empty():
		return "陷阱应发起 trap_explosion 动作"
	var err: String = _drive_trap_explosion_damage(battle, trap_expls[0].action_id)
	if err != "":
		return err
	if player_mech.current_hp != hp_before - 4:
		return "2陷阱连锁覆盖机甲应HP-4（前%d 后%d）" % [hp_before, player_mech.current_hp]
	return true


## 设陷状态：arm 记录位置 -> 机甲离场在原位放陷阱 + 消耗1层
func test_set_trap_arm_and_leave_places_trap():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	# 直接施加2层设陷状态（绕过卡牌流程，测 arm/离场核心逻辑）
	player_mech.add_status({"type": &"SET_TRAP", "stacks": 2, "status_id": gs.next_id(&"status")})
	# arm 在当前位置
	var arm_res: Dictionary = ctx.map_service.arm_set_trap(player_mech.mech_id)
	if not bool(arm_res.get("ok", false)):
		return "arm 失败: %s" % String(arm_res.get("message", ""))
	var old_pos: Dictionary = player_mech.position.duplicate()
	# 再次 arm 同位置应无效
	var arm2: Dictionary = ctx.map_service.arm_set_trap(player_mech.mech_id)
	if bool(arm2.get("ok", false)):
		return "同位置重复 arm 应失败"
	# 移动到相邻格（需动力）
	player_mech.power = 20
	var target := _HexGrid.neighbors(old_pos)[0]
	var mv: Dictionary = ctx.map_service.move_mech_to_hex(player_mech.mech_id, target)
	if not bool(mv.get("ok", false)):
		return "移动失败: %s" % String(mv.get("message", ""))
	# 原位应放置陷阱
	var traps: Array = gs.map_state.get_markers_at(int(old_pos.q), int(old_pos.r))
	var has_trap: bool = false
	for m in traps:
		if m.get("type", &"") == &"TRAP":
			has_trap = true
	if not has_trap:
		return "离场应在原位放置陷阱"
	# 层数 2 -> 1
	var st: Dictionary = player_mech.get_status(&"SET_TRAP")
	if int(st.get("stacks", 0)) != 1:
		return "设陷层数应=1 实际%d" % int(st.get("stacks", 0))
	return true


## 设陷状态可叠加：重复施加累加层数
func test_set_trap_status_stacks():
	var battle := _new_battle(false)
	var gs = battle.context.game_state
	var ctx = battle.context
	var player_mech = gs.get_mech_for_player(&"player")
	ctx.game_actions.add_status({"target_id": player_mech.mech_id, "status": {"type": &"SET_TRAP", "stacks": 2}})
	ctx.game_actions.add_status({"target_id": player_mech.mech_id, "status": {"type": &"SET_TRAP", "stacks": 2}})
	if player_mech.get_status_stacks(&"SET_TRAP") != 4:
		return "叠加后应=4层 实际%d" % player_mech.get_status_stacks(&"SET_TRAP")
	return true


## 事件标记重生：全部消失后在空闲点重生
func test_event_marker_regeneration():
	var battle := _new_battle(true)
	var gs = battle.context.game_state
	# 清空所有事件标记
	var to_remove: Array = []
	for m in gs.map_state.markers:
		if m.get("type", &"") == &"EVENT":
			to_remove.append(m.get("marker_id", &""))
	for mid in to_remove:
		gs.map_state.remove_marker(mid)
	if gs.map_state.has_event_markers():
		return "清空后应无事件标记"
	# 重生
	battle.context.map_service._maybe_regenerate_event_markers(gs)
	var regen := 0
	for m in gs.map_state.markers:
		if m.get("type", &"") == &"EVENT":
			regen += 1
	if regen == 0:
		return "事件标记应重生至少1个"
	# 被机甲占据的点不应有标记（一次性跳过）
	for m in gs.map_state.markers:
		if m.get("type", &"") != &"EVENT":
			continue
		if battle.context.map_service._hex_occupied_by_mech(gs, int(m.get("q", 0)), int(m.get("r", 0))):
			return "被机甲占据的事件点不应重生标记"
	# 重生数应=未被占据的事件点数
	var free_points := 0
	for p in gs.map_state.marker_points:
		if p.get("type", &"") != &"EVENT":
			continue
		if not battle.context.map_service._hex_occupied_by_mech(gs, int(p.get("q", 0)), int(p.get("r", 0))):
			free_points += 1
	if regen != free_points:
		return "重生数应=%d（空闲事件点）实际%d" % [free_points, regen]
	return true


## 事件标记未全部消失时不重生
func test_event_marker_no_regen_when_exist():
	var battle := _new_battle(true)
	var gs = battle.context.game_state
	var before := 0
	for m in gs.map_state.markers:
		if m.get("type", &"") == &"EVENT":
			before += 1
	if before == 0:
		return "开局应有事件标记"
	battle.context.map_service._maybe_regenerate_event_markers(gs)
	var after := 0
	for m in gs.map_state.markers:
		if m.get("type", &"") == &"EVENT":
			after += 1
	if after != before:
		return "仍有事件标记时不应重生（前%d 后%d）" % [before, after]
	return true
