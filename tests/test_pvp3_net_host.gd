## test_pvp3_net_host.gd - net_host 多 client + hello 握手验证（阶段2）
##
## 验证 net_host 支持多 client（星型拓扑）：
##   - 2 client 连接 + hello 握手，host 按 player_id 识别 enemy/third（不靠连接顺序）
##   - send() 广播双收
##   - send_to(player_id) 定向单发
##   - is_client_connected(player_id) / client_count()
##
## 用真实 TCP（localhost），每测试随机端口避免 TIME_WAIT 冲突。
extends RefCounted

const _NetHost = preload("res://scripts/net/net_host.gd")
const _NetClient = preload("res://scripts/net/net_client.gd")


func _pump(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _cleanup(nodes: Array) -> void:
	for nd in nodes:
		if nd != null and is_instance_valid(nd):
			if nd is _NetHost:
				nd.stop()
			elif nd is _NetClient:
				nd.disconnect_from_host()
			nd.queue_free()
	await _pump(3)


## 建 host + 2 client（enemy/third），返回 {host,c1,c2,connected}。connected 收握手 player_id。
func _build_host_clients(port: int) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var host = _NetHost.new()
	tree.root.add_child(host)
	host.start(port, 2)
	var c1 = _NetClient.new()
	c1.local_player_id = &"enemy"
	tree.root.add_child(c1)
	c1.connect_to(port)
	var c2 = _NetClient.new()
	c2.local_player_id = &"third"
	tree.root.add_child(c2)
	c2.connect_to(port)
	return {"host": host, "c1": c1, "c2": c2}


func _rand_port() -> int:
	var rng := RandomNumberGenerator.new()
	return rng.randi_range(40000, 50000)


# ═══════════════════════════════════════════
# 2 client 连接 + hello 握手，host 按 player_id 识别
# ═══════════════════════════════════════════

func test_pvp3_net_host_two_clients_handshake() -> Variant:
	var port := _rand_port()
	var built = _build_host_clients(port)
	var host = built.host
	var connected: Array = []
	host.client_connected.connect(func(pid): connected.append(String(pid)))
	await _pump(25)
	if host.client_count() != 2:
		await _cleanup([host, built.c1, built.c2])
		return "握手后 client_count 应为2，实际 %d（connected=%s）" % [host.client_count(), str(connected)]
	if not host.is_client_connected(&"enemy"):
		await _cleanup([host, built.c1, built.c2])
		return "host 未识别 enemy client（connected=%s）" % str(connected)
	if not host.is_client_connected(&"third"):
		await _cleanup([host, built.c1, built.c2])
		return "host 未识别 third client（connected=%s）" % str(connected)
	if not connected.has("enemy") or not connected.has("third"):
		await _cleanup([host, built.c1, built.c2])
		return "client_connected 信号缺 enemy/third：%s" % str(connected)
	await _cleanup([host, built.c1, built.c2])
	return true


# ═══════════════════════════════════════════
# send() 广播：2 client 都收到
# ═══════════════════════════════════════════

func test_pvp3_net_host_broadcast() -> Variant:
	var port := _rand_port()
	var built = _build_host_clients(port)
	var host = built.host
	var c1 = built.c1
	var c2 = built.c2
	var c1_msgs: Array = []
	var c2_msgs: Array = []
	c1.message_received.connect(func(m): c1_msgs.append(m))
	c2.message_received.connect(func(m): c2_msgs.append(m))
	await _pump(25)  # 等握手完成
	host.send({"type": "test", "data": "broadcast"})
	await _pump(12)
	await _cleanup([host, c1, c2])
	if c1_msgs.size() < 1:
		return "enemy client 未收到广播（c1=%d）" % c1_msgs.size()
	if c2_msgs.size() < 1:
		return "third client 未收到广播（c2=%d）" % c2_msgs.size()
	return true


# ═══════════════════════════════════════════
# send_to(player_id) 定向：只目标 client 收到
# ═══════════════════════════════════════════

func test_pvp3_net_host_send_to() -> Variant:
	var port := _rand_port()
	var built = _build_host_clients(port)
	var host = built.host
	var c1 = built.c1  # enemy
	var c2 = built.c2  # third
	var c1_msgs: Array = []
	var c2_msgs: Array = []
	c1.message_received.connect(func(m): c1_msgs.append(m))
	c2.message_received.connect(func(m): c2_msgs.append(m))
	await _pump(25)  # 等握手完成（send_to 需 player_id 已识别）
	# 定向发给 enemy（c1）
	host.send_to(&"enemy", {"type": "test", "data": "to_enemy"})
	await _pump(12)
	await _cleanup([host, c1, c2])
	if c1_msgs.size() != 1:
		return "enemy client 应收到1条定向消息，实际 %d" % c1_msgs.size()
	if c2_msgs.size() != 0:
		return "third client 不应收到 enemy 定向消息，实际 %d" % c2_msgs.size()
	return true


# ═══════════════════════════════════════════
# 2人兼容：单 client（max_clients 默认）仍正常握手
# ═══════════════════════════════════════════

func test_net_host_single_client_compat() -> Variant:
	var port := _rand_port()
	var tree := Engine.get_main_loop() as SceneTree
	var host = _NetHost.new()
	tree.root.add_child(host)
	host.start(port)  # 默认 max_clients=2，2人不传也兼容
	var c1 = _NetClient.new()
	c1.local_player_id = &"enemy"
	tree.root.add_child(c1)
	c1.connect_to(port)
	var connected: Array = []
	host.client_connected.connect(func(pid): connected.append(String(pid)))
	await _pump(25)
	if host.client_count() != 1:
		await _cleanup([host, c1])
		return "单 client 握手后 client_count 应为1，实际 %d" % host.client_count()
	if not host.is_client_connected(&"enemy"):
		await _cleanup([host, c1])
		return "单 client 未识别 enemy"
	if not host.is_client_connected():
		await _cleanup([host, c1])
		return "is_client_connected() 无参应返回 true（2人兼容）"
	await _cleanup([host, c1])
	return true
