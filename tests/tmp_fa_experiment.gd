extends SceneTree

## 实验：模拟3个PvP3进程同秒打开同一个 session_log 文件的写入行为
## 用法: godot --headless -s res://tests/tmp_fa_experiment.gd -- --tag=A [--delay=N]

func _init() -> void:
	var tag := "?"
	var delay_ms := 0
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if String(args[i]).begins_with("--tag="):
			tag = String(args[i]).substr(6)
		elif String(args[i]).begins_with("--delay="):
			delay_ms = int(String(args[i]).substr(8))
	if delay_ms > 0:
		OS.delay_msec(delay_ms)
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists("battle_logs"):
		dir.make_dir("battle_logs")
	# 与 SessionLogger 完全一致的 stamp 逻辑（固定同秒，模拟两 client 同秒）
	var stamp := "20260827_EXP01"
	var path := "res://battle_logs/session_log_%s.txt" % stamp
	var f := FileAccess.open(path, FileAccess.WRITE_READ)
	if f == null:
		print("PROC %s: OPEN FAILED (err=%d)" % [tag, FileAccess.get_open_error()])
		quit(1)
		return
	f.seek_end()
	f.store_line("════════ 会话日志 ════════")
	f.store_line("启动时间: %s (proc %s)" % [stamp, tag])
	f.flush()
	OS.delay_msec(300)
	for i in range(10):
		f.seek_end()
		f.store_line("[LINE] proc=%s line=%d" % [tag, i])
		f.flush()
		OS.delay_msec(100)
	f.close()
	print("PROC %s: DONE" % tag)
	quit(0)
