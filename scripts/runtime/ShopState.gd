## ShopState.gd — 商店状态
##
## 商店放置3张普通装备、1张高级装备、1张隐藏高级装备。
class_name ShopState
extends RefCounted

## 3 张普通装备牌的 instance_id
var normal_slots: Array[StringName] = []

## 1 张高级装备牌的 instance_id
var advanced_slot: StringName = &""

## 1 张隐藏高级装备牌的 instance_id（背面朝上）
var hidden_advanced_slot: StringName = &""

## 隐藏高级装备是否已被查看
var hidden_revealed: bool = false
