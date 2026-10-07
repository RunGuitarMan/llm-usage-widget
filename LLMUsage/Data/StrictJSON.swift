import Foundation

/// A bounded, strict JSON syntax tree. Ranges point into the original UTF-8;
/// the settings editor inserts bytes and never serializes existing values.
struct StrictJSON {
    indirect enum Value: Equatable {
        case object([Member]), array([Node]), string(String), number(String), bool(Bool), null
    }
    struct Member: Equatable { var key: String; var value: Node }
    struct Node: Equatable {
        var range: Range<Int>
        var value: Value
        var members: [Member]? { if case .object(let values) = value { return values }; return nil }
        subscript(_ key: String) -> Node? { members?.first { $0.key == key }?.value }
        var string: String? { if case .string(let value) = value { return value }; return nil }
    }
    enum Failure: Error { case invalid }
    private var bytes: [UInt8]
    private var offset = 0
    static func parse(_ data: Data, limit: Int = 16 * 1024 * 1024) throws -> Node {
        guard data.count <= limit else { throw Failure.invalid }
        var parser = StrictJSON(bytes: Array(data))
        let node = try parser.node(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw Failure.invalid }
        return node
    }
    private mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
    private mutating func string() throws -> String {
        let start = offset
        guard take(34) else { throw Failure.invalid }
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            guard byte >= 32 else { throw Failure.invalid }
            if byte == 34 && !escaped {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw Failure.invalid }
                return value
            }
            if byte == 92 && !escaped { escaped = true } else { escaped = false }
        }
        throw Failure.invalid
    }
    private mutating func node(depth: Int) throws -> Node {
        guard depth < 64 else { throw Failure.invalid }
        whitespace()
        let start = offset
        guard offset < bytes.count else { throw Failure.invalid }
        let value: Value
        if take(123) {
            var members: [Member] = []; var keys = Set<String>(); whitespace()
            if !take(125) {
                repeat {
                    whitespace(); let key = try string(); whitespace()
                    guard keys.insert(key).inserted, take(58) else { throw Failure.invalid }
                    members.append(.init(key: key, value: try node(depth: depth + 1))); whitespace()
                    if take(125) { break }
                    guard take(44) else { throw Failure.invalid }
                } while true
            }
            value = .object(members)
        } else if take(91) {
            var nodes: [Node] = []; whitespace()
            if !take(93) {
                repeat {
                    nodes.append(try node(depth: depth + 1)); whitespace()
                    if take(93) { break }
                    guard take(44) else { throw Failure.invalid }
                } while true
            }
            value = .array(nodes)
        } else if bytes[offset] == 34 { value = .string(try string()) }
        else if take(116) { try literal([114, 117, 101]); value = .bool(true) }
        else if take(102) { try literal([97, 108, 115, 101]); value = .bool(false) }
        else if take(110) { try literal([117, 108, 108]); value = .null }
        else {
            _ = take(45)
            if !take(48) {
                guard offset < bytes.count, (49...57).contains(bytes[offset]) else { throw Failure.invalid }
                digits()
            }
            if take(46) { guard offset < bytes.count, (48...57).contains(bytes[offset]) else { throw Failure.invalid }; digits() }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                guard offset < bytes.count, (48...57).contains(bytes[offset]) else { throw Failure.invalid }; digits()
            }
            value = .number(String(decoding: bytes[start..<offset], as: UTF8.self))
        }
        return Node(range: start..<offset, value: value)
    }
    private mutating func digits() { while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 } }
    private mutating func literal(_ suffix: [UInt8]) throws { for byte in suffix { guard take(byte) else { throw Failure.invalid } } }
}
