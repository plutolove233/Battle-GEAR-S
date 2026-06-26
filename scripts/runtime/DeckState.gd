## DeckState.gd — 牌堆状态
##
## 管理行动牌堆、装备牌堆（普通/高级）、机师牌堆、事件牌堆和弃牌堆。
class_name DeckState
extends RefCounted

## 行动牌堆
var action_deck: Array[StringName] = []

## 普通装备牌堆（N + R）
var equipment_deck: Array[StringName] = []

## 高级装备牌堆（SR + SSR）
var advanced_equipment_deck: Array[StringName] = []

## 机师牌堆
var pilot_deck: Array[StringName] = []

## 事件牌堆
var event_deck: Array[StringName] = []

## 统一弃牌堆
var discard_pile: Array[StringName] = []
