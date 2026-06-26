## PlayerState.gd — 玩家运行时状态
class_name PlayerState
extends RefCounted

## 玩家唯一 ID（&"player" / &"enemy"）
var player_id: StringName = &""

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

## 本回合已使用的每回合一次效果
var once_per_turn_used: Dictionary = {}  # key → bool

## 回合内计数器（移动格数、攻击次数等，供效果条件判断）
var turn_counters: Dictionary = {}

## 玩家身上的状态效果列表（商店折扣等）
var statuses: Array[Dictionary] = []
