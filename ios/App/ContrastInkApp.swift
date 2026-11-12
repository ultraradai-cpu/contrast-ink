import SwiftUI
import UIKit

@main
struct ContrastInkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lecture = Lecture.shared
    @StateObject private var recorder = LectureRecorder()

    init() {
        // the app's own UI test: a sample deck, and a finger that draws (the simulator has no Apple Pencil)
        if ProcessInfo.processInfo.arguments.contains("-uitest") {
            var s = Lecture.shared.settings
            s.fingerDraws = true; s.tool = .pen; s.color = 0; s.width = 2; s.fadingInk = false
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
