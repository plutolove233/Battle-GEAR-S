## ActionRegistry.gd — 动作实例注册表
##
## 管理所有活跃的动作实例，提供创建/查询/清理功能。
## 当动作结算完成后，自动清理该动作及关联的临时监听器。
extends RefCounted
class_name ActionRegistry

## 依赖注入：GameContext 容器
var context = null

## 活跃动作实例：{ action_id: Action }
var active_actions: Dictionary = {}

## 动作ID计数器
var _id_counter: int = 0


## 注册动作实例
func register(action: Action) -> void:
	if action == null:
		return
	if action.action_id == &"":
		action.action_id = _next_id()
	active_actions[action.action_id] = action


## 注销动作实例
func unregister(action_id: StringName) -> void:
	active_actions.erase(action_id)


## 获取动作实例
func get_action(action_id: StringName) -> Action:
	return active_actions.get(action_id)


## 按类型获取动作实例列表
func get_actions_by_type(action_type: StringName) -> Array:
	var result: Array = []
	for aid: StringName in active_actions:
		var action: Action = active_actions[aid]
		if action.action_type == action_type:
			result.append(action)
	return result


## 动作结算后清理：移除动作实例，同时清理关联的临时监听器与抑制效果
func cleanup_action(action_id: StringName) -> void:
	# 流程续跑回调（回合结束/事件计时等分段流程挂起时写入 _flow_resume_call）：
	# 携带者的动作完成（completed 或 cancelled 皆走本出口）即代表挂起交互已结束，
	# call_deferred 续跑流程剩余步骤（cleanup 常在动作树递归深处，deferred 防重入）。
	var flow_act: Action = active_actions.get(action_id)
	if flow_act != null and flow_act.record != null:
		var flow_cb = flow_act.record.get("_flow_resume_call", null)
		if flow_cb is Callable and flow_cb.is_valid():
			flow_act.record.erase("_flow_resume_call")
			flow_cb.call_deferred()
	# 清理 TimingEngine 中关联的临时监听器与抑制效果
	if context != null and context.timing_engine != null:
		context.timing_engine.unregister_listeners_for_action(action_id)
		context.timing_engine.clear_suppressions_for_action(action_id)
	# 移除动作实例
	active_actions.erase(action_id)


## 生成下一个动作ID
func _next_id() -> StringName:
	_id_counter += 1
	return &"action_%d" % _id_counter


## 获取当前活跃动作数量
func get_active_count() -> int:
	return active_actions.size()


## 获取所有活跃动作的ID列表
func get_active_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for aid: StringName in active_actions:
		ids.append(aid)
	return ids
