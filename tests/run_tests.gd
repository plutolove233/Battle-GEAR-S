extends SceneTree

var failures: int = 0


func _init() -> void:
	# -s (SceneTree) 模式下 autoload 单例不会自动加载，而 GameActions/ActionEngine 等
	# 大量脚本原本引用 autoload SessionLogger（裸标识符在 -s 编译期不可解析）。
	# 现已全部改用 SLog（preload 代理，见 scripts/services/slog.gd），编译不再依赖裸标识符；
	# 此处仅为运行期提供 /root/SessionLogger 节点，供 SLog._logger() 查找转发（游戏正常
	# 启动时 autoload 自动提供，测试模式需手动补）。
	_ensure_autoload("SessionLogger", "res://scripts/services/session_logger.gd")

	# 用 Node 驱动器挂到 root，借 process_frame 信号 flush call_deferred
	# （动作父子链恢复靠 call_deferred，-s 模式下 SceneTree._init 不跑主循环迭代，
	# 必须有帧驱动才能让 deferred 执行）。
	var driver := TestDriver.new()
	driver.tree_ref = self
	root.add_child(driver)


## 测试驱动器：逐文件/逐方法运行测试，每个方法间 await process_frame
## 使 call_deferred 排入的恢复调用能被 flush。
class TestDriver:
	extends Node
	var tree_ref: SceneTree = null
	var test_files: Array[String] = []
	var current_index: int = 0
	var failures: int = 0

	func _ready() -> void:
		test_files = [
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
			"res://tests/test_evade_response_completes.gd",
			"res://tests/test_evade_enemy_turn_resume.gd",
			"res://tests/test_expose_response_steal.gd",
			"res://tests/test_expose_predict_scenarios.gd",
			"res://tests/test_counter_attack_effect2.gd",
			"res://tests/test_counter_attack_chain.gd",
			"res://tests/test_assault_chase_flow.gd",
			"res://tests/test_assault_noncounter_response.gd",
			"res://tests/test_assault_autoplay_ordering.gd",
			"res://tests/test_flash_real_flow.gd",
			"res://tests/test_flash_counter_order.gd",
			"res://tests/test_attack_settle_priority_order.gd",
			"res://tests/test_smash_armor_break_real_flow.gd",
			"res://tests/test_defend_real_flow.gd",
			"res://tests/test_armor_this_turn_fix.gd",
			"res://tests/test_sniper_range_fix.gd",
			"res://tests/test_unicorn_repeat_loop.gd",
			"res://tests/test_thrust_effect2_real_flow.gd",
			"res://tests/test_repair_repro.gd",
			"res://tests/test_energy_unite_fix.gd",
			"res://tests/test_energy_charge_might.gd",
			"res://tests/test_unite_status_flow.gd",
			"res://tests/test_unite_parallel_settlement.gd",
		"res://tests/test_unite_pvp_parallel.gd",
			"res://tests/test_cover_real_flow.gd",
			"res://tests/test_predict_discards_cover.gd",
			"res://tests/test_awaken_real_flow.gd",
		"res://tests/test_equipment_effects.gd",
		"res://tests/test_pilot_system.gd",
		"res://tests/test_pilot_integration.gd",
		"res://tests/test_pilot_001_akrom.gd",
		"res://tests/test_pilot_001_cover_thrust.gd",
			"res://tests/test_pilot_001_energy_charge.gd",
			"res://tests/test_pilot_002_rabil.gd",
			"res://tests/test_pilot_003_selkill.gd",
			"res://tests/test_pilot_004_masha.gd",
			"res://tests/test_pilot_005_kent.gd",
			"res://tests/test_pilot_008_andromeda.gd",
		"res://tests/test_pilot_011_dean.gd",
		"res://tests/test_pilot_012_mariel.gd",
		"res://tests/test_pilot_012_013_dual_attack.gd",
		"res://tests/test_pilot_013_bartolov.gd",
		"res://tests/test_pilot_014_aaron.gd",
		"res://tests/test_pilot_015_nora.gd",
		"res://tests/test_pilot_016_murdoch.gd",
		"res://tests/test_pilot_017_volt.gd",
		"res://tests/test_pilot_018_tesi.gd",
		"res://tests/test_pilot_019_kente.gd",
		"res://tests/test_pilot_020_kende.gd",
		"res://tests/test_pilot_021_taliyah.gd",
		"res://tests/test_pilot_022.gd",
		"res://tests/test_pilot_023_kande.gd",
		"res://tests/test_pilot_024_lin.gd",
		"res://tests/test_pilot_025_joshua.gd",
		"res://tests/test_pilot_026_ivan.gd",
		"res://tests/test_pilot_025_026_realpath.gd",
		"res://tests/test_pilot_027_veronica.gd",
		"res://tests/test_pilot_028_wur.gd",
		"res://tests/test_pilot_029_keber.gd",
		"res://tests/test_pilot_030_brook.gd",
		"res://tests/test_pilot_031_laitel.gd",
		"res://tests/test_pilot_032_aeria.gd",
		"res://tests/test_pilot_033_yuri.gd",
		"res://tests/test_pilot_034_cervantes.gd",
		"res://tests/test_pilot_035_kumas.gd",
		"res://tests/test_pilot_036_felice.gd",
		"res://tests/test_pilot_037_qingtong.gd",
		"res://tests/test_pilot_038_aodai.gd",
		"res://tests/test_pilot_039_kaiwei.gd",
		"res://tests/test_pilot_040_tiger.gd",
		"res://tests/test_pilot_041_gaiqite.gd",
		"res://tests/test_pilot_042_delendi.gd",
		"res://tests/test_pilot_043_gwen.gd",
		"res://tests/test_pilot_044_suolun.gd",
		"res://tests/test_pilot_045_kenzier.gd",
		"res://tests/test_pilot_046_horn.gd",
		"res://tests/test_pilot_046_popup_close.gd",
		"res://tests/test_pilot_047_leona.gd",
		"res://tests/test_pilot_047_fork.gd",
		"res://tests/test_pilot_048_chiya.gd",
		"res://tests/test_pilot_049_jiening.gd",
		"res://tests/test_pilot_049_fork.gd",
		"res://tests/test_pilot_049_popup_routing.gd",
		"res://tests/test_pilot_050_jessica.gd",
		"res://tests/test_pilot_052_saier.gd",
		"res://tests/test_pilot_053_yalin.gd",
		"res://tests/test_pilot_054_likal.gd",
		"res://tests/test_pilot_055_hawk.gd",
		"res://tests/test_pilot_056_kaili.gd",
		"res://tests/test_pilot_057_graham.gd",
		"res://tests/test_pilot_058_camilla.gd",
		"res://tests/test_pilot_059_weir.gd",
		"res://tests/test_pilot_060_kaide.gd",
		"res://tests/test_pilot_061_aishi.gd",
		"res://tests/test_pilot_065_yinxue.gd",
		"res://tests/test_pilot_063_butcher.gd",
		"res://tests/test_pilot_062_luoern.gd",
		"res://tests/test_pilot_064_boge.gd",
		"res://tests/test_pilot_066_hacker.gd",
		"res://tests/test_pilot_067_dan.gd",
		"res://tests/test_pilot_068_bingpo.gd",
		"res://tests/test_pilot_069_yingsha.gd",
		"res://tests/test_pilot_070_liehuo.gd",
		"res://tests/test_pilot_071_miya.gd",
		"res://tests/test_pilot_072_kaxiu.gd",
		"res://tests/test_pilot_073_falco.gd",
		"res://tests/test_pilot_074_taite.gd",
		"res://tests/test_pilot_075_kenensi.gd",
		"res://tests/test_pilot_076_疾风.gd",
		"res://tests/test_pilot_077_viola.gd",
		"res://tests/test_pilot_079_linuo.gd",
		"res://tests/test_pilot_081_汀兰.gd",
		"res://tests/test_pilot_082_温斯顿.gd",
		"res://tests/test_pilot_083_瓦恩.gd",
		"res://tests/test_pilot_084_莎菲雅.gd",
		"res://tests/test_pilot_085_mangke.gd",
		"res://tests/test_pilot_086_獠鼠.gd",
		"res://tests/test_pilot_087_tanila.gd",
		"res://tests/test_pilot_088_conquer.gd",
		"res://tests/test_weapon_effects.gd",
		"res://tests/test_weapon_named_response.gd",
		"res://tests/test_weapon_name_recognition.gd",
		"res://tests/test_lark_torso_virtual_weapon.gd",
		"res://tests/test_lock_effect.gd",
		"res://tests/test_ai_controller.gd",
		"res://tests/test_ai_input_bridge.gd",
		"res://tests/test_log_bugs_fix.gd",
		"res://tests/test_state_snapshot_roundtrip.gd",
		"res://tests/test_net_transport.gd",
		"res://tests/test_pvp_client_intents.gd",
		"res://tests/test_pvp_lockstep_sync.gd",
		"res://tests/test_pvp_lockstep_attack_combo.gd",
		"res://tests/test_pvp3_setup.gd",
		"res://tests/test_pvp3_net_host.gd",
		"res://tests/test_pvp3_turn_rotation.gd",
		"res://tests/test_pvp3_pilot_select.gd",
		"res://tests/test_pvp3_victory.gd",
		"res://tests/test_pvp3_ui.gd",
		"res://tests/test_pvp3_lockstep_sync.gd",
		"res://tests/test_pvp3_lockstep_attack_combo.gd",
		"res://tests/test_map_markers.gd",
		"res://tests/test_event_cards.gd",
		"res://tests/test_event_card_fixes.gd",
		"res://tests/test_pilot_051_080.gd",
		"res://tests/test_pvp3_p051_ui_double_click.gd",
		"res://tests/test_pvp3_p080_move_desync.gd",
		"res://tests/test_p080_event_li_diag.gd",
		"res://tests/test_pvp3_p080_event_li_desync.gd",
		"res://tests/test_pvp3_p080_li_cancel_routing.gd",
		"res://tests/test_multi_target_attack.gd",
		]
		_apply_slice()
		_run()

	## 分段运行：环境变量 GEAR_TEST_SLICE="N/M"（N从0开始）只跑第 N 段（共 M 段）。
	## 规避单进程反复 load_all 累积段错误（各段独立进程跑）。不设则跑全部。
	func _apply_slice() -> void:
		var slice_str: String = OS.get_environment("GEAR_TEST_SLICE")
		if slice_str == "":
			return
		var parts := slice_str.split("/")
		if parts.size() != 2:
			return
		var idx: int = int(parts[0])
		var total: int = int(parts[1])
		if total <= 0 or idx < 0 or idx >= total:
			return
		var per: int = int(ceil(float(test_files.size()) / float(total)))
		var start: int = idx * per
		var endv: int = mini(start + per, test_files.size())
		test_files = test_files.slice(start, endv)
		print("[SEGMENT %d/%d] files %d..%d (%d files)" % [idx, total, start, endv - 1, test_files.size()])

	func _run() -> void:
		for path in test_files:
			if not ResourceLoader.exists(path):
				continue
			await _run_file(path)
		_finish()

	func _run_file(path: String) -> void:
		var script: Script = load(path)
		if script == null:
			return
		var suite: Object = script.new()
		var methods: Array = []
		for item in suite.get_method_list():
			if String(item.name).begins_with("test_"):
				methods.append(item.name)
		for method_name in methods:
			await get_tree().process_frame
			# 每个测试方法前重置全局 RNG，防止上个测试的 seed() 残留污染全局 randi() 路径
			# （campaign_state._shuffle_and_copy 等）。context.rng 的确定性由 battle.rng_seed
			# 默认 12345 保证（见 battle_state.gd），不受全局 seed() 影响。
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

	func _finish() -> void:
		if failures > 0:
			print("TESTS FAILED: %d failure(s)" % failures)
		else:
			print("TESTS PASSED")
		if tree_ref:
			tree_ref.quit(1 if failures > 0 else 0)


func _ensure_autoload(p_name: String, path: String) -> void:
	if root == null:
		return
	if root.has_node(p_name):
		return
	var script: Script = load(path)
	if script == null:
		push_error("run_tests: 无法加载 autoload %s @ %s" % [p_name, path])
		return
	var inst = script.new()
	if inst is Node:
		inst.name = p_name
		root.add_child(inst)
