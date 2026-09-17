import XCTest
@testable import Loomup

final class StorageUploadTests: XCTestCase {
    func testLargeDataUsesBoundedChunksAndRetries() async throws {
        let http = MockHTTP()
        let size = 8 * 1024 * 1024 + 3
        let offset = LockedValue(0)
        let dropped = LockedValue(false)
        http.handler = { method, url, _, body in
            let session: () -> [String: Any] = { ["id": "session", "size": size, "offset": offset.snapshot(), "chunk_size": 8 * 1024 * 1024] }
            if url.hasSuffix("/uploads") { return (try JSONSerialization.data(withJSONObject: ["data": session()]), 200) }
            if method == "PUT" {
                let start = Int(URLComponents(string: url)!.queryItems!.first!.value!)!
                let count = body!.count
                XCTAssertLessThanOrEqual(count, 8 * 1024 * 1024)
                offset.withValue { $0 = start + count }
                if dropped.withValue({ value in if value { return false }; value = true; return true }) {
                    throw URLError(.networkConnectionLost)
                }
                return (try JSONSerialization.data(withJSONObject: ["data": session()]), 200)
            }
            XCTAssertTrue(url.hasSuffix("/complete"))
            XCTAssertEqual(offset.snapshot(), size)
            return (try JSONSerialization.data(withJSONObject: ["data": ["id": "object", "bucket": "files", "path": "movie.mp4", "name": "movie.mp4", "size": size, "created_at": 1, "updated_at": 1]]), 200)
        }
        let client = createClient(url: URL(string: "https://example.test")!, token: "token", http: http)
        let object = try await client.storage.from("files").upload(path: "movie.mp4", data: Data(repeating: 42, count: size), contentType: "video/mp4")
        XCTAssertEqual(object.size, Int64(size))
        XCTAssertEqual(http.calls.filter { $0.method == "PUT" }.count, 3)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 42, count: size).write(to: file)
        offset.withValue { $0 = 0 }; dropped.withValue { $0 = false }
        let fromFile = try await client.storage.from("files").upload(path: "movie.mp4", fileURL: file, contentType: "video/mp4")
        XCTAssertEqual(fromFile.size, Int64(size))
        XCTAssertEqual(http.calls.filter { $0.method == "PUT" }.count, 6)
    }
}

private struct FileDownloadHTTP: HTTPTransport {
    let file: URL
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw LoomupError("Download must not use an in-memory response", code: "test")
    }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension StorageUploadTests {
    func testFileDownloadUsesDiskTransport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3]).write(to: file)
        let client = createClient(url: URL(string: "https://example.test")!, token: "token", http: FileDownloadHTTP(file: file))
        let downloaded = try await client.storage.from("files").downloadFile(path: "file.bin")
        XCTAssertEqual(downloaded, file)
    }
}
