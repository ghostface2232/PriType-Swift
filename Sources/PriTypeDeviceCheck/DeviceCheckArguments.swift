import Foundation

/// What a command line asked for.
///
/// Parsing lives here, apart from the process, because the interesting cases are
/// the ones that must not silently become a green run: a misspelled id, a
/// `--timeout` with nothing after it, a flag nobody recognizes. Those are worth
/// tests, and a `main.swift` cannot have any.
public struct DeviceCheckArguments: Sendable, Equatable {
    public var selection: DeviceCheckSelection
    public var timeout: TimeInterval?
    public var wantsList: Bool
    public var wantsHelp: Bool

    public init(selection: DeviceCheckSelection = DeviceCheckSelection(),
                timeout: TimeInterval? = nil,
                wantsList: Bool = false,
                wantsHelp: Bool = false) {
        self.selection = selection
        self.timeout = timeout
        self.wantsList = wantsList
        self.wantsHelp = wantsHelp
    }

    public enum ParseError: Error, Sendable, Equatable {
        case unrecognized(String)
        case missingValue(String)
        case unusableTimeout(String)
        case emptySelection(String)

        public var message: String {
            switch self {
            case .unrecognized(let argument): return "unrecognized argument: \(argument)"
            case .missingValue(let flag): return "\(flag) needs a value"
            case .unusableTimeout(let value): return "--timeout wants a positive number of seconds, not \(value)"
            case .emptySelection(let value):
                return "--only names no check: \(value.debugDescription)"
            }
        }
    }

    /// - Parameter arguments: the arguments *after* the executable's own name.
    public static func parse(_ arguments: [String]) throws -> DeviceCheckArguments {
        var parsed = DeviceCheckArguments()
        var index = arguments.startIndex

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.endIndex {
            switch arguments[index] {
            case "--help", "-h":
                parsed.wantsHelp = true
            case "--list":
                parsed.wantsList = true
            case "--interactive":
                parsed.selection.includeInteractive = true
            case "--allow-mutation":
                parsed.selection.allowMutation = true
            case "--only":
                let value = try nextValue(for: "--only")
                let ids = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // An empty set means "no filter" to the runner, so a value that
                // trims away to nothing — `--only ""`, `--only ",,"`, or
                // `--only "$CHECKS"` with the variable unset — would quietly run
                // every unattended check and report on a set nobody asked for.
                // Asking for nothing is a mistake, not a request for everything.
                guard !ids.isEmpty else { throw ParseError.emptySelection(value) }
                parsed.selection.ids.formUnion(ids)
            case "--timeout":
                let value = try nextValue(for: "--timeout")
                guard let seconds = TimeInterval(value), seconds > 0 else {
                    throw ParseError.unusableTimeout(value)
                }
                parsed.timeout = seconds
            case let other:
                throw ParseError.unrecognized(other)
            }
            index += 1
        }
        return parsed
    }
}
