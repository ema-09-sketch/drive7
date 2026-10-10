import SwiftUI

struct ContentView: View {
    private let serverURL = URL(string: "http://100.69.14.53")!

    var body: some View {
        DriveWebView(url: serverURL)
            .ignoresSafeArea()
    }
}
