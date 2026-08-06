# 机师牌 SSR 落码工程 · 下一 session 接力提示词 v3（2026-08-05）

> 本提示词接续上一 session（pilot_003 effect_02 离堆强制使用完成）。**SSR 001-010 十个机师的 effect 机制层已全部落码**。剩下的是：集成测试完善、UI 完善、PvP state_snapshot、实机双窗口验证。

## 0. 权威来源与裁定优先级（必读）

1. **权威拆解**：`new_logic/机师牌效果逻辑拆解_SSR_001-010.txt`（外部模型已输出）。每个 effect 的「回答」「补充」「重要补充」是用户检查裁定的结果，权威最高，与拆解正文冲突时以裁定为准。
2. **任务书原版**：`new_logic/机师牌落码_SSR001-010+机师系统_下一session提示词.md`（含裁定 delta、共享新增件、落码顺序）。
3. **记忆**：`MEMORY.md` 里 `pilot-system-infra-progress-2026-08-05` 是当前进度记忆（**已更新到 effect_02 完成**）；`gdscript-lambda-value-capture`、`pilot-effects-decomp-and-semantics-2026-08-05` 等相关。每完成一块更新进度记忆。
4. **先做 PvP 双人类玩家，不管 AI**。逻辑和 UI 按 `player_id` 通用路由。

## 1. 注意事项（与用户约定）

1. **先不管 AI**，做 PvP 人类玩家逻辑和 UI，按 player_id 通用路由。
2. **不要做多余阅读**，有记忆就用记忆，立即开始；记得存/更新记忆。
3. **操作过程中不懂不确定就问我**（过程中商量着来），多问少错。
4. **不要用 Agent（subagent）**。不要用 python3，用 python。
5. **保证先前测试全部通过无回归**（当前基线：**446 测试 PASS**，pilot_system 32 测试）。
6. **Godot 在 `F:/Godot_4.6/Godot_v4.6-stable_win64.exe`**，每次测试用 timeout 即时关闭：
   ```bash
   timeout 150 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd 2>&1 | grep -E "TESTS (PASSED|FAILED)|FAIL |SCRIPT ERROR" | head -8
   ```
7. **用中文回复用户**（用户看不懂英文）。代码/标识符/文件内注释保持英文。

## 2. 已完成进度（SSR 001-010 机制层全部完成，446 测试全过）

| 机师 | 完成 effect | 说明 |
|---|---|---|
| pilot_001 阿克罗姆 | effect_01 双重生效 | REPEAT_USED_ACTION_EFFECT_CHAIN 重新执行 DIRECT effect，repeat_depth 防递归 |
| pilot_002 莱比尔 | **effect_01 batch transform 完整（4切片）** + effect_02 + effect_03 | 见 2.1 |
| pilot_003 瑟尔基尔 | **effect_01 公开埋牌 + effect_02 离堆强制使用 + effect_03 跳过正面牌** | **effect_02 本 session 完成，见 2.2** |
| pilot_004 玛沙 | effect_01/02/03a/03b 全 | POWER_CAP_MODIFIER 等 |
| pilot_005 肯特 | effect_01/02/03 全 | faction aura provider + granted |
| pilot_006 里昂 | effect_01/02/03 全 | effect_03 战后逼迫 |
| pilot_007 珀修斯 | effect_01/02 全 | effect_02 类型破绽 |
| pilot_008 安德洛美达 | effect_01a/01b/02/03 全 | X 变量绑 card_instance_id |
| pilot_009 美杜莎 | effect_01 全（含**使用受控牌+立即弃置全弃**） | |
| pilot_010 刻托 | effect_01/02/03 全 | SWAP 持久 + 视为序列 + 第4张禁止 |

测试文件：`tests/test_pilot_system.gd`（32 测试：test1-29 + test30/31 + test_pilot_selection_with_cost）。测试模式：`_new_battle()` 建 BattleState + context；`_make_pilot_instance(gs, cdb, card_id, owner)` 建机师牌实例；直接调 `game_actions.xxx` 验证动作语义；effect 触发用 `fire_timing` + `resume_pending_effect`；helper 测试用 `_Action.new()` mock action + `timing_engine._helper(...)`。

### 2.1 pilot_002 effect_01 batch transform（完整）

