## MarkerService.gd - 地图标记触发服务
##
## 处理地图标记的效果执行（触发由 MapService._check_map_markers 驱动）：
## - 金币标记：投1骰，按映射得金币（1-3→3、4-5→4、6→6）
## - 事件标记：抽1张事件牌并设置（_trigger_event_marker 预抽并记录事件牌名，日志显示生效事件）
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


## ── 通用「标记生效」atom 模块（效果 _seq 链串行触发用）──
## 供「标记再生效/标记交互」类效果（如墨尘 pilot_080 移至分支）在效果 _seq 链中
## 串行触发标记生效：返回单个 atom（由 TimingEngine._continue_seq_effect_actions 执行），
## 事件标记 -> EXECUTE_SET_EVENT_CARD（抽事件牌堆顶1张设到指定机甲，完整流程）；
## 金币标记 -> GAIN_GOLD_BY_DIE（标准 1-3/4-5/6 分支掷骰获金）；
## 陷阱标记 -> EXECUTE_TRAP_EXPLOSION（标准爆炸流程，含连锁）。
## 与 trigger_marker（正常移动落格触发，顶层执行）是同一套标记语义的两种驱动方式；
## 复用时直接把本 atom 追加进效果 _seq 即可，无需与具体卡牌/机师绑定。
func build_marker_trigger_atom(marker: Dictionary, mech_id: StringName, player_id: StringName) -> Dictionary:
	if marker.is_empty():
		return {}
	var marker_type: StringName = marker.get("type", &"")
	var marker_q: int = int(marker.get("q", 0))
	var marker_r: int = int(marker.get("r", 0))
	if player_id == &"":
		player_id = _get_owner_of_mech(mech_id)
	if marker_type == &"EVENT":
		return {"type": &"EXECUTE_SET_EVENT_CARD", "params": {
			"mech_id": mech_id,
			"source": {"mech_id": mech_id, "player_id": player_id},
		}}
	if marker_type == &"GOLD":
		return {"type": &"GAIN_GOLD_BY_DIE", "params": {
			"player_id": player_id, "reason": &"GOLD_MARKER",
			"branches": [[1, 3, 3], [4, 5, 4], [6, 6, 6]],
		}}
	if marker_type == &"TRAP":
		return {"type": &"EXECUTE_TRAP_EXPLOSION", "params": {
			"trigger_q": marker_q, "trigger_r": marker_r, "trigger_mech_id": mech_id,
		}}
	return {}


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
	# 统一走 gain_gold 获金时点（GAIN_GOLD_AFTER 等，_fire_gold_timings 虚拟 action fire），
	# 使「他方获金」类效果（如维罗妮卡获金分半）能监听到金币标记来源；不直接 gold += 绕过时点。
	# reason=GOLD_MARKER 供监听器区分来源；roll 已用 context.rng（PvP 双端确定性），gain_gold 不耗 rng。
	if context.game_actions != null:
		context.game_actions.gain_gold({"player_id": player_id, "amount": gold, "reason": &"GOLD_MARKER"})
	else:
		player.gold += gold

	gs.write_log(&"marker_gold", {
		"mech_id": String(mech_id),
		"player_id": String(player_id),
		"roll": roll,
		"gold_gained": gold,
	})
	return {"ok": true, "type": "gold", "roll": roll, "gold_gained": gold}


## 事件标记：拾取后立即将事件牌堆顶1张设置到机甲事件区域（set_event_card 动作：
## 顶掉旧牌/注册效果/初始化计时；牌堆耗尽仅记日志）。效果即刻生效（瞬时+持续）。
## 预抽事件牌堆顶1张（pop_front 确定性，PvP 双/三端同一移动操作下抽到同一张），
## 把事件牌信息写入 marker_event 日志供 UI 显示"此次生效的事件"，并把该牌传给
## set_event_card 动作（其 _step_resolve_card 优先用 record.event_card_id，不再二次抽取）。
func _trigger_event_marker(mech_id: StringName, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	var ev_card_id: StringName = &""
	var ev_name := ""
	if context.deck_service != null:
		var ev_drawn: Array = context.deck_service.draw_from_deck(&"event_deck", 1)
		if not ev_drawn.is_empty():
			ev_card_id = StringName(String(ev_drawn[0]))
			var ev_card = gs.get_card(ev_card_id)
			if ev_card != null and ev_card.def != null:
				ev_name = String(ev_card.def.display_name)
	gs.write_log(&"marker_event", {
		"mech_id": String(mech_id),
		"card_id": String(ev_card_id),
		"card_name": ev_name,
	})
	if context.action_service != null:
		var ev_params: Dictionary = {"mech_id": mech_id, "source": {"mech_id": mech_id}}
		if ev_card_id != &"":
			ev_params["event_card_id"] = ev_card_id
		context.action_service.execute(&"set_event_card", ev_params)
	return {"ok": true, "type": "event", "event_card_id": ev_card_id}


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
