# PvP 测试模式（双窗口人类对人类）实现计划

## 1. 目标

在保留原"人类打 AI"模式的前提下，新增**双窗口 PvP 测试模式**：同一台电脑上两个 Godot 进程，分别扮演 player / enemy，各自控制己方机甲与全部操作（攻击、响应、购买、移动、装备、卖出、开发者模式修改），所有操作实时同步到对方窗口。把 AI 换成另一个人类，方便测逻辑。

## 2. 关键决策（已与用户确认）

| 项 | 决策 |
|----|------|
| 进程模型 | **双进程 + 本地 TCP 同步**（非单进程双窗口） |
| 信息隐藏 | 各窗口只看己方手牌；对方手牌显示牌背/数量；装备/地图/商店/弃牌堆公开 |
| 启动方式 | 主菜单按钮「PvP测试模式」自动开两窗 |
| 窗口尺寸 | 保持 1536×768（用户自行用双显示器排布） |
| 权威模型 | player 窗 = host（跑全部游戏逻辑），enemy 窗 = client（纯视图 + 发输入意图） |

> 权威模型说明：双进程中必须有一方持有真实 GameContext 跑逻辑。选 player 窗当 host（主菜单先启动它），它再 spawn 一个 Godot 子进程当 client（enemy 窗）。client 不执行任何动作逻辑，只渲染快照 + 把用户操作打包成 intent 发给 host 执行。这样每个进程的 app_root 信号链保持单一路径，避免"两个 app_root 连同一组信号导致重复处理"。

## 3. 架构总览

```
┌─────────────── Host 进程（player 窗，权威）───────────────┐
│  app_root (game_mode=PVP, local_player_id="player")        │
│  GameContext (真实，双方 is_human=true，无 AIController 驱动)│
│  ActionEngine/TimingEngine/Services 正常跑                  │
│  ┌─ NetHost (TCPServer @127.0.0.1:port)                    │
│  │   发: snapshot / popup / close_popup / battle_over      │
│  │   收: intent                                            │
│  └─ 弹窗路由: popup 目标方==client 时转发，否则本地显示      │
└─────────────────────────────────────────────────────────────┘
           ▲ TCP localhost (JSON, 换行分隔)        │
           │ snapshot/popup 下行                  │ intent 上行
           ▼                                      ▼
┌─────────────── Client 进程（enemy 窗，视图）───────────────┐
│  app_root (is_network_client=true, local_player_id="enemy")│
│  GameContext (镜像，仅 game_state 被快照覆盖，action 系统闲置)│
│  ┌─ NetClient (StreamPeerTCP -> 127.0.0.1:port)            │
│  │   收: snapshot -> apply_snapshot -> refresh              │
│  │   收: popup -> 走与 host 相同的 show_popup 代码路径      │
│  │   发: intent (用户点击/选牌/弹窗选择/开发者编辑)         │
│  └─ 所有本地输入: 不执行，转 intent 发 host                  │
└─────────────────────────────────────────────────────────────┘
```

## 4. 进程启动与命令行

- 主场景仍 `res://scenes/app/app_root.tscn`。`app_root._ready` 读 `OS.get_cmdline_args()`：
  - 无 PvP 参数 → 现有流程（主菜单 → PvE 教学）。主菜单新增按钮「PvP测试模式」。
  - `--pvp-client --pvp-port <p> --pvp-local-player <pid>` → client 模式：跳过主菜单/战役，建一个空 GameContext（仅装数据 + 占位 action 系统），连 host，等第一条 snapshot 后进战斗界面。
- 主菜单「PvP测试模式」按钮 → host 模式：
  1. 选端口（如 45678），`NetHost.start(port)` 监听。
  2. `OS.create_process(godot_exe, ["--main-scice"? no, 用 --path . --pvp-client --pvp-port 45678 --pvp-local-player enemy])` spawn client 进程。用 `.vscode/settings.json` 里的 Godot 路径 `F:/Godot_4.6/Godot_v4.6-stable_win64.exe`。
  3. host 走 PvP setup（见 §10）建局，player 先手。client 连上后 host 发首条 snapshot。

