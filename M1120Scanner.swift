import AppKit
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Vision
import Darwin

// M1120 Scanner v1.3.1: native AppKit, multi-page PDF, optional local Vision OCR.
// Uses the previously tested patched SANE binary. No SwiftUI, no network calls.

enum ScanMode: String {
    case gray = "Gray"
    case color = "Color"
}

enum ScanPaper: Int, CaseIterable {
    case a4, letter, a5, small, fullBed

    var title: String {
        switch self {
        case .a4: return "A4 (210 × 297 mm)"
        case .letter: return "Letter (216 × 279 mm)"
        case .a5: return "A5 (148 × 210 mm)"
        case .small: return "Small (100 × 150 mm)"
        case .fullBed: return "Full glass (216 × 297 mm)"
        }
    }
    var widthMM: Int {
        switch self {
        case .a4: return 210
        case .letter, .fullBed: return 216
        case .a5: return 148
        case .small: return 100
        }
    }
    var heightMM: Int {
        switch self {
        case .a4, .fullBed: return 297
        case .letter: return 279
        case .a5: return 210
        case .small: return 150
        }
    }
    var pageRect: CGRect {
        let pointsPerMM: CGFloat = 72.0 / 25.4
        return CGRect(x: 0, y: 0,
                      width: CGFloat(widthMM) * pointsPerMM,
                      height: CGFloat(heightMM) * pointsPerMM)
    }
}

enum ScanFormat: Int {
    case pdf, png, jpeg
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

struct ScanSettings {
    let mode: ScanMode
    let dpi: Int
    let paper: ScanPaper
    let format: ScanFormat
    let destination: URL
    let searchablePDF: Bool
}

struct StagedPage {
    let png: URL
    let paper: ScanPaper
}

enum ScanFailure: LocalizedError {
    case missingScanner
    case missingImageMagick
    case invalidDestination
    case incomplete(String)
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .missingScanner:
            return "Patched scanimage is missing from ~/m1120-sane-test/install/bin. Keep the patched SANE installation."
        case .missingImageMagick:
            return "ImageMagick is missing. Install it with: brew install imagemagick"
        case .invalidDestination:
            return "The destination folder is unavailable. Select another folder."
        case .incomplete(let details), .failed(let details):
            return details
        case .cancelled:
            return "Operation cancelled. If the printer remains on 'Scanning to PC', power-cycle it. Already scanned pages are preserved."
        }
    }
}

final class ScannerEngine {
    // Public state is read and written on the main thread, except captured immutable snapshots.
    private(set) var isBusy = false
    private(set) var status = "Ready to scan"
    private(set) var errorText: String?
    private(set) var lastFile: URL?
    private(set) var pages: [StagedPage] = []
    var onUpdate: (() -> Void)?

    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancellationRequested = false
    private let scanBinary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("m1120-sane-test/install/bin/scanimage").path

