import Foundation

protocol VMProgressPhase: CaseIterable, RawRepresentable, Equatable, Sendable where RawValue == String {
    var buttonTitle: String { get }
}

enum VMResetPhase: String, VMProgressPhase {
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

enum VMLaunchPhase: String, VMProgressPhase {
    case checking
    case verifying
    case preparing
    case finishing
    case starting

    var buttonTitle: String {
        switch self {
        case .checking: "Checking VM…"
        case .verifying: "Verifying the Omarchy image…"
        case .preparing: "Unpacking Omarchy…"
        case .finishing: "Compacting the disk…"
        case .starting: "Starting Omarchy…"
        }
    }
}

/// A step of a VM operation, with how much of it is done when the launcher
/// can measure that.
struct VMProgress<Phase: VMProgressPhase>: Equatable, Sendable {
    var phase: Phase
    var percent: Int?

    var title: String {
        guard let percent else { return phase.buttonTitle }
        return "\(phase.buttonTitle) \(percent)%"
    }
}

enum VMProgressOperation: String {
    case reset = "Reset"
    case launch = "Launch"
}

/// Pipe reads can split a marker anywhere. Accept only complete, exact
/// launcher-owned lines, and discard oversized log lines without growing state.
struct VMProgressStream<Phase: VMProgressPhase> {
    private let phasePrefix: String
    private let percentPrefix: String
    private let knownPhases = Array(Phase.allCases)

    init(operation: VMProgressOperation) {
        phasePrefix = "[qemu-gpu] \(operation.rawValue) phase: "
        percentPrefix = "[qemu-gpu] \(operation.rawValue) progress: "
    }

    private var line = Data()
    private var discardingLine = false
    private(set) var progress: VMProgress<Phase>?

    mutating func append(_ data: Data) -> [VMProgress<Phase>] {
        var updates: [VMProgress<Phase>] = []
        for byte in data {
            if byte == 10 {
                if !discardingLine {
                    if line.last == 13 { line.removeLast() }
                    if let next = accept(String(decoding: line, as: UTF8.self)) {
                        progress = next
                        updates.append(next)
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
        return updates
    }

    /// Phases only move forward, and a percentage only rises within its phase.
    private func accept(_ text: String) -> VMProgress<Phase>? {
        if text.hasPrefix(phasePrefix) {
            let previousIndex = progress.flatMap { knownPhases.firstIndex(of: $0.phase) } ?? -1
            guard let next = Phase(rawValue: String(text.dropFirst(phasePrefix.count))),
                  let nextIndex = knownPhases.firstIndex(of: next),
                  nextIndex > previousIndex else { return nil }
            return VMProgress(phase: next)
        }
        if text.hasPrefix(percentPrefix), let progress {
            let digits = text.dropFirst(percentPrefix.count)
            guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let percent = Int(digits), (0...100).contains(percent),
                  percent > progress.percent ?? -1 else { return nil }
            return VMProgress(phase: progress.phase, percent: percent)
        }
        return nil
    }
}
