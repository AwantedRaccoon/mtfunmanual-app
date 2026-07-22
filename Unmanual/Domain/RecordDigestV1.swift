import CryptoKit
import Foundation

enum RecordDigestV1 {
    static let version = 1

    struct Field: Equatable, Sendable {
        let name: String
        let value: Value

        init(_ name: String, _ value: Value) {
            self.name = name
            self.value = value
        }
    }

    enum Value: Equatable, Sendable {
        case null
        case bool(Bool)
        case integer(Int64)
        case double(Double)
        case string(String)
        case uuid(UUID)
        case timestampMicroseconds(Int64)
    }

    enum EncodingError: Error, Equatable {
        case emptyRecordType
        case emptyFieldName
        case duplicateFieldName(String)
        case stringTooLarge
        case nonFiniteNumber
        case timestampOutOfRange
    }

    static func canonicalBytes(
        recordType: String,
        recordID: UUID,
        fields: [Field]
    ) throws -> Data {
        let normalizedRecordType = normalize(recordType)
        guard !normalizedRecordType.isEmpty else { throw EncodingError.emptyRecordType }

        let normalizedFields = try fields.map { field -> Field in
            let name = normalize(field.name)
            guard !name.isEmpty else { throw EncodingError.emptyFieldName }
            return Field(name, normalize(field.value))
        }
        .sorted { lhs, rhs in
            lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }

        for pair in zip(normalizedFields, normalizedFields.dropFirst()) where pair.0.name == pair.1.name {
            throw EncodingError.duplicateFieldName(pair.0.name)
        }

        var result = Data("UNMANUAL-RECORD-DIGEST\0".utf8)
        result.append(UInt8(version))
        try appendString(normalizedRecordType, to: &result)
        appendUUID(recordID, to: &result)
        try appendUInt32(normalizedFields.count, to: &result)

        for field in normalizedFields {
            try appendString(field.name, to: &result)
            try append(field.value, to: &result)
        }
        return result
    }

    static func sha256Hex(
        recordType: String,
        recordID: UUID,
        fields: [Field]
    ) throws -> String {
        let bytes = try canonicalBytes(recordType: recordType, recordID: recordID, fields: fields)
        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func timestampValue(_ date: Date) throws -> Value {
        .timestampMicroseconds(try timestampMicroseconds(date))
    }

    static func timestampMicroseconds(_ date: Date) throws -> Int64 {
        let roundedMicroseconds = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard roundedMicroseconds.isFinite,
              let microseconds = Int64(exactly: roundedMicroseconds) else {
            throw EncodingError.timestampOutOfRange
        }
        return microseconds
    }

    private static func append(_ value: Value, to data: inout Data) throws {
        switch value {
        case .null:
            data.append(0x00)
        case let .bool(value):
            data.append(value ? 0x02 : 0x01)
        case let .integer(value):
            data.append(0x03)
            appendInt64(value, to: &data)
        case let .double(value):
            guard value.isFinite else { throw EncodingError.nonFiniteNumber }
            data.append(0x04)
            appendUInt64(value.bitPattern, to: &data)
        case let .string(value):
            data.append(0x05)
            try appendString(value, to: &data)
        case let .uuid(value):
            data.append(0x06)
            appendUUID(value, to: &data)
        case let .timestampMicroseconds(value):
            data.append(0x07)
            appendInt64(value, to: &data)
        }
    }

    private static func normalize(_ value: Value) -> Value {
        guard case let .string(string) = value else { return value }
        return .string(normalize(string))
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private static func appendString(_ value: String, to data: inout Data) throws {
        let bytes = Data(normalize(value).utf8)
        guard bytes.count <= Int(UInt32.max) else { throw EncodingError.stringTooLarge }
        try appendUInt32(bytes.count, to: &data)
        data.append(bytes)
    }

    private static func appendUUID(_ value: UUID, to data: inout Data) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: Int, to data: inout Data) throws {
        guard value >= 0, value <= Int(UInt32.max) else { throw EncodingError.stringTooLarge }
        var bigEndian = UInt32(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt64(_ value: Int64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
