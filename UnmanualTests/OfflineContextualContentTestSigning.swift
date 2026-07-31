import CoreFoundation
import Foundation
@testable import Unmanual

enum OfflineContextualContentTestSigning {
    static func resign(
        _ data: Data,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var root = try requireDictionary(
            JSONSerialization.jsonObject(with: data)
        )
        try mutate(&root)

        var cards = try requireArrayOfDictionaries(root["cards"])
        for index in cards.indices {
            cards[index].removeValue(forKey: "cardDigest")
            cards[index]["cardDigest"] =
                OfflineContextualContentCanonicalJSON.digest(
                    try jsonValue(cards[index])
                )
        }
        root["cards"] = cards

        var unsignedRoot = root
        var unsignedManifest = try requireDictionary(
            unsignedRoot["manifest"]
        )
        unsignedManifest.removeValue(forKey: "contentDigest")
        unsignedRoot["manifest"] = unsignedManifest

        var manifest = try requireDictionary(root["manifest"])
        manifest["contentDigest"] =
            OfflineContextualContentCanonicalJSON.digest(
                try jsonValue(unsignedRoot)
            )
        root["manifest"] = manifest
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
    }

    static func jsonValue(
        _ value: Any
    ) throws -> OfflineContextualJSONValue {
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(try array.map(jsonValue))
        }
        if let object = value as? [String: Any] {
            return .object(
                try object.mapValues(jsonValue)
            )
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .integer(number.intValue)
        }
        throw FixtureError.invalidFoundationJSON
    }

    static func requireDictionary(
        _ value: Any?
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FixtureError.invalidFoundationJSON
        }
        return object
    }

    static func requireArrayOfDictionaries(
        _ value: Any?
    ) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw FixtureError.invalidFoundationJSON
        }
        return array
    }

    enum FixtureError: Error {
        case invalidFoundationJSON
    }
}
