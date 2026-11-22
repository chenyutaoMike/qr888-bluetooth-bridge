import CoreGraphics
import Foundation
import zlib

struct LabelPage {
    enum Invalid: LocalizedError {
        case driverData
        var errorDescription: String? { "无法完整预览这份启锐驱动输出。请取消任务，检查纸张和打印设置后再提交。" }
    }

    let widthMM: Double
    let heightMM: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let copies: Int
    private let bytesPerRow: Int
    private let compressed: Data

    static func parse(_ data: Data) throws -> [LabelPage] {
        let newline = Data([13, 10])
        let comma = Data([44])
        let bitmap = Data("BITMAP ".utf8)
        var cursor = data.startIndex
        var pages: [LabelPage] = []

        func field(upTo delimiter: Data, limit: Int) throws -> String {
            let end = min(cursor + limit, data.endIndex)
            guard let match = data.range(of: delimiter, in: cursor..<end),
                  let value = String(data: data[cursor..<match.lowerBound], encoding: .ascii) else {
                throw Invalid.driverData
            }
            cursor = match.upperBound
            return value
        }

        func number() throws -> Int {
            guard let value = Int(try field(upTo: comma, limit: 12)), value >= 0 else { throw Invalid.driverData }
            return value
        }

        func millimeters(_ field: Substring) -> Double? {
            guard field.hasSuffix(" mm"), let value = Double(field.dropLast(3)), value > 0, value <= 1000 else { return nil }
            return value
        }

        while cursor < data.endIndex {
            while cursor < data.endIndex && data[cursor] == 0 { cursor += 1 }
            if cursor == data.endIndex { break }
            let size = try field(upTo: newline, limit: 128)
            guard size.hasPrefix("SIZE ") else { throw Invalid.driverData }
            let dimensions = size.dropFirst(5).split(separator: ",")
            guard dimensions.count == 2, let width = millimeters(dimensions[0]),
                  let height = millimeters(dimensions[1]) else { throw Invalid.driverData }
            while !data[cursor...].starts(with: bitmap) {
                let command = try field(upTo: newline, limit: 128)
                // These stock-driver commands do not draw onto the label bitmap.
                guard command == "CLS" || command.hasPrefix("SET ") || command.hasPrefix("SETC ") ||
                        command.hasPrefix("REFERENCE ") || command.hasPrefix("GAP ") ||
                        command.hasPrefix("BLINE ") || command.hasPrefix("OFFSET ") ||
                        command.hasPrefix("DENSITY ") || command.hasPrefix("SPEED ") else { throw Invalid.driverData }
            }
            cursor += bitmap.count
            let x = try number()
            let y = try number()
            let stride = try number()
            let rows = try number()
            let mode = try number()
            let length = try number()
            let columns = Int((width * 300 / 25.4).rounded())
            let packed = (columns + 7) / 8
            let aligned = ((packed + 3) / 4) * 4
            guard x == 0, y == 0, mode == 3, columns > 0, stride == packed || stride == aligned,
                  rows > 0, abs(rows - Int((height * 300 / 25.4).rounded())) <= 1,
                  length > 0, length <= data.endIndex - cursor else { throw Invalid.driverData }
            let compressed = data.subdata(in: cursor..<(cursor + length))
            cursor += length
            guard try field(upTo: newline, limit: 2).isEmpty else { throw Invalid.driverData }
            let print = try field(upTo: newline, limit: 128)
            guard print.hasPrefix("PRINT ") else { throw Invalid.driverData }
            let counts = print.dropFirst(6).split(separator: ",")
            guard counts.count == 2, let sets = Int(counts[0]), let perSet = Int(counts[1]),
                  (1...9999).contains(sets), (1...9999).contains(perSet) else { throw Invalid.driverData }
            let page = LabelPage(widthMM: width, heightMM: height, pixelWidth: columns, pixelHeight: rows,
                                 copies: sets * perSet, bytesPerRow: stride, compressed: compressed)
            _ = try page.pixels()
            pages.append(page)
        }
        guard !pages.isEmpty else { throw Invalid.driverData }
        return pages
    }

    private func pixels() throws -> Data {
        var raw = Data(count: bytesPerRow * pixelHeight)
        var length = uLongf(raw.count)
        let status = raw.withUnsafeMutableBytes { target in
            compressed.withUnsafeBytes { source in
                uncompress(target.bindMemory(to: Bytef.self).baseAddress, &length,
                           source.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
            }
        }
        guard status == Z_OK, length == raw.count else { throw Invalid.driverData }
        return raw
    }

    func image() throws -> CGImage {
        let raw = try pixels()
        let provider = CGDataProvider(data: raw as CFData)
        let decode: [CGFloat] = [1, 0] // The label driver stores 1 for black dots.
        guard let source = provider, let image = CGImage(width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: source, decode: decode, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Invalid.driverData
        }
        return image
    }
}
