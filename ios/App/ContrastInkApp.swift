import SwiftUI
import UIKit

@main
struct ContrastInkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lecture = Lecture.shared
    @StateObject private var recorder = LectureRecorder()

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        // UI tests that start from no saved marks, or an empty library
        if args.contains("-resetMarks") { SavedMarks.removeAll() }
        if args.contains("-resetLibrary") { try? FileManager.default.removeItem(at: Library.folder) }
        #endif
        // the app's own UI test: a sample deck, and a finger that draws (the simulator has no Apple Pencil)
        if args.contains("-uitest") {
            var s = Lecture.shared.settings
            // -pencilOnly: the iPad's default, a finger swipes slides and doesn't draw
            s.fingerDraws = !args.contains("-pencilOnly"); s.tool = .pen; s.color = 0; s.width = 2; s.fadingInk = false
            Lecture.shared.settings = s
            Lecture.shared.open(Library.sampleDeck())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lecture)
                .environmentObject(recorder)
                .preferredColorScheme(.dark)
        }
    }
}

/// The iPad's own screen leaving (Home, another app, the lock button). With a projector connected the app as a
/// whole can stay in the foreground (the projector's scene still shows), so the main scene's own notice is listened
/// to as well as the app's; the handler may be called twice for one leaving.
enum MainScreen {
    static func onLeave(_ handler: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
        center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { note in
            guard let scene = note.object as? UIScene, scene.session.role == .windowApplication else { return }
            Task { @MainActor in handler() }
        }
    }
}

/// A projector or TV (HDMI adapter or AirPlay) gets its own clean picture: the slide and the ink, no toolbar.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let c = UISceneConfiguration(name: "Projector", sessionRole: session.role)
            c.delegateClass = ProjectorSceneDelegate.self
            return c
        }
        return UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}

final class ProjectorSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = UIHostingController(rootView: ProjectorView().environmentObject(Lecture.shared))
        w.isHidden = false
        window = w
    }
}
