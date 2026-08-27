## run_batch.gd - 批量测试驱动（一次进程跑多个测试文件，用于全量分段回归）
## 用法：godot --headless --path . -s res://tests/run_batch.gd -- <file1.gd> <file2.gd> ...
extends SceneTree

var failures: int = 0


func _init() -> void:
	_ensure_autoload("SessionLogger", "res://scripts/services/session_logger.gd")
	var driver := TestDriver.new()
	driver.tree_ref = self
	root.add_child(driver)


func _ensure_autoload(p_name: String, path: String) -> void:
	if root == null:
		return
	if root.has_node(p_name):
		return
	var script: Script = load(path)
	if script == null:
		return
	var inst = script.new()
	if inst is Node:
		inst.name = p_name
		root.add_child(inst)


class TestDriver:
	extends Node
	var tree_ref: SceneTree = null
	var failures: int = 0

	func _ready() -> void:
		var args: Array = OS.get_cmdline_user_args()
		var paths: Array = []
		for a in args:
			if String(a).ends_with(".gd") and ResourceLoader.exists(String(a)):
				paths.append(String(a))
		if paths.is_empty():
			print("BATCH: 无有效测试文件参数")
			_finish()
			return
		_run_all(paths)

	func _run_all(paths: Array) -> void:
		for test_path: String in paths:
			var script: Script = load(test_path)
			if script == null:
				failures += 1
				print("FAIL %s -> (加载失败)" % test_path)
				continue
			var suite: Object = script.new()
			var methods: Array = []
			for item in suite.get_method_list():
				if String(item.name).begins_with("test_"):
					methods.append(item.name)
			for method_name in methods:
				await get_tree().process_frame
				seed(20260719)
				var result = await suite.call(method_name)
				if typeof(result) == TYPE_BOOL and result == true:
					print("PASS %s::%s" % [test_path, method_name])
				elif typeof(result) == TYPE_BOOL and result == false:
					failures += 1
					print("FAIL %s::%s -> (返回 false)" % [test_path, method_name])
				else:
					failures += 1
					print("FAIL %s::%s -> %s" % [test_path, method_name, str(result)])
			suite = null
		_finish()

	func _finish() -> void:
		if failures > 0:
			print("TESTS FAILED: %d failure(s)" % failures)
		else:
			print("TESTS PASSED")
		if tree_ref:
			tree_ref.quit(1 if failures > 0 else 0)
