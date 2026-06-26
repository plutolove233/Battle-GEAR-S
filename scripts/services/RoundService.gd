## RoundService.gd — 轮次管理服务
##
## 管理行动顺序、轮次变化。
## 当前为1v1简化版：玩家 → 敌方 轮流行动。
class_name RoundService
extends RefCounted

var context = null  # type: GameContext

## 行动顺序列表
var turn_order: Array[StringName] = [&"player", &"enemy"]

## 当前行动顺序索引
var current_index: int = 0


## 获取当前行动玩家 ID
func get_current_player_id() -> StringName:
	if current_index < turn_order.size():
		return turn_order[current_index]
	return &""


## 推进到下一个玩家
## 返回下一个玩家的 player_id
func advance_to_next() -> StringName:
	current_index = (current_index + 1) % turn_order.size()
	return get_current_player_id()


## 是否是新轮次的开始（即回到第一个玩家）
func is_new_round() -> bool:
	return current_index == 0


## 重置到轮次开始
func reset_round() -> void:
	current_index = 0


## 设置行动顺序
func set_turn_order(order: Array[StringName]) -> void:
	turn_order = order
	current_index = 0
