## net_transport.gd - TCP 消息传输层
##
## 在 StreamPeerTCP 之上提供「带 4 字节长度前缀的 Variant 消息」收发。
## 用 var_to_bytes / bytes_to_var（二进制编码）而非 var_to_str/JSON，
## 因为后者会把 StringName 降级成 String，破坏 runtime 用 &"头部" 查 slots 字典。
## var_to_bytes 保留 StringName 原始类型，bytes_to_var 还原。
##
## 帧格式：[4 字节小端 uint32 长度 L][L 字节 variant 编码]
class_name NetTransport
extends RefCounted

const HEADER_SIZE := 4


## 编码一条消息为带长度前缀的字节流
static func encode(msg: Variant) -> PackedByteArray:
	var body := var_to_bytes(msg)
	var hdr := PackedByteArray()
	hdr.resize(HEADER_SIZE)
	hdr.encode_u32(0, body.size())
	var out := PackedByteArray()
	out.append_array(hdr)
	out.append_array(body)
	return out


## 发送一条消息（同步 put_data，TCP 发送缓冲足以下发完）
static func send(peer: StreamPeer, msg: Variant) -> Error:
	if peer == null:
		return ERR_INVALID_PARAMETER
	return peer.put_data(encode(msg))


## 消息读取缓冲：累积 socket 收到的字节，弹出完整消息。
## 用法：每帧把 peer.get_data(get_available_bytes()) 喂给 append，
## 再循环 pop() 取出每条完整消息（无完整消息返回 null）。
class NetMessageReader:
	extends RefCounted
	var _buf := PackedByteArray()

	func append(data: PackedByteArray) -> void:
		if data.is_empty():
			return
		_buf.append_array(data)

	## 返回下一条完整消息；缓冲不足返回 null。
	## 注：本协议消息恒为非空 Dictionary，故 null 一定表示「无完整消息」。
	func pop() -> Variant:
		while _buf.size() >= HEADER_SIZE:
			var L := _buf.decode_u32(0)
			if _buf.size() < HEADER_SIZE + L:
				return null  # 尚未收齐，等下一帧
			var payload := _buf.slice(HEADER_SIZE, HEADER_SIZE + L)
			# 消费已读字节
			_buf = _buf.slice(HEADER_SIZE + L)
			var msg = bytes_to_var(payload)
			if msg == null:
				# 解码失败（理论上 localhost 可靠 TCP 不会发生），跳过继续
				push_warning("[NetTransport] bytes_to_var returned null, skipping")
				continue
			return msg
		return null

	func clear() -> void:
		_buf.clear()
