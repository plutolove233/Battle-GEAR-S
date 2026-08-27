## MapService.gd — 地图移动服务
##
## 负责：
## - 机甲移动验证与执行
## - 路径可达性检查（基于 BattleMath BFS）
## - 移动动力消耗计算
class_name MapService
extends RefCounted

var context = null  # type: GameContext

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


## 移动机甲到目标六角格
## 验证可移动 → 路径可达 → 计算消耗 → 扣除动力 → 更新位置 → 触发钩子
## power_budget: 可选的动力上限（用于回避/疾行等"使用部分动力移动"的效果）。
##   为 -1 时不限制（使用机甲当前全部动力）；否则可达性与消耗都按 min(机甲动力, power_budget) 判断，
##   但实际扣除仍从机甲动力中扣除（剩余动力保留）。
func move_mech_to_hex(mech_id: StringName, target: Dictionary, power_budget: int = -1) -> Dictionary:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)

	# ── 1. 验证机甲可以移动 ──
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	if not mech.can_move():
		return {"ok": false, "message": "机甲无法移动（动力不足或被锁定）"}
	if mech.power <= 0:
		return {"ok": false, "message": "动力不足"}
	if mech.destroyed:
		return {"ok": false, "message": "机甲已被摧毁"}

	# 本次移动可使用的动力上限
	var avail_power: int = mech.power
	if power_budget >= 0:
		avail_power = min(mech.power, power_budget)

	# ── 2. 验证目标格在地图上 ──
	if not gs.map_state.has_cell(target):
		return {"ok": false, "message": "目标格不在地图上"}

	# ── 3. 验证目标格没有被其他机甲占据 ──
	for other_id: StringName in gs.mechs:
		var other: MechState = gs.mechs[other_id]
		if other_id != mech_id and not other.destroyed:
			if HexGrid.key(other.position) == HexGrid.key(target):
				return {"ok": false, "message": "目标格已被占据"}

	# ── 4. 验证路径可达（BFS） ──
	var map_tiles: Array = []
	for cell_key: String in gs.map_state.cells:
		map_tiles.append(gs.map_state.cells[cell_key].to_dict())

	if not BattleMath.can_move(mech.position, target, avail_power, map_tiles):
		return {"ok": false, "message": "目标格不可达或超出动力范围"}

	# ── 5. 计算动力消耗（基础地形每格消耗1点） ──
	var distance: int = HexGrid.distance(mech.position, target)
	var power_cost: int = _calculate_power_cost(mech.position, target, gs)

	if power_cost > avail_power:
		return {"ok": false, "message": "动力不足以移动到目标格"}

	# ── 6. 扣除动力 ──
	if context.game_actions:
			context.game_actions.spend_power({"mech_id": mech_id, "amount": power_cost})
	else:
		mech.power -= power_cost

	# ── 7. 更新位置 ──
	var old_position: Dictionary = mech.position.duplicate()
	mech.position = {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}

	# 累计本回合移动格数（effect_012/013 帝国腿主动效果阈值用）。
	# net_move 路径（PvP 人类移动 / battle.move_unit）不走 basic_move 动作，
	# 故在此按 hex 距离补计；action 路径（basic_move）逐格 +=1 已自洽，两路径互不重叠。
	mech.cells_moved_this_turn += distance

	# ── 8. 触发移动钩子 ──
	_fire_hook(_EffectConst.HOOK_MECH_MOVED, {
		"mech_id": String(mech_id),
		"from": old_position,
		"to": target,
		"power_spent": power_cost,
	})

	# ── 9. 设陷状态离场放置 + 检查目标格地图标记 ──
	_check_set_trap_leave(mech, old_position)
	_check_map_markers(mech, target)

	gs.write_log(&"mech_moved", {
		"mech_id": String(mech_id),
		"from_q": int(old_position.get("q", 0)),
		"from_r": int(old_position.get("r", 0)),
		"to_q": int(target.get("q", 0)),
		"to_r": int(target.get("r", 0)),
		"power_cost": power_cost,
	})
	return {"ok": true, "mech_id": mech_id, "position": target, "power_cost": power_cost}


