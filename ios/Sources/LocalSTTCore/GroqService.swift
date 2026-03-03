import Foundation

/// Groq Whisper API client for speech-to-text.
///
/// Ported from `backend/groq_stt.py`. Sends audio directly to Groq's
/// OpenAI-compatible API endpoint — no backend server needed.
public final class GroqService: Sendable {
    private let apiKey: String
    private let model = "whisper-large-v3-turbo"
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Transcribe WAV audio data using Groq's Whisper API.
    ///
    /// - Parameters:
    ///   - wavData: Complete WAV file data (16kHz mono 16-bit PCM)
    ///   - language: ISO language code ("en", "fr", etc.) or nil for auto-detect
    ///   - prompt: Vocabulary prompt for biasing (max 896 chars)
    /// - Returns: Transcription result
    /// - Throws: ``GroqError`` on failure
    public func transcribe(
        wavData: Data,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        let startTime = Date()

        let (body, contentType) = buildMultipartBody(
            wavData: wavData,
            language: language,
            prompt: prompt
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroqError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
        let processingTime = Date().timeIntervalSince(startTime)

        let duration = groqResponse.duration
            ?? WAVEncoder.estimateDuration(from: wavData)

        return TranscriptionResult(
            text: groqResponse.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: groqResponse.language ?? language ?? "unknown",
            duration: duration,
            processingTime: processingTime
        )
    }

    /// Test API connectivity by sending a minimal request.
    /// Returns true if the API key is valid.
    public func testConnection() async -> Bool {
        // Create a minimal 0.1s silent WAV to test the API
        let silentSamples = Data(count: WAVEncoder.sampleRate / 10 * WAVEncoder.bytesPerSample)
        let wavData = WAVEncoder.encode(pcmData: silentSamples)

        do {
            _ = try await transcribe(wavData: wavData)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Multipart Form Data Building

    /// Build multipart/form-data request body.
    ///
    /// Matches the parameters used in `backend/groq_stt.py:transcribe()`.
    public func buildMultipartBody(
        wavData: Data,
        language: String?,
        prompt: String?
    ) -> (Data, String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        // model field
        body.appendFormField(name: "model", value: model, boundary: boundary)

        // response_format field
        body.appendFormField(name: "response_format", value: "verbose_json", boundary: boundary)

        // language field (optional)
        if let language, !language.isEmpty {
            body.appendFormField(name: "language", value: language, boundary: boundary)
        }

        // prompt field (optional)
        if let prompt, !prompt.isEmpty {
            body.appendFormField(name: "prompt", value: prompt, boundary: boundary)
        }

        // file field
        body.appendFormFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData, boundary: boundary)

        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let contentType = "multipart/form-data; boundary=\(boundary)"
        return (body, contentType)
    }
}

// MARK: - Response Model

struct GroqResponse: Decodable {
    let text: String
    let language: String?
    let duration: TimeInterval?
}

// MARK: - Errors

public enum GroqError: LocalizedError, Sendable {
    case missingAPIKey
    case httpError(statusCode: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Groq API key not configured. Add it in Settings."
        case .httpError(let code, let body):
            if code == 401 {
                return "Invalid Groq API key. Check Settings."
            }
            return "Groq API error (\(code)): \(body)"
        case .invalidResponse:
            return "Invalid response from Groq API."
        }
    }
}

// MARK: - Data Multipart Helpers

extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFormFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
