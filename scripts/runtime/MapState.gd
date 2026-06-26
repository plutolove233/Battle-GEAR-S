## MapState.gd — 地图状态
##
## 存储六边形网格地图的格子信息和标记。
class_name MapState
extends RefCounted

const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")

## 地图格子：HexGrid.key(hex) → MapCellState
var cells: Dictionary = {}

## 地图标记列表（Array[Dictionary]，兼容旧接口）
## 每个标记: { "marker_id": StringName, "q": int, "r": int, "type": StringName }
var markers: Array[Dictionary] = []


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


## 添加标记
func add_marker(marker_id: StringName, q: int, r: int, type: StringName) -> void:
	markers.append({
		"marker_id": marker_id,
		"q": q,
		"r": r,
		"type": type,
	})
	# 更新对应格子的 marker_id
	var key: String = "%s,%s" % [q, r]
	var cell = cells.get(key)
	if cell:
		cell.marker_id = marker_id