## 计算到目标格的最低动力路径（不包含起点，包含终点）。
## GREEN=2、NORMAL=1、RED不可通过；其他机甲所在格不可进入。
func find_optimal_path(mech_id: StringName, target: Dictionary, power_budget: int) -> Array[Dictionary]:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null or not gs.map_state.has_cell(target):
		return []
	var start: Dictionary = mech.position.duplicate()
	var start_key: String = HexGrid.key(start)
	var target_key: String = HexGrid.key(target)
	if start_key == target_key:
		return []

	# 通用移动消耗参数（效果元数据 move_cost_mod 驱动）：持有者玩家绿格耗1（含光环转化绿格），
	# 敌方仍耗2；光环格（各持有者+6邻居，红格除外）视为绿格。按需派生（不存状态）。
	var mover_player: StringName = mech.owner_player_id
	var _mcp: Dictionary = resolve_move_cost_params(mover_player)
	var green_cost: int = int(_mcp["green_cost"])
	var aura_cells: Dictionary = _mcp["aura_cells"]

	var blocked: Dictionary = {}
	for other_id: StringName in gs.mechs:
		var other: MechState = gs.mechs[other_id]
		if other_id != mech_id and not other.destroyed:
			blocked[HexGrid.key(other.position)] = true

	# 优先直线：起点->终点的六边形立方插值直线最符合直觉（不绕远）。
	# 若该直线全程可通行（未被占/非红区/存在）且耗动力在内，直接返回；否则回退 Dijkstra 绕路。
	var straight: Array[Dictionary] = HexGrid.line(start, target)
	if not straight.is_empty():
		var total_cost := 0
		var straight_ok := true
		for cell_hex: Dictionary in straight:
			var ck: String = HexGrid.key(cell_hex)
			if blocked.has(ck):
				straight_ok = false
				break
			var sc = gs.map_state.cells.get(ck)
			if sc == null:
				straight_ok = false
				break
			var sterrain: StringName = _get_cell_terrain(sc)
			if sterrain == &"RED" or sterrain == &"blocked":
				straight_ok = false
				break
			total_cost += green_cost if sterrain == &"GREEN" or sterrain == &"rough" or aura_cells.has(ck) else 1
			if total_cost > power_budget:
				straight_ok = false
				break
		if straight_ok:
			return straight

	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0}]
	var costs: Dictionary = {start_key: 0}
	var previous: Dictionary = {}
	while not frontier.is_empty():
		frontier.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["cost"]) < int(b["cost"]))
		var current_entry: Dictionary = frontier.pop_front()
		var current: Dictionary = current_entry["hex"]
		var current_key: String = HexGrid.key(current)
		var current_cost: int = int(current_entry["cost"])
		if current_cost != int(costs.get(current_key, 1 << 30)):
			continue
		if current_key == target_key:
			break
		for neighbor: Dictionary in HexGrid.neighbors(current):
			var neighbor_key: String = HexGrid.key(neighbor)
			if blocked.has(neighbor_key):
				continue
			var cell = gs.map_state.cells.get(neighbor_key)
			if cell == null:
				continue
			var terrain: StringName = _get_cell_terrain(cell)
			if terrain == &"RED" or terrain == &"blocked":
				continue
			var step_cost: int = green_cost if terrain == &"GREEN" or terrain == &"rough" or aura_cells.has(neighbor_key) else 1
			var next_cost: int = current_cost + step_cost
			if next_cost > power_budget or next_cost >= int(costs.get(neighbor_key, 1 << 30)):
				continue
			costs[neighbor_key] = next_cost
			previous[neighbor_key] = current_key
			frontier.append({"hex": neighbor, "cost": next_cost})

	if not costs.has(target_key):
		return []
	var reversed_path: Array[Dictionary] = []
	var cursor: String = target_key
	while cursor != start_key:
		var parts: PackedStringArray = cursor.split(",")
		reversed_path.append({"q": int(parts[0]), "r": int(parts[1])})
		if not previous.has(cursor):
			return []
		cursor = previous[cursor]
	reversed_path.reverse()
	return reversed_path


