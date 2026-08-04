## MapState.gd - 地图状态
##
## 存储六边形网格地图的格子信息和标记。
##
## 标记分两层：
##   1. marker_points（地图标记点）：常驻贴图，仅用于生成标记，
##      不影响移动/战斗。开局设置 8 金币点 + 8 事件点（陷阱无标记点）。
##      金币点开局生成 1 枚金币标记后不再刷新；
##      事件点在地图上所有事件标记消失后立即重生（被机甲占据的点一次性跳过）。
##   2. markers（地图标记）：可触发，机甲进入其所在格即弃置并执行效果。
##      一个格子上可有多个标记（不同类型可共存）。
##      标记与机甲（实体）不能同时存在于一个格子：机甲到达即触发。
class_name MapState
extends RefCounted

const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")

## 地图格子：HexGrid.key(hex) -> MapCellState
var cells: Dictionary = {}

## 地图标记列表（Array[Dictionary]，兼容旧接口）
## 每个标记: { "marker_id": StringName, "q": int, "r": int, "cell_id": String,
##            "type": StringName (GOLD/EVENT/TRAP), "source_point_id": StringName }
var markers: Array[Dictionary] = []

## 地图标记点（常驻，仅用于生成标记，不影响移动/战斗）
## 每个: { "point_id": StringName, "q": int, "r": int, "cell_id": String,
##        "type": StringName (GOLD/EVENT) }
var marker_points: Array[Dictionary] = []


## 添加一个格子
func add_cell(q: int, r: int, terrain: StringName = &"NORMAL") -> void:
	var key: String = "%s,%s" % [q, r]
	var cell := _MapCellState.new(key, q, r, terrain)
	cells[key] = cell


## 获取指定坐标的格子信息（返回 Dictionary，兼容旧接口）
func get_cell(hex: Dictionary) -> Dictionary:
	var key: String = "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	var cell = cells.get(key)
	if cell:
		return cell.to_dict()
	return {}


## 获取指定坐标的 MapCellState 对象
func get_cell_state(hex: Dictionary):
	var key: String = "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	return cells.get(key, null)


## 格子是否存在
func has_cell(hex: Dictionary) -> bool:
	var key: String = "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	return cells.has(key)


## 设置格子地形（配置阶段用）
func set_cell_terrain(q: int, r: int, terrain: StringName) -> void:
	var key: String = "%s,%s" % [q, r]
	var cell = cells.get(key)
	if cell:
		cell.terrain = terrain


# ═══════════════════════════════════════════
# 标记点（marker_points）
# ═══════════════════════════════════════════

## 添加一个标记点
func add_marker_point(point_id: StringName, q: int, r: int, type: StringName) -> void:
	var cell_id: String = "%s,%s" % [q, r]
	marker_points.append({
		"point_id": point_id,
		"q": q,
		"r": r,
		"cell_id": cell_id,
		"type": type,
	})


## 获取指定坐标的标记点（通常 0 或 1 个）
func get_marker_points_at(q: int, r: int) -> Array:
	var result: Array = []
	for point in marker_points:
		if int(point.get("q", 0)) == q and int(point.get("r", 0)) == r:
			result.append(point)
	return result


# ═══════════════════════════════════════════
# 标记（markers）
# ═══════════════════════════════════════════

## 添加标记
## source_point_id: 生成此标记的标记点 id（陷阱/效果设置的标记为空）
func add_marker(marker_id: StringName, q: int, r: int, type: StringName, source_point_id: StringName = &"") -> void:
	var cell_id: String = "%s,%s" % [q, r]
	markers.append({
		"marker_id": marker_id,
		"q": q,
		"r": r,
		"cell_id": cell_id,
		"type": type,
		"source_point_id": source_point_id,
	})
	# 更新对应格子的 marker_id（单标记缓存，旧接口兼容；多标记时仅记最后一个）
	var cell = cells.get(cell_id)
	if cell:
		cell.marker_id = marker_id


## 获取指定坐标的所有标记（一格可有多个）
func get_markers_at(q: int, r: int) -> Array:
	var result: Array = []
	for marker in markers:
		if int(marker.get("q", 0)) == q and int(marker.get("r", 0)) == r:
			result.append(marker)
	return result


## 按 marker_id 移除标记
func remove_marker(marker_id: StringName) -> void:
	for i in range(markers.size()):
		if markers[i].get("marker_id", &"") == marker_id:
			# 清空对应格子的 marker_id 缓存
			var cell_id: String = markers[i].get("cell_id", "")
			var cell = cells.get(cell_id)
			if cell and cell.marker_id == marker_id:
				cell.marker_id = &""
			markers.remove_at(i)
			return


## 是否还存在事件标记（用于重生判定）
func has_event_markers() -> bool:
	for marker in markers:
		if marker.get("type", &"") == &"EVENT":
			return true
	return false


## 旧接口兼容：添加标记（仅 type，无 source_point_id）
## 保留供外部旧调用方使用
func add_marker_legacy(marker_id: StringName, q: int, r: int, type: StringName) -> void:
	add_marker(marker_id, q, r, type, &"")
