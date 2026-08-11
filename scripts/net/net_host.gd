## net_host.gd - PvP host 端 TCP 服务（多 client，星型拓扑）
##
## host（player 窗，权威进程）监听 127.0.0.1:port，接受最多 max_clients 个 client 连接。
## 3人 PvP：2 个 client（enemy/third）。2人 PvP：1 个 client（enemy）。
##
## 握手：client 连上后发 {"type":"hello","player_id":...}，host 据此识别 client 归属
## （连接顺序不固定，必须靠 player_id 识别 enemy/third）。hello 不走 message_received，
## 而是记录 _peer_player_ids 并 emit client_connected(player_id)。
##
## host 调 send() 广播所有 client；send_to(player_id) 定向单发（seed/候选等需定向）。
extends Node

const NetTransport = preload("res://scripts/net/net_transport.gd")

## client 连上并完成握手（hello 到达）。player_id = client 归属（enemy/third/...）。
signal client_connected(player_id: StringName)
## client 断开。player_id 为已握手的归属（未握手则 &""）。
signal client_disconnected(player_id: StringName)
signal message_received(msg: Variant)

var _server := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _readers: Array = []  # NetMessageReader，与 _peers 一一对应
var _peer_player_ids: Array[StringName] = []  # hello 后填充，未握手=&""
var _port: int = 0
var _max_clients: int = 2
var _listening: bool = false


func start(port: int, max_clients: int = 2) -> Error:
	_port = port
	_max_clients = max_clients
	var err: Error = _server.listen(port, "127.0.0.1")
	_listening = (err == OK)
	return err


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.disconnect_from_host()
	_peers.clear()
	_readers.clear()
	_peer_player_ids.clear()
	if _server.is_listening():
		_server.stop()
	_listening = false


## 是否有 client 连接。player_id 为空=任意已连接 peer；非空=指定 player_id 已握手。
## 2人兼容：is_client_connected() 无参 = 任意 peer 已连接。
func is_client_connected(player_id: StringName = &"") -> bool:
	if player_id == &"":
		for peer in _peers:
			if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				return true
		return false
	return _peer_player_ids.has(player_id)


## 已握手 client 数
func client_count() -> int:
	var n: int = 0
	for pid in _peer_player_ids:
		if pid != &"":
			n += 1
	return n


## 广播给所有已连接 client
func send(msg: Variant) -> void:
	for peer in _peers:
		if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			NetTransport.send(peer, msg)


## 定向发送给指定 player_id 的 client（须已握手）
func send_to(player_id: StringName, msg: Variant) -> void:
	for i in range(_peers.size()):
		if _peer_player_ids[i] == player_id:
			var peer = _peers[i]
			if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				NetTransport.send(peer, msg)
			return


func _process(_delta: float) -> void:
	if not _listening:
		return
	# 接受新连接（直到 max_clients 满）
	while _peers.size() < _max_clients and _server.is_connection_available():
		var new_peer = _server.take_connection()
		if new_peer != null:
			_peers.append(new_peer)
			_readers.append(NetTransport.NetMessageReader.new())
			_peer_player_ids.append(&"")  # 未握手，等 hello
	# 轮询每个 peer 读取消息
	var i: int = 0
	while i < _peers.size():
		var peer = _peers[i]
		peer.poll()
		var status = peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			var avail = peer.get_available_bytes()
			if avail > 0:
				var got = peer.get_data(avail)
				if got[0] == OK:
					_readers[i].append(got[1])
			while true:
				# emit 回调(client_connected/message_received)可能触发 _quit_pvp_session -> stop()
				# 清空 _peers/_readers；此时退出本帧避免 _readers[i] 越界（同 else 分支 return 语义）
				if i >= _readers.size():
					return
				var msg = _readers[i].pop()
				if msg == null:
					break
				if typeof(msg) == TYPE_DICTIONARY and String(msg.get("type", "")) == "hello":
					# 握手：记录 player_id，emit client_connected（不走 message_received）
					var pid: StringName = StringName(String(msg.get("player_id", "")))
					_peer_player_ids[i] = pid
					client_connected.emit(pid)
				else:
					message_received.emit(msg)
			i += 1
		else:
			# 断开/错误：移除该 peer 并通知
			var pid: StringName = _peer_player_ids[i]
			_peers.remove_at(i)
			_readers.remove_at(i)
			_peer_player_ids.remove_at(i)
			client_disconnected.emit(pid)
			# 结束本帧，避免 emit 触发的回调（_quit_pvp_session 会 stop/queue_free）在遍历中途修改 _peers
			return
