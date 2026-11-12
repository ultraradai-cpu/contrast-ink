import ContrastInkCore
import Foundation
import XCTest
@testable import ContrastInkPC

final class MacRulesTests: XCTestCase {
    func testSettingsRoundTripAndRepair() throws {
        var s = MacSettings()
        s.tool = .oval; s.color = 4; s.width = 2; s.opacity = 0.3; s.toolbarX = 12; s.toolbarY = 800; s.tabletPad = true
        let back = MacSettings.decode(s.encoded(), screens: 2)
        XCTAssertEqual(back, s)
        // damaged or old copies: what is missing keeps its default, what is out of range is brought back
        let odd = MacSettings.decode(Data("{\"tool\":\"brush\",\"color\":99,\"width\":-3,\"opacity\":7,\"screen\":5,\"undoWithZ\":\"yes\"}".utf8), screens: 2)
        XCTAssertEqual(odd.tool, .pen)
        XCTAssertEqual(odd.color, Settings.colors.count - 1)
        XCTAssertEqual(odd.width, 0)
        XCTAssertEqual(odd.opacity, 1)
        XCTAssertEqual(odd.screen, 1)
        XCTAssertTrue(odd.undoWithZ)
        XCTAssertEqual(MacSettings.decode(Data("garbage".utf8), screens: 1), MacSettings())
        XCTAssertEqual(MacSettings.decode(nil, screens: 1), MacSettings())
        XCTAssertEqual(MacSettings().lineWidth, Settings.widths[1])
    }

    func testKeysWhileDrawing() {
        func k(_ code: UInt16, _ c: String, cmd: Bool = false, ctrl: Bool = false, z: Bool = true) -> MacKey? {
            MacKeys.resolve(keyCode: code, characters: c, command: cmd, control: ctrl, undoWithZ: z)
        }
        XCTAssertEqual(k(35, "p"), .action(.pen))
        XCTAssertEqual(k(4, "H"), .action(.highlighter))
        XCTAssertEqual(k(0, "a"), .action(.arrow))
        XCTAssertEqual(k(31, "o"), .action(.oval))
        XCTAssertEqual(k(14, "e"), .action(.eraser))
        XCTAssertEqual(k(37, "l"), .action(.laser))
        XCTAssertEqual(k(18, "1"), .action(.color(0)))
        XCTAssertEqual(k(22, "6"), .action(.color(5)))
        XCTAssertEqual(k(33, "["), .action(.thinner))
        XCTAssertEqual(k(30, "]"), .action(.thicker))
        XCTAssertEqual(k(3, "f"), .action(.fade))
        XCTAssertEqual(k(8, "c"), .action(.clear))
        XCTAssertEqual(k(6, "z"), .action(.undo))
        XCTAssertNil(k(6, "z", z: false))
        XCTAssertEqual(k(6, "z", cmd: true, z: false), .action(.undo))
        XCTAssertNil(k(8, "c", cmd: true), "⌘C is not Clear")
        XCTAssertNil(k(35, "p", ctrl: true))
        XCTAssertEqual(k(MacKeys.escape, ""), .stopDrawing)
        XCTAssertEqual(k(MacKeys.right, ""), .pass(.next))
        XCTAssertEqual(k(MacKeys.space, " "), .pass(.next))
        XCTAssertEqual(k(MacKeys.pageUp, ""), .pass(.previous))
        XCTAssertEqual(k(MacKeys.left, ""), .pass(.previous))
        XCTAssertNil(k(9, "v"))
    }