## 5. 状态序列化（`scripts/net/state_snapshot.gd`）

`serialize(context, viewer_pid: StringName) -> Dictionary` 把 host 的 game_state 序列化成可传输 Dict；`apply_snapshot(context, snap)` 在 client 把 Dict 重建回 game_state。client 用同一份 DataRegistry/CardDatabase，所以 CardDef 由 card_id 重新绑定（不传 def 全文，只传 card_id）。

快照内容：
- `players`: 每个 pid → {gold, is_human, action_card_limit, attack_limit, once_per_turn_used, turn_counters, statuses, hand_revealed, sell_equipment_count_this_turn, action_hand[], equipment_hand[]}
  - **信息隐藏**：viewer 自己的手牌 → 完整 card_instance_id 列表（client 能查到 def）；对方手牌 → 替换为等长占位（card_instance_id 保留但标记 hidden=true，UI 渲染牌背；或在 apply 时给对方手牌造"背面牌"占位实例）。先实现：对方手牌只传 count，client 用虚拟背面牌占位。
- `mechs`: 每个 mech_id → {owner, frame_card_id, current_hp, max_hp, power, max_power, position{q,r}, destroyed, attack_count, statuses, slots{slot_id→{kind, base_armor/power/durability, region_damage_tokens, equipped_card_instance_id, modifiers}}}
  - 装备在槽位上的牌是公开信息 → 完整 instance_id（client 查 def）。
- `cards`: 仅序列化 viewer 需要看到的牌实例 → 自己手牌 + 双方已装备牌 + 临时区(tmp_zone) + 公开弃牌。每张 → {card_id, zone, slot_id, mech_id, owner, damage_tokens, timer, counters, disabled, face_down}。对方手牌不在此。
- `map_state`: cells{key→{q,r,terrain,cost,passable}}, markers。
- `deck_state`: 各牌堆 count（action/equipment/advanced/pilot/event deck + 各 discard pile）。不传内容。
- `shop_state`: normal_slots[], advanced_slot, hidden_advanced_slot(revealed?), 各 slot 的 card_instance_id（商店公开）。
- `log`: 全量日志数组（最近 N 条，UI 消息日志用）。
- `turn_number`, `active_player_id`, `phase`。
- `viewer_pid`（client 校验用）。

**脏标记合并**：host 不每次状态变更立即发，而是标 `_net_dirty=true`，在 `_process` 末尾（或 call_deferred）若 dirty 则发一次 snapshot。避免一次攻击 5 时点发 5 次快照。

## 6. IPC 协议（JSON，换行分隔）

`scripts/net/net_transport.gd`：封装 StreamPeerTCP 的「行式 JSON」收发（`JSON.stringify` 默认紧凑、转义换行；以 `\n` 分隔消息）。大快照可能跨包，用缓冲区累积到 `\n` 再解析。

**Host → Client**：
| type | data | 说明 |
|------|------|------|
| `snapshot` | 完整快照 Dict | client apply + refresh |
| `popup` | {popup_type, params} | client 调 show_popup(popup_type, params) |
| `close_popup` | {popup_type} | client 关闭对应弹窗（动作完成/取消时） |
| `battle_over` | {state, reason} | client 显示结果 |
| `log` | {entry} | 可选：增量日志（也可全靠 snapshot 带 log） |