    private func resetCancellation() {
        lock.lock()
        cancellationRequested = false
        lock.unlock()
    }
    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
    private func report(_ message: String) {
        DispatchQueue.main.async {
            self.status = message
            self.onUpdate?()
        }
    }
    private func begin(_ status: String) -> Bool {
        assert(Thread.isMainThread)
        guard !isBusy else { return false }
        resetCancellation()
        isBusy = true
        errorText = nil
        self.status = status
        onUpdate?()
        return true
    }
    private func end(error: Error?) {
        assert(Thread.isMainThread)
        isBusy = false
        if let error = error {
            errorText = error.localizedDescription
            status = "Operation not completed"
        }
        onUpdate?()
    }
    private func magickPath() -> String? {
        return ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    func cancel() {
        assert(Thread.isMainThread)
        guard isBusy else { return }
        lock.lock()
        cancellationRequested = true
        let running = activeProcess
        lock.unlock()
        if let running = running, running.isRunning {
            // Only terminate the child process launched by this app.
            _ = Darwin.kill(running.processIdentifier, SIGKILL)
        }
        status = "Cancelling…"
        onUpdate?()
    }
    private func validateDestination(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ScanFailure.invalidDestination }
    }
    private func run(_ executable: String, args: [String], log: URL) throws {
        if isCancelled() { throw ScanFailure.cancelled }
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        lock.lock()
        activeProcess = process
        let wasCancelled = cancellationRequested
        lock.unlock()
        if wasCancelled {
            lock.lock(); activeProcess = nil; lock.unlock()
            throw ScanFailure.cancelled
        }
        do { try process.run() }
        catch {
            lock.lock(); activeProcess = nil; lock.unlock()
            throw error
        }
        if isCancelled() && process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        lock.lock()
        activeProcess = nil
        let cancelled = cancellationRequested
        lock.unlock()
        if cancelled { throw ScanFailure.cancelled }
        if process.terminationStatus != 0 {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let excerpt = String(detail.suffix(1400)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScanFailure.failed(excerpt.isEmpty ?
                "The scanner or converter exited with status \(process.terminationStatus)." :
                "The scanner or converter failed:\n\n\(excerpt)")
        }
    }
    private func verify(_ file: URL) throws {
        let info = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (info[.size] as? NSNumber)?.int64Value ?? 0
        if size < 100 { throw ScanFailure.incomplete("The device produced an empty or incomplete scan file.") }
    }
    private func freeOutput(in folder: URL, format: ScanFormat) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "Scan_\(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(format.fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)_\(number).\(format.fileExtension)")
            number += 1
        }
        return url
    }
    private func deletePage(_ page: StagedPage) {
        try? FileManager.default.removeItem(at: page.png.deletingLastPathComponent())
    }

    // Capture one sheet. Each successfully scanned page is isolated in its own temporary folder.
    private func capture(_ settings: ScanSettings) throws -> StagedPage {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: scanBinary) else { throw ScanFailure.missingScanner }
        guard let magick = magickPath() else { throw ScanFailure.missingImageMagick }
        let folder = fm.temporaryDirectory.appendingPathComponent("m1120-sheet-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let raw = folder.appendingPathComponent("page.pnm")
            let png = folder.appendingPathComponent("page.png")
            let log = folder.appendingPathComponent("scan.log")
            report("Scanning sheet at \(settings.dpi) DPI…")
            try run(scanBinary, args: [
                "--mode", settings.mode.rawValue,
                "--resolution", String(settings.dpi),
                "-x", String(settings.paper.widthMM),
                "-y", String(settings.paper.heightMM),
                "--format=pnm", "--output-file=\(raw.path)"
            ], log: log)
            try verify(raw)
            if isCancelled() { throw ScanFailure.cancelled }
            report("Preparing scanned image…")
            try run(magick, args: [raw.path, "-units", "PixelsPerInch", "-density", String(settings.dpi), png.path], log: log)
            try verify(png)
            try? fm.removeItem(at: raw)
            if isCancelled() { throw ScanFailure.cancelled }
            return StagedPage(png: png, paper: settings.paper)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    // Uses macOS Vision OCR; hidden text is embedded in the PDF over the original image.
    // OCR runs entirely on-device, and image appearance is preserved.
    private func addInvisibleText(_ image: CGImage, in rect: CGRect, to context: CGContext) throws -> Int {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var count = 0
        for observation in request.results ?? [] {
            if isCancelled() { throw ScanFailure.cancelled }
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let box = observation.boundingBox // Normalized coordinates, origin at bottom left.
            let width = box.width * rect.width
            let height = box.height * rect.height
            if width < 1 || height < 1 { continue }
            let fontSize = max(4.0, min(60.0, height * 0.82))
            let font = NSFont.systemFont(ofSize: fontSize)
            let str = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(str)
            let naturalWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if naturalWidth <= 0 { continue }
            context.saveGState()
            context.setTextDrawingMode(.invisible)
            context.textMatrix = CGAffineTransform(scaleX: width / naturalWidth, y: 1)
            context.textPosition = CGPoint(
                x: rect.minX + box.minX * rect.width,
                y: rect.minY + box.minY * rect.height + max(0, (height - fontSize) / 2)
            )
            CTLineDraw(line, context)
            context.restoreGState()
            count += 1
        }
        return count
    }

    private func pdfDocument(from sheets: [StagedPage], output: URL, ocr: Bool) throws {
        guard let first = sheets.first else { throw ScanFailure.incomplete("No scanned pages to save.") }
        var mediaBox = first.paper.pageRect
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw ScanFailure.failed("macOS could not create the PDF document.")
        }
        defer { context.closePDF() }
        for (index, sheet) in sheets.enumerated() {
            if isCancelled() { throw ScanFailure.cancelled }
            report(ocr ? "Recognizing text on page \(index + 1) of \(sheets.count)…" :
                "Adding page \(index + 1) of \(sheets.count)…")
            guard let source = CGImageSourceCreateWithURL(sheet.png as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ScanFailure.incomplete("Could not decode page \(index + 1). Your scanned pages have been retained.")
            }
            // A document uses one paper size, locked after its first page.
            let pageRect = first.paper.pageRect
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(pageRect)
            context.interpolationQuality = .high
            context.draw(image, in: pageRect)
            if ocr { _ = try addInvisibleText(image, in: pageRect, to: context) }
            context.endPDFPage()
        }
    }

    // Single-page scans still save immediately, as they did in version 1.2.
    func scan(_ settings: ScanSettings, addToBatch: Bool) {
        assert(Thread.isMainThread)
        guard begin(addToBatch ? "Scanning next page…" : "Scanning document…") else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                if !addToBatch { try validateDestination(settings.destination) }
                let page = try capture(settings)
                if addToBatch {
                    DispatchQueue.main.async {
                        self.pages.append(page)
                        self.status = "\(self.pages.count) page(s) scanned. Place the next sheet, or save your PDF."
                        self.end(error: nil)
                    }
                } else {
                    do {
                        let fm = FileManager.default
                        let destination = freeOutput(in: settings.destination, format: settings.format)
                        switch settings.format {
                        case .png:
                            try fm.moveItem(at: page.png, to: destination)
                        case .jpeg:
                            guard let magick = magickPath() else { throw ScanFailure.missingImageMagick }
                            let jpeg = page.png.deletingLastPathComponent().appendingPathComponent("out.jpg")
                            let log = page.png.deletingLastPathComponent().appendingPathComponent("convert.log")
                            try run(magick, args: [page.png.path, "-quality", "92", jpeg.path], log: log)
                            try verify(jpeg)
                            if isCancelled() { throw ScanFailure.cancelled }
                            try fm.moveItem(at: jpeg, to: destination)
                        case .pdf:
                            let pdf = page.png.deletingLastPathComponent().appendingPathComponent("document.pdf")
                            try pdfDocument(from: [page], output: pdf, ocr: settings.searchablePDF)
                            try verify(pdf)
                            if isCancelled() { throw ScanFailure.cancelled }
                            try fm.moveItem(at: pdf, to: destination)
                        }
                        deletePage(page)
                        DispatchQueue.main.async {
                            self.lastFile = destination
                            self.status = "Saved: \(destination.lastPathComponent)"
                            self.end(error: nil)
                        }
                    } catch {
                        deletePage(page)
                        throw error
                    }
                }
            } catch {
                DispatchQueue.main.async { self.end(error: error) }
            }
        }
    }

    func saveBatch(to destinationFolder: URL, searchablePDF: Bool) {
        assert(Thread.isMainThread)
        guard !pages.isEmpty, begin("Creating multi-page PDF…") else { return }
        let snapshot = pages
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let stagedPDF = FileManager.default.temporaryDirectory.appendingPathComponent("m1120-output-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: stagedPDF) }
            do {
                try validateDestination(destinationFolder)
                try pdfDocument(from: snapshot, output: stagedPDF, ocr: searchablePDF)
                try verify(stagedPDF)
                if isCancelled() { throw ScanFailure.cancelled }
                let output = freeOutput(in: destinationFolder, format: .pdf)
                try FileManager.default.moveItem(at: stagedPDF, to: output)
                DispatchQueue.main.async {
                    self.pages.removeAll()
                    snapshot.forEach { self.deletePage($0) }
                    self.lastFile = output
                    self.status = "Saved \(snapshot.count)-page PDF: \(output.lastPathComponent)"
                    self.end(error: nil)
                }
            } catch {
                // Preserve all scanned pages for another Save PDF attempt.
                DispatchQueue.main.async { self.end(error: error) }
            }
        }
    }

    func removeLastPage() {
        assert(Thread.isMainThread)
        guard !isBusy, let last = pages.popLast() else { return }
        deletePage(last)
        status = pages.isEmpty ? "Ready to scan" : "\(pages.count) page(s) remaining"
        errorText = nil
        onUpdate?()
    }
    func discardBatch() {
        assert(Thread.isMainThread)
        guard !isBusy else { return }
        pages.forEach { deletePage($0) }
        pages.removeAll()
        status = "Ready to scan"
        errorText = nil
        onUpdate?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let engine = ScannerEngine()
    private var selectedFolder = UserDefaults.standard.string(forKey: "m1120.saveFolder") ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    private var previousSingleFormat = 0

    private let modeChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dpiChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let paperChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let multipageCheck = NSButton(checkboxWithTitle: "Combine multiple sheets into one PDF", target: nil, action: nil)
    private let ocrCheck = NSButton(checkboxWithTitle: "Make PDF searchable (offline OCR)", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private let pagesLabel = NSTextField(labelWithString: "0 pages in document")
    private let statusLabel = NSTextField(labelWithString: "Ready to scan")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let scanButton = NSButton(title: "Scan document", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save PDF", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove last page", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard pages", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel current operation", target: nil, action: nil)
    private let folderButton = NSButton(title: "Choose folder…", target: nil, action: nil)
    private let openButton = NSButton(title: "Open saved file", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        engine.onUpdate = { [weak self] in self?.refresh() }
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return confirmClose() ? .terminateNow : .terminateCancel
    }
    private func confirmClose() -> Bool {
        if engine.isBusy {
            let alert = NSAlert()
            alert.messageText = "A scan or PDF save is in progress"
            alert.informativeText = "Cancel the current operation before closing the app."
            alert.addButton(withTitle: "Keep app open")
            alert.runModal()
            return false
        }
        if !engine.pages.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard \(engine.pages.count) unsaved pages?"
            alert.informativeText = "Pages in a multi-page document have not yet been saved as a PDF."
            alert.addButton(withTitle: "Keep scanning")
            alert.addButton(withTitle: "Discard pages and quit")
            if alert.runModal() != .alertSecondButtonReturn { return false }
            engine.discardBatch()
        }
        return true
    }
    private func setupMenu() {
        let bar = NSMenu()
        let mainItem = NSMenuItem()
        bar.addItem(mainItem)
        let app = NSMenu()
        app.addItem(withTitle: "Quit M1120 Scanner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainItem.submenu = app
        NSApp.mainMenu = bar
    }
    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        return result
    }
    private func divider() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
    private func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 770),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "M1120 Scanner"
        window.center()
        window.delegate = self
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root

        let heading = label("M1120 Scanner", size: 25, bold: true)
        let subheading = label("HP LaserJet M1120  ·  Office document scanning", size: 12)
        subheading.textColor = .secondaryLabelColor
        let headingStack = NSStackView(views: [heading, subheading])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 3

        modeChoice.addItems(withTitles: ["Grayscale", "Colour"])
        dpiChoice.addItems(withTitles: ["150 DPI — draft", "200 DPI — text", "300 DPI — recommended", "600 DPI — fine detail"])
        dpiChoice.selectItem(at: 2)
        paperChoice.addItems(withTitles: ScanPaper.allCases.map { $0.title })
        formatChoice.addItems(withTitles: ["PDF — document", "PNG — image", "JPEG — image"])
        formatChoice.target = self
        formatChoice.action = #selector(changedFormat(_:))
        [modeChoice, dpiChoice, paperChoice, formatChoice].forEach {
            $0.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let settingsGrid = NSGridView(views: [
            [label("Mode"), modeChoice],
            [label("Resolution"), dpiChoice],
            [label("Page size"), paperChoice],
            [label("Save as"), formatChoice]
        ])
        settingsGrid.rowSpacing = 10
        settingsGrid.columnSpacing = 22
        settingsGrid.column(at: 0).xPlacement = .trailing
        settingsGrid.column(at: 1).xPlacement = .fill

        multipageCheck.target = self
        multipageCheck.action = #selector(changedMultipage(_:))
        ocrCheck.state = UserDefaults.standard.object(forKey: "m1120.ocr") == nil ||
            UserDefaults.standard.bool(forKey: "m1120.ocr") ? .on : .off
        ocrCheck.target = self
        ocrCheck.action = #selector(changedOCR(_:))
        let modeStack = NSStackView(views: [multipageCheck, ocrCheck])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 8

        folderLabel.stringValue = selectedFolder
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.toolTip = selectedFolder
        folderLabel.font = NSFont.systemFont(ofSize: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderButton.target = self
        folderButton.action = #selector(chooseFolder(_:))
        let folderRow = NSStackView(views: [folderLabel, folderButton])
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 12

        pagesLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let helpText = label("Place the next sheet face down, click Scan page, and repeat. Then click Save PDF.", size: 11)
        helpText.textColor = .secondaryLabelColor
        let pageStack = NSStackView(views: [pagesLabel, helpText])
        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 4

        scanButton.target = self
        scanButton.action = #selector(scanDocument(_:))
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(savePDF(_:))
        saveButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeLast(_:))
        discardButton.target = self
        discardButton.action = #selector(discardPages(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelOperation(_:))
        openButton.target = self
        openButton.action = #selector(openLast(_:))
        revealButton.target = self
        revealButton.action = #selector(revealLast(_:))
        let primaryButtons = NSStackView(views: [scanButton, saveButton, cancelButton])
        primaryButtons.orientation = .horizontal
        primaryButtons.alignment = .centerY
        primaryButtons.spacing = 10
        let secondaryButtons = NSStackView(views: [removeButton, discardButton, openButton, revealButton])
        secondaryButtons.orientation = .horizontal
        secondaryButtons.alignment = .centerY
        secondaryButtons.spacing = 10

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 12)
        errorLabel.maximumNumberOfLines = 4
        errorLabel.isHidden = true

        let footnote = label("Local OCR (macOS Vision). Maximum tested resolution: 600 DPI. No cloud upload.", size: 11)
        footnote.textColor = .tertiaryLabelColor
        let main = NSStackView(views: [
            headingStack, divider(), label("SCAN SETTINGS", size: 11, bold: true), settingsGrid,
            modeStack, divider(), label("SAVE LOCATION", size: 11, bold: true), folderRow,
            divider(), label("DOCUMENT", size: 11, bold: true), pageStack,
            primaryButtons, secondaryButtons, statusRow, errorLabel, footnote
        ])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 25),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -25),
            main.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
            folderRow.widthAnchor.constraint(equalTo: main.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: main.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: main.widthAnchor)
        ])
    }

    private func isMultipage() -> Bool { multipageCheck.state == .on }
    private func isPDF() -> Bool { isMultipage() || formatChoice.indexOfSelectedItem == 0 }
    private func refresh() {
        assert(Thread.isMainThread)
        let busy = engine.isBusy
        let multi = isMultipage()
        let hasPages = !engine.pages.isEmpty
        [modeChoice, dpiChoice, folderButton, scanButton].forEach { $0.isEnabled = !busy }
        paperChoice.isEnabled = !busy && !hasPages
        formatChoice.isEnabled = !busy && !multi
        multipageCheck.isEnabled = !busy && !hasPages
        ocrCheck.isEnabled = !busy && isPDF()
        scanButton.title = multi ? "Scan next page" : "Scan document"
        saveButton.isHidden = !multi
        saveButton.isEnabled = multi && hasPages && !busy
        removeButton.isHidden = !multi
        removeButton.isEnabled = multi && hasPages && !busy
        discardButton.isHidden = !multi
        discardButton.isEnabled = multi && hasPages && !busy
        pagesLabel.stringValue = multi ? "\(engine.pages.count) page(s) in current document" : "Single-page mode"
        cancelButton.isHidden = !busy
        cancelButton.isEnabled = busy
        openButton.isEnabled = !busy && engine.lastFile != nil
        revealButton.isEnabled = !busy && engine.lastFile != nil
        statusLabel.stringValue = engine.status
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        errorLabel.stringValue = engine.errorText ?? ""
        errorLabel.isHidden = engine.errorText == nil
    }
    @objc private func changedMultipage(_ sender: Any?) {
        if isMultipage() {
            previousSingleFormat = max(0, formatChoice.indexOfSelectedItem)
            formatChoice.selectItem(at: 0)
        } else {
            formatChoice.selectItem(at: previousSingleFormat)
        }
        refresh()
    }
    @objc private func changedFormat(_ sender: Any?) { refresh() }
    @objc private func changedOCR(_ sender: Any?) {
        UserDefaults.standard.set(ocrCheck.state == .on, forKey: "m1120.ocr")
    }
    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.directoryURL = URL(fileURLWithPath: selectedFolder)
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url.path
            folderLabel.stringValue = selectedFolder
            folderLabel.toolTip = selectedFolder
            UserDefaults.standard.set(selectedFolder, forKey: "m1120.saveFolder")
        }
    }
    @objc private func scanDocument(_ sender: Any?) {
        guard let paper = ScanPaper(rawValue: paperChoice.indexOfSelectedItem),
              let format = ScanFormat(rawValue: formatChoice.indexOfSelectedItem) else { return }
        let options = [150, 200, 300, 600]
        let index = dpiChoice.indexOfSelectedItem
        guard index >= 0 && index < options.count else { return }
        let mode: ScanMode = modeChoice.indexOfSelectedItem == 1 ? .color : .gray
        engine.scan(ScanSettings(mode: mode, dpi: options[index], paper: paper,
                                 format: isMultipage() ? .pdf : format,
                                 destination: URL(fileURLWithPath: selectedFolder),
                                 searchablePDF: ocrCheck.state == .on), addToBatch: isMultipage())
    }
    @objc private func savePDF(_ sender: Any?) {
        engine.saveBatch(to: URL(fileURLWithPath: selectedFolder), searchablePDF: ocrCheck.state == .on)
    }
    @objc private func removeLast(_ sender: Any?) { engine.removeLastPage() }
    @objc private func discardPages(_ sender: Any?) {
        guard !engine.pages.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Discard all \(engine.pages.count) scanned pages?"
        alert.informativeText = "These unsaved scans cannot be recovered after you discard them."
        alert.addButton(withTitle: "Keep pages")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertSecondButtonReturn { engine.discardBatch() }
    }
    @objc private func cancelOperation(_ sender: Any?) { engine.cancel() }
    @objc private func openLast(_ sender: Any?) {
        if let file = engine.lastFile { NSWorkspace.shared.open(file) }
    }
    @objc private func revealLast(_ sender: Any?) {
        if let file = engine.lastFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}

@main
struct M1120App {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}