extends SceneTree

var failures: int = 0

func _init() -> void:
	var test_files: Array[String] = [
		"res://tests/test_smoke.gd",
		"res://tests/test_data_registry.gd",
		"res://tests/test_battle_math.gd",
		"res://tests/test_battle_state.gd",
		"res://tests/test_campaign_state.gd",
	]
	for path in test_files:
		if not ResourceLoader.exists(path):
			continue
		_run_test_file(path)
	if failures > 0:
		print("TESTS FAILED: %d failure(s)" % failures)
		quit(1)
	else:
		print("TESTS PASSED")
		quit(0)

func _run_test_file(path: String) -> void:
	var script: Script = load(path)
	var suite: Object = script.new()
	for method_name in suite.get_method_list().map(func(item): return item.name):
		if String(method_name).begins_with("test_"):
			var result = suite.call(method_name)
			if result != true:
				failures += 1
				print("FAIL %s::%s -> %s" % [path, method_name, str(result)])
			else:
				print("PASS %s::%s" % [path, method_name])
