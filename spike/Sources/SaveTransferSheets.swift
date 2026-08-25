import SwiftUI
import UIKit

/// `UIActivityViewController` in SwiftUI clothing.
///
/// The export writes a real file into Application Support and hands its URL here.
/// Nothing is copied anywhere the reader can see until she picks a destination, which is
/// why the confirmation says "You'll choose where to put the file next".
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
