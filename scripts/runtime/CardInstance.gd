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
## &"event_slot" / &"pilot_slot" / &"reserve_slot" / &"discard"
## &"temp_zone"（使用行动牌动作执行期间，牌离开持有者进入临时区，结算后才进 discard）
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
var effect_negated: bool = false  # NEGATE_EQUIPMENT_EFFECT 压制：效果无效但保留牌面 stats

## 事件牌计时器（仅 EventCardDef 使用）
var timer: int = 0

## 通用计数器（武器蓄能、事件进度等）
var counters: Dictionary = {}

## 对哪些玩家可见（展示牌效果持续展示时使用）
## 存储玩家ID列表：Array[StringName]
var known_to: Array[StringName] = []

## 聚能状态层数（用于武器蓄能）
var energy_charge_stacks: int = 0

## ── 武器装备牌运行时修正（effect_093+ 武器效果用）──
## 持久/临时威力修正列表：[{delta, duration, bucket, source_card_id}]
## duration: &"PERMANENT"(跨回合持久) / &"THIS_OWNER_TURN"(到所属玩家回合结束) / &"THIS_TURN"
## bucket: 区分修正来源(weapon_012/014衰减、聚能临时、形态等)，便于精确清除/上限回复
var might_modifiers: Array = []
## 持久/临时射程修正列表（结构同 might_modifiers）
var range_modifiers: Array = []
## 武器形态（流星钢锤 effect_098/099）：&"" / &"normal" / &"extended"
var weapon_mode: StringName = &""
## 武器冷却截止回合序号（effect_125/126）：-1=无冷却；>当前回合序号时不可攻击
var cooldown_until_turn: int = -1
## 锁定状态关联（effect_104 拘束钩爪）：锁定期间本牌不能攻击。存被锁目标 mech_id，&""=未锁定
var lock_target_mech_id: StringName = &""


func _init(p_instance_id: StringName = &"", p_def = null) -> void:
	instance_id = p_instance_id
	def = p_def


## 获取牌面名称
func get_display_name() -> String:
	if def:
		return def.display_name
	return ""
