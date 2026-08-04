## MarkerService.gd - 地图标记触发服务
##
## 处理地图标记的效果执行（触发由 MapService._check_map_markers 驱动）：
## - 金币标记：投1骰，按映射得金币（1-3→3、4-5→4、6→6）
## - 事件标记：抽1张事件牌并设置（效果待实装，当前仅文本）
## - 陷阱标记：发起 trap_explosion 动作（洪水扩散+逐机甲HP/损伤结算）
##
## 标记的查找/移除/重生由 MapState/MapService 负责，本服务只执行效果。
class_name MarkerService
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")

var context = null  # type: GameContext


## 触发指定标记（执行其效果）。不从 map_state 移除--移除由调用方负责。
## marker: { "marker_id", "q", "r", "cell_id", "type", "source_point_id" }
func trigger_marker(mech_id: StringName, marker: Dictionary) -> Dictionary:
	var marker_type: StringName = marker.get("type", &"")
	match marker_type:
		&"GOLD":
			return _trigger_gold_marker(mech_id, marker)
		&"EVENT":
			return _trigger_event_marker(mech_id, marker)
		&"TRAP":
			return _trigger_trap_marker(mech_id, marker)
		_:
			return {"ok": true, "message": "未知标记类型，无事发生"}


## 旧入口兼容：按坐标查找并触发该格所有标记（查找+移除）。
## 保留供 legacy GameActions 调用；新流程走 MapService._check_map_markers。
func trigger_marker_at(mech_id: StringName, hex: Dictionary) -> Dictionary:
	var gs = context.game_state
	var q: int = int(hex.get("q", 0))
	var r: int = int(hex.get("r", 0))
	var here: Array = gs.map_state.get_markers_at(q, r)
	if here.is_empty():
		return {"ok": true, "message": "无标记"}
	var to_trigger: Array = here.duplicate(true)
	for m: Dictionary in to_trigger:
		gs.map_state.remove_marker(m.get("marker_id", &""))
	var last: Dictionary = {"ok": true}
	for m: Dictionary in to_trigger:
		last = trigger_marker(mech_id, m)
	return last


## ── 标记效果实现 ──


## 金币标记：投1个D6，按映射得金币（1-3→3、4-5→4、6→6）
func _trigger_gold_marker(mech_id: StringName, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	var player_id: StringName = _get_owner_of_mech(mech_id)
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "找不到玩家"}

	var rng = context.rng if (context != null and context.rng != null) else null
	var roll: int = (rng.randi_range(1, _GameConfig.GOLD_MARKER_D6) if rng != null else (randi() % _GameConfig.GOLD_MARKER_D6 + 1))
	var gold: int = _GameConfig.gold_marker_payout(roll)
	player.gold += gold

	gs.write_log(&"marker_gold", {
		"mech_id": String(mech_id),
		"player_id": String(player_id),
		"roll": roll,
		"gold_gained": gold,
	})
	return {"ok": true, "type": "gold", "roll": roll, "gold_gained": gold}


## 事件标记：抽1张事件牌并设置到机甲事件槽。
## 效果待实装，当前仅记录文本。
func _trigger_event_marker(mech_id: StringName, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	gs.write_log(&"marker_event", {
		"mech_id": String(mech_id),
		"message": "事件标记触发（效果待实装，无事发生）",
	})
	return {"ok": true, "type": "event"}


## 陷阱标记：发起陷阱爆炸动作（洪水扩散+逐机甲结算，HP+损伤经 damage_change 路由）。
## 触发陷阱已由调用方移除；本服务只发起爆炸，爆炸内的连锁移除由 trap_explosion 动作负责。
func _trigger_trap_marker(mech_id: StringName, marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	gs.write_log(&"marker_trap", {
		"mech_id": String(mech_id),
		"q": int(marker.get("q", 0)),
		"r": int(marker.get("r", 0)),
	})
	if context.action_service != null:
		context.action_service.execute(&"trap_explosion", {
			"trigger_q": int(marker.get("q", 0)),
			"trigger_r": int(marker.get("r", 0)),
			"trigger_mech_id": mech_id,
			"source": {"mech_id": mech_id},
		})
	return {"ok": true, "type": "trap"}


## ── 内部方法 ──


## 获取机甲所属玩家ID
func _get_owner_of_mech(mech_id: StringName) -> StringName:
	var gs = context.game_state
	var mech = gs.mechs.get(mech_id)
	if mech:
		return mech.owner_player_id
	return &""