**Client → Host**（统一 `intent` 包，`action` 字段区分）：
| action | params | host 处理 |
|--------|--------|-----------|
| `click_hex` | {q,r} | 等价于 client 方的 _on_battle_hex_clicked，按当前等待输入类型路由 |
| `play_action_card` | {card_instance_id} | 等价 _on_action_card_clicked |
| `popup_choice` | {popup_type, choice} | 按弹窗类型调对应 on_ui_confirmed / handle_response_selection / 等 |
| `popup_cancel` | {popup_type} | on_ui_cancelled / 关闭弹窗 |
| `end_turn` | {} | _end_player_turn |
| `shop_buy` | {kind, slot_index, mode} | _on_shop_*_clicked 等价 |
| `shop_refresh` / `shop_reveal` / `shop_buy_hidden` | {} | 对应处理 |
| `sell_equipment` | {card_instance_id} | _on_sell_panel_equipment_selected |
| `set_equipment` | {card_instance_id, slot_id} | _do_set_equipment |
| `equipment_active` | {card_instance_id, effect_id} | _on_equipment_active_clicked |
| `dev_edit` | {op, ...} | 转发到 DevModeService 对应方法（见 §9） |

host 收到 intent 后，**以 client 的 local_player_id 身份**执行对应 app_root 方法（复用现有方法，不重写逻辑），执行完自然触发状态变更 → 发 snapshot。

## 7. 弹窗路由表（host 决定弹在哪个窗）

host 的 `action_ui_bridge.request_ui_popup` 现在只连 host app_root。host 新增 `_popup_owner(popup_type, params) -> StringName`：

| popup_type | 归属方判定 |
|------------|-----------|
| `weapon_select` / `attack_target_select` | params.attacker_id → mech.owner |
| `move_target_select` | params.mech_id → owner |
| `response_window` | params.target_id（被攻击方/响应方）→ owner |
| `discard_card_select` | params.discard_player_id |
| `damage_token_placement` | params.executor 或 target_mech_id → owner（放置者） |
| `use_card_confirm` / `choice_select` / `effect_choice` / `mech_target_select` / `weapon_charge_select` / `repair_target_select` / `redirect_select` | 发起方（params.mech_id/source_mech_id/player_id/action 的 player_id）→ owner |
| `card_show` / `generic_input` | best-effort：发起方 owner |

- 归属方 == host 本地（player）→ 现有 `_on_action_ui_popup_requested` 正常本地显示。
- 归属方 == client（enemy）→ **不本地显示**，发 `{type:"popup", popup_type, params}` 给 client。client 收到后调同一个 `show_popup(popup_type, params)`（把现有 `_on_action_ui_popup_requested` body 重构成 `show_popup` 公共方法，信号 handler 与 client 网络回调都调它）。
- 动作完成/取消关闭弹窗时，host 若曾把该弹窗转发给 client，发 `close_popup`。
- `request_target_selection`（TimingEngine 信号）同理路由。

## 8. 回合流程 PvP（无 AI）

- `game_mode == PVP` 时，禁用 `AIController` 回合驱动：`_start_enemy_turn_flow` / `_check_enemy_turn_complete` / `ai_controller.take_next_action` 全部不走。
- `_end_player_turn`（当前 active 方点结束）：`end_turn(active)` → 胜负检查 → `start_turn(opponent)`。对方窗口解锁，本窗口锁定。发 snapshot。
- `_on_action_completed`：PVP 下只 `_request_refresh()` + 标 net_dirty，不驱动"敌方回合完成"。动作暂停（响应窗口/损伤放置）期间，靠对方 intent 恢复。
- 回合守卫已存在（`active_player_id` 非 local 则拦截输入），天然实现"非己方回合锁定"。client 侧同理由 snapshot 的 active_player_id 决定可否操作。
- 手牌超上限弃牌：结束回合时若需弃牌，归属方的窗口弹弃牌面板（走 popup 路由）。

## 9. 开发者模式双向

现状：DevModePanel 调 `context.dev_mode_service.*` 改任意玩家状态（已支持选玩家，记忆 [[devmode-player-select-overwrites]]）。

