import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
