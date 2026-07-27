## SessionLogger.gd — 全局会话日志（Autoload 单例）
##
## 一次游戏启动到最终结束，仅保存一个本地日志文件。
## 文件内容包含两类记录：
##   1) 游戏内消息（消息面板显示的中文事件文字）
##   2) 代码调用返回结果（服务层调用的入参与返回值/错误，便于复盘与排查）
##
## 游戏内消息面板（BattleMessageLog）只负责显示，不再直接写文件；
## 所有落盘操作统一汇聚到这里。
##
## 日志记录规范（新逻辑文档要求）：
## - 效果、动作、时点
## - 输入的参数（对象、类型、数值、修正方式等）
## - 指定的对象
## - 执行的结果
extends Node

const _LOG_DIR := "res://battle_logs/"

var _file: FileAccess = null
var _file_path: String = ""
## 是否已为本会话打开文件（仅打开一次）
var _opened: bool = false
## 累计写入字节数（用于软上限兜底）
var _bytes_written: int = 0
## 已触发软上限停写（避免重复 push_warning）
var _capped: bool = false
## 单会话日志软上限（字节）。正常会话远不到 1MB；超此必是异常循环，
## 停止落盘防止再次写爆磁盘（历史曾出现 7GB+ 日志文件）。
const _CAP_MEGABYTES: int = 50
const _CAP_BYTES: int = _CAP_MEGABYTES * 1024 * 1024


func _ready() -> void:
	_open_session_file()


func _notification(what: int) -> void:
	# 应用退出时确保缓冲落盘
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_close_session_file()


## 追加一条游戏内消息（去 BBCode 后的纯文本，与面板显示一致）
func log_message(text: String) -> void:
	_write_line("[MSG] %s" % _strip_bbcode(text))


## 记录时点触发信息
##   timing    : 时点名（如 ATTACK_BEFORE）
##   action_id : 动作ID
##   action_type: 动作类型
##   payload   : 时点携带的参数
func log_timing(timing: StringName, action_id: StringName, action_type: StringName, payload: Dictionary) -> void:
	_write_line("[TIMING] %s | action=%s type=%s payload=%s" % [
		String(timing), String(action_id), String(action_type), _compact_str(payload),
	])


## 记录效果执行
##   effect_id : 效果ID
##   source    : 效果来源（牌ID、机甲ID等）
##   action_id : 所属动作ID
##   action    : 效果执行的动作类型
##   result    : 执行结果（成功/失败/跳过及原因）
func log_effect(effect_id: StringName, source: Dictionary, action_id: StringName, action: String, result: Dictionary) -> void:
	var src_str := ""
	if source.has("card_instance_id"):
		src_str = "card:" + String(source.get("card_instance_id", &""))
	if source.has("mech_id"):
		src_str += " mech:" + String(source.get("mech_id", &""))
	if source.has("player_id"):
		src_str += " player:" + String(source.get("player_id", &""))
	_write_line("[EFFECT] id=%s source=%s action_id=%s action=%s result=%s" % [
		String(effect_id), src_str, String(action_id), action, _compact_str(result),
	])


## 记录动作步骤执行
##   action_id  : 动作ID
##   action_type: 动作类型（如 attack, use_action_card）
##   step_name  : 步骤名
##   step_index : 步骤索引
##   input_args : 输入参数
##   output     : 输出结果
func log_action_step(action_id: StringName, action_type: StringName, step_name: StringName, step_index: int, input_args: Dictionary, output: Dictionary) -> void:
	_write_line("[STEP] action=%s type=%s step=%s(%d) in=%s out=%s" % [
		String(action_id), String(action_type), String(step_name), step_index,
		_compact_str(input_args), _compact_str(output),
	])


## 记录动作每个步骤的完整record（包含所有参数）
##   action_id   : 动作ID
##   action_type : 动作类型
##   step_name   : 当前步骤名
##   record      : 动作当前记录的全部数据
func log_action_detail(action_id: StringName, action_type: StringName, step_name: StringName, record: Dictionary) -> void:
	_write_line("[ACTION_DETAIL] action=%s type=%s step=%s record=%s" % [
		String(action_id), String(action_type), String(step_name), _compact_str(record),
	])


## 记录数值修正动作的详细参数
##   action_id  : 所属动作ID
##   target_id  : 修正对象ID（机甲ID或攻击动作ID）
##   target_type: 修正对象类型（"mech" 或 "attack"）
##   stat_type  : 数值类型（护甲/动力/威力/范围/金币）
##   value      : 修正数值量
##   method     : 修正方式（"add"增加/"sub"减少/"restore"回复）
##   source     : 来源信息 {effect_id, mech_id, card_id, card_name}
func log_stat_modify(action_id: StringName, target_id: StringName, target_type: String, stat_type: String, value: int, method: String, source: Dictionary) -> void:
	var src_str := _format_source(source)
	_write_line("[STAT_MODIFY] action=%s target=%s(%s) type=%s value=%d method=%s source=%s" % [
		String(action_id), String(target_id), target_type, stat_type, value, method, src_str,
	])