- **授予**：`GameSetupService._grant_pilot_002_to_federation_mechs` 向联邦机师注册 granted DIRECT 进攻 `pilot_002_granted_transfer_attack`（虚拟时点）+ AVAILABILITY 防御 `pilot_002_granted_transfer_defense`（ATTACK_AT）。`_register_pilot_effects` 里 pilot_002_effect_01 provider 跳过→调授予。
- **交牌流程**：CHOOSE_MANY_CARDS `store_result_key=pilot_002_transfer_batch` → TRANSFER_ACTION_CARDS（`$runtime.xxx` + `to_player_id` 转换 + batch_tag 标记）→ GRANT_TRANSFER_BATCH_AS_NAMED_TYPE（登记批次+注册批次使用 listener+存 `payload["pilot_002_current_batch_id"]`）→（防御链）PILOT_002_USE_BATCH_AS_NAMED → DRAW_ACTION 2。
- **批次使用**：`PILOT_002_USE_BATCH_AS_NAMED`（非原子，映射 use_action_card + `_extract_pilot_002_batch_use_params`：调 `pilot_002_discard_batch` 丢弃整批保留首张虚拟牌 + virtual_transform as action_001_进攻/009_防御 + attack_is_active 控制攻击数）。批次使用 effect：`pilot_002_batch_use_attack`(DIRECT) + `pilot_002_batch_use_defense`(AVAILABILITY)。
- **破裂检测**：`PILOT_002_HAS_USABLE_BATCH` 条件（批次牌任一离手牌则 false）。
- **离场清除**：`unset_pilot` 里 `clear_pilot_002_batches_for_source`（裁定歧义4：莱比尔离场所有权限和增益都没了）。
- 关键：`ActionPilotEffects._pilot_002_batches` 静态存储 + register/get/mark_used/clear_for_source/get_usable_attack_batch helper。

### 2.2 pilot_003 瑟尔基尔（effect_01/02/03 全部完成）

- **effect_01 公开埋牌**（once_per_turn）：`INSERT_ACTION_CARDS_FACE_UP_RANDOM` atomic（随机插入牌堆+标记 `face_up_in_deck/leave_deck_owner_mech/leave_deck_owner_pid/source_pilot/face_up_leave_use` counters）；`CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP` need_input act_type（复用 unite 单选面板选1张置顶，resume phase=`pilot_003_choose_top`）；`pilot_003_move_to_deck_top`。
- **effect_02 离堆强制使用**（本 session 完成，方案B）：见 2.2.1。
- **effect_03 跳过公开牌**：`TOGGLE_PILOT_003_SKIP` atomic（切换 `is_pilot_003_skip_active`）；`GameActions.draw_action_cards` 改造（skip 激活时 count+1 + 跳过 face_up_in_deck 牌找第一张背面牌）；unset 清除。**简化版**（仅 self toggle，任务书裁定"复选框列表勾选玩家"的完整 UI 待做）。

#### 2.2.1 pilot_003 effect_02 离堆强制使用（本 session 完成）

