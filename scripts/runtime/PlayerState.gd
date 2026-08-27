## PlayerState.gd — 玩家运行时状态
class_name PlayerState
extends RefCounted

## 玩家唯一 ID（&"player" / &"enemy"）
var player_id: StringName = &""

## 是否由人类控制（true=人类，需要 UI 弹窗/选框；false=AI，由 AIController 代码决策）
## 多玩家时按此字段路由 UI，而非 hardcoded player_id == &"player"。
var is_human: bool = true

## 金币
var gold: int = 15

## 行动牌手牌（CardInstance.instance_id 列表）
var action_hand: Array[StringName] = []

## 装备牌手牌（CardInstance.instance_id 列表）
var equipment_hand: Array[StringName] = []

## 行动牌手牌上限（由机师牌决定）
var action_card_limit: int = 5

## 每回合攻击次数上限（由机师牌决定）
var attack_limit: int = 1

## 本回合已使用的每回合效果次数（key → int 使用次数）
var once_per_turn_used: Dictionary = {}

## 回合内计数器（移动格数、攻击次数等，供效果条件判断）
var turn_counters: Dictionary = {}

## 玩家身上状态效果列表（商店折扣等）
var statuses: Array[Dictionary] = []

## 行动牌手牌是否对对手明牌（用于弃牌选择时判断明暗牌）
var hand_revealed: bool = false

## 本回合已卖出装备的次数
var sell_equipment_count_this_turn: int = 0
## 付费抽行动牌本回合次数（2金币抽牌，每我方回合1次）
var paid_draw_count_this_turn: int = 0


## 增加「下个我方回合行动牌上限+X」（可叠加，立即生效，不跨到下下回合）。
## 通用机制：立即 action_card_limit += delta，并累加到 statuses 的
## next_owner_turn_action_hand_bonus；TurnService.start_turn 在该玩家回合开始
## 到期清除（action_card_limit -= stacks）。平行于 MechState.next_owner_turn_attack_bonus。
func add_next_owner_turn_action_hand_bonus(delta: int) -> void:
	action_card_limit += delta
	for s: Dictionary in statuses:
		if s.get("type", &"") == &"next_owner_turn_action_hand_bonus":
			s["stacks"] = int(s.get("stacks", 0)) + delta
			return
	statuses.append({"type": &"next_owner_turn_action_hand_bonus", "stacks": delta})


## 当前待到期清除的行动牌上限加成（stacks 总和）
func get_next_owner_turn_action_hand_bonus() -> int:
	var total: int = 0
	for s: Dictionary in statuses:
		if s.get("type", &"") == &"next_owner_turn_action_hand_bonus":
			total += int(s.get("stacks", 0))
	return total


## 清除下个我方回合行动牌上限加成（回合开始到期清除后调用）
func clear_next_owner_turn_action_hand_bonus() -> void:
	statuses = statuses.filter(func(s: Dictionary) -> bool:
		return s.get("type", &"") != &"next_owner_turn_action_hand_bonus"
	)