## ── 通用移动消耗参数（效果元数据 move_cost_mod 驱动，不绑机师ID） ──
## 返回 {"green_cost": int, "aura_cells": {cell_key: true}}：
##   green_cost -- mover 玩家的绿格移动消耗（默认 2；场上该玩家效果声明 "green_cost" 时取最小）
##   aura_cells -- 场上所有效果的光环格并集（"aura_shape"="adjacent_6"=持有者所在格+6邻居，
##                 红格除外）；光环格对【所有】玩家视为绿格（光环全局、折扣玩家作用域）
## 扫描场上所有机甲的【全部槽位】牌（机师/装备）聚合效果定义 move_cost_mod 元数据：
## 牌在场上机甲槽位=效果活跃，卸牌/机甲死亡后槽位清空自然失效，无需监听/清理。
## 任何牌的效果声明 move_cost_mod（ActionEffect 字段）即自动生效，复用时复制效果定义改元数据即可。
## 调用点：find_optimal_path / basic_move / single_move 动力扣除 / RangeCalculator 可达性 / 光环渲染。
func resolve_move_cost_params(mover_player_id) -> Dictionary:
	var result: Dictionary = {"green_cost": 2, "aura_cells": {}}
	var gs: GameState = context.game_state
	if gs == null or gs.mechs == null:
		return result
	var mod_index: Dictionary = _ActionPilotEffects.get_pilot_move_mod_index(context)
	if mod_index.is_empty():
		return result
	var mover_pid: String = String(mover_player_id) if mover_player_id != null else ""
	var ms = gs.map_state
	var green_cost: int = 2
	var aura_cells: Dictionary = {}
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.destroyed or m.slots == null:
			continue
		var holder_is_mover: bool = String(m.owner_player_id) == mover_pid
		for slot_id: StringName in m.slots:
			var slot = m.slots[slot_id]
			if slot == null:
				continue
			var card = slot.equipped_card
			if card == null or card.def == null:
				continue
			var mods: Array = mod_index.get(card.def.card_id, [])
			if mods.is_empty():
				continue
			for mod: Dictionary in mods:
				if mod.is_empty():
					continue
				# 绿格折扣：仅效果持有者玩家的机甲移动时生效（多效果取最小）
				if holder_is_mover and mod.has("green_cost"):
					green_cost = min(green_cost, int(mod["green_cost"]))
				# 光环格：按形状计算，全场并集（红格除外）
				if StringName(mod.get("aura_shape", &"")) == &"adjacent_6":
					_add_aura_cell(aura_cells, ms, m.position)
					for n: Dictionary in HexGrid.neighbors(m.position):
						_add_aura_cell(aura_cells, ms, n)
	result["green_cost"] = green_cost
	result["aura_cells"] = aura_cells
	return result


## 攻击/武器射程用的光环绿格集合（全局：场上所有 move_cost_mod 效果的 aura 并集，红格除外）。
## 攻击路径调用 RangeCalculator.is_in_weapon_range / get_weapon_reachable_hexes 时传入此集合，
## 使光环格在武器射程 BFS 中视为绿格（耗 2 射程预算，全场无折扣、含光环持有者自己的攻击；
## 天然绿格本就耗 2 不变；红格照旧阻挡）。与移动不同：移动的 green_cost 折扣仅对效果持有者生效，
## 攻击恒为 2。传 null mover 表示「不取任何玩家折扣」，仅要全局 aura。
func get_attack_aura_cells() -> Dictionary:
	return resolve_move_cost_params(null)["aura_cells"]