- **方案**（用户确认 B）：抽牌路径手动 fire 时点（虚拟 Action），**不改核心抽牌流程**。
- **时点**：`CARD_LEAVE_ACTION_DECK_BEFORE`（TimingConst 已加）。fire 点接入 `DeckService.draw_from_deck`：抽到带 `pilot_003_face_up_leave_use` 标记的行动牌时，用轻量虚拟 Action（仿 `TurnService._fire_timing`，action_type=card_zone_change，record 含 card_instance_id/from_zone=action_deck/to_zone=hand/player_id=metadata owner）fire 该时点。
- **拦截握手**：`draw_from_deck` 改 `while drawn.size() < count`（被拦截牌弹出但不计入 drawn，续抽补足 count——歧义4"被拦截牌不计入已获得数量"）；fire 后读 `card.counters["pilot_003_intercepted"]`（CANCEL 写入），true 则 erase 该标记 + continue。
- **`CANCEL_PARENT_CARD_TRANSFER`**（atomic）：解析 `$payload.card_instance_id` → 写 `card.counters["pilot_003_intercepted"]=true`。
- **`IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK`**（atomic）：`_handle_pilot_003_immediately_use`——使用者=card.counters 的 `pilot_003_leave_deck_owner_pid/_mech`（metadata 权威）；`_pilot_003_can_use_card` 预检（**含 AVAILABILITY 效果→不可用**/无 DIRECT|LISTEN→不可用/**攻击牌需至少1武器能命中1存活敌方**）；可用→`_pilot_003_force_use` 独立顶层 `use_action_card`（`source_action_id=pilot_003_force_use` 非空→validate 跳过 can_attack + settle 跳过攻击数=passive 攻击；先清正面/metadata counters+zone=temp_zone；**保留 pilot_003_intercepted 供 draw 读**）；不可用→`_pilot_003_unusable_discard`（清正面/metadata + `deck_service.discard_card(reason=pilot_003_unusable_face_up_card)` + `draw_action_cards(owner,1)` 补偿）。
- **条件 op**：`PAYLOAD_CARD_HAS_RUNTIME_TAG`（读 payload.card_instance_id→card.counters[tag]）+ `PAYLOAD_FROM_ZONE_IS`（payload.from_zone==zone）。**坑：条件参数从 `condition.get("params", condition)` 读（params 嵌套），不可直接 `condition.get("tag"/"zone")`（顶层为空）。**
- **effect 定义**：pilot_003_effect_02 LISTEN CARD_LEAVE priority30 listen_action_type=card_zone_change，conditions 含上述两 op，actions=[CANCEL_PARENT_CARD_TRANSFER, IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK]。注册走 `_register_pilot_effects` 通用 LISTEN 分支。
- **测试 test30（不可用防御→弃置+抽1）**：防御含 AVAILABILITY→预检 false→公开弃牌+enemy仍抽到1张背面牌+P1抽1补偿+正面标记清除。**test31（可用进攻→强制使用）**：enemy移近到(4,2)使基础武器 range4 命中→use_action_card 动作存在于 registry（暂停等武器选择）+attack_count_this_turn 不变+enemy补足抽数。
- **局限**：fire 点只接**抽牌路径**；拆解文"拦截所有离堆原因"（牌堆顶弃置/检索/展示后移动）未接。

### 2.3 基础设施

- **infra 2.1 开局选择机制**（test28 PASS）：`CampaignState.generate_random_pilot_selection(count=3)`（Fisher-Yates 从 registry.list_pilot_cards() 全量池）+ `select_pilot_with_cost(pilot_id)`（校验 available_gold>=cost，扣金币，设 selected_pilot）+ `available_gold=15`。
- **infra 2.6 dev 换机师**（test29 PASS）：`DevModeService.change_pilot(player_id, pilot_def_id)`（unset 旧+set 新）+ `modify_player_limits(player_id, attack_limit, action_card_limit, gold)`（即时重算 max_attacks_per_turn）。
- **UI 部分**：equipment_panel 摘要加剩余攻击数（`攻击:attack_count_this_turn/max_attacks_per_turn`）；机师槽 DIRECT 触发按钮显示效果名（`bind_ctx.slot_id=="pilot"` 时 `btn.text=display_name`）。pilot DIRECT 效果已通过 `_active_by_card` 机制在机师槽自动渲染（`can_trigger_active_effect` 置灰）。

## 3. 待做清单（按优先级）

### A. 集成测试完善（各 effect 触发链 + 换机师 + PvP 双窗口）
- 每个 effect 至少跑拆解文「测试场景」的 a/b/c（正常/取消/条件不满足）。用 `fire_timing` + `resume_pending_effect(action_id, {"chosen_option_index":N})` 触发 LISTEN effect + CHOOSE_ONE。
- 重点：pilot_002 batch transform 完整链（granted DIRECT→交牌→批次使用→破裂）、pilot_003 e1（插牌→置顶）+ e2 补充场景、pilot_006 e3（attack ATTACK_SETTLE→选目标→二选一→选牌 use_action_card）、pilot_009（DIRECT 触发→支付→grant→使用/弃置）、pilot_007 e2（ATTACK_PRE 触发）。
- **换机师测试**：dev 换机师→旧 listener 注销 + 派生失效 + 变量隔离（pilot_008 X 不转移/pilot_009 控制解除/pilot_002 批次全清/pilot_003 skip 清除）。
- PvP 双人类玩家场景：两窗口操作，验证跨玩家弹窗、状态同步（实机验证见 D）。

### B. UI 完善
- **悬停浮窗**：机师效果按钮悬停显示效果介绍/状态/已用次数/剩余次数/X 变量（仿 equipment 悬停浮框 `_build_tooltip_bbcode`）。
- **pilot_003 effect_03 复选框 UI**（裁定权威）：点 effect_03 按钮弹复选框列表（列出所有玩家含自己），勾选"抽牌跳过正面牌"的玩家，提交后生效；被勾选玩家抽牌遇正面牌自动跳过；仅当瑟尔基尔自己被勾选且本次即将抽的牌含正面牌时本次抽牌数+1。当前实现是简化版（仅 self toggle），需扩展为多玩家勾选（`ActionPilotEffects._pilot_003_skip` 已按 source_pilot→{player_id} 存，可支持）。
- **开局选择 UI**：app_root 出击准备屏显示3张随机机师牌（名称/阵营/稀有度/费用/技能文本），点选1张→扣 cost→显示剩余金币→进装备选择。初始金币15。PvP 流程；教程保留 pilots[0]。
- **dev 面板机师操作区**：下拉选机师→change_pilot；编辑 attack_limit/action_card_limit/gold→modify_player_limits。

### C. PvP state_snapshot 补机师数值
- 已同步：attack_count_this_turn/max_attacks_per_turn/attack_limit/action_card_limit（state_snapshot.gd 60-61/118-119/268-269/303-304）。
- 需补：机师 card_instance_id + def（pilot 槽，需 set_pilot 双端执行或 snapshot 重建）、X 变量（pilot_008，存 card.counters["var_X"]）、正面牌（pilot_003，双端一致随机种子）、pilot_009 控制状态、pilot_006 悬赏标记。**注意：这些是 ActionPilotEffects 静态存储 + card.counters，PvP 双端需一致同步。**

### D. 实机验证（PvP 双人类玩家）
- 两窗口完整流程：开局选机师→装备选择→战斗→各机师效果触发。
- 重点：pilot_002 交牌弹窗跨玩家路由、pilot_003 埋牌/离堆拦截的跨窗口一致性、pilot_006 二选一弹窗归属被选机甲玩家。

### E. 剩余杂项
- `pilot_002_granted_transfer_defense` 防御链的响应窗口双选交互（交牌者选交牌→目标立即用批次当防御）实机验证。
- `PILOT_002_USE_BATCH_AS_NAMED` 的 `_is_atomic_action` 已确认不包含（正确，非原子）。
- **effect_02 扩展**：fire 点扩展到其他离堆原因（牌堆顶弃置/检索/展示后移动）——拆解文要求，当前只接抽牌路径。

## 4. 关键坑（必读）

- **GeneratedActionEffects 在 `scripts/action_core/`**（非 generated_database）。ActionPilotEffects 在 `scripts/generated_database/`。
- **DeckState 字段 `action_discard_pile`**（非 action_discard）。
- **card_id 带_名字后缀**：`action_001_进攻`/`action_008_回避`/`action_009_防御`/`pilot_002_莱比尔`/`pilot_003_瑟尔基尔`/`pilot_006_里昂` 等。effect_ids 须手工核对 JSON 补全（pilot_003 补 effect_03 已做、pilot_006 补 effect_03 已做）。
- **priority higher-first**：TimingEngine sort `pa > pb`，数值越大越先；范围 -1~30，常规 10，顺序保证 20/30。
- **String != StringName 在 Godot 4.6 触发 mem null 崩溃**（CHOOSE_ONE chooser 路由 `co_chooser_expr != &""` 改 `!= ""`）。凡 String 与 StringName 比较用同类型。
- **deal_damage fire_hook 在 ATTACK_SETTLE 挂起链+mock_action 未注册时崩溃**：pilot_006 回落用 `PILOT_006_DEAL_4_DAMAGE` 直接减 HP（不走 fire_hook）。
- **ActionPilotEffects.set_aura_game_state 必须注入**（start_tutorial 已加；新测试若用 set_aura_game_state 需调用）。
- **`_resolve_mech_id_expr`**：`"$payload."`=9字符 substr(9)，`"$binding_context."`=17字符 substr(17)。
- **`$runtime.xxx`** = `payload[xxx]`（CHOOSE_MANY store_result_key 存入 payload[key]）；`_resolve_atomic_value` 已支持。
- **CHOOSE_MANY_CARDS**：per_card_actions 路径（thrust）与 store_result_key 路径（pilot_002/003 批次）不同；挂起需存 `act_idx`，resume store_result_key 路径存 payload[key] + `_seq` 续跑主循环剩余。
- **modify_mech_power 即时改 power 不留痕**：POWER_CAP_MODIFIER 用 cap_bonus + get_total_power 算入。
- **GDScript lambda 按值捕获 int/bool**：测试信号计数须用 Array。
- **`_register_pilot_effects` provider（pilot_005/002 effect_01）须在 effect==null 检查前处理**（provider 无 ActionEffect 定义）。
- **mock_action 需手动设 `action_id`**（未注册时 ActionRegistry 不生成），否则 `_pending_effect[action.action_id]` 用空 key。
- **条件 op 参数从 `condition.get("params", condition)` 读**（params 嵌套），不可直接 `condition.get("tag"/"zone"/"threshold")`（顶层为空）。这是本 session 踩到的坑。
- **条件 op 直接 `payload.get("target_id")` 取目标**，不解析 `$payload.xxx` 字符串；`$payload.xxx` 字符串在 `_resolve_mech_id_expr`/`_resolve_atomic_value` 解析。

## 5. 落码顺序建议

1. **集成测试完善**（各 effect 触发链 + 换机师 + PvP 双窗口）。这是下 session 最值得先做的——机制层已全部完成，测试能把隐性 bug 提前暴露。
2. **UI 完善**：悬停浮窗 → pilot_003 e3 复选框 UI → dev 面板机师区 → 开局选择 UI。
3. **PvP state_snapshot** 补机师实例/派生状态。
4. **实机验证**：PvP 双人类玩家窗口走完整流程。
5. 杂项：effect_02 扩展到其他离堆原因。

每完成一块：跑 `timeout 150 ... run_tests.gd` 确认无回归 → 更新 `pilot-system-infra-progress` 记忆 → 继续。过程中不确定就问用户，不要停。
