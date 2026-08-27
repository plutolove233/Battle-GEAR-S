## run_one.gd - 单文件测试驱动（调试用）
## 用法:
##   "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_one.gd -- res://tests/test_xxx.gd [res://tests/test_yyy.gd ...]
## 与 run_tests.gd 同款驱动逻辑（SessionLogger 手动补 + process_frame flush + 每方法重置 seed），
## 仅跑命令行指定的测试文件，用于快速迭代；全量回归仍走 run_tests.gd（可配 GEAR_TEST_SLICE）。
extends SceneTree


func _init() -> void:
	_ensure_autoload("SessionLogger", "res://scripts/services/session_logger.gd")
	var driver := Driver.new()
	driver.tree_ref = self
	root.add_child(driver)


func _ensure_autoload(p_name: String, path: String) -> void:
	if root == null:
		return
	if root.has_node(p_name):
		return
	var script: Script = load(path)
	if script == null:
		push_error("run_one: 无法加载 autoload %s @ %s" % [p_name, path])
		return
	var inst = script.new()
	if inst is Node:
		inst.name = p_name
		root.add_child(inst)


class Driver:
	extends Node
	var tree_ref: SceneTree = null
	var failures: int = 0

	func _ready() -> void:
		var args := OS.get_cmdline_user_args()
		if args.is_empty():
			print("用法: -s res://tests/run_one.gd -- res://tests/test_xxx.gd ...")
			if tree_ref:
				tree_ref.quit(1)
			return
		for path in args:
			await _run_file(path)
		if failures > 0:
			print("TESTS FAILED: %d failure(s)" % failures)
		else:
			print("TESTS PASSED")
		if tree_ref:
			tree_ref.quit(1 if failures > 0 else 0)

	func _run_file(path: String) -> void:
		if not ResourceLoader.exists(path):
			print("FAIL 不存在 %s" % path)
			failures += 1
			return
		var script: Script = load(path)
		if script == null:
			print("FAIL 无法加载 %s" % path)
			failures += 1
			return
		var suite: Object = script.new()
		var methods: Array = []
		for item in suite.get_method_list():
			if String(item.name).begins_with("test_"):
				methods.append(item.name)
		for method_name in methods:
			await get_tree().process_frame
			# 每个测试方法前重置全局 RNG（与 run_tests.gd 一致）
			seed(20260719)
			var result = await suite.call(method_name)
			if typeof(result) == TYPE_BOOL and result == true:
				print("PASS %s::%s" % [path, method_name])
			elif typeof(result) == TYPE_BOOL and result == false:
				failures += 1
				print("FAIL %s::%s -> (返回 false)" % [path, method_name])
			else:
				failures += 1
				print("FAIL %s::%s -> %s" % [path, method_name, str(result)])
