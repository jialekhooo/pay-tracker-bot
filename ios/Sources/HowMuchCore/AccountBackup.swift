import Foundation

/// A portable ZIP containing the account document and the receipt JPEGs it references.
/// JPEGs are already compressed, so entries use ZIP's stored method. Nothing is extracted
/// to disk: only the exact document/receipt names are accepted on import.
public struct AccountBackup {
    public var data: TrackerData
    public var receipts: [UUID: Data]
    public static let maximumBytes = 110_000_000

    public init(data: TrackerData, receipts: [UUID: Data]) throws {
        try data.validate()
        let required = Set(data.claims.compactMap(\.receiptID) + (data.expenses ?? []).compactMap(\.receiptID))
        guard required == Set(receipts.keys), receipts.values.allSatisfy({ !$0.isEmpty && $0.count <= 750_000 }),
              receipts.count <= 2000, receipts.values.reduce(0, { $0 + $1.count }) <= 100_000_000 else {
            throw TrackerError.invalid("The backup must contain every attached receipt photo, up to 100 MB in total.")
        }
        self.data = data; self.receipts = receipts
    }

    /// A claim can point at a photo the account no longer has, for example after an earlier
    /// JSON archive (which holds no photos) was restored into a new account.
    public static func removingReceipts(_ missing: Set<UUID>, from data: TrackerData) -> TrackerData {
        var trimmed = data
        for index in trimmed.claims.indices {
            if let id = trimmed.claims[index].receiptID, missing.contains(id) { trimmed.claims[index].receiptID = nil }
        }
        if var expenses = trimmed.expenses {
            for index in expenses.indices {
                if let id = expenses[index].receiptID, missing.contains(id) { expenses[index].receiptID = nil }
            }
            trimmed.expenses = expenses
        }
        return trimmed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let document = try encoder.encode(data)
        guard document.count <= 10_000_000 else { throw TrackerError.invalid("The account document is larger than 10 MB.") }
        let entries = [("tracker.json", document)] + receipts.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { ("receipts/" + $0.key.uuidString.lowercased() + ".jpg", $0.value) }
        guard entries.count < 65535 else { throw TrackerError.invalid("Too many receipts in this backup.") }
        var zip = Data(), directory = Data()
        for (name, bytes) in entries {
            let path = Data(name.utf8), crc = Self.crc32(bytes), offset = zip.count
            zip.u32(0x04034b50); zip.u16(20); zip.u16(0); zip.u16(0); zip.u16(0); zip.u16(33)
            zip.u32(crc); zip.u32(UInt32(bytes.count)); zip.u32(UInt32(bytes.count)); zip.u16(path.count); zip.u16(0)
            zip.append(path); zip.append(bytes)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(0); directory.u16(0)
            directory.u16(0); directory.u16(33); directory.u32(crc); directory.u32(UInt32(bytes.count)); directory.u32(UInt32(bytes.count))
            directory.u16(path.count); directory.u16(0); directory.u16(0); directory.u16(0); directory.u16(0); directory.u32(0); directory.u32(UInt32(offset))
            directory.append(path)
        }
        let start = zip.count
        zip.append(directory); zip.u32(0x06054b50); zip.u16(0); zip.u16(0); zip.u16(entries.count); zip.u16(entries.count)
        zip.u32(UInt32(directory.count)); zip.u32(UInt32(start)); zip.u16(0)
        guard zip.count <= Self.maximumBytes else { throw TrackerError.invalid("This backup is too large.") }
        return zip
    }

    /// Receipt IDs belong to the destination account after its uploads complete.
    /// Require the complete map before changing any claim references.
    public func restoringReceipts(_ replacements: [UUID: UUID]) throws -> TrackerData {
        guard Set(replacements.keys) == Set(receipts.keys) else {
            throw TrackerError.invalid("Not all receipt photos have been restored. Your current records have been kept.")
        }
        var restored = data
        for index in restored.claims.indices {
            if let old = restored.claims[index].receiptID { restored.claims[index].receiptID = replacements[old] }
        }
        if var expenses = restored.expenses {
            for index in expenses.indices {
                if let old = expenses[index].receiptID { expenses[index].receiptID = replacements[old] }
            }
            restored.expenses = expenses
        }
        try restored.validate()
        return restored
    }

