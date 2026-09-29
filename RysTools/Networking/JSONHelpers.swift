import Foundation

// The web app's saved Drive JSON is loosely/dynamically shaped (plain JS objects), so
// rather than writing strict Codable structs for every nested shape (scenarios,
// valuesByScenario, lockedAmounts, customRows, ...), this reads it the same loose way
// via [String: Any] — much less code for a proof-of-concept reading real, already-live
// data than modeling the whole schema up front.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }

    func double(_ key: String) -> Double {
        if let d = self[key] as? Double { return d }
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) ?? 0 }
        return 0
    }

    func object(_ key: String) -> JSONObject { self[key] as? JSONObject ?? [:] }

    func array(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
}

enum JSONHelpers {
    static func parse(_ data: Data) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject ?? [:]
    }

    static func serialize(_ object: JSONObject) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
