import EventKit
import Foundation

enum MikuToolError: LocalizedError {
    case unsupportedTool(String)
    case missingParameter(String)
    case invalidDate(String)
    case permissionDenied(String)
    case noDefaultCalendar(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            return "Unsupported tool: \(name)"
        case .missingParameter(let name):
            return "Missing tool parameter: \(name)"
        case .invalidDate(let value):
            return "Could not read date: \(value)"
        case .permissionDenied(let scope):
            return "Permission denied for \(scope)."
        case .noDefaultCalendar(let scope):
            return "No default \(scope) calendar is available."
        case .saveFailed(let message):
            return "Could not save: \(message)"
        }
    }
}

final class MikuToolExecutor: @unchecked Sendable {
    private let eventStore = EKEventStore()

    func execute(
        _ tool: AIResultTool,
        completion: @escaping @MainActor (Result<String, MikuToolError>) -> Void
    ) {
        switch tool.name {
        case "calendar.create_event":
            createCalendarEvent(tool, completion: completion)
        case "reminders.create_reminder":
            createReminder(tool, completion: completion)
        default:
            Task { @MainActor in completion(.failure(.unsupportedTool(tool.name))) }
        }
    }

    private func createCalendarEvent(
        _ tool: AIResultTool,
        completion: @escaping @MainActor (Result<String, MikuToolError>) -> Void
    ) {
        requestAccess(to: .event, scopeName: "Calendar") { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Task { @MainActor in completion(.failure(.permissionDenied("Calendar"))) }
                return
            }

            do {
                guard let calendar = self.eventStore.defaultCalendarForNewEvents else {
                    throw MikuToolError.noDefaultCalendar("Calendar")
                }

                let title = try self.requiredParam("title", in: tool)
                let start = try self.dateParam("start", in: tool)
                let end = try self.optionalDateParam("end", in: tool)
                    ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)
                    ?? start.addingTimeInterval(3600)

                let event = EKEvent(eventStore: self.eventStore)
                event.calendar = calendar
                event.title = title
                event.startDate = start
                event.endDate = max(end, start.addingTimeInterval(900))
                event.notes = tool.params["notes"]

                try self.eventStore.save(event, span: .thisEvent, commit: true)
                Task { @MainActor in completion(.success("Added to Calendar")) }
            } catch let error as MikuToolError {
                Task { @MainActor in completion(.failure(error)) }
            } catch {
                Task { @MainActor in completion(.failure(.saveFailed(error.localizedDescription))) }
            }
        }
    }

    private func createReminder(
        _ tool: AIResultTool,
        completion: @escaping @MainActor (Result<String, MikuToolError>) -> Void
    ) {
        requestAccess(to: .reminder, scopeName: "Reminders") { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Task { @MainActor in completion(.failure(.permissionDenied("Reminders"))) }
                return
            }

            do {
                guard let calendar = self.eventStore.defaultCalendarForNewReminders() else {
                    throw MikuToolError.noDefaultCalendar("Reminders")
                }

                let title = try self.requiredParam("title", in: tool)
                let reminder = EKReminder(eventStore: self.eventStore)
                reminder.calendar = calendar
                reminder.title = title
                reminder.notes = tool.params["notes"]

                if let due = try self.optionalDateParam("due", in: tool) {
                    reminder.dueDateComponents = Calendar.current.dateComponents(
                        [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                        from: due
                    )
                }

                try self.eventStore.save(reminder, commit: true)
                Task { @MainActor in completion(.success("Added Reminder")) }
            } catch let error as MikuToolError {
                Task { @MainActor in completion(.failure(error)) }
            } catch {
                Task { @MainActor in completion(.failure(.saveFailed(error.localizedDescription))) }
            }
        }
    }

    private func requestAccess(
        to entityType: EKEntityType,
        scopeName: String,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let status = EKEventStore.authorizationStatus(for: entityType)
        switch status {
        case .fullAccess, .writeOnly:
            completion(true)
        case .authorized:
            completion(true)
        case .notDetermined:
            eventStore.requestAccess(to: entityType) { granted, _ in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func requiredParam(_ key: String, in tool: AIResultTool) throws -> String {
        guard let value = tool.params[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw MikuToolError.missingParameter(key)
        }
        return value
    }

    private func dateParam(_ key: String, in tool: AIResultTool) throws -> Date {
        let value = try requiredParam(key, in: tool)
        guard let date = parseDate(value) else {
            throw MikuToolError.invalidDate(value)
        }
        return date
    }

    private func optionalDateParam(_ key: String, in tool: AIResultTool) throws -> Date? {
        guard let value = tool.params[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        guard let date = parseDate(value) else {
            throw MikuToolError.invalidDate(value)
        }
        return date
    }

    private func parseDate(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let formats = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}
