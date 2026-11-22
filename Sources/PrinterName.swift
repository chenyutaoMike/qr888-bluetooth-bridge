import Foundation

enum PrinterName {
    static func supports(_ candidate: String?) -> Bool {
        guard let name = candidate?.lowercased() else { return false }
        let model = "qr-888xpro"
        return name == model || name.hasPrefix(model + "_")
    }
}