    public static func decode(_ zip: Data) throws -> AccountBackup {
        guard zip.count <= maximumBytes, zip.count >= 22 else { throw invalidZIP }
        // Check the directory boundary before reading any entry lengths.
        let footer = zip.count - 22
        guard try zip.r32(footer) == 0x06054b50, try zip.r16(footer + 4) == 0,
              try zip.r16(footer + 6) == 0, try zip.r16(footer + 20) == 0,
              try zip.r16(footer + 8) == zip.r16(footer + 10) else { throw invalidZIP }
        let count = try zip.r16(footer + 8), directoryStart = Int(try zip.r32(footer + 16))
        guard (1...2001).contains(count), directoryStart <= footer, Int(try zip.r32(footer + 12)) == footer - directoryStart else { throw invalidZIP }
        var cursor = directoryStart, files: [String: Data] = [:], localEnd = 0
        for _ in 0..<count {
            guard try zip.r32(cursor) == 0x02014b50, try zip.r16(cursor + 8) == 0,
                  try zip.r16(cursor + 10) == 0, try zip.r16(cursor + 34) == 0 else { throw invalidZIP }
            let size = Int(try zip.r32(cursor + 20)), nameCount = try zip.r16(cursor + 28)
            let nameEnd = cursor + 46 + nameCount
            let next = nameEnd + (try zip.r16(cursor + 30)) + (try zip.r16(cursor + 32))
            guard next <= footer, size <= 10_000_000, size == Int(try zip.r32(cursor + 24)),
                  let name = String(data: zip.subdata(in: cursor + 46..<nameEnd), encoding: .utf8), files[name] == nil else { throw invalidZIP }
            let local = Int(try zip.r32(cursor + 42))
            guard local == localEnd, try zip.r32(local) == 0x04034b50,
                  try zip.r16(local + 6) == 0, try zip.r16(local + 8) == 0,
                  try zip.r32(local + 14) == zip.r32(cursor + 16),
                  try zip.r32(local + 18) == UInt32(size), try zip.r32(local + 22) == UInt32(size),
                  try zip.r16(local + 26) == nameCount else { throw invalidZIP }
            let begin = local + 30 + nameCount + (try zip.r16(local + 28))
            guard begin <= directoryStart, size <= directoryStart - begin,
                  zip.subdata(in: local + 30..<local + 30 + nameCount) == Data(name.utf8) else { throw invalidZIP }
            let bytes = zip.subdata(in: begin..<begin + size)
            guard crc32(bytes) == (try zip.r32(cursor + 16)) else { throw invalidZIP }
            files[name] = bytes; localEnd = begin + size; cursor = next
        }
        guard cursor == footer, localEnd == directoryStart, let document = files.removeValue(forKey: "tracker.json") else { throw invalidZIP }
        let data = try JSONDecoder().decode(TrackerData.self, from: document)
        var receipts: [UUID: Data] = [:]
        for (name, bytes) in files {
            guard name.hasPrefix("receipts/"), name.hasSuffix(".jpg"),
                  let id = UUID(uuidString: String(name.dropFirst(9).dropLast(4))),
                  name == "receipts/" + id.uuidString.lowercased() + ".jpg", receipts[id] == nil else { throw invalidZIP }
            receipts[id] = bytes
        }
        return try AccountBackup(data: data, receipts: receipts)
    }

    private static var invalidZIP: TrackerError { .invalid("This backup is damaged or unsupported. Choose the original HowMuch ZIP backup, or an earlier JSON archive.") }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }
    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func u16(_ value: Int) { append(UInt8(value & 255)); append(UInt8((value >> 8) & 255)) }
    mutating func u32(_ value: UInt32) { for shift in stride(from: 0, through: 24, by: 8) { append(UInt8((value >> shift) & 255)) } }
    func r16(_ index: Int) throws -> Int {
        guard index >= 0, index <= count - 2 else { throw TrackerError.invalid("Incomplete backup file.") }
        return Int(self[index]) | Int(self[index + 1]) << 8
    }
    func r32(_ index: Int) throws -> UInt32 {
        guard index >= 0, index <= count - 4 else { throw TrackerError.invalid("Incomplete backup file.") }
        return UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
}