- **Host 侧**：DevModePanel 正常工作，改完标 net_dirty 发 snapshot。可改双方（满足"修改彼此状态"）。
- **Client 侧**：DevModePanel 需网络模式。方案：给 DevModePanel 加 `network_forward: bool` 标志（由 client app_root setup 时置 true）。所有改状态的操作，若 network_forward，不发本地 DevModeService，而是 emit 信号 `dev_edit_requested(op, params)`，client app_root 收到后发 `intent{action:"dev_edit", op, params}` 给 host。host 的 intent 处理器调 host DevModeService 同一方法 → 标 dirty 发 snapshot。
- 实现：DevModePanel 内部把对 dev_mode_service 的直接调用收拢到一个 `_apply_dev_edit(op, params)` 方法；host 模式直接调服务，client 模式 emit 信号转发。需读 DevModePanel 确认其操作粒度（加牌/改属性/改损伤/改手牌等）。

## 10. app_root 改造点

新增字段：
- `var game_mode: StringName = &"PVE"`（`PVE` / `PVP`）
- `var local_player_id: StringName = &"player"`（host=player，client=enemy）
- `var is_network_client: bool = false`（client 模式开关）
- `var net_host = null` / `var net_client = null`

参数化硬编码 `&"player"`：
- `move_unit("player")` → `local_player_id`
- `_on_action_card_clicked` / `_on_equipment_card_clicked` 的 mech 查询 → `get_mech_for_player(local_player_id)`
- 装备设置/卖出/商店购买 → `local_player_id`
- `_end_player_turn` → 结束 `local_player_id` 的回合
- 回合守卫 `_is_human_player_id` 已通用（读 is_human），不变
- battle_board / hand_panel / equipment_panel 渲染：它们读 `battle.context.game_state` 全局，天然显示双方；只需确保 hand_panel 显示 `local_player_id` 的手牌（当前硬编码 player，需改）

模式分支：
- `game_mode==PVP && !is_network_client`（host）：弹窗路由（§7）+ 发 snapshot（§5 脏标记）+ 无 AI 回合（§8）
- `is_network_client`（client）：不连本地 action_ui_bridge/timing_engine 的弹窗信号（弹窗靠网络消息）；所有输入转 intent（§6）；不调 battle.execute_*；不跑 AI；_on_action_completed 不驱动回合
- `game_mode==PVE`：完全现有路径，零改动

PvP setup（新方法，替代 `_start_tutorial_battle` 的 PvP 分支）：调 GameSetupService 建局，但双方 `is_human=true`，不创建/不驱动 AIController（context.ai_controller 可保留实例但 PvP 下不调 on_turn_start）。

## 11. 新增文件

| 文件 | 职责 |
|------|------|
| `scripts/net/state_snapshot.gd` | serialize / apply_snapshot（§5） |
| `scripts/net/net_transport.gd` | 行式 JSON TCP 收发（StreamPeerTCP 封装） |
| `scripts/net/net_host.gd` | host 端：TCPServer 监听、accept、收 intent、发 snapshot/popup |
| `scripts/net/net_client.gd` | client 端：connect、收 snapshot/popup、发 intent |
| `scripts/net/pvp_launcher.gd` | spawn client 进程（OS.create_process + godot 路径 + 命令行） |
| `scripts/net/sync_protocol.gd` | 消息类型常量 + intent→host 方法分发的辅助 |
| `tests/test_state_snapshot_roundtrip.gd` | 序列化往返测试（Phase A） |

## 12. 修改文件

| 文件 | 改动 |
|------|------|
| `scripts/app/app_root.gd` | §10 全部（local_player_id/game_mode/is_network_client、参数化 player、弹窗路由、show_popup 重构、intent 处理、client 输入分支、PvP setup、主菜单按钮） |
| `scripts/battle/battle_state.gd` | 加 `start_pvp_battle()`（双方 is_human，无 AI 装备逻辑差异待定）；PvP turn flow 辅助 |
| `scripts/services/GameSetupService.gd` | 加 `setup_pvp_battle()`（同 tutorial 但 enemy.is_human=true；或复用 setup_tutorial_battle 加参数） |
| `scripts/ui/hand_panel.gd` | 显示 `local_player_id` 手牌（当前硬编码 player） |
| `scripts/ui/dev_mode_panel.gd` | §9 network_forward 分支 |
| （可能）`scripts/ui/equipment_panel.gd` / `battle_board.gd` | 若硬编码 player 视角则参数化 |
| `project.godot` | 无需改（命令行参数即可，不新增 autoload） |

