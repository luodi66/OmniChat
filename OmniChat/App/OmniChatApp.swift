import SwiftUI
import SwiftData

@main
struct OmniChatApp: App {
    @StateObject private var engine = ChatEngine()
    @AppStorage("appearance") private var appearance: String = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(for: [ProviderConfig.self, Conversation.self, ChatMessage.self])
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
