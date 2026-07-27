## test_runner_scene.gd — 主场景模式测试入口
##
## -s (SceneTree) 模式下 autoload 全局标识符不注册（SessionLogger 等），
## 导致 GameActions 等脚本编译失败、battle 初始化链断裂。
## 用主场景运行可让 autoload 正常加载。用法：
##   godot --headless --path . res://tests/test_runner_scene.tscn
extends Node

var failures: int = 0

func _ready() -> void:
	var test_files: Array[String] = [
		"res://tests/test_smoke.gd",
		"res://tests/test_data_registry.gd",
		"res://tests/test_battle_math.gd",
		"res://tests/test_battle_state.gd",
		"res://tests/test_campaign_state.gd",
		"res://tests/test_effect_primitives.gd",
		"res://tests/test_action_card_effects.gd",
		"res://tests/test_timing_listener.gd",
		"res://tests/test_action_execution.gd",
		"res://tests/test_target_selection.gd",
		"res://tests/test_param_extraction.gd",
		"res://tests/test_response_window_registration.gd",
		"res://tests/test_respond_attack_flow.gd",
		"res://tests/test_counter_attack_effect2.gd",
		"res://tests/test_flash_real_flow.gd",
		"res://tests/test_ai_input_bridge.gd",
	]
	for path in test_files:
		if not ResourceLoader.exists(path):
			continue
		_run_test_file(path)
	if failures > 0:
		print("TESTS FAILED: %d failure(s)" % failures)
		get_tree().quit(1)
	else:
		print("TESTS PASSED")
		get_tree().quit(0)


func _run_test_file(path: String) -> void:
	var script: Script = load(path)
	var suite: Object = script.new()
	for method_name in suite.get_method_list().map(func(item): return item.name):
		if String(method_name).begins_with("test_"):
			var result = suite.call(method_name)
			if typeof(result) == TYPE_BOOL and result == true:
				print("PASS %s::%s" % [path, method_name])
			else:
				failures += 1
				print("FAIL %s::%s -> %s" % [path, method_name, str(result)])
