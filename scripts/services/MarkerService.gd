## MarkerService.gd — 地图标记触发服务
##
## 处理地图标记的触发逻辑：
## - 金币标记：投骰获得金币
## - 事件标记：翻开事件牌并设置
## - 陷阱标记：触发爆炸，中心和相邻1格机甲受伤
class_name MarkerService
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")

var context = null  # type: GameContext


## 触发指定坐标的标记
## 当机甲移动到有标记的格子时调用
func trigger_marker_at(mech_id: StringName, hex: Dictionary) -> Dictionary:
	# 查找该坐标的标记
	var marker = _find_marker_at(hex)
	if marker == null:
		return {"ok": true, "message": "无标记"}

	var result: Dictionary = {}

	match marker.get("type", &""):
		&"GOLD":
			result = _trigger_gold_marker(mech_id, marker)
		&"EVENT":
			result = _trigger_event_marker(mech_id, marker)
		&"TRAP":
			result = _trigger_trap_marker(mech_id, hex, marker)
		_:
			result = {"ok": true, "message": "未知标记类型"}

	# 标记已触发，移除
	_remove_marker(marker)

	return result


## ── 标记触发实现 ──


## 金币标记：投1个D6，获得对应金币
func _trigger_gold_marker(mech_id: StringName, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	var player_id: StringName = _get_owner_of_mech(mech_id)
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "找不到玩家"}

	var roll: int = randi() % _GameConfig.GOLD_MARKER_D6 + 1
	player.gold += roll

	gs.write_log(&"marker_gold", {
		"mech_id": String(mech_id),
		"roll": roll,
		"gold_gained": roll,
	})
	return {"ok": true, "type": "gold", "roll": roll, "gold_gained": roll}


## 事件标记：从事件牌堆抽1张并设置到机甲事件槽
func _trigger_event_marker(mech_id: StringName, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}

	# 从事件牌堆抽1张
	var drawn: Array[StringName] = context.deck_service.draw_from_deck(&"event_deck", 1)
	if drawn.is_empty():
		return {"ok": false, "message": "事件牌堆为空"}

	var card_id: StringName = drawn[0]
	var card = gs.get_card(card_id)
	if card:
		card.zone = &"event_slot"
		card.owner_player_id = _get_owner_of_mech(mech_id)

	# 设置到事件槽
	if mech.slots.has(&"event_1"):
		mech.slots[&"event_1"].equipped_card = card

	# 注册效果
	if context.effect_registry and card:
		context.effect_registry.register_card(card)

	gs.write_log(&"marker_event", {
		"mech_id": String(mech_id),
		"card_id": String(card_id),
	})
	return {"ok": true, "type": "event", "card_id": String(card_id)}


## 陷阱标记：中心格和相邻1格内的机甲受伤
func _trigger_trap_marker(mech_id: StringName, hex: Dictionary, _marker: Dictionary) -> Dictionary:
	var gs = context.game_state
	var damage: int = _GameConfig.TRAP_BLAST_DAMAGE
	var tokens: int = _GameConfig.TRAP_BLAST_TOKENS

	# 找到爆炸范围内的所有机甲
	var affected_mechs: Array[StringName] = []
	for m_id: StringName in gs.mechs:
		var m = gs.mechs[m_id]
		if m.destroyed:
			continue
		var dist: int = _HexGrid.distance(hex, m.position)
		if dist <= _GameConfig.TRAP_BLAST_RANGE:
			affected_mechs.append(m_id)

	# 对每个受影响的机甲造成伤害
	for affected_id: StringName in affected_mechs:
		var affected_mech = gs.mechs.get(affected_id)
		if affected_mech:
			affected_mech.current_hp = max(0, affected_mech.current_hp - damage)
			if tokens > 0:
				context.damage_token_service.place_damage_tokens({
					"mech_id": affected_id,
					"count": tokens,
					"source": "trap",
				})
			if affected_mech.current_hp <= 0:
				gs.destroy_mech(affected_id, "trap")

	gs.write_log(&"marker_trap", {
		"mech_id": String(mech_id),
		"damage": damage,
		"affected_count": affected_mechs.size(),
	})
	return {"ok": true, "type": "trap", "damage": damage, "affected_count": affected_mechs.size()}


## ── 内部方法 ──


## 查找指定坐标的标记
func _find_marker_at(hex: Dictionary) -> Dictionary:
	var map_state = context.game_state.map_state
	for marker in map_state.markers:
		if int(marker.get("q", 0)) == int(hex.get("q", 0)) and int(marker.get("r", 0)) == int(hex.get("r", 0)):
			return marker
	return {}


## 移除标记
func _remove_marker(marker: Dictionary) -> void:
	var map_state = context.game_state.map_state
	map_state.markers.erase(marker)


## 获取机甲所属玩家ID
func _get_owner_of_mech(mech_id: StringName) -> StringName:
	var gs = context.game_state
	var mech = gs.mechs.get(mech_id)
	if mech:
		return mech.owner_player_id
	return &""
