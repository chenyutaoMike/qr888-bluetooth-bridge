import CoreGraphics
import Foundation

func sample(_ number: Int) -> Data {
    // One 8 × 8 raster with one black dot, compressed with zlib.
    let pixels: [UInt8] = [0x78, 0x9c, 0x6b, 0x60, 0x80, 0x00, 0x00, 0x04, 0x08, 0x00, 0x81]
    let header = "SIZE 0.68 mm,0.68 mm\r\nREFERENCE 0,0\r\nCLS\r\nBITMAP 0,0,1,8,3,\(pixels.count),"
    return Data(header.utf8) + Data(pixels) + Data("\r\nPRINT \(number),1\r\n".utf8)
}

precondition(PrinterName.supports("QR-888XPro"))
precondition(PrinterName.supports("qr-888xpro_ab12_BLE"))
precondition(!PrinterName.supports("QR-888BT"))
precondition(!PrinterName.supports("QR-888XProMax"))
precondition(!PrinterName.supports(nil))

let setup = QueueConfiguration.production
precondition(setup.matches("设备示例：lpd://127.0.0.1:19150/qr888?timeout=170\n"))
precondition(!setup.matches("device: lpd://127.0.0.1:19150/qr888-other"))
precondition(!setup.matches("device: ipp://192.0.2.1/printers/demo"))
precondition(!setup.installArguments(ppd: "/Library/tmp/example.ppd").contains("-d"))

let single = sample(1)
let hundred = Data(repeating: 0, count: 64) + (0..<100).reduce(into: Data()) { data, _ in data.append(single) }
let pages = try LabelPage.parse(hundred)
precondition(pages.count == 100 && pages.reduce(0) { $0 + $1.copies } == 100)
let image = try pages[0].image()
precondition(image.width == 8 && image.height == 8)
precondition((try? LabelPage.parse(Data(single.dropLast(8)))) == nil)

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: scratch) }
let spool = try PrintSpool(directory: scratch)
let job = PrintJob(title: "测试标签", data: hundred)
let first = try spool.enqueue(job)
let second = try spool.enqueue(job)
let reopened = try PrintSpool(directory: scratch)
precondition(reopened.pending == [first, second])
let stored = try reopened.read(first)
precondition(stored.title == job.title && stored.data == hundred)
let started = try reopened.start(first)
try reopened.remove(second)
let afterRestart = try PrintSpool(directory: scratch)
precondition(afterRestart.pending.isEmpty && afterRestart.interrupted == [started])
try afterRestart.remove(started)
print("Printer discovery, CUPS settings, 100 labels and spool recovery passed")
