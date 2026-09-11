import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Halo").font(.title).bold()
            Text("A quiet activity surface for your Mac")
                .foregroundColor(.secondary)
            Divider()
            Text("Click the dashed-circle icon in the menu bar to add a test activity.")
                .font(.callout)
            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 200)
    }
}
