## CardInstance.gd — 运行时卡牌实例
##
## CardInstance 表示游戏中实际存在的一张牌。
## 同一张 CardDef 有 count 张复制品，每张有独立的 instance_id 和运行时状态。
class_name CardInstance
extends RefCounted

## 全局唯一实例 ID（由 GameState.next_id 生成）
var instance_id: StringName = &""

## 静态定义引用
var def = null  # type: CardDef

## 所属玩家
var owner_player_id: StringName = &""

## 所属机甲（装备到机甲时设置）
var mech_id: StringName = &""

## 当前所在区域
## &"action_hand" / &"equipment_hand" / &"equipment_slot" / &"weapon_slot"
## &"event_slot" / &"pilot_slot" / &"reserve_slot" / &"discard_pile"
## &"action_deck" / &"equipment_deck" / &"advanced_equipment_deck"
## &"pilot_deck" / &"event_deck" / &"shop"
var zone: StringName = &""

## 区域内具体槽位（&"头部"/&"躯干"/&"weapon_1" 等）
var slot_id: StringName = &""

## 装备牌上的损伤计数
var damage_tokens: int = 0

## 是否背面朝上（备用区域中的装备牌）
var face_down: bool = false

## 效果是否被临时无效化
var disabled: bool = false

## 事件牌计时器（仅 EventCardDef 使用）
var timer: int = 0

## 通用计数器（武器蓄能、事件进度等）
var counters: Dictionary = {}


func _init(p_instance_id: StringName = &"", p_def = null) -> void:
	instance_id = p_instance_id
	def = p_def


## 获取牌面名称
func get_display_name() -> String:
	if def:
		return def.display_name
	return ""