## 攻击路径障碍格集合：场上所有其他存活机甲所在格（{cell_key: true}）。
## 机甲（含陷落"不能被选为目标"的机甲--如同消失但依然作为障碍）阻挡攻击 BFS 穿过：
## 其所在格可作终点（可被指向/命中），但路径不可经其继续向外扩展，打后面的目标须绕路。
## exclude_mech_id：攻击方自身（其格为 BFS origin，无需排除；传空则全部机甲格都算）。
## 调用方传给 RangeCalculator.is_in_weapon_range / get_weapon_reachable_hexes 的 blocked_keys。
## 攻击路径障碍格集合：**陷落（cannot_be_targeted）机甲**所在格 {key: true}。
## 规则书未规定普通机甲阻挡攻击路径（普通机甲可被指向/命中，BFS 照常穿过）；
## 仅"机甲如同消失、不能被指定为目标"的陷落机甲依然作为障碍（打后面的须绕开，
## 参考格雷厄姆 p057 移陷 BFS 语义）。exclude_mech_id 排除攻击方自身。
func get_attack_blocked_keys(exclude_mech_id: StringName = &"") -> Dictionary:
	var blocked: Dictionary = {}
	var gs: GameState = context.game_state
	if gs == null or gs.mechs == null:
		return blocked
	for mid: StringName in gs.mechs:
		if String(mid) == String(exclude_mech_id):
			continue
		var m = gs.mechs[mid]
		if m == null or m.destroyed or m.current_hp <= 0:
			continue
		if not m.has_status(&"cannot_be_targeted"):
			continue
		var pos: Dictionary = m.position
		if pos == null or pos.is_empty():
			continue
		blocked[HexGrid.key(pos)] = true
	return blocked


## 光环格并入集合（格不存在/红格除外；key 与 HexGrid.key 一致 "q,r"）
func _add_aura_cell(aura_cells: Dictionary, ms, hex: Dictionary) -> void:
	if ms == null:
		return
	var key: String = HexGrid.key(hex)
	var cell = ms.cells.get(key)
	if cell == null:
		return
	if _get_cell_terrain(cell) == &"RED":
		return  # 红格除外
	aura_cells[key] = true


## 基础移动的“更新位置”阶段调用：这里只提交位置，不再次扣动力。
func commit_basic_move(mech_id: StringName, target: Dictionary, power_cost: int) -> Dictionary:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	var old_position: Dictionary = mech.position.duplicate()
	mech.position = {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}
	_fire_hook(_EffectConst.HOOK_MECH_MOVED, {
		"mech_id": String(mech_id), "from": old_position, "to": target, "power_spent": power_cost,
	})
	# 设陷状态离场放置（离开已记录位置）+ 触发并弃置该格所有地图标记（机甲与标记不能共存）。
	_check_set_trap_leave(mech, old_position)
	_check_map_markers(mech, target)
	gs.write_log(&"mech_moved", {
		"mech_id": String(mech_id),
		"from_q": int(old_position.get("q", 0)), "from_r": int(old_position.get("r", 0)),
		"to_q": int(target.get("q", 0)), "to_r": int(target.get("r", 0)),
		"power_cost": power_cost,
	})
	return {"ok": true, "position": target, "power_cost": power_cost}


## ── 内部方法 ──


## 计算移动动力消耗
## 基础地形每格消耗1点，特殊地形可增加消耗
func _calculate_power_cost(origin: Dictionary, target: Dictionary, gs: GameState) -> int:
	var base_cost: int = HexGrid.distance(origin, target)

	# 检查目标格是否有特殊地形
	var target_cell = gs.map_state.get_cell(target)
	var terrain: StringName = _get_cell_terrain(target_cell)
	match terrain:
		&"rough", &"GREEN":
			return base_cost + 1  # 粗糙地形额外消耗1点
		&"blocked", &"RED":
			return 999  # 不可通过
		_:
			return base_cost


func _get_cell_terrain(cell) -> StringName:
	if cell == null:
		return &"normal"
	if cell is _MapCellState:
		return cell.terrain
	if typeof(cell) == TYPE_DICTIONARY:
		return cell.get("terrain", &"normal")
	return &"normal"


