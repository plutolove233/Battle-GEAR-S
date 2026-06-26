## MechSlotDef.gd — 机甲槽位定义
##
## 描述机甲上一个可装备区域的静态属性。
class_name MechSlotDef
extends RefCounted

## 槽位标识：&"头部"/&"躯干"/&"右臂"/&"左臂"/&"右腿"/&"左腿"
##          /&"weapon_1"/&"weapon_2"/&"reserve_1"/&"reserve_2"
##          /&"event_1"/&"pilot_1"
var slot_id: StringName = &""

## 槽位大类：&"PART" / &"WEAPON" / &"RESERVE" / &"EVENT" / &"PILOT"
var slot_kind: StringName = &"PART"

## 框架基础护甲（仅部件区域有效）
var base_armor: int = 0

## 框架基础动力（仅部件区域有效）
var base_power: int = 0

## 备用区域基础耐久
var base_durability: int = 0

## 此槽位中的装备牌是否可以在设置状态下卖出
var can_sell_while_set: bool = false
