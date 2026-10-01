import Foundation

enum VMResetPhase: String, CaseIterable, Sendable {
    case checking
    case deleting
    case finishing

    var buttonTitle: String {
        switch self {
        case .checking: "Checking VM…"
        case .deleting: "Deleting VM…"
        case .finishing: "Finishing reset…"
        }
    }
}

enum VMLaunchPhase: String, CaseIterable, Sendable {
    case checking
    case preparing
    case verifying
    case finishing
    case starting

    var buttonTitle: String {
        switch self {
        case .checking: "Checking VM…"
        case .preparing: "Preparing image…"
        case .verifying: "Verifying image…"
        case .finishing: "Finishing setup…"
        case .starting: "Starting Omarchy…"
        }
    }
}

enum VMProgressOperation: String {
    case reset = "Reset"
    case launch = "Launch"
}

/// Pipe reads can split a phase marker anywhere. Accept only complete, exact
/// launcher-owned lines, and discard oversized log lines without growing state.
struct VMProgressStream<Phase: CaseIterable & RawRepresentable & Equatable> where Phase.RawValue == String {
    private let prefix: String
    private let knownPhases = Array(Phase.allCases)

    init(operation: VMProgressOperation) {
        prefix = "[qemu-gpu] \(operation.rawValue) phase: "
    }

    private var line = Data()
    private var discardingLine = false
    private(set) var phase: Phase?

    mutating func append(_ data: Data) -> [Phase] {
        var phases: [Phase] = []
        for byte in data {
            if byte == 10 {
                if !discardingLine {
                    if line.last == 13 { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    let previousIndex = phase.flatMap { knownPhases.firstIndex(of: $0) } ?? -1
                    if text.hasPrefix(prefix),
                       let next = Phase(rawValue: String(text.dropFirst(prefix.count))),
                       let nextIndex = knownPhases.firstIndex(of: next),
                       nextIndex > previousIndex {
                        phase = next
                        phases.append(next)
                    }
                }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count < 256 {
                    line.append(byte)
                } else {
                    line.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        return phases
    }
}
