/// Messages of an ACP v1 agent. Written by the documentation and the v1 schema 1.35.0, NOT recorded from a live agent:
/// none was at hand.
enum ACPRecordings {
    static func initialize(_ capabilities: String = "{}", version: String = "1") -> String {
        #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":\#(version),"agentCapabilities":\#(capabilities),"agentInfo":{"name":"fake","title":"Fake","version":"1.2"},"authMethods":[]}}"#
    }
    static let full = #"{"loadSession":true,"sessionCapabilities":{"resume":{},"systemPrompt":{},"additionalDirectories":{}}}"#
    static let session = #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#
    static func update(_ u: String, session: String = "s1") -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(session)","update":\#(u)}}"#
    }
    static func text(_ t: String, id: String? = nil, session: String = "s1") -> String {
        update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(t)"}\#(id.map { #","messageId":"\#($0)""# } ?? "")}"#, session: session)
    }
    static func tool(_ id: String, _ title: String) -> String {
        update(#"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(title)","kind":"edit","status":"pending"}"#)
    }
    static func cost(_ n: String, _ currency: String = "USD") -> String {
        update(#"{"sessionUpdate":"usage_update","used":10,"size":100,"cost":{"amount":\#(n),"currency":"\#(currency)"}}"#)
    }
    static func end(_ reason: String = "end_turn") -> String { #"{"jsonrpc":"2.0","id":4,"result":{"stopReason":"\#(reason)"}}"# }
    static func error(_ id: Int, _ code: Int, _ text: String = "boom") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(text)"}}"#
    }
    static func ask(_ id: String = "7", options: String = #"[{"optionId":"a","name":"Yes","kind":"allow_once"},{"optionId":"w","name":"Always","kind":"allow_always"},{"optionId":"r","name":"No","kind":"reject_once"}]"#) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Run tests","kind":"execute","rawInput":{"command":"npm test"}},"options":\#(options)}}"#
    }
    static func call(_ id: String, _ method: String, _ params: String, session: String = "s1") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":{"sessionId":"\#(session)",\#(params)}}"#
    }
}
