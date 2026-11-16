import XCTest
import MLX
import ImageIO
@testable import ServerCore

final class ServerCoreTests: XCTestCase {
    func status(_ code: Int, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in XCTAssertEqual((error as? APIError)?.status, code, file: file, line: line) }
    }
    func testStringAndPartsContent() throws {
        let a = try ChatRequest(data: jsonData(["messages": [["role": "user", "content": "Hello"]], "chat_template_kwargs": ["enable_thinking": false], "reasoning_effort": "low", "extra_body": [:]]))
        let b = try ChatRequest(data: jsonData(["messages": [["role": "user", "content": [["type": "text", "text": "Hello"]]]], "max_tokens": 7, "temperature": 0.4, "top_p": 0.8, "stream": true]))
        XCTAssertEqual(a.messages.first?.text, b.messages.first?.text)
        XCTAssertEqual(b.maxTokens, 7); XCTAssertEqual(b.temperature, 0.4); XCTAssertEqual(b.topP, 0.8); XCTAssertTrue(b.stream)
    }
    func fixture() throws -> Data { try PNG.encode(MLXArray([-1.0 as Float, 1, -1, -1, 1, -1], [1, 3, 1, 2])) }
    func testPNGKnownTensorAndURI() throws {
        // Two pixels: blue, red. Read PNG pixels back to check channel order and normalization.
        let png = try fixture()
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(try decodeDataURI("data:image/png;base64," + png.base64EncodedString()), png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 1)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let pointer = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: 8)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pointer, count: 8)), [0, 0, 255, 255, 255, 0, 0, 255])
    }
    func testHistoryAndMultipleImages() throws {
        let uri = "data:image/png;base64," + (try fixture()).base64EncodedString()
        let request = try ChatRequest(data: jsonData(["messages": [
            ["role": "system", "content": "Be concise"],
            ["role": "user", "content": [["type": "image_url", "image_url": ["url": uri]], ["type": "text", "text": "first"]]],
            ["role": "assistant", "content": "One"],
            ["role": "user", "content": [["type": "text", "text": "Compare"], ["type": "image_url", "image_url": ["url": uri]]]]]]))
        XCTAssertEqual(request.messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(request.messages.flatMap(\.images).count, 2)
        XCTAssertTrue(request.messages[1].text.hasPrefix("<image>\n"))
    }
    func testBadInputs400() {
        for value: Any in [[:], ["messages": []], ["messages": [["role": "tool", "content": "x"]]], ["messages": [["role": "user", "content": 4]]], ["messages": [["role": "user", "content": "<IMG_CONTEXT>"]]], ["messages": [["role": "user", "content": "x"]], "max_tokens": -1], ["messages": [["role": "user", "content": "x"]], "top_p": 0]] {
            status(400) { _ = try ChatRequest(data: jsonData(value)) }
        }
        for uri in ["https://example.com/a.png", "data:image/png;base64,!!!!", "data:image/png;base64,aGVsbG8="] { status(400) { _ = try decodeDataURI(uri) } }
        for size in ["0x1024", "1025x1024", "4096x4096", "1024", "256x2048"] { status(400) { _ = try ImageRequest(fields: ["prompt": "cat", "size": size]) } }
        status(400) { _ = try ImageRequest(fields: ["prompt": "cat", "n": 2]) }
    }
    func testAuth401AndKeyPermissions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let key = try Auth.loadKey(path: path.path)
        XCTAssertGreaterThanOrEqual(key.count, 40)
        XCTAssertEqual(try Auth.loadKey(path: path.path), key)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Auth.check("Bearer " + key, key: key)
        for header in [nil, "Basic x", "Bearer " + key.dropLast(), "Bearer " + key + "x", "Bearer " + String(repeating: "x", count: key.count)] { status(401) { try Auth.check(header, key: key) } }
    }
    func testQueueOverflow429AndRelease() throws {
        let queue = JobQueue()
        for _ in 0..<9 { try queue.reserve() }
        XCTAssertEqual(queue.health["queue"] as? Int, 8)
        status(429) { try queue.reserve() }
        queue.finish(); try queue.reserve()
        for _ in 0..<9 { queue.finish() }
        XCTAssertEqual(queue.health["queue"] as? Int, 0)
    }
    func testHTTPFraming() throws {
        let request = try HTTPRequest(header: Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\nContent-Type: application/json".utf8))
        XCTAssertEqual(request.length, 2)
        for header in ["Content-Length: -1", "Content-Length: 2\r\nContent-Length: 3", "Transfer-Encoding: chunked\r\nContent-Length: 2"] {
            XCTAssertThrowsError(try HTTPRequest(header: Data(("POST / HTTP/1.1\r\n" + header).utf8)))
        }
        status(413) { _ = try HTTPRequest(header: Data("POST / HTTP/1.1\r\nContent-Length: 26214401".utf8)) }
    }
    func testMultipartBinaryAndValidation() throws {
        let image = try fixture()
        var data = Data("--test\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nBlue sky\r\n--test\r\nContent-Disposition: form-data; name=\"image\"; filename=\"x.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        data += image; data += Data("\r\n--test--\r\n".utf8)
        let form = try Multipart(data: data, contentType: "multipart/form-data; boundary=\"test\"")
        XCTAssertEqual(form.image, image); XCTAssertEqual(form.fields["prompt"] as? String, "Blue sky")
        _ = try ImageRequest(fields: form.fields, image: form.image)
        status(400) { _ = try Multipart(data: Data("--test\r\ninvalid".utf8), contentType: "multipart/form-data; boundary=test") }
    }
    func testUnicodeStreamDeltas() {
        var stream = DecodedTextStream()
        let decoded = ["A", "Ae", "Ae\u{301}", "Ae\u{301}👩", "Ae\u{301}👩\u{200d}", "Ae\u{301}👩\u{200d}💻", "Ae\u{301}👩\u{200d}💻中"]
        let chunks = decoded.compactMap { stream.delta($0) }
        XCTAssertEqual(Data(chunks.joined().utf8), Data(decoded.last!.utf8))
        XCTAssertEqual(chunks.count, decoded.count)
        XCTAssertNil(stream.delta(decoded.last! + "\u{fffd}"))
        XCTAssertEqual(stream.delta(decoded.last! + "文"), "文")
        XCTAssertNil(stream.delta(decoded.last! + "文"))
        XCTAssertEqual(stream.delta(decoded.last! + "文\u{fffd}", final: true), "\u{fffd}")
    }
    func testConfigPrecedenceAndValidation() throws {
        let config = try Configuration(arguments: ["--port", "8004"], env: ["SENSENOVA_PORT": "8005", "SENSENOVA_HOST": "127.0.0.1"])
        XCTAssertEqual(config.port, 8004); XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertThrowsError(try Configuration(arguments: ["--port", "0"], env: [:]))
    }
}
