import Foundation

/// 从公网下载 OTA 固件。必须在后台线程执行，避免在 @MainActor 上调用 URLSession 卡死。
enum FirmwareDownloadClient {
    private static let logTag = "[FirmwareDownload]"

    static func fetchContentLength(url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        AppRequestHeaders.apply(to: &request)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        let length = http.expectedContentLength
        return length > 0 ? Int(length) : nil
    }

    static func download(
        from url: URL,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(onProgress: onProgress) { result in
                continuation.resume(with: result)
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            request.cachePolicy = .reloadIgnoringLocalCacheData
            AppRequestHeaders.apply(to: &request)

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 600
            config.waitsForConnectivity = false

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: request)
            delegate.task = task
            print("\(logTag) start url=\(url.absoluteString)")
            DebugLogStore.logHTTPSent(
                method: "GET",
                url: url.absoluteString,
                body: "firmware download",
                headers: request.allHTTPHeaderFields
            )
            task.resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: (@Sendable (Int) -> Void)?
        private let completion: (Result<Data, Error>) -> Void
        fileprivate weak var session: URLSession?
        fileprivate var task: URLSessionDownloadTask?
        private var finished = false

        init(onProgress: (@Sendable (Int) -> Void)?, completion: @escaping (Result<Data, Error>) -> Void) {
            self.onProgress = onProgress
            self.completion = completion
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let http = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }
            guard totalBytesExpectedToWrite > 0 else { return }
            // Reserve completion for a payload which has passed content validation.
            let percent = min(99, Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100))
            onProgress?(percent)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard !finished else { return }
            guard let response = downloadTask.response as? HTTPURLResponse else {
                finish(.failure(FirmwareDownloadError.badResponse))
                return
            }
            guard (200...299).contains(response.statusCode) else {
                DebugLogStore.logHTTPReceived(
                    method: "GET",
                    url: downloadTask.originalRequest?.url?.absoluteString ?? "",
                    statusCode: response.statusCode,
                    body: "<firmware download rejected before transfer to glasses>",
                    headers: DebugLogStore.headerFields(from: response)
                )
                finish(.failure(FirmwareDownloadError.httpStatus(response.statusCode)))
                return
            }

            do {
                let data = try Data(contentsOf: location)
                do {
                    try FirmwareDownloadValidation.validate(data, response: response)
                } catch let error as FirmwareDownloadValidation.ValidationError {
                    DebugLogStore.logHTTPReceived(
                        method: "GET",
                        url: downloadTask.originalRequest?.url?.absoluteString ?? "",
                        statusCode: response.statusCode,
                        body: "<firmware download rejected before transfer to glasses: bytes=\(data.count) reason=\(error)>",
                        headers: DebugLogStore.headerFields(from: response)
                    )
                    switch error {
                    case .emptyFile: finish(.failure(FirmwareDownloadError.emptyFile))
                    case .documentResponse: finish(.failure(FirmwareDownloadError.invalidFile))
                    case .lengthMismatch: finish(.failure(FirmwareDownloadError.incompleteFile))
                    }
                    return
                }
                print("\(FirmwareDownloadClient.logTag) done status=\(response.statusCode) bytes=\(data.count)")
                DebugLogStore.logHTTPReceived(
                    method: "GET",
                    url: downloadTask.originalRequest?.url?.absoluteString ?? "",
                    statusCode: response.statusCode,
                    body: "<firmware \(data.count) bytes>",
                    headers: DebugLogStore.headerFields(from: response)
                )
                onProgress?(100)
                finish(.success(data))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                DebugLogStore.logHTTPReceived(
                    method: "GET",
                    url: task.originalRequest?.url?.absoluteString ?? "",
                    statusCode: nil,
                    body: nil,
                    error: error.localizedDescription
                )
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            session?.invalidateAndCancel()
            completion(result)
        }
    }
}

enum FirmwareDownloadError: LocalizedError {
    case badResponse
    case httpStatus(Int)
    case emptyFile
    case invalidFile
    case incompleteFile

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return L10n.t("固件下载响应异常", "Unexpected firmware download response")
        case .httpStatus(let code):
            return L10n.t("固件下载失败(\(code))", "Firmware download failed (\(code))")
        case .emptyFile:
            return L10n.t("固件文件为空", "Firmware file is empty")
        case .invalidFile:
            return L10n.t("下载内容不是有效固件，请更换网络后重试", "The download is not valid firmware. Try another network and retry")
        case .incompleteFile:
            return L10n.t("固件下载不完整，请重新下载", "Firmware download is incomplete. Please download it again")
        }
    }
}
