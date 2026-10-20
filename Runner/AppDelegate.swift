import Contacts
import ContactsUI
import EventKit
import Flutter
import UIKit
import UserNotifications
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SnapCuePlatform") {
      let channel = FlutterMethodChannel(name: "snapcue/platform", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "calendarPermission":
          result(EventBridge.status())
        case "requestCalendarPermission":
          EventBridge.request { result($0) }
        case "listCalendars":
          result(EventBridge.calendars())
        case "createEvent":
          EventBridge.run(result) { try EventBridge.create(args) }
        case "updateEvent":
          EventBridge.run(result) { try EventBridge.update(args) }
        case "deleteEvent":
          EventBridge.run(result) { try EventBridge.delete(args["eventId"] as? String ?? "") }
        case "eventExists":
          result(EventBridge.store.event(withIdentifier: args["eventId"] as? String ?? "") != nil)
        case "insertContact":
          result(NewContact.present(
            name: args["name"] as? String ?? "",
            phone: args["phone"] as? String ?? "",
            email: args["email"] as? String ?? ""))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SnapCueOcr") {
      let channel = FlutterMethodChannel(name: "snapcue/ocr", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "recognize" else { return result(FlutterMethodNotImplemented) }
        guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
          return result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
        }
        TextRecognizer.recognize(path: path, completion: result)
      }
    }
  }
}

/// Adds, updates, and removes only the events the user chooses.
enum EventBridge {
  static let store = EKEventStore()

  static func status() -> String {
    let s = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      if s == .fullAccess { return "granted" }
      if s == .writeOnly { return "denied" }
    } else if s == .authorized {
      return "granted"
    }
    return s == .notDetermined ? "undetermined" : "denied"
  }

  static func request(_ done: @escaping (String) -> Void) {
    let finish: (Bool, Error?) -> Void = { granted, _ in DispatchQueue.main.async { done(granted ? "granted" : "denied") } }
    if #available(iOS 17.0, *) {
      store.requestFullAccessToEvents(completion: finish)
    } else {
      store.requestAccess(to: .event, completion: finish)
    }
  }

  static func calendars() -> [[String: Any]] {
    guard status() == "granted" else { return [] }
    let fallback = store.defaultCalendarForNewEvents?.calendarIdentifier
    return store.calendars(for: .event).filter { $0.allowsContentModifications }.map {
      ["id": $0.calendarIdentifier, "name": $0.title, "account": $0.source.title, "primary": $0.calendarIdentifier == fallback]
    }
  }

  static func run(_ result: @escaping FlutterResult, _ block: () throws -> Any) {
    guard status() == "granted" else { return result(FlutterError(code: "denied", message: "Calendar access is off", details: nil)) }
    do { result(try block()) } catch { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
  }

  private static func apply(_ e: EKEvent, _ a: [String: Any]) {
    e.title = a["title"] as? String ?? ""
    e.notes = a["notes"] as? String
    e.location = a["location"] as? String
    e.isAllDay = a["allDay"] as? Bool ?? false
    e.startDate = Date(timeIntervalSince1970: ((a["start"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    e.endDate = Date(timeIntervalSince1970: ((a["end"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    if let tz = a["timezone"] as? String { e.timeZone = TimeZone(identifier: tz) }
    e.alarms = nil
    if let minutes = (a["reminderMinutes"] as? NSNumber)?.intValue, minutes >= 0 {
      e.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
    }
  }

  static func create(_ a: [String: Any]) throws -> String {
    let e = EKEvent(eventStore: store)
    e.calendar = store.calendar(withIdentifier: a["calendarId"] as? String ?? "") ?? store.defaultCalendarForNewEvents
    apply(e, a)
    try store.save(e, span: .thisEvent, commit: true)
    return e.eventIdentifier ?? ""
  }

  static func update(_ a: [String: Any]) throws -> Bool {
    guard let e = store.event(withIdentifier: a["eventId"] as? String ?? "") else { return false }
    apply(e, a)
    try store.save(e, span: .thisEvent, commit: true)
    return true
  }

  static func delete(_ id: String) throws -> Bool {
    guard let e = store.event(withIdentifier: id) else { return false }
    try store.remove(e, span: .thisEvent, commit: true)
    return true
  }
}

/// Presents the system "new contact" screen, pre-filled. Nothing is saved
/// unless the user taps Done there.
final class NewContact: NSObject, CNContactViewControllerDelegate {
  static let shared = NewContact()

  static func present(name: String, phone: String, email: String) -> Bool {
    guard let top = topController() else { return false }
    let contact = CNMutableContact()
    let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
    contact.givenName = parts.first ?? ""
    if parts.count > 1 { contact.familyName = parts[1] }
    if !phone.isEmpty {
      contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
    }
    if !email.isEmpty {
      contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
    }
    let controller = CNContactViewController(forNewContact: contact)
    controller.contactStore = CNContactStore()
    controller.delegate = shared
    top.present(UINavigationController(rootViewController: controller), animated: true)
    return true
  }

  func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
    viewController.dismiss(animated: true)
  }

  static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

/// On-device text recognition with Apple Vision for the `snapcue/ocr` channel.
enum TextRecognizer {
  static func recognize(path: String, completion: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let finish: (Any?) -> Void = { value in DispatchQueue.main.async { completion(value) } }
      guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
        return finish(FlutterError(code: "unreadable", message: "Could not read the image", details: nil))
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let handler = VNImageRequestHandler(
        cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
      do {
        try handler.perform([request])
        // Line heights (relative to the image) let Dart spot the headline.
        let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
          guard let text = observation.topCandidates(1).first?.string else { return nil }
          return ["t": text, "h": Double(observation.boundingBox.height)]
        }
        finish(["text": lines.compactMap { $0["t"] as? String }.joined(separator: "\n"), "lines": lines])
      } catch {
        finish(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
      }
    }
  }
}

extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .upMirrored: self = .upMirrored
    case .down: self = .down
    case .downMirrored: self = .downMirrored
    case .left: self = .left
    case .leftMirrored: self = .leftMirrored
    case .right: self = .right
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