## 记录动作执行结果
##   action_id   : 动作ID
##   action_type : 动作类型
##   result_type : 结果类型（"hit"/"miss"/"damage"/"heal"/"cancelled"/"negated"/"completed"）
##   details     : 详细结果数据
func log_action_result(action_id: StringName, action_type: StringName, result_type: String, details: Dictionary) -> void:
	_write_line("[ACTION_RESULT] action=%s type=%s result=%s details=%s" % [
		String(action_id), String(action_type), result_type, _compact_str(details),
	])


## 记录动作完成
##   action_id  : 动作ID
##   action_type: 动作类型
##   final_record: 最终记录的全部数据
func log_action_complete(action_id: StringName, action_type: StringName, final_record: Dictionary) -> void:
	_write_line("[ACTION_COMPLETE] action=%s type=%s record=%s" % [
		String(action_id), String(action_type), _compact_str(final_record),
	])


## 记录响应窗口
##   action_id : 触发响应的动作ID
##   timing    : 时点
##   available_cards: 可用牌列表
##   selected  : 玩家选择的牌
func log_response_window(action_id: StringName, timing: StringName, available_cards: Array, selected: Array) -> void:
	var avail_str := ""
	for c in available_cards:
		avail_str += c.get("card_name", "unknown") + "(" + String(c.get("effect_id", &"")) + "),"
	var select_str := ""
	for s in selected:
		select_str += s.get("card_name", "unknown") + ","
	_write_line("[RESPONSE_WINDOW] action=%s timing=%s available=[%s] selected=[%s]" % [
		String(action_id), String(timing), avail_str, select_str,
	])


## 记录一段自由文本（调试/分隔等），不分类前缀
func log_raw(text: String) -> void:
	_write_line(text)


## 记录服务调用
##   service_name : 服务类名
##   method_name  : 方法名
##   input_args   : 输入参数
##   output       : 输出结果
func log_call(service_name: String, method_name: String, input_args: Dictionary, output: Dictionary) -> void:
	_write_line("[CALL] %s.%s in=%s out=%s" % [
		service_name, method_name, _compact_str(input_args), _compact_str(output),
	])


# ═══════════════════════════════════════════
# 内部
# ═══════════════════════════════════════════

## 本会话只打开一次文件；若已打开则复用
func _open_session_file() -> void:
	if _opened:
		return
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists("battle_logs"):
		dir.make_dir("battle_logs")
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [
		dt.get("year", 0), dt.get("month", 0), dt.get("day", 0),
		dt.get("hour", 0), dt.get("minute", 0), dt.get("second", 0),
	]
	_file_path = "res://battle_logs/session_log_%s.txt" % stamp
	_file = FileAccess.open(_file_path, FileAccess.WRITE_READ)
	if _file == null:
		push_warning("SessionLogger: 无法创建会话日志文件: %s" % _file_path)
		return
	_opened = true
	_file.seek_end()
	_file.store_line("════════ 会话日志 ════════")
	_file.store_line("启动时间: %s" % stamp)
	_file.store_line("")
	_file.flush()


func _close_session_file() -> void:
	if _file != null and is_instance_valid(_file):
		_file.close()
	_file = null
	_opened = false


## 写入一行并立即落盘（会话日志量不大，实时 flush 便于崩溃后复盘）
## 软上限兜底：累计写入超过 _CAP_BYTES 后停止落盘，防止异常循环写爆磁盘。
func _write_line(line: String) -> void:
	if _capped:
		return
	if not _opened:
		_open_session_file()
	if _file == null or not is_instance_valid(_file):
		return
	# 字节估算：UTF-8 下中文字符占 3 字节，line.to_utf8_buffer().size() 是精确字节数，
	# 但每行都转 buffer 开销大；用长度近似并在临界区精确校验即可。
	var line_bytes: int = line.to_utf8_buffer().size() + 1  # +1 for newline
	if _bytes_written + line_bytes > _CAP_BYTES:
		_capped = true
		_file.seek_end()
		_file.store_line("[CAP] 会话日志已达软上限 %d MB，停止落盘（疑似异常循环写日志）" % _CAP_MEGABYTES)
		_file.flush()
		push_warning("SessionLogger: 会话日志达软上限，停止落盘")
		return
	_file.seek_end()
	_file.store_line(line)
	_file.flush()
	_bytes_written += line_bytes


## 尽量紧凑地把任意对象转成单行字符串（去掉换行，避免破坏日志结构）
func _compact_str(value) -> String:
	var s := str(value)
	s = s.replace("\n", "\\n").replace("\r", "")
	return s


## 去除 BBCode 标签，得到纯文本
func _strip_bbcode(text: String) -> String:
	var s := text
	var out := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == "[":
			var end := s.find("]", i)
			if end != -1:
				i = end + 1
				continue
		out += c
		i += 1
	return out


## 格式化来源信息为可读字符串
func _format_source(source: Dictionary) -> String:
	var parts: Array = []
	if source.has("effect_id"):
		parts.append("effect:" + String(source["effect_id"]))
	if source.has("card_id"):
		parts.append("card:" + String(source["card_id"]))
	if source.has("card_name"):
		parts.append("牌:" + String(source["card_name"]))
	if source.has("mech_id"):
		parts.append("mech:" + String(source["mech_id"]))
	if source.has("player_id"):
		parts.append("player:" + String(source["player_id"]))
	if source.has("source_action_id"):
		parts.append("from_action:" + String(source["source_action_id"]))
	return String(",").join(parts) if not parts.is_empty() else "unknown"
