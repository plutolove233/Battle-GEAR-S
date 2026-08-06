## TargetChecker.gd — 效果目标合法性检查器
##
## TargetChecker 负责检查效果的目标是否合法。
## 每个目标规则是一个字典 { rule: StringName, ... }，rule 决定检查逻辑。
## check_all 要求所有目标规则都满足才返回 true。
## 当前实现的目标规则：
##   NO_TARGET, TARGET_SLOT_EXISTS, TARGET_IS_MECH, TARGET_IN_RANGE,
##   TARGET_IN_WEAPON_RANGE, TARGET_IS_ADJACENT, TARGET_HAS_EQUIPMENT,
##   CHOOSE_OWN_SLOT, CHOOSE_OWN_WEAPON, CHOOSE_ENEMY_MECH,
##   CHOOSE_ENEMY_MECH_IN_RANGE, CHOOSE_OWN_EQUIPMENT_IN_SLOT,
##   CHOOSE_MAP_CELL_IN_WEAPON_RANGE, CHOOSE_MECH_IN_VARIABLE_RANGE
extends RefCounted
class_name TargetChecker

## Preloaded references for cross-file custom types
const _EffectBinding = preload("res://scripts/action_core/EffectBinding.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


## 检查所有目标规则
static func check_all(binding, payload: Dictionary, target_rules: Array) -> bool:
	if target_rules.is_empty():
		return true
	for rule in target_rules:
		if not check_single(binding, payload, rule):
			return false
	return true


## 检查单个目标规则
static func check_single(binding, payload: Dictionary, rule: Dictionary) -> bool:
	var rule_name: StringName = rule.get("rule", &"NO_TARGET")
	match rule_name:
		&"NO_TARGET":
			return true

		&"TARGET_SLOT_EXISTS":
			var target_mech_id: StringName = payload.get("target_mech_id", payload.get("target_id", &""))
			var slot_id: StringName = payload.get("slot_id", &"")
			if target_mech_id == &"" or slot_id == &"":
				return false
			return payload.get("slot_exists", false)

		&"TARGET_IS_MECH":
			var target_id: StringName = payload.get("target_id", &"")
			if target_id == &"":
				return false
			return payload.get("target_is_mech", false)

		&"TARGET_IN_RANGE":
			# 参数支持 params 嵌套（新机师牌 {"params": {"range": N}}）与顶层（旧牌 {"range": N}）两种格式
			var range_params: Dictionary = rule.get("params", rule)
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			var range_value: int = int(range_params.get("range", rule.get("range", 1)))
			# DIRECT 主动效果（effect_fire）payload 无 source_pos/target_pos/distance：从 binding.context
			# 反查 source_mech_id/target_id 对应机甲位置（与 TARGET_IS_ADJACENT_OR_SELF 同款回退），
			# 否则 pilot_009 等 DIRECT 效果目标选择 resume 后 target 检查永假，反复弹目标选择窗死循环。
			if (source_pos.is_empty() or target_pos.is_empty()) and binding != null and binding.context != null:
				var gs = binding.context.game_state
				if gs != null:
					var src_mid: StringName = binding.get_source_mech_id()
					var tgt_mid: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
					var src_mech = gs.mechs.get(src_mid) if src_mid != &"" else null
					var tgt_mech = gs.mechs.get(tgt_mid) if tgt_mid != &"" else null
					if source_pos.is_empty() and src_mech != null:
						source_pos = src_mech.position
					if target_pos.is_empty() and tgt_mech != null:
						target_pos = tgt_mech.position
			if source_pos.is_empty() or target_pos.is_empty():
				var precomputed_distance: int = payload.get("distance", -1)
				if precomputed_distance >= 0:
					return precomputed_distance <= range_value
				return false
			return _HexGrid.distance(source_pos, target_pos) <= range_value

		&"TARGET_IN_WEAPON_RANGE":
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			var range_value: int = int(payload.get("weapon_range", 1))
			var map_cells: Dictionary = payload.get("map_cells", {})
			if source_pos.is_empty() or target_pos.is_empty():
				return false
			if map_cells.is_empty():
				return _HexGrid.distance(source_pos, target_pos) <= range_value
			return _RangeCalculator.is_in_weapon_range(source_pos, target_pos, range_value, map_cells)

		&"TARGET_IS_ADJACENT":
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			if source_pos.is_empty() or target_pos.is_empty():
				return false
			return _HexGrid.distance(source_pos, target_pos) <= 1

		&"TARGET_IS_ADJACENT_OR_SELF":
			# 维修等效果：目标包含自身与周围1格内的机甲
			var source_mech_id: StringName = binding.get_source_mech_id()
			var target_id: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
			if target_id == &"":
				return false
			# 自身直接通过
			if target_id == source_mech_id:
				return true
			# 相邻判断：优先用 payload 里的 pos，缺失时经 binding.context 查机甲位置
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			if (source_pos.is_empty() or target_pos.is_empty()) and binding != null and binding.context != null:
				var gs = binding.context.game_state
				if gs != null:
					var src_mech = gs.mechs.get(source_mech_id) if source_mech_id != &"" else null
					var tgt_mech = gs.mechs.get(target_id) if target_id != &"" else null
					if src_mech != null:
						source_pos = src_mech.position
					if tgt_mech != null:
						target_pos = tgt_mech.position
			if source_pos.is_empty() or target_pos.is_empty():
				return false
			return _HexGrid.distance(source_pos, target_pos) <= 1

		&"TARGET_HAS_EQUIPMENT":
			var equipment_id: StringName = rule.get("equipment_id", &"")
			if equipment_id == &"":
				return false
			var target_equipment_ids: Array = payload.get("target_equipment_ids", [])
			return equipment_id in target_equipment_ids

		&"CHOOSE_OWN_SLOT":
			var slot_id: StringName = payload.get("selected_slot_id", &"")
			return slot_id != &""

		&"CHOOSE_OWN_WEAPON":
			var weapon_id: StringName = payload.get("selected_weapon_id", &"")
			return weapon_id != &""

		&"CHOOSE_ENEMY_MECH":
			var target_id: StringName = payload.get("target_id", &"")
			if target_id == &"":
				return false
			var owner_id: StringName = binding.get_owner_player_id()
			var target_owner: StringName = payload.get("target_owner_id", &"")
			if target_owner == &"" and binding != null and binding.get("context") != null and binding.context.game_state != null:
				var _tm = binding.context.game_state.mechs.get(target_id)
				if _tm != null:
					target_owner = _tm.owner_player_id
			if target_owner != &"":
				return target_owner != owner_id
			return payload.get("target_is_enemy", false)

		&"CHOOSE_OTHER_MECH":
			# 选择其他机甲（不能是自己）
			var target_id: StringName = payload.get("target_id", &"")
			if target_id == &"":
				return false
			var owner_id: StringName = binding.get_owner_player_id()
			var target_owner: StringName = payload.get("target_owner_id", &"")
			# 从游戏状态反查目标机甲所属玩家（resume 仅注入 target_id，未带 target_owner_id/
			# target_is_enemy 标志--此前锁定牌实际施加从未生效，因这里反复校验失败重弹目标选择）
			if target_owner == &"" and binding != null and binding.get("context") != null and binding.context.game_state != null:
				var _tm = binding.context.game_state.mechs.get(target_id)
				if _tm != null:
					target_owner = _tm.owner_player_id
			# 如果已有目标所属信息，检查不是自己
			if target_owner != &"":
				return target_owner != owner_id
			# 否则检查是否是敌方
			return payload.get("target_is_enemy", false)

		&"CHOOSE_ENEMY_MECH_IN_RANGE":
			# 选择N格范围内的敌方机甲
			var target_id: StringName = payload.get("target_id", &"")
			if target_id == &"":
				return false
			var owner_id: StringName = binding.get_owner_player_id()
			var target_owner: StringName = payload.get("target_owner_id", &"")
			if target_owner != &"" and target_owner == owner_id:
				return false
			var max_range: int = int(rule.get("range", 5))
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			if source_pos.is_empty() or target_pos.is_empty():
				return payload.get("target_in_range", false)
			return _HexGrid.distance(source_pos, target_pos) <= max_range

		&"CHOOSE_OWN_EQUIPMENT_IN_SLOT":
			# 选择自身区域中的装备牌
			var selected_card_id: StringName = payload.get("selected_card_id", &"")
			return selected_card_id != &""

		&"CHOOSE_MAP_CELL_IN_WEAPON_RANGE":
			# 选择武器范围内的格子（用于设陷阱等）
			var cell_pos: Dictionary = payload.get("selected_cell_pos", {})
			if cell_pos.is_empty():
				return false
			var source_pos: Dictionary = payload.get("source_pos", {})
			if source_pos.is_empty():
				return true  # 无法校验时放行
			var weapon_range: int = int(payload.get("weapon_range", 1))
			return _HexGrid.distance(source_pos, cell_pos) <= weapon_range

		&"CHOOSE_MECH_IN_VARIABLE_RANGE":
			# 选择(基础+变量)范围内的机甲
			var target_id: StringName = payload.get("target_id", &"")
			if target_id == &"":
				return false
			var base_range: int = int(rule.get("base_range", 4))
			var variable_name: StringName = rule.get("variable_name", &"")
			var extra_range: int = 0
			if variable_name != &"":
				var owner_id: StringName = binding.get_owner_player_id()
				var mech_id: StringName = binding.get_source_mech_id()
				var key: String = "%s_%s_%s" % [owner_id, mech_id, variable_name]
				extra_range = int(payload.get("variable_%s" % key, 0))
			var max_range: int = base_range + extra_range
			var source_pos: Dictionary = payload.get("source_pos", {})
			var target_pos: Dictionary = payload.get("target_pos", {})
			if source_pos.is_empty() or target_pos.is_empty():
				return payload.get("target_in_range", false)
			return _HexGrid.distance(source_pos, target_pos) <= max_range


		_:
			push_warning("TargetChecker: 未知目标规则 %s，默认返回 true" % rule_name)
			return true
