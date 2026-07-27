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
	var test_path: String = ""
	var failures: int = 0

	func _ready() -> void:
		# 命令行参数：res://tests/xxx.gd
		var args: Array = OS.get_cmdline_user_args()
		if args.size() > 0:
			test_path = args[0]
		else:
			test_path = "res://tests/test_unite_parallel_settlement.gd"
		_run()

	func _run() -> void:
		if not ResourceLoader.exists(test_path):
			print("找不到测试文件: %s" % test_path)
			_finish()
			return
		var script: Script = load(test_path)
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
		_finish()

	func _finish() -> void:
		if failures > 0:
			print("TESTS FAILED: %d failure(s)" % failures)
		else:
			print("TESTS PASSED")
		if tree_ref:
			tree_ref.quit(1 if failures > 0 else 0)
