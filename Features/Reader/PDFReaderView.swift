import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let comicId: String
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            }

            PDFKitView(url: APIClient.shared.pdfURL(comicId: comicId))
                .ignoresSafeArea()
                .opacity(isLoading ? 0 : 1)
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                    .padding(8)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isLoading = false
            }
        }
    }
}

// MARK: - PDFKit 桥接

struct PDFKitView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .black

        if let url {
            if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
                var request = URLRequest(url: url)
                request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data, let doc = PDFDocument(data: data) {
                        DispatchQueue.main.async {
                            pdfView.document = doc
                        }
                    }
                }.resume()
            } else {
                pdfView.document = PDFDocument(url: url)
            }
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
