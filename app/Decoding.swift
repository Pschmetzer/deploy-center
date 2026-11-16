// Deploy Center — Tolerant decoding helpers shared by the models: a missing or odd field is
// "unknown", never a failed sheet.

import Foundation

/// One element of a list that may not decode; the rest of the list still does.
struct Lossy<T: Decodable>: Decodable {
    let value: T?; let error: String?
    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder); error = nil } catch { value = nil; self.error = "\(error)" }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// An element that could not be read becomes nil and is dropped, instead of failing the whole list.
struct Skippable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct Lax {
    let c: KeyedDecodingContainer<AnyKey>?
    init(_ d: Decoder) { c = try? d.container(keyedBy: AnyKey.self) }
    init(container: KeyedDecodingContainer<AnyKey>?) { c = container }

    func num(_ k: String) -> Double? {
        guard let c else { return nil }
        if let d = try? c.decodeIfPresent(Double.self, forKey: AnyKey(k)) { return d }
        // A number sent as text still counts.
        if let s = try? c.decodeIfPresent(String.self, forKey: AnyKey(k)) { return Double(s) }
        return nil
    }
    func str(_ k: String) -> String? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(String.self, forKey: AnyKey(k))
    }
    func bool(_ k: String) -> Bool? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(Bool.self, forKey: AnyKey(k))
    }
    func obj<T: Decodable>(_ k: String) -> T? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(T.self, forKey: AnyKey(k))
    }
    func list<T: Decodable>(_ k: String) -> [T] {
        guard let c, let raw = try? c.decodeIfPresent([Skippable<T>].self, forKey: AnyKey(k)) else { return [] }
        return raw.compactMap { $0.value }
    }
    func sub(_ k: String) -> Lax {
        guard let c else { return Lax(container: nil) }
        return Lax(container: try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(k)))
    }
}
