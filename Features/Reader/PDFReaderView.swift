import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let comicId: String
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var loadError = false
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PDFKitView(
                url: APIClient.shared.pdfURL(comicId: comicId),
                isLoading: $isLoading,
                loadError: $loadError
            )
            .id(reloadID)
            .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            }

            if loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                    Text("PDF 加载失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("重试") {
                        loadError = false
                        reloadID = UUID() // 强制重建 PDFKitView
                    }
                    .buttonStyle(.bordered)
                }
            }
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
    }
}

// MARK: - PDFKit 桥接

struct PDFKitView: UIViewRepresentable {
    let url: URL?
    @Binding var isLoading: Bool
    @Binding var loadError: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var dataTask: URLSessionDataTask?
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .black

        if let url {
            isLoading = true
            loadError = false
            let request = APIClient.shared.authenticatedRequest(url: url, timeout: 60)
            let task = URLSession.shared.dataTask(with: request) { data, _, error in
                DispatchQueue.main.async {
                    isLoading = false
                    if let data, let doc = PDFDocument(data: data) {
                        pdfView.document = doc
                    } else {
                        loadError = true
                    }
                }
            }
            context.coordinator.dataTask = task
            task.resume()
        }

        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
