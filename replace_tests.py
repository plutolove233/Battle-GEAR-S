# -*- coding: utf-8 -*-
import io
path = 'tests/test_pilot_integration.gd'
with io.open(path, 'r', encoding='utf-8') as fh:
    lines = fh.read().split('\n')

def replace_func(lines, func_name, new_body):
    start = None
    for i, line in enumerate(lines):
        if line.startswith('func ' + func_name + '('):
            start = i
            break
    if start is None:
        print("NOT FOUND:", func_name)
        return lines, False
    end = None
    for i in range(start + 1, len(lines)):
        s = lines[i].strip()
        if s == 'return true' or s == 'return false':
            end = i
            break
    if end is None:
        print("NO END:", func_name)
        return lines, False
    new_lines = new_body.split('\n')
    return lines[:start] + new_lines + lines[end + 1:], True

new1 = u"""func test_pilot_006_effect03_full_chain_auto_fallback() -> Variant:
\tvar battle := _new_battle()
\tif battle == null or battle.context == null:
\t\treturn "battle 初始化失败"
\tvar gs = battle.context.game_state
\tvar cdb = battle.context.card_database
\tvar player_mech = gs.get_mech_for_player(&"player")
\tvar enemy_mech = gs.get_mech_for_player(&"enemy")
\tif player_mech == null or enemy_mech == null:
\t\treturn "机甲缺失"
\tgs.active_player_id = &"player"
\tgs.phase = &"MAIN"
\tenemy_mech.position = {"q": 4, "r": 2}
\t_clear_map_terrain(battle)
\tvar card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
\tif card == null:
\t\treturn "找不到 pilot_006_里昂"
\tbattle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
\tvar enemy = gs.players.get(&"enemy")
\tenemy.action_hand.clear()
\tvar hp_before: int = enemy_mech.current_hp
\tvar attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
\tbattle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
\t# 两段式：ATTACK_SETTLE 不阻塞，注册延迟 pending（不弹窗）
\tif attack.state == &"waiting_timing":
\t\treturn "两段式 ATTACK_SETTLE 不应挂起弹窗"
\tvar pend := _ActionPilotEffects.pop_pilot_006_post_attack(attack.action_id)
\tif pend.is_empty():
\t\treturn "应注册战后逼迫 pending"
\t# 顶层执行 effect_03b（模拟 attack 完成后 app_root 触发）
\tvar fire := _Action.new()
\tfire.action_id = &"test_p006_e3b_fb"
\tfire.action_type = &"effect_fire"
\tfire.record = {"effect_id": &"pilot_006_effect_03b", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
\tfire.state = &"running"
\tfire.context = battle.context
\tbattle.context.action_registry.register(fire)
\tbattle.context.timing_engine._execute_effect_by_id(&"pilot_006_effect_03b", fire.record, fire)
\t# 选机甲挂起（CHOOSE_OTHER_MECH）
\tif fire.state != &"waiting_timing":
\t\treturn "effect_03b 应挂起选机甲 state=%s" % String(fire.state)
\tbattle.context.timing_engine.resume_pending_effect(fire.action_id, {"target_id": enemy_mech.mech_id})
\t# enemy 无攻击牌 -> CHOOSE_ONE 仅剩\"4伤害\" -> 自动选 -> HP-4
\tif enemy_mech.current_hp != hp_before - 4:
\t\treturn "无攻击牌应回落4伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
\t_clear_all_pilot_static()
\treturn true"""

new2 = u"""func test_pilot_006_effect03_full_chain_choose_4damage() -> Variant:
\tvar battle := _new_battle()
\tif battle == null or battle.context == null:
\t\treturn "battle 初始化失败"
\tvar gs = battle.context.game_state
\tvar cdb = battle.context.card_database
\tvar player_mech = gs.get_mech_for_player(&"player")
\tvar enemy_mech = gs.get_mech_for_player(&"enemy")
\tif player_mech == null or enemy_mech == null:
\t\treturn "机甲缺失"
\tgs.active_player_id = &"player"
\tgs.phase = &"MAIN"
\tenemy_mech.position = {"q": 4, "r": 2}
\t_clear_map_terrain(battle)
\tvar card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
\tif card == null:
\t\treturn "找不到 pilot_006_里昂"
\tbattle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
\tvar enemy = gs.players.get(&"enemy")
\tvar atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
\tif atk == null:
\t\treturn "找不到 action_001_进攻"
\tenemy.action_hand.append(atk.instance_id)
\tvar hp_before: int = enemy_mech.current_hp
\tvar attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
\tbattle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
\tvar pend := _ActionPilotEffects.pop_pilot_006_post_attack(attack.action_id)
\tif pend.is_empty():
\t\treturn "应注册战后逼迫 pending"
\tvar fire := _Action.new()
\tfire.action_id = &"test_p006_e3b_4dmg"
\tfire.action_type = &"effect_fire"
\tfire.record = {"effect_id": &"pilot_006_effect_03b", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
\tfire.state = &"running"
\tfire.context = battle.context
\tbattle.context.action_registry.register(fire)
\tbattle.context.timing_engine._execute_effect_by_id(&"pilot_006_effect_03b", fire.record, fire)
\tif fire.state != &"waiting_timing":
\t\treturn "effect_03b 应挂起选机甲 state=%s" % String(fire.state)
\tbattle.context.timing_engine.resume_pending_effect(fire.action_id, {"target_id": enemy_mech.mech_id})
\t# enemy 有攻击牌+武器射程覆盖 -> 两 option 可用 -> 挂起二选一
\tif fire.state != &"waiting_timing":
\t\treturn "选机甲后应挂起二选一弹窗 state=%s" % String(fire.state)
\tif not battle.context.timing_engine._pending_effect.has(fire.action_id):
\t\treturn "_pending_effect 应有二选一挂起记录"
\t# 选\"受到4伤害\"（option index 1）
\tbattle.context.timing_engine.resume_pending_effect(fire.action_id, {"chosen_option_index": 1})
\tif enemy_mech.current_hp != hp_before - 4:
\t\treturn "选4伤害后应 HP-4 实=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
\t_clear_all_pilot_static()
\treturn true"""

lines, ok1 = replace_func(lines, 'test_pilot_006_effect03_full_chain_auto_fallback', new1)
lines, ok2 = replace_func(lines, 'test_pilot_006_effect03_full_chain_choose_4damage', new2)

with io.open(path, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(lines))
print("ok1=%s ok2=%s" % (ok1, ok2))
