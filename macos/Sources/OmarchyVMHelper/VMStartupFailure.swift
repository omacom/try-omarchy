import Foundation

/// Startup failures happen before Linux boots as well as inside QEMU. Keep the
/// launcher's diagnostic visible so an ordinary retry does not require a reset
/// or an unexplained reinstall.
enum VMStartupFailure {
    static func message(status: Int32, standardError: String) -> String {
        if standardError.contains("run-qemu-gpu: the installed app is damaged or has an invalid code signature") {
            return "The installed app failed its code-signature check. Replace it with a freshly built or downloaded copy, then try again. Replacing the app keeps your saved VM."
        }

        // The supervisor bounds stderr, but it can contain shell diagnostics
        // from the optional HVF probe followed by the actual launch failure.
        // Prefer the launcher's final explanation over those earlier lines.
        let lines = standardError.components(separatedBy: .newlines)
        let explanation = lines.last {
            $0.hasPrefix("run-qemu-gpu: ") || $0.hasPrefix("qemu-persistent-storage: ")
        }
        let diagnostic = String((explanation ?? standardError).suffix(1_800))
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let details = String(String.UnicodeScalarView(diagnostic))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "Omarchy couldn’t start (exit status \(status)). Try launching again."
        return details.isEmpty ? summary : "\(summary)\n\nStartup details:\n\(details)"
    }
}
