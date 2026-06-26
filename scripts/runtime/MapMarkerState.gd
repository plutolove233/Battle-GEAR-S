## MapMarkerState.gd — 地图标记运行时状态
##
## 地图上的特殊标记：金币、事件、陷阱。
class_name MapMarkerState
extends RefCounted

## 标记唯一 ID
var marker_id: StringName = &""

## 所在格子 ID（与 MapCellState.cell_id 格式一致）
var cell_id: String = ""

## 标记类型
## &"GOLD"  — 金币标记：投骰获得金币
## &"EVENT" — 事件标记：翻开事件牌并设置
## &"TRAP"  — 陷阱标记：触发爆炸，中心和相邻1格机甲受伤
var type: StringName = &"GOLD"

## 是否已被发现/翻开
var revealed: bool = false

## 标记的 q 坐标（冗余存储，方便查询）
var q: int = 0

## 标记的 r 坐标
var r: int = 0


func _init(p_marker_id: StringName = &"", p_cell_id: String = "", p_type: StringName = &"GOLD", p_q: int = 0, p_r: int = 0) -> void:
	marker_id = p_marker_id
	cell_id = p_cell_id
	type = p_type
	q = p_q
	r = p_r


## 转为 Dictionary（兼容旧接口）
func to_dict() -> Dictionary:
	return {
		"marker_id": String(marker_id),
		"cell_id": cell_id,
		"type": String(type),
		"revealed": revealed,
		"q": q,
		"r": r,
	}
