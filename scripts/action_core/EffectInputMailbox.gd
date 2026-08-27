class_name EffectInputMailbox
extends RefCounted

## 通用「早到输入信箱」（引擎级基建，不绑任何卡牌/效果，可独立复用）。
##
## 解决的竞态：效果恢复输入（resume_effect 的 data，来自网络 op 或 UI 点击）到达本端时，
## 目标动作尚未挂起（多帧 deferred 执行链还没推进到挂起点，如 basic_move 的 yield_frame
## 步骤 midway 的标记触发挂起）。此前 TimingEngine.resume_pending_effect 对未知 action_id
## 静默返回，输入永久丢失、动作无限等待 -> 三端锁步发散。
##
## 机制：未命中挂起的恢复输入先入信箱；挂起注册后由宿主（ActionUIBridge._on_action_needs_input
## 汇入点 / TimingEngine.fire_timing 顶部）排空补投（deferred resume_pending_effect）。
## 动作 id 全局唯一且单调，正常时序不会重复投递；错 id（发散）输入永远不会匹配挂起，
## 故必须有界：单动作保最新 KEEP_PER_ACTION 份，全局 FIFO 淘汰至 MAX_ENTRIES。
##
## 复用方式：复制本文件改 KEEP_PER_ACTION/MAX_ENTRIES/日志前缀即可，无外部依赖（仅 SLog）。

const SLog = preload("res://scripts/services/slog.gd")

## 单动作保留份数（保最新；同一动作连续多次早到只留最后几份）
const KEEP_PER_ACTION: int = 2
## 全局上限（防错 id 泄漏；FIFO 淘汰最旧）
const MAX_ENTRIES: int = 32

## { action_id字符串: Array[Dictionary]（按到达顺序，旧->新） }
var _boxes: Dictionary = {}
var _total: int = 0


func is_empty() -> bool:
	return _total <= 0


func size() -> int:
	return _total


## 暂存一份早到输入（resume_pending_effect 未命中挂起时调用）。
func stash(action_id: StringName, input_data: Dictionary) -> void:
	var key := String(action_id)
	if not _boxes.has(key):
		_boxes[key] = []
	var box: Array = _boxes[key]
	box.append(input_data)
	_total += 1
	while box.size() > KEEP_PER_ACTION:
		box.pop_front()
		_total -= 1
	while _total > MAX_ENTRIES:
		if not _evict_oldest():
			break
	SLog.log_raw("[MAILBOX] 暂存早到恢复输入 action=%s 键=%s（动作尚未挂起，待挂起注册后补投）"
		% [key, str(input_data.keys())])


## 取出并清空该动作的全部暂存输入（按到达顺序）。无暂存返回空数组。
func drain(action_id: StringName) -> Array:
	var key := String(action_id)
	if not _boxes.has(key):
		return []
	var box: Array = _boxes[key]
	_boxes.erase(key)
	_total -= box.size()
	return box


## 有暂存且已出现在挂起注册表（pending_registry）里的动作 id 列表。
## 供 fire_timing 顶部兜底排空：只补投「现在确实挂起着」的动作。
func collect_ready(pending_registry: Dictionary) -> Array[StringName]:
	var ready: Array[StringName] = []
	if _total <= 0:
		return ready
	for key in _boxes.keys():
		if pending_registry.has(key):
			ready.append(StringName(key))
	return ready


func clear() -> void:
	_boxes.clear()
	_total = 0


func _evict_oldest() -> bool:
	for key in _boxes.keys():
		var box: Array = _boxes[key]
		if not box.is_empty():
			box.pop_front()
			_total -= 1
			if box.is_empty():
				_boxes.erase(key)
			SLog.log_raw("[MAILBOX] 全局上限淘汰最早已暂存输入 action=%s" % key)
			return true
	return false