## 13. 分阶段交付（每阶段可独立测）

- **Phase A — 序列化往返**：`state_snapshot.gd` serialize/apply_snapshot + 单测（host 状态序列化→新 context 还原→逐字段断言）。无网络。✅ 可用现有 `run_tests.gd` 跑。
- **Phase B — 传输层**：`net_transport.gd` + net_host/net_client，两进程能连上、echo 一条消息。手动起两进程验证。
- **Phase C — client 渲染 host 状态**：host 发首条 snapshot，client apply + 渲染棋盘/机甲/己方手牌（只读）。证明序列化→UI 通路。
- **Phase D — 移动意图往返**：client 发 `click_hex` 移动 intent，host 执行 move + 发 snapshot，client 看到移动；host 本地移动也同步到 client。
- **Phase E — PvP 回合流程**：结束回合切换 active 方，两窗锁定/解锁正确，无 AI。手牌超限弃牌路由。
- **Phase F — 打牌/装备/商店/卖出意图**：client 能通过 intent 打行动牌、设装备、买/卖/刷新商店。
- **Phase G — 弹窗路由**（最大块）：响应窗口/武器选择/损伤放置/目标选择/二选一 等弹窗正确路由到归属方窗口，client 选择回传 host 续跑。含攻击全流程、迎击、识破、反击。
- **Phase H — 开发者模式双向**：client dev 编辑 → host → snapshot；host dev 编辑 → snapshot。
- **Phase I — 打磨**：对方手牌牌背渲染、日志同步、battle_over、断线处理、信息隐藏校验、边界 case。

每阶段做完跑 `run_tests.gd` 确保未破坏 PvE 既有测试（~21 文件，已知 test_expose_response_steal 既有失败可忽略）。

## 14. 风险与权衡

| 风险 | 缓解 |
|------|------|
| 快照大、频繁发卡顿 | 脏标记 + 帧末合并发一次（同 app_root 现有 `_request_refresh` 模式） |
| client 全量 apply_snapshot 重置 UI 动画/滚动 | 测试模式可接受；若明显问题，Phase I 改增量更新 |
| CardDef 同步：client 必须加载同一份数据 | client 启动也跑 DataRegistry.load_all（已做） |
| 弹窗归属判定错→弹错窗口 | `_popup_owner` 表 + 每类单测；动作暂停时 host 不本地显示已转发弹窗 |
| intent 时序：client 在非己方回合发操作 | host 侧复用现有回合守卫拦截非法操作 + 回 intent 错误 |
| client 断线/进程崩溃 | host 检测断开 → 提示（测试模式不自动恢复，重启即可） |
| OS.create_process 路径/引号问题（Windows） | 用 godot exe 绝对路径 + 数组参数（不用 shell 拼接） |
| DevModePanel 操作粒度未确认 | Phase H 前先读 DevModePanel.gd 确认其方法清单 |

## 15. 保持 PvE 不变

所有 PvP 逻辑由 `game_mode`/`is_network_client` 门控。PvE 路径（`game_mode==PVE && !is_network_client`）走原代码，零行为变更。`AIController` 仅在 PvE 被调用。原主菜单「新战役」按钮不动。

---

## 实施顺序建议

先做 **Phase A**（序列化，纯本地可测，风险最低，是后续一切的基础），跑通往返测试后给你看结果，再进 Phase B 联网。每个 Phase 完成即汇报、可回看。
