import Foundation

@main struct HarnessBenchmark {
 @MainActor static func main() async throws {
  let a=CommandLine.arguments; let engine=a[1], workspace=a[2], prompt=try String(contentsOfFile:a[3],encoding:.utf8), resultPath=a[4]
  let sid=UUID().uuidString, requestID=UUID().uuidString
  let api: HarnessAPI?
  let socket: URLSessionWebSocketTask
  var clientID=""
  func decode(_ message: URLSessionWebSocketTask.Message) throws -> Data {
   switch message {case .data(let d): return d; case .string(let s): return Data(s.utf8); @unknown default: throw HarnessError(message:"Unknown frame")}
  }
  if engine == "dsh" {
   let log=try String(contentsOfFile:NSHomeDirectory()+"/.dsh/web.stdout.log",encoding:.utf8)
   let re=try NSRegularExpression(pattern:"http://127\\.0\\.0\\.1:3080/\\?token=[^\\s\\u001b]+")
   guard let m=re.matches(in:log,range:NSRange(log.startIndex...,in:log)).last,let range=Range(m.range,in:log) else {throw HarnessError(message:"No DSH login")}
   let(base,token)=try HarnessAPI.parse(String(log[range]));let connection=HarnessAPI(base:base);try await connection.login(token:token!)
   let catalog=try await connection.rpc("session/modelCatalog")
   guard catalog["default"]["model"].string == "qwen3.8-27b", catalog["default"]["provider"].string == "homerig" else {throw HarnessError(message:"Wrong DSH default model")}
   _ = try await connection.rpc("session/create",args:["request":.object(["sessionId":.string(sid),"cwd":.string(workspace)])])
   _ = try await connection.rpc("session/rename",args:["request":.object(["sessionId":.string(sid),"title":.string("BENCH " + URL(fileURLWithPath:workspace).lastPathComponent)])])
   socket=connection.socket();api=connection
   func open(_ endpoint:String,_ id:String,_ args:[String:JSON]) async throws {
    let f=JSON.object(["type":.string("open"),"streamId":.string(id),"endpoint":.string(endpoint),"payload":.object(["args":.object(args)])])
    try await socket.send(.string(String(decoding: JSONEncoder().encode(f), as: UTF8.self)))
   }
   try await open("$events","events",[:])
   while clientID.isEmpty {let f=try JSON.decodeWire(decode(await socket.receive())); if f["value"]["type"].string == "ready" {clientID=f["value"]["clientId"].string}}
   try await open("session/follow","follow",["request":.object(["address":.object(["kind":.string("session"),"sessionId":.string(sid)]),"maxMessages":.number(100),"assistantStream":.bool(true)])])
   while true {let f=try JSON.decodeWire(decode(await socket.receive()));if f["value"]["type"].string == "snapshot" {break}}
  } else {
   api=nil
   let config=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:a[5])))
   var request=URLRequest(url:URL(string:config["endpoint"]!)!);request.setValue("Bearer " + config["token"]!,forHTTPHeaderField:"Authorization")
   socket=URLSession.shared.webSocketTask(with:request);socket.resume()
   try await socket.send(.data(JSONEncoder().encode(NativeCommand(op:"open",session:sid))))
   while true {let e=try JSONDecoder().decode(NativeEvent.self,from:decode(await socket.receive()));if e.op == "error" {throw HarnessError(message:e.text ?? "Host error")};if e.op == "synced" {break}}
  }
  let cancelOnText = ProcessInfo.processInfo.environment["HARNESS_BENCH_CANCEL"] == "1"
  var cancelAt: Double?
  let start=ProcessInfo.processInfo.systemUptime
  var firstReasoning:Double?,firstText:Double?,firstActivity:Double?,toolCount=0,reasoning="",text="",outcome="unknown"
  var transcript=Transcript(), events:[JSON]=[], intervals:[Double]=[],lastDelta:Double?
  let timeout=Task {try? await Task.sleep(for:.seconds(120));if !Task.isCancelled {socket.cancel(with:.goingAway,reason:nil)}}
  defer {timeout.cancel();socket.cancel(with:.goingAway,reason:nil)}
  if let api {
   _ = try await api.rpc("session/prompt",args:["request":.object(["sessionId":.string(sid),"requestId":.string(requestID),"mode":.string("queue"),"content":.array([.object(["type":.string("text"),"text":.string(prompt)])])])])
  } else {try await socket.send(.data(JSONEncoder().encode(NativeCommand(op:"prompt",session:sid,id:requestID,text:prompt))))}
  do {
   stream: while true {
    let data=try decode(await socket.receive()), now=ProcessInfo.processInfo.systemUptime-start
    let raw=try JSON.decodeWire(data);events.append(.object(["elapsed":.number(now),"frame":raw]))
    var deltaText="",deltaReasoning=""
    if let api {
     let v=raw["value"]
     if v["type"].string == "waterfall",v["agentId"].string == sid,v["event"].string == "approval/request" {
      _ = try await api.rpc("$events/result",args:["clientId":.string(clientID),"eventId":v["eventId"],"outcome":.object(["kind":.string("result"),"value":.string("allowed-once")])])
     }
     if raw["streamId"].string == "follow", v["type"].string == "assistant-stream", v["frame"]["type"].string == "chunk" {
      let c=v["frame"]["chunk"]
      if c["type"].string == "text-delta" {deltaText=c["text"].string}
      if c["type"].string == "reasoning-delta" {deltaReasoning=c["text"].string}
     }
     if raw["streamId"].string == "follow",v["type"].string == "event" {
      let e=v["event"],d=e["data"],kind=e["type"].string
      if kind == "assistant/chunk" {let c=d["chunk"];if c["type"].string == "text-delta" {deltaText=c["text"].string};if c["type"].string == "reasoning-delta" {deltaReasoning=c["text"].string}}
      if kind == "chunkrow/text-chunks" {deltaText=d["texts"].array.map(\.string).joined()}
      if kind == "chunkrow/reasoning-chunks" {deltaReasoning=d["texts"].array.map(\.string).joined()}
      if kind == "tool/call" {toolCount += 1;if firstActivity == nil {firstActivity=now}}
      var records=transcript.events;records.append(e);transcript.replace(records.map{.object(["event":$0])},cursor:e["seq"].int)
      if kind == "turn/end" {outcome=d["reason"]["kind"].string;break stream}
     }
    } else {
     let e=try JSONDecoder().decode(NativeEvent.self,from:data)
     if e.op == "text" {deltaText=e.text ?? ""};if e.op == "reasoning" {deltaReasoning=e.text ?? ""}
     if e.op == "toolCall" {toolCount += 1;if firstActivity == nil {firstActivity=now}}
     if e.op == "approval",let approval=e.approval {try await socket.send(.data(JSONEncoder().encode(NativeCommand(op:"approval",session:sid,id:approval.id,allow:true))))}
     if e.op == "error" {outcome=e.text ?? "error";break stream}
     if e.op == "stage",["completed","cancelled","failed"].contains(e.stage ?? "") {outcome=e.stage!;break stream}
    }
    if !deltaReasoning.isEmpty {if firstReasoning == nil {firstReasoning=now};reasoning += deltaReasoning}
    if !deltaText.isEmpty {
     if firstText == nil {firstText=now};text += deltaText
     if cancelOnText && cancelAt == nil {
      cancelAt=ProcessInfo.processInfo.systemUptime-start
      if let api { _ = try await api.rpc("session/cancel",args:["request":.object(["sessionId":.string(sid)])]) }
      else { try await socket.send(.data(JSONEncoder().encode(NativeCommand(op:"cancel",session:sid)))) }
     }
    }
    if !deltaText.isEmpty || !deltaReasoning.isEmpty {
     if firstActivity == nil {firstActivity=now};if let lastDelta {intervals.append(now-lastDelta)};lastDelta=now
    }
   }
  } catch {
   outcome="timeout_or_transport_error: " + error.localizedDescription
   if let api {_ = try? await api.rpc("session/cancel",args:["request":.object(["sessionId":.string(sid)])])}
  }
  if api != nil {text=transcript.rows.filter{$0.kind == .assistant}.map(\.text).joined(separator:"\n")}
  let end=ProcessInfo.processInfo.systemUptime-start
  let result:JSON = .object(["engine":.string(engine),"session":.string(sid),"workspace":.string(workspace),"first_activity_s":firstActivity.map(JSON.number) ?? .null,"first_reasoning_s":firstReasoning.map(JSON.number) ?? .null,"first_text_s":firstText.map(JSON.number) ?? .null,"total_s":.number(end),"cancel_to_end_s":cancelAt.map { .number(end-$0) } ?? .null,"max_delta_gap_s":.number(intervals.max() ?? 0),"tools":.number(Double(toolCount)),"text":.string(text),"reasoning_chars":.number(Double(reasoning.count)),"outcome":.string(outcome)])
  try Data(result.pretty.utf8).write(to:URL(fileURLWithPath:resultPath))
  try JSONEncoder().encode(JSON.array(events)).write(to:URL(fileURLWithPath:resultPath + ".events.json"))
  print("\(engine): \(String(format:"%.2f",end))s, first output \(String(format:"%.2f",firstActivity ?? -1))s, tools \(toolCount), \(outcome)")
 }
}