## 检查目标格的地图标记：机甲到达即弃置该格所有标记并执行效果。
## 标记与机甲不能共存，故机甲进入含标记的格子会触发全部标记。
## 一格可有多个标记（不同类型共存），全部触发后检查事件标记重生。
func _check_map_markers(mech: MechState, target: Dictionary) -> void:
	var gs: GameState = context.game_state
	var q: int = int(target.get("q", 0))
	var r: int = int(target.get("r", 0))
	var markers_here: Array = gs.map_state.get_markers_at(q, r)
	if markers_here.is_empty():
		return
	# 先全部弃置（从 map_state 移除），再逐个执行效果，避免触发中再次查询到自身。
	var to_trigger: Array = markers_here.duplicate(true)
	for m: Dictionary in to_trigger:
		gs.map_state.remove_marker(m.get("marker_id", &""))
	for m: Dictionary in to_trigger:
		if context.marker_service:
			context.marker_service.trigger_marker(mech.mech_id, m)
	# 事件标记重生检查（所有事件标记消失后立即重生，被占据点一次性跳过）
	_maybe_regenerate_event_markers(gs)


## 设陷状态"设陷"按钮：记录机甲当前位置（arm）。机甲离开该位置后在原位放陷阱+消耗1层。
## armed_cell 存于 SET_TRAP 状态字典。一位置同时只 arm 1 个（再点同位置无效，须先移动）。
func arm_set_trap(mech_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	var st: Dictionary = mech.get_status(&"SET_TRAP")
	if st.is_empty() or int(st.get("stacks", 0)) <= 0:
		return {"ok": false, "message": "无可用设陷层数"}
	var cur: String = HexGrid.key(mech.position)
	if String(st.get("armed_cell", "")) == cur:
		return {"ok": false, "message": "已在当前位置设陷，请先移动后再设陷"}
	st["armed_cell"] = cur
	gs.write_log(&"set_trap_armed", {"mech_id": String(mech_id), "cell": cur})
	return {"ok": true, "cell": cur}


## 设陷状态离场放置：机甲离开已记录位置时在原位放置1陷阱标记并消耗1层设陷状态。
func _check_set_trap_leave(mech: MechState, old_position: Dictionary) -> void:
	var gs: GameState = context.game_state
	var st: Dictionary = mech.get_status(&"SET_TRAP")
	if st.is_empty():
		return
	var armed: String = String(st.get("armed_cell", ""))
	if armed == "":
		return
	if armed != HexGrid.key(old_position):
		return  # 未离开已记录位置
	var parts := armed.split(",")
	var q: int = int(parts[0])
	var r: int = int(parts[1])
	gs.map_state.add_marker(gs.next_id(&"marker"), q, r, &"TRAP")
	gs.write_log(&"marker_trap_placed", {"cell_id": armed, "source": &"set_trap_leave"})
	# 消耗1层；归0则移除状态（注销回合末清除监听器）
	st["armed_cell"] = ""
	st["stacks"] = int(st.get("stacks", 1)) - 1
	if int(st["stacks"]) <= 0 and context.game_actions != null:
		context.game_actions.remove_status({"target_id": mech.mech_id, "status_type": &"SET_TRAP"})


## 事件标记重生：当地图上无事件标记时，在所有空闲事件标记点上重新放置事件标记。
func _maybe_regenerate_event_markers(gs: GameState) -> void:
	var map_state = gs.map_state
	if map_state.has_event_markers():
		return
	var regen_count: int = 0
	for point: Dictionary in map_state.marker_points:
		if point.get("type", &"") != &"EVENT":
			continue
		var pq: int = int(point.get("q", 0))
		var pr: int = int(point.get("r", 0))
		# 被机甲占据 -> 一次性跳过（机甲离开后也不补放，等下一次"全部消失"）
		if _hex_occupied_by_mech(gs, pq, pr):
			continue
		# 防御性：该点已有标记则跳过
		if not map_state.get_markers_at(pq, pr).is_empty():
			continue
		map_state.add_marker(gs.next_id(&"marker"), pq, pr, &"EVENT", point.get("point_id", &""))
		regen_count += 1
	if regen_count > 0:
		gs.write_log(&"event_markers_regenerated", {"count": regen_count})


## 指定格是否被任一未摧毁机甲占据
func _hex_occupied_by_mech(gs: GameState, q: int, r: int) -> bool:
	for m_id: StringName in gs.mechs:
		var m: MechState = gs.mechs[m_id]
		if m.destroyed:
			continue
		if int(m.position.get("q", 0)) == q and int(m.position.get("r", 0)) == r:
			return true
	return false


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
