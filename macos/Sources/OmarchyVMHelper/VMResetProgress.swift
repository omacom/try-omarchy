import Foundation

enum VMResetPhase: String, CaseIterable, Sendable {
    case checking
    case deleting
    case preparing
    case verifying
    case finishing

    var buttonTitle: String {
        switch self {
        case .checking: "Checking VM…"
        case .deleting: "Deleting VM…"
        case .preparing: "Preparing image…"
        case .verifying: "Verifying image…"
        case .finishing: "Finishing reset…"
        }
    }
}

/// Pipe reads can split a phase marker anywhere. Accept only complete, exact
/// launcher-owned lines, and discard oversized log lines without growing state.
struct VMResetProgressStream {
    private var line = Data()
    private var discardingLine = false
    private(set) var phase: VMResetPhase?

    mutating func append(_ data: Data) -> [VMResetPhase] {
        var phases: [VMResetPhase] = []
        for byte in data {
            if byte == 10 {
                if !discardingLine {
                    if line.last == 13 { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    let prefix = "[qemu-gpu] Reset phase: "
                    let previousIndex = phase.flatMap { VMResetPhase.allCases.firstIndex(of: $0) } ?? -1
                    if text.hasPrefix(prefix),
                       let next = VMResetPhase(rawValue: String(text.dropFirst(prefix.count))),
                       let nextIndex = VMResetPhase.allCases.firstIndex(of: next),
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
