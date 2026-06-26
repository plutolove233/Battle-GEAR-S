## MapCellState.gd — 地图格子运行时状态
##
## 每个六边形格子的状态，包含地形类型和标记引用。
class_name MapCellState
extends RefCounted

## 格子唯一 ID（与 HexGrid.key 格式一致："q,r"）
var cell_id: String = ""

## 轴向坐标 q
var q: int = 0

## 轴向坐标 r
var r: int = 0

## 地形类型
## &"NORMAL" — 普通地形，移动消耗1动力
## &"GREEN"  — 绿色地形，移动消耗2动力
## &"RED"    — 红色地形，不可进入
var terrain: StringName = &"NORMAL"

## 地图标记 ID（空表示无标记）
var marker_id: StringName = &""


func _init(p_cell_id: String = "", p_q: int = 0, p_r: int = 0, p_terrain: StringName = &"NORMAL") -> void:
	cell_id = p_cell_id
	q = p_q
	r = p_r
	terrain = p_terrain


## 获取移动消耗（动力点数）
func get_move_cost() -> int:
	match terrain:
		&"GREEN":
			return 2
		&"RED":
			return -1  # 不可进入
		_:
			return 1


## 是否可通过
func is_passable() -> bool:
	return terrain != &"RED"


## 转为 Dictionary（兼容旧接口）
func to_dict() -> Dictionary:
	return {
		"cell_id": cell_id,
		"q": q,
		"r": r,
		"terrain": String(terrain),
		"marker_id": String(marker_id),
	}
