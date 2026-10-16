import Foundation

/// A single command to send to a tag via `transceive`. Carries the bytes and
/// enough context for the advanced console to label and route the response.
public struct RawCommand: Hashable, Sendable {
    public let bytes: Data
    public let name: String?
    public let expectedResponseLength: Int?
    public let family: TagFamily

    public init(
        bytes: Data,
        name: String? = nil,
        expectedResponseLength: Int? = nil,
        family: TagFamily = .unknown
    ) {
        self.bytes = bytes
        self.name = name
        self.expectedResponseLength = expectedResponseLength
        self.family = family
    }
}

/// An ordered chain of commands. Parsed from text like:
///
///     21:60:00, 21:00:E1:40
///
/// - `,` separates one command from the next.
/// - `:` separates the bytes within a command.
/// - `??` is a placeholder that the writer binds at run time from
///   `BindingContext.uid` (one byte taken per `??`, MSB-first), or from a
///   per-command override.
public struct RawCommandSequence: Hashable, Sendable {
    public let commands: [Token]
    public let family: TagFamily

    public init(commands: [Token], family: TagFamily = .unknown) {
        self.commands = commands
        self.family = family
    }

    /// A command-shaped chunk of the original sequence — each chunk is a list
    /// of either literal bytes or `??` placeholders. Materialised into
    /// `RawCommand` by `bind(...)`.
    public struct Token: Hashable, Sendable {
        public let elements: [Element]
        public init(elements: [Element]) {
            self.elements = elements
        }

        public enum Element: Hashable, Sendable {
            case byte(UInt8)
            case placeholder
        }
    }

    public struct BindingContext: Hashable, Sendable {
        public let uid: Data
        public init(uid: Data) {
            self.uid = uid
        }
    }

    public enum BindingError: Error, Hashable, Sendable {
        case notEnoughUIDBytes(needed: Int, available: Int)
    }

    /// Resolves placeholders into literal bytes by reading from
    /// `context.uid` (MSB-first). Throws if the UID does not supply enough
    /// bytes — callers should surface this as a `TagError.protocolError`.
    public func bind(to context: BindingContext) throws -> [RawCommand] {
        var uidCursor = 0
        return try commands.map { token in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(token.elements.count)
            for element in token.elements {
                switch element {
                case .byte(let b):
                    bytes.append(b)

                case .placeholder:
                    guard uidCursor < context.uid.count else {
                        throw BindingError.notEnoughUIDBytes(
                            needed: uidCursor + 1,
                            available: context.uid.count
                        )
                    }
                    bytes.append(context.uid[uidCursor])
                    uidCursor += 1
                }
            }
            return RawCommand(bytes: Data(bytes), family: family)
        }
    }
}

// MARK: - Parsing

public extension RawCommandSequence {
    enum ParseError: Error, Hashable, Sendable {
        case emptyInput
        case invalidByte(String)
        case orphanedSeparator
    }

    /// Parse `21:60:00, 21:00:E1:40` into a `RawCommandSequence`.
    /// Whitespace inside tokens is tolerated; `??` is a placeholder.
    static func parse(_ input: String, family: TagFamily = .unknown) throws -> RawCommandSequence {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyInput }

        var tokens: [Token] = []
        for rawCommand in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let commandString = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandString.isEmpty else { throw ParseError.orphanedSeparator }

            var elements: [Token.Element] = []
            for piece in commandString.split(separator: ":", omittingEmptySubsequences: false) {
                let pieceString = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if pieceString == "??" {
                    elements.append(.placeholder)
                    continue
                }
                guard pieceString.count == 2,
                      let byte = UInt8(pieceString, radix: 16)
                else {
                    throw ParseError.invalidByte(pieceString)
                }
                elements.append(.byte(byte))
            }
            tokens.append(Token(elements: elements))
        }
        return RawCommandSequence(commands: tokens, family: family)
    }
}
