## Action.gd — 动作基类
##
## 所有游戏动作的统一基类。每个动作包含：
##   action_id  —— 动作实例唯一标识
##   action_type —— 动作类型（如 "attack", "use_action_card" 等）
##   source     —— 发出此动作的效果/动作及来源
##   record     —— 动作当前记录的信息（随步骤执行更新）
##   steps      —— 步骤定义数组 [{step_name, timing_point, handler}]
##   state      —— 当前状态：pending/running/waiting_input/waiting_timing/completed/cancelled
##
## 动作执行流程（翻转后：handler 先执行，再 fire timing，对齐设计文档语义）：
##   依次执行每个步骤 → 执行步骤handler → 更新record → 发出该步骤对应的时点
##   遇到需要玩家输入的步骤时暂停，返回等待信号
##   遇到时点有监听器时暂停，等待监听效果执行完毕
##
## 参考：new_logic/各动作的生命周期与时点.docx
extends RefCounted
class_name Action

## 动作实例唯一标识
var action_id: StringName = &""

## 动作类型标识（如 "attack", "use_action_card", "stat_modify" 等）
var action_type: StringName = &""

## 发出此动作的效果/动作及来源
## 格式：{effect_id: StringName, card_instance_id: StringName, mech_id: StringName, player_id: StringName, source_action_id: StringName}
var source: Dictionary = {}

## 动作当前记录的信息（随步骤执行更新）
var record: Dictionary = {}

## 步骤定义数组
## 每个步骤：{step_name: StringName, timing_point: StringName, handler: Callable}
## - step_name: 步骤名称（用于日志和调试）
## - timing_point: 该步骤 handler 完成后发出的时点名（空则不发出）
## - handler: 步骤处理函数，签名 func(action: Action) -> Dictionary
##   返回 {} 表示继续，{"need_input": {...}} 表示需要玩家输入
var steps: Array = []

## 当前执行到的步骤索引（-1 表示未开始）
var current_step_index: int = -1

## 当前步骤的执行阶段（翻转后用于记录本步走到哪阶段，让暂停/恢复能续跑剩余阶段）
##   &""            —— 未进入/已结束本步；恢复时从阶段1重跑 handler（need_input 路径）
##   &"handler_done" —— handler 已跑、record 已合并；恢复时进阶段2 fire timing（sub_action 路径）
##   &"timing_firing"—— 正在 fire timing（监听器执行中，可能挂起）；恢复时推进到 timing_done（不重 fire）
##   &"timing_done"  —— timing 完成；恢复时进阶段3 完成本步
var current_step_phase: StringName = &""

## 当前步骤的 timing 是否已 fire 过（防止暂停恢复后重 fire 同一时点）
## 阶段3 fire 前置 true，本步 timing 处理完清 false
var _step_timing_fired: bool = false

## 待补跑的 regular listeners（响应窗口打开时 fire_timing 暂存，窗口关闭后由 _execute_step 阶段3 补跑）
## 含强袭 effect2 等 LISTEN 效果——文档语义要求它们在响应窗口关闭后、responded 已写入时执行
var _pending_regular_listeners: Array = []
## 补跑对应的 timing 与 payload（_run_pending_regular_listeners 执行时注入 binding_context 用）
var _pending_timing: StringName = &""
var _pending_timing_payload: Dictionary = {}
## 补跑 listeners 是否已排序（避免剩余续跑时重排打乱顺序）
var _pending_sorted: bool = false

## 动作状态
var state: StringName = &"pending"

## 依赖注入：GameContext 容器
var context = null

## 是否被否定（如识破的无效攻击效果）
var negated: bool = false

## 是否不可否定（如预判的效果3）
var unnegatable: bool = false

## 父动作等待完成的效果动作ID列表
## 当步骤执行产生效果动作时（效果/时点触发产生的动作，如攻击A、单次移动等），将效果动作ID加入此列表
## 父动作暂停等待，直到列表清空后继续执行
var pending_effect_action_ids: Array[StringName] = []

## 效果动作的父动作ID
## 效果动作完成时通过此字段通知父动作
var parent_action_id: StringName = &""

## 调试：execute_attack step 是否已执行过（用于检测 attack 动作被二次驱动的 bug3b）
## 放成员变量而非 record，避免污染 timing payload。
var _execute_attack_ran: bool = false


## 初始化步骤定义（子类重写）
func setup_steps() -> void:
	pass


## 获取动作的显示名称（用于日志，子类可重写）
func get_display_name() -> String:
	return String(action_type)


## 获取动作的摘要信息（用于日志）
func get_summary() -> Dictionary:
	return {
		"action_id": String(action_id),
		"action_type": String(action_type),
		"state": String(state),
		"current_step": current_step_index,
		"record": record,
	}


## 跳过指定数量的步骤（用于识破无效攻击等场景）
## 跳到 target_step_index 并执行该步骤
func skip_to_step(target_step_index: int) -> void:
	current_step_index = target_step_index - 1


## 设置步骤列表（工厂方法，避免 RefCounted 直接赋值问题）
func set_steps(steps_data: Array) -> void:
	steps = steps_data


## 添加单个步骤
func add_step(step_name: StringName, timing_point: StringName, handler: Callable) -> void:
	steps.append({
		"step_name": step_name,
		"timing_point": timing_point,
		"handler": handler,
	})