    #if canImport(CryptoKit)
    func testObsPasswordAnswer() {
        // computed independently (Python's hashlib) from protocol.md's recipe
        XCTAssertEqual(Obs.auth(password: "supersecretpassword", salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
                                challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="),
                       "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
        let id = Obs.identify(hello: ["op": 0, "d": ["authentication": ["salt": "s", "challenge": "c"]]], password: "p")
        XCTAssertEqual((id["d"] as? [String: Any])?["authentication"] as? String, Obs.auth(password: "p", salt: "s", challenge: "c"))
        let open = Obs.identify(hello: ["op": 0, "d": [:] as [String: Any]], password: nil)
        XCTAssertNil((open["d"] as? [String: Any])?["authentication"])
        XCTAssertEqual((open["d"] as? [String: Any])?["eventSubscriptions"] as? Int, 64)
    }
    #endif

    func testObsConfigOnTheMac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("obs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(Obs.readConfig(folder: dir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[General]\nX=1\n[OBSWebSocket]\nServerEnabled=true\nServerPort=4456\nAuthRequired=false\nServerPassword=abc\n"
            .write(to: dir.appendingPathComponent("global.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Obs.readConfig(folder: dir), Obs.Connection(enabled: true, port: 4456, password: nil))
        let json = dir.appendingPathComponent("plugin_config/obs-websocket", isDirectory: true)
        try FileManager.default.createDirectory(at: json, withIntermediateDirectories: true)
        try "{\"server_enabled\":true,\"server_port\":4455,\"auth_required\":true,\"server_password\":\"pw\"}"
            .write(to: json.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Obs.readConfig(folder: dir), Obs.Connection(enabled: true, port: 4455, password: "pw"))
        try "{}".write(to: json.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Obs.readConfig(folder: dir), Obs.Connection(enabled: false, port: 4455, password: ""))
        XCTAssertEqual(Obs.folder(home: URL(fileURLWithPath: "/Users/x")).path, "/Users/x/Library/Application Support/obs-studio")
        XCTAssertTrue(Obs.screenKinds.contains("screen_capture"))
        XCTAssertEqual(Obs.timer(65), "1:05")
        XCTAssertEqual(Obs.timer(3725), "1:02:05")
    }

    func testUsbMuxPackets() throws {
        XCTAssertEqual(UsbMux.swapped(47830), 0xD6BA)
        let p = UsbMux.connect(device: 7, port: 47830)
        let head = [UInt8](p.prefix(16))
        XCTAssertEqual(Int(head[0]) | Int(head[1]) << 8, p.count)
        XCTAssertEqual(Array(head[4..<16]), [1, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(UsbMux.bodyLength(header: p.prefix(16)), p.count - 16)
        let body = try XCTUnwrap(PropertyListSerialization.propertyList(from: p.dropFirst(16), format: nil) as? [String: Any])
        XCTAssertEqual(body["MessageType"] as? String, "Connect")
        XCTAssertEqual(body["DeviceID"] as? Int, 7)
        XCTAssertEqual(body["PortNumber"] as? Int, 0xD6BA)
        XCTAssertNil(UsbMux.bodyLength(header: Data(repeating: 0, count: 15)))
        XCTAssertNil(UsbMux.bodyLength(header: Data([4, 0, 0, 0] + [UInt8](repeating: 0, count: 12))))

        let list: [String: Any] = ["DeviceList": [
            ["DeviceID": 3, "MessageType": "Attached", "Properties": ["ConnectionType": "USB", "DeviceID": 3]],
            ["DeviceID": 4, "MessageType": "Attached", "Properties": ["ConnectionType": "Network", "DeviceID": 4]],
        ]]
        let reply = try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        XCTAssertEqual(UsbMux.devices(reply), [3])
        XCTAssertEqual(UsbMux.devices(Data("nonsense".utf8)), [])
        let ok = try PropertyListSerialization.data(fromPropertyList: ["MessageType": "Result", "Number": 0], format: .xml, options: 0)
        XCTAssertEqual(UsbMux.result(ok), 0)
    }

    func testAdb() {
        XCTAssertEqual(Adb.devices("List of devices attached\nR58N123\tdevice\nemulator-5554\toffline\nXYZ\tunauthorized\nABC\tdevice\n\n"),
                       ["R58N123", "ABC"])
        XCTAssertEqual(Adb.candidates(path: "/usr/bin:/opt/homebrew/bin/", home: "/Users/x"),
                       ["/usr/bin/adb", "/opt/homebrew/bin/adb", "/Users/x/Library/Android/sdk/platform-tools/adb", "/usr/local/bin/adb"])
        XCTAssertEqual(Adb.reverseArguments(serial: "R58"), ["-s", "R58", "reverse", "tcp:47830", "tcp:47830"])
    }
}
