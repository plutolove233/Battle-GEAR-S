## slog.gd — SessionLogger 的编译期可见代理
##
## 背景：Godot 4.x 在 `-s`（SceneTree 脚本）模式下不会把 autoload 注册到
## GDScript 编译上下文，导致所有引用裸标识符 `SessionLogger` 的脚本
## （GameActions / ActionEngine / TimingEngine / ActionService / EffectEngine 等）
## 在 headless 测试中编译失败（"Identifier not found: SessionLogger"），
## 进而使 GameContext 初始化链整条断裂，50 个测试全部失败。
##
## 解决：本脚本用 `class_name SLog` 提供一个编译期全局可见的标识符，
## 运行时转发到 autoload 节点 /root/SessionLogger（游戏正常启动时存在）。
## 这样：
##   - 正常游戏：转发到真正的 SessionLogger 单例，行为不变；
##   - headless 测试：单例可能不存在，转发方法静默跳过（不写日志，但不阻断流程）。
##
## 所有调用点统一用 `SLog.xxx(...)` 取代 `SessionLogger.xxx(...)`。
##
## 注意：本脚本不使用 `class_name`（Godot `-s` 测试模式下 class_name 全局类型
## 不会被编译上下文识别，与 autoload 同理）。各调用文件顶部用
## `const SLog = preload("res://scripts/services/slog.gd")` 引入，
## preload 在正常游戏与 `-s` headless 测试下均可解析。
extends RefCounted


## 取得真正的 SessionLogger autoload 节点（运行时查找）；不存在则返回 null。
static func _logger() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("SessionLogger")


static func log_message(text: String) -> void:
	var l := _logger()
	if l:
		l.log_message(text)


static func log_timing(timing: StringName, action_id: StringName, action_type: StringName, payload: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_timing(timing, action_id, action_type, payload)


static func log_effect(effect_id: StringName, source: Dictionary, action_id: StringName, action: String, result: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_effect(effect_id, source, action_id, action, result)


static func log_action_step(action_id: StringName, action_type: StringName, step_name: StringName, step_index: int, input_args: Dictionary, output: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_action_step(action_id, action_type, step_name, step_index, input_args, output)


static func log_action_detail(action_id: StringName, action_type: StringName, step_name: StringName, record: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_action_detail(action_id, action_type, step_name, record)


static func log_stat_modify(action_id: StringName, target_id: StringName, target_type: String, stat_type: String, value: int, method: String, source: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_stat_modify(action_id, target_id, target_type, stat_type, value, method, source)


static func log_action_result(action_id: StringName, action_type: StringName, result_type: String, details: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_action_result(action_id, action_type, result_type, details)


static func log_action_complete(action_id: StringName, action_type: StringName, final_record: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_action_complete(action_id, action_type, final_record)


static func log_response_window(action_id: StringName, timing: StringName, available_cards: Array, selected: Array) -> void:
	var l := _logger()
	if l:
		l.log_response_window(action_id, timing, available_cards, selected)


static func log_raw(text: String) -> void:
	var l := _logger()
	if l:
		l.log_raw(text)


static func log_call(service_name: String, method_name: String, input_args: Dictionary, output: Dictionary) -> void:
	var l := _logger()
	if l:
		l.log_call(service_name, method_name, input_args, output)
