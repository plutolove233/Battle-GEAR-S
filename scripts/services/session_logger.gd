## SessionLogger.gd — 全局会话日志（Autoload 单例）
##
## 一次游戏启动到最终结束，仅保存一个本地日志文件。
## 文件内容包含两类记录：
##   1) 游戏内消息（消息面板显示的中文事件文字）
##   2) 代码调用返回结果（服务层调用的入参与返回值/错误，便于复盘与排查）
##
## 游戏内消息面板（BattleMessageLog）只负责显示，不再直接写文件；
## 所有落盘操作统一汇聚到这里。
extends Node

const _LOG_DIR := "res://battle_logs/"

var _file: FileAccess = null
var _file_path: String = ""
## 是否已为本会话打开文件（仅打开一次）
var _opened: bool = false


func _ready() -> void:
	_open_session_file()


func _notification(what: int) -> void:
	# 应用退出时确保缓冲落盘
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_close_session_file()


## 追加一条游戏内消息（去 BBCode 后的纯文本，与面板显示一致）
func log_message(text: String) -> void:
	_write_line("[MSG] %s" % _strip_bbcode(text))


## 记录一次代码调用及其返回结果。
##   caller   : 调用方描述（如 "app_root" / "battle" / 服务名）
##   method   : 被调用的方法/动作名（如 "set_equipment" / "end_player_turn" / "begin_attack"）
##   args     : 入参（字典或可 str() 化的对象）
##   result   : 返回结果（字典/布尔/状态等）
func log_call(caller: String, method: String, args = {}, result = null) -> void:
	_write_line("[CALL] %s::%s(args=%s) -> %s" % [
		caller, method, _compact_str(args), _compact_str(result),
	])


## 记录一段自由文本（调试/分隔等），不分类前缀
func log_raw(text: String) -> void:
	_write_line(text)


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
func _write_line(line: String) -> void:
	if not _opened:
		_open_session_file()
	if _file == null or not is_instance_valid(_file):
		return
	_file.seek_end()
	_file.store_line(line)
	_file.flush()


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
