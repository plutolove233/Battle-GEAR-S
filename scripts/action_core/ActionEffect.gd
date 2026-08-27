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

## ── 选目标前确认 ──
## true=效果需要玩家选择目标前，先弹"是否发动"确认窗（显示效果说明，可取消），
## 确认后才进入目标选择（_request_target_selection 通用处理）。里昂战后逼迫等用。
@export var confirm_before_target: bool = false
## 确认窗"发动"按钮文案；空=回退"发动<display_name>"
@export var confirm_label: String = ""

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

## ── 机师牌 UI 按钮（通用，绑定效果条目而非机师ID） ──
## true=此效果不渲染独立按钮（隐藏被动子效果，如 pilot_034_effect_02b 复仇反击的触发部分）。
## 注册照常（LISTEN 监听照常触发），仅 equipment_panel 跳过建按钮。
@export var hide_button: bool = false
## >0 时，此隐藏效果的描述合并到"可见按钮中的第 N 个"（按 effect_id 排序后、跳过隐藏后编号）的悬停补充说明。
## 0=不合并（仅隐藏）。支持多个隐藏效果合并到同一按钮（equipment_panel 累计成数组展示）。
@export var merge_desc_into_index: int = 0

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

## ── 移动消耗修正元数据（通用效果元数据，与机师ID无关） ──
## 非空时声明本效果对移动动力计算的影响，由 MapService.resolve_move_cost_params
## 扫描场上效果持有牌聚合（牌在场上机甲槽位=效果活跃，卸牌/死亡自然失效，无需清理）。键：
##   "green_cost": int        -- 效果持有者玩家移动时的绿格消耗覆盖值（多效果取最小，默认 2）
##   "aura_shape": StringName -- 光环形状：目前支持 "adjacent_6"=持有者所在格+6邻居（红格除外）；
##                               光环格对【所有】玩家视为绿格（光环全局、折扣玩家作用域）
## 例：汀兰 pilot_081_effect_01 = {"green_cost": 1, "aura_shape": &"adjacent_6"}。
## 任何机师/装备牌效果声明同元数据即自动生效（移动/BFS/渲染各调用点统一走通用查询），
## 不绑机师ID -- 复用时复制效果定义并改 move_cost_mod 即可，移动代码零改动。
@export var move_cost_mod: Dictionary = {}

## ── 注册时初始化计数器（通用效果元数据，与机师ID无关） ──
## 非空时，效果绑定注册到卡牌实例（GameSetupService._register_pilot_effects /
## use_action_card._register_card_effects 等）时把 {key: value} 写入 card.counters
## （仅当键不存在，不覆盖运行中已消耗的值）。解决"中途换上机师牌要等下回合才生效"：
## 计数器初始值随注册立即可用，回合开始的重置逻辑（如 SET_CARD_COUNTER）照常覆盖。
## 例：莉诺原价购买 = { "face_value_buy_uses": 2 }。任何带同效果的牌即生效，不绑机师。
var init_counters: Dictionary = {}

## ── 悬停进度显示（通用效果元数据，与卡牌ID无关） ──
## 非空时声明本效果关联的计数器进度，UI（equipment_panel 悬停/槽位行）据此显示
## "进度 X/threshold（已领取）"。TRACK_EVENT_PROGRESS 写 var_ 前缀键。键：
##   "counter_key": StringName       -- 进度计数器名（实际读 card.counters["var_<key>"]）
##   "threshold": int                -- 目标阈值
##   "claimed_counter_key": StringName -- 可选：领取标记计数器名（>=1 显示"已领取"）
## 例：任务牌奖励效果 = {"counter_key": &"task_progress", "threshold": 10,
##                        "claimed_counter_key": &"task_claimed"}。
## 任何带同元数据的效果即生效，不绑卡牌。
var progress_display: Dictionary = {}

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


## 开启选目标前确认
func set_confirm_before_target(value: bool) -> void:
	confirm_before_target = value


## 设置费用列表
func set_costs(costs_data) -> void:
	costs = costs_data


## 设置动作列表
func set_actions(actions_data) -> void:
	actions = actions_data


## 设置来源信息
func set_source(source_data: Dictionary) -> void:
	source = source_data
