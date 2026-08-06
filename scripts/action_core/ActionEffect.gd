## ActionEffect.gd — 新版效果定义
##
## 替代原 CardEffect，支持三种模式：
##   DIRECT       —— 直接执行：使用行动牌时立即执行
##   LISTEN       —— 监听型：监听指定动作的指定时点
##   AVAILABILITY —— 可用条件型：在响应窗口等场景中作为可选牌出现
##
## 参考：new_logic/行动牌的效果与逻辑.docx
extends Resource
class_name ActionEffect

## 效果唯一标识
@export var effect_id: StringName = &""

## 效果显示名称
@export var display_name: String = ""

## 优先级：数值越大越先执行（TimingEngine 排序 `pa > pb`，高优先级先 fire）。
## 约定范围 -1~30：常规 10，顺序保证用 20/30，上限 30。
@export var priority: int = 100

## ── 效果模式 ──
## DIRECT: 直接执行（使用行动牌时立即执行）
## LISTEN: 监听型（监听指定动作的指定时点）
## AVAILABILITY: 可用条件型（在响应窗口等场景中作为可选牌出现）
@export var mode: String = "DIRECT"

## ── 监听配置（LISTEN 模式使用） ──
## 监听的时点名
@export var listen_timing: StringName = &""
## 绑定的动作ID（空=监听所有匹配时点的动作；非空=仅监听此action_id的动作）
@export var listen_action_id: StringName = &""
## 绑定的动作类型（空=不限；如 "attack" 表示只监听攻击动作发出的时点）
@export var listen_action_type: StringName = &""

## ── 可用条件（AVAILABILITY 模式使用） ──
## 可用条件类型（如 "RESPOND_ATTACK" 表示响应攻击）
@export var availability_condition: StringName = &""
## 可用条件的优先级（如回避=5，识破=30）
@export var availability_priority: int = 5

## ── 条件列表 ──
## 每个条件：{ op: StringName, ... } 必须全部满足才触发
@export var conditions = []

## ── 目标规则 ──
## 每个规则：{ rule: StringName, ... } 目标合法性检查
@export var target_rules = []

## ── 费用列表 ──
## 每个费用：{ cost_type: StringName, ... } 触发前需支付
@export var costs = []

## ── 动作列表 ──
## 每个动作：{ type: StringName, params?: Dictionary } 按序执行
## type 包括：EXECUTE_ATTACK, EXECUTE_STAT_MODIFY, EXECUTE_BASIC_MOVE, EXECUTE_SINGLE_MOVE,
##   EXECUTE_SET_EQUIP, EXECUTE_GAIN_CARD, EXECUTE_DISCARD, EXECUTE_EFFECT_FIRE,
##   EXECUTE_HP_CHANGE, EXECUTE_DAMAGE_CHANGE, EXECUTE_SHOW_CARD,
##   MODIFY_ATTACK_POWER, MODIFY_ARMOR, MOVE_MECH, ADD_STATUS, REMOVE_STATUS, ...
@export var actions = []

## ── 效果间依赖 ──
## 必须先执行完此效果ID后才可触发本效果
@export var requires_effect: StringName = &""

## ── 效果描述文本 ──
@export_multiline var description: String = ""

## ── 每回合一次控制 ──
@export var once_per_turn_key: StringName = &""
@export var once_per_turn_max: int = 1

## ── 每局一次控制 ──
## 非空时，ActionEngine/TimingEngine 触发前校验本局已用次数（GameState.once_per_game_used，
## key 格式 "<key>@<card_instance_id>"），达到 once_per_game_max 则不触发。
## 机师牌本批 SSR 未用此字段，但建系统时一并加上，供后续批次（如 pilot_033 弃2装抽高级 本局1次）使用。
@export var once_per_game_key: StringName = &""
@export var once_per_game_max: int = 1

## ── 手牌期间永久监听（LISTEN 模式使用）──
## true=牌在手牌期间作为永久监听器监听他人动作（如推进 effect2 监听他人使用迎击牌），
## 而非使用此牌时绑到自身 use_action_card。register_hand_card_availability 注册，
## _register_card_effects 跳过（不自触发）。
@export var permanent_while_in_hand: bool = false

## ── 来源信息 ──
## 记录发出此效果的效果/动作及来源
var source: Dictionary = {}

## ── 工厂方法（解决 Resource 类型直接赋值问题） ──

## 创建测试用效果实例
static func create_test(
	effect_id_val: StringName = &"",
	mode_val: String = "DIRECT",
	priority_val: int = 10
) -> ActionEffect:
	var effect := ActionEffect.new()
	effect.effect_id = effect_id_val
	effect.mode = mode_val
	effect.priority = priority_val
	return effect


## 设置条件列表
func set_conditions(conditions_data) -> void:
	conditions = conditions_data


## 设置目标规则
func set_target_rules(rules_data) -> void:
	target_rules = rules_data


## 设置费用列表
func set_costs(costs_data) -> void:
	costs = costs_data


## 设置动作列表
func set_actions(actions_data) -> void:
	actions = actions_data


## 设置来源信息
func set_source(source_data: Dictionary) -> void:
	source = source_data
