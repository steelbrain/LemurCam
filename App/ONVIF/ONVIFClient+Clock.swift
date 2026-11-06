import Foundation
import XMLKit

// Internal (not private) so `@testable` unit tests can exercise the parsing and
// offset arithmetic directly with canned responses.
internal extension ONVIFClient {
    /// The device's UTC time from a GetSystemDateAndTime response, or nil when the
    /// response has no complete, valid `UTCDateTime` (some devices report only their
    /// local time, which cannot be converted without guessing the time zone).
    static func parseSystemDateAndTime(_ data: Data) -> Date? {
        guard let root = try? ONVIFXML.parse(data) else { return nil }
        var utc: XMLKit.XMLElement?
        root.findElements(named: "UTCDateTime") { element in
            if utc == nil { utc = element }
        }
        guard let date = utc?["Date"], let time = utc?["Time"],
              let year = number(in: date, "Year"), (1970...9999).contains(year),
              let month = number(in: date, "Month"), let day = number(in: date, "Day"),
              let hour = number(in: time, "Hour"), let minute = number(in: time, "Minute"),
              let second = number(in: time, "Second") else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        // A leap second (60) is not a valid component; one second of error is harmless.
        let components = DateComponents(
            calendar: calendar, timeZone: .gmt, year: year, month: month, day: day,
            hour: hour, minute: minute, second: min(second, 59)
        )
        guard components.isValidDate else { return nil }
        return components.date
    }

    /// Offset from the Mac's clock to the device's, assuming the device read its
    /// clock halfway through the round trip.
    static func clockOffset(deviceTime: Date, requestSent: Date, responseReceived: Date) -> TimeInterval {
        let midpoint = requestSent.addingTimeInterval(responseReceived.timeIntervalSince(requestSent) / 2)
        return deviceTime.timeIntervalSince(midpoint)
    }

    private static func number(in element: XMLKit.XMLElement, _ name: String) -> Int? {
        element[name]?.getText().flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
