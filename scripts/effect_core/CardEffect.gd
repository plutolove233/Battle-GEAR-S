## CardEffect.gd — 所有牌效果的统一数据结构
##
## CardEffect 描述一张牌"能做什么"——触发条件（hook）和动作列表。
## 同一张牌的多个效果各自独立，由效果系统在对应时机调用。
## 数据结构来源于规则表 Effect全牌表.xlsx "核心执行框架" 第1行。
extends Resource
class_name CardEffect

## 效果唯一标识
@export var effect_id: StringName = &""

## 效果显示名称
@export var display_name: String = ""

## 效果模式：ACTIVE / PASSIVE / STATIC
@export_enum("ACTIVE", "PASSIVE", "STATIC")
var mode: String = "PASSIVE"

## 触发时机（Hook 名称，对应 EffectConst.HOOK_* 常量）
@export var hook: StringName = &""

## 优先级：数值越小越先执行
@export var priority: int = 100

## 每回合一次键：非空时表示此效果每回合只能触发有限次
@export var once_per_turn_key: StringName = &""

## 每回合最大触发次数（默认1；配合 once_per_turn_key 使用）
@export var once_per_turn_max: int = 1

## 条件列表：[{ op: StringName, ... }] 必须全部满足才触发
@export var conditions: Array[Dictionary] = []

## 目标规则：[{ rule: StringName, ... }] 目标合法性检查
@export var target_rules: Array[Dictionary] = []

## 费用列表：[{ cost_type: StringName, ... }] 触发前需支付
@export var costs: Array[Dictionary] = []

## 动作列表：[{ type: StringName, params?: Dictionary }] 按序执行
@export var actions: Array[Dictionary] = []

## 效果描述文本
@export_multiline var description: String = ""
