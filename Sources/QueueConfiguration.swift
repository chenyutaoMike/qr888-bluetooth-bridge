import Foundation

struct QueueConfiguration {
    let name: String
    let title: String
    let port: UInt16

    static let production = QueueConfiguration(name: "QR888_BLE", title: "启锐 QR-888XPro 蓝牙", port: 19150)
    static let test = QueueConfiguration(name: "QR888_RELEASE_TEST", title: "启锐预览测试（离线）", port: 19152)

    static let cupsSocket = "/var/run/cupsd"

    private var endpoint: String { "lpd://127.0.0.1:\(port)/qr888" }

    func matches(_ output: String) -> Bool {
        guard let match = output.range(of: endpoint) else { return false }
        let before = output[..<match.lowerBound].last
        let after = output[match.upperBound...].first
        let startsHere = before == nil || before == ":" || before == "：" || before?.isWhitespace == true
        let endsHere = after == nil || after == "?" || after?.isWhitespace == true
        return startsHere && endsHere
    }

    func installArguments(ppd: String) -> [String] {
        ["-h", Self.cupsSocket, "-p", name, "-D", title,
         "-v", endpoint + "?reserve=none&timeout=170&contimeout=10", "-P", ppd,
         "-o", "printer-is-shared=false", "-o", "PageSize=w283h283",
         "-o", "ColorModel=Gray", "-o", "Darkness=10", "-E"]
    }
}
