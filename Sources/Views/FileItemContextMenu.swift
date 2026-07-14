import SwiftUI

/// The right-click menu for file items, shared by the list and icon views.
/// Empty `ids` means the click landed on the background.
struct FileItemContextMenu: View {
    @Environment(AppState.self) private var appState
    let ids: Set<FileItem.ID>
    let model: PaneModel
    let paneIndex: Int

    var body: some View {
        let items = resolvedMenuItems
        let imageOnlySelection = !items.isEmpty && items.allSatisfy(\.isImage)
        let visualMediaSelection = !items.isEmpty && items.allSatisfy {
            $0.isImage || $0.isVideoMedia
        }
        let audioOnlySelection = !items.isEmpty && items.allSatisfy(\.isAudioMedia)
        let spreadsheetOnlySelection = !items.isEmpty && items.allSatisfy(\.isSpreadsheet)
        let textCodeSelection = items.count == 1 && items.first.map {
            $0.isText && !$0.isSpreadsheet
        } == true
        let applicationSelection = items.count == 1 && items.first?.isApplicationBundle == true
        let diskImageSelection = items.count == 1 && items.first?.isDiskImage == true
        let installerSelection = items.count == 1 && items.first?.isInstallerPackage == true
        let presentationOnlySelection = !items.isEmpty && items.allSatisfy(\.isPresentation)
        let fontOnlySelection = !items.isEmpty && items.allSatisfy(\.isFontFile)
        let eBookSelection = items.count == 1 && items.first?.isEPUB == true
        let contactCardOnlySelection = !items.isEmpty && items.allSatisfy(\.isContactCard)
        let documentOnlySelection = !items.isEmpty
            && items.allSatisfy(DocumentPDFConverter.canConvert)
            && !spreadsheetOnlySelection
            && !textCodeSelection
        let folderOnlySelection = !items.isEmpty
            && items.allSatisfy(\.isDirectory)
            && !items.contains(where: \.isToolPackage)
        let archiveSelection = items.count == 1 && items.first?.isArchive == true
        if ids.isEmpty {
            menuButton("New Folder", systemImage: "folder.badge.plus") {
                activate()
                appState.showNewFolderPrompt = true
            }
            menuButton("New Text File", systemImage: "doc.badge.plus") {
                activate()
                appState.showNewFilePrompt = true
            }
            if appState.canPasteFilesFromClipboard {
                Divider()
                menuButton("Paste Item", systemImage: "clipboard") {
                    activate()
                    appState.pasteClipboardFiles(to: model.currentURL, move: false)
                }
            }
            Divider()
            menuButton("Open in Terminal", systemImage: "terminal") {
                activate()
                appState.openTerminal(at: model.currentURL)
            }
            menuButton("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
        } else {
            menuButton("Open", systemImage: "arrow.up.forward.app") {
                activate()
                model.open(ids)
            }
            if ids.count == 1, let item = items.first, !item.isDirectory, !item.isText {
                menuButton("Edit in Text Editor", systemImage: "square.and.pencil") {
                    activate()
                    appState.beginEditText(ids)
                }
            }
            menuButton("Quick Look", systemImage: "eye") {
                activate()
                appState.quickLookSelection()
            }
            menuButton("Share via AirDrop", systemImage: "airdrop") {
                activate()
                appState.shareSelectionViaAirDrop(ids)
            }
            if items.contains(where: { !$0.isDirectory }) {
                menuButton("Create As Snippet", systemImage: "text.quote") {
                    activate()
                    appState.createSnippetFromSelection(ids)
                }
            }
            if imageOnlySelection {
                menuButton("Extract Text", systemImage: "text.viewfinder") {
                    activate()
                    appState.extractTextFromImages(ids)
                }
            }
            menuButton("Add to Drop Stack", systemImage: "tray.and.arrow.down") {
                activate()
                appState.addSelectionToDropStack(ids)
            }
            Divider()
            if appState.isDualPane {
                menuButton("Copy to Other Pane", systemImage: "rectangle.split.2x1") {
                    activate()
                    appState.transferSelection(ids, move: false)
                }
                menuButton("Move to Other Pane", systemImage: "arrow.right.square") {
                    activate()
                    appState.transferSelection(ids, move: true)
                }
                Divider()
            }
            menuButton("Move into New Folder…", systemImage: "folder.badge.plus") {
                activate()
                appState.beginMoveSelectionIntoNewFolder(ids)
            }
            menuButton("Move to Parent Folder", systemImage: "arrow.up.folder") {
                activate()
                appState.moveSelectionToParentFolder(ids)
            }
            menuButton("Duplicate", systemImage: "plus.square.on.square") {
                activate()
                appState.duplicateSelection(ids)
            }
            if !items.isEmpty {
                menuButton("Compress to ZIP", systemImage: "doc.zipper") {
                    activate()
                    appState.compressSelectionToZip(ids)
                }
            }
            menuButton("Batch Rename…", systemImage: "textformat") {
                activate()
                appState.beginBatchRename(ids)
            }
            Menu {
                Button("Clear Rating") {
                    activate()
                    appState.rateSelection(0, ids: ids)
                }
                Divider()
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating == 1 ? "" : "s")") {
                        activate()
                        appState.rateSelection(rating, ids: ids)
                    }
                }
            } label: {
                Label("Rating", systemImage: "star")
            }
            if imageOnlySelection {
                Menu {
                    if items.count == 1 {
                        Button("Annotate Image…") {
                            activate()
                            appState.beginAnnotateImage(ids)
                        }
                    }
                    Button("Resize Images…") {
                        activate()
                        appState.beginResize(ids)
                    }
                    Button("Convert Images…") {
                        activate()
                        appState.beginConvert(ids)
                    }
                    Button("Convert to Grayscale") {
                        activate()
                        appState.grayscaleImages(ids)
                    }
                    Button("Optimize Images") {
                        activate()
                        appState.optimizeImages(ids)
                    }
                    Button("Create 512px Thumbnails") {
                        activate()
                        appState.createImageThumbnails(ids)
                    }
                    Divider()
                    Menu("Rotate & Flip") {
                        Button("Rotate Left") {
                            activate()
                            appState.transformSelection(ids, operation: .rotateLeft)
                        }
                        Button("Rotate Right") {
                            activate()
                            appState.transformSelection(ids, operation: .rotateRight)
                        }
                        Divider()
                        Button("Flip Horizontal") {
                            activate()
                            appState.transformSelection(ids, operation: .flipHorizontal)
                        }
                        Button("Flip Vertical") {
                            activate()
                            appState.transformSelection(ids, operation: .flipVertical)
                        }
                    }
                    Button("Export Contact Sheet PDF") {
                        activate()
                        appState.exportContactSheet(ids)
                    }
                    if items.count >= 2 {
                        Divider()
                        Button("Play Slideshow") {
                            activate()
                            appState.beginPreviewSlideshow(ids)
                        }
                        Button("Merge Into Video…") {
                            activate()
                            appState.beginMergeIntoVideo(ids)
                        }
                    }
                } label: {
                    Label("Image Tools…", systemImage: "photo")
                }
            }
            if visualMediaSelection, !imageOnlySelection {
                Menu {
                    Button("Convert Media…") {
                        activate()
                        appState.beginConvert(ids)
                    }
                    Button("Play Slideshow") {
                        activate()
                        appState.beginPreviewSlideshow(ids)
                    }
                    if items.count >= 2 {
                        Button("Merge Into Video…") {
                            activate()
                            appState.beginMergeIntoVideo(ids)
                        }
                    }
                } label: {
                    Label("Media Tools…", systemImage: "play.rectangle")
                }
            }
            if audioOnlySelection {
                Menu {
                    Button("Play in Preview") {
                        activate()
                        appState.showPreviewForSelection(ids)
                    }
                    Button("Convert to M4A") {
                        activate()
                        appState.convertAudioToM4A(ids)
                    }
                    Divider()
                    Button("Open Voice Recorder…") {
                        activate()
                        appState.showVoiceRecorderTool()
                    }
                } label: {
                    Label("Audio Tools…", systemImage: "waveform")
                }
            }
            if spreadsheetOnlySelection {
                Menu {
                    Button("Open in Numbers") {
                        activate()
                        appState.openSpreadsheetsInNumbers(ids)
                    }
                    if let spreadsheet = items.first, items.count == 1 {
                        if let sourceFormat = SpreadsheetDelimitedFormat(url: spreadsheet.url) {
                            let destinationFormat: SpreadsheetDelimitedFormat = sourceFormat.fileExtension == "csv"
                                ? .tsv
                                : .csv
                            Button("Convert to \(destinationFormat.title)") {
                                activate()
                                appState.convertDelimitedSpreadsheet(ids, to: destinationFormat)
                            }
                            Button("Copy Table Summary") {
                                activate()
                                appState.copySpreadsheetSummary(ids)
                            }
                        } else {
                            Button("Export to CSV") {
                                activate()
                                appState.exportSpreadsheetToCSV(ids)
                            }
                        }
                    }
                } label: {
                    Label("Spreadsheet Tools…", systemImage: "tablecells")
                }
            }
            if textCodeSelection, let textFile = items.first {
                Menu {
                    Button("Open in Text Editor") {
                        activate()
                        appState.beginEditText(ids)
                    }
                    Button("Copy File Contents") {
                        activate()
                        appState.copyTextFileContents(ids)
                    }
                    Button("Convert to PDF") {
                        activate()
                        appState.convertDocumentToPDF(ids)
                    }
                    if textFile.isJSONFile {
                        Divider()
                        Button("Format JSON") {
                            activate()
                            appState.formatJSON(ids, minify: false)
                        }
                        Button("Minify JSON") {
                            activate()
                            appState.formatJSON(ids, minify: true)
                        }
                        Button("Validate JSON") {
                            activate()
                            appState.validateJSON(ids)
                        }
                    }
                } label: {
                    Label("Text & Code Tools…", systemImage: "curlybraces")
                }
            }
            if documentOnlySelection {
                Menu {
                    Button("Convert to PDF") {
                        activate()
                        appState.convertDocumentToPDF(ids)
                    }
                    Button("Open in Pages") {
                        activate()
                        appState.openDocumentsInPages(ids)
                    }
                } label: {
                    Label("Document Tools…", systemImage: "doc.text")
                }
            }
            if applicationSelection, let application = items.first {
                Menu {
                    Button("Launch App") {
                        activate()
                        appState.launchApplication(ids)
                    }
                    Button("Show Package Contents") {
                        activate()
                        appState.showApplicationPackageContents(ids)
                    }
                    Button("Open in Terminal") {
                        activate()
                        appState.openTerminal(at: application.url)
                    }
                    Divider()
                    Button("Copy App Details") {
                        activate()
                        appState.copyApplicationDetails(ids)
                    }
                } label: {
                    Label("App Tools…", systemImage: "app")
                }
            }
            if diskImageSelection {
                Menu {
                    Button("Mount Disk Image") {
                        activate()
                        appState.mountDiskImage(ids)
                    }
                    Divider()
                    Button("Copy SHA-256 Checksum") {
                        activate()
                        appState.copyDiskImageChecksum(ids)
                    }
                } label: {
                    Label("Disk Image Tools…", systemImage: "externaldrive")
                }
            }
            if installerSelection, let installer = items.first {
                Menu {
                    Button("Open Installer") {
                        activate()
                        appState.openInstallerPackage(ids)
                    }
                    if installer.isDirectory {
                        Button("Show Package Contents") {
                            activate()
                            appState.showInstallerPackageContents(ids)
                        }
                    }
                    Divider()
                    Button("Copy Installer Details") {
                        activate()
                        appState.copyInstallerDetails(ids)
                    }
                } label: {
                    Label("Installer Tools…", systemImage: "shippingbox")
                }
            }
            if presentationOnlySelection {
                Menu {
                    Button("Open in Keynote") {
                        activate()
                        appState.openPresentationsInKeynote(ids)
                    }
                    if items.count == 1 {
                        Button("Export to PDF") {
                            activate()
                            appState.exportPresentationToPDF(ids)
                        }
                    }
                } label: {
                    Label("Presentation Tools…", systemImage: "rectangle.on.rectangle")
                }
            }
            if fontOnlySelection {
                Menu {
                    Button("Open in Font Book") {
                        activate()
                        appState.openFontsInFontBook(ids)
                    }
                    Button("Install Fonts") {
                        activate()
                        appState.installFonts(ids)
                    }
                    Divider()
                    Button("Copy Font Details") {
                        activate()
                        appState.copyFontDetails(ids)
                    }
                } label: {
                    Label("Font Tools…", systemImage: "textformat.size")
                }
            }
            if eBookSelection {
                Menu {
                    Button("Open in Books") {
                        activate()
                        appState.openEBooksInBooks(ids)
                    }
                    Button("Copy Book Details") {
                        activate()
                        appState.copyEBookDetails(ids)
                    }
                } label: {
                    Label("EPUB Tools…", systemImage: "book")
                }
            }
            if contactCardOnlySelection {
                Menu {
                    Button("Open in Contacts") {
                        activate()
                        appState.openContactCardsInContacts(ids)
                    }
                    Button("Copy Contact Details") {
                        activate()
                        appState.copyContactDetails(ids)
                    }
                } label: {
                    Label("Contact Tools…", systemImage: "person.crop.rectangle")
                }
            }
            if folderOnlySelection {
                Menu {
                    Button("Calculate Size") {
                        activate()
                        model.calculateSizes(ids)
                    }
                    if items.count == 1, let folder = items.first {
                        Button("Open in Terminal") {
                            activate()
                            appState.openTerminal(at: folder.url)
                        }
                        Divider()
                        Button("Organize This Folder…") {
                            activate()
                            appState.organizeFolder(at: folder.url)
                        }
                        Button("Clean Up This Folder…") {
                            activate()
                            appState.cleanUpFolder(at: folder.url)
                        }
                    }
                } label: {
                    Label("Folder Tools…", systemImage: "folder")
                }
            }
            if archiveSelection, let archive = items.first {
                Menu {
                    Button("Browse Archive") {
                        activate()
                        appState.browseArchive(ids)
                    }
                    if archive.isZipArchive {
                        Button("View Archive Contents") {
                            activate()
                            appState.showArchiveContents(ids)
                        }
                    }
                    Button("Copy File List") {
                        activate()
                        appState.copyArchiveFileList(ids)
                    }
                    Divider()
                    Button("Extract Archive") {
                        activate()
                        appState.extractArchive(ids)
                    }
                } label: {
                    Label("Archive Tools…", systemImage: "archivebox")
                }
            }
            if items.contains(where: MediaConverter.canConvert),
               !imageOnlySelection,
               !visualMediaSelection {
                menuButton("Convert…", systemImage: "arrow.triangle.2.circlepath") {
                    activate()
                    appState.beginConvert(ids)
                }
            }
            if !items.isEmpty, items.allSatisfy(PDFTools.isPDF) {
                Menu {
                    if items.count >= 2 {
                        Button("Merge PDFs") {
                            activate()
                            appState.mergePDFs(ids)
                        }
                        Divider()
                    }
                    if items.count == 1 {
                        Button("Extract Pages…") {
                            activate()
                            appState.beginPDFTool(.extractPages, ids: ids)
                        }
                        Button("Split into Individual Pages") {
                            activate()
                            appState.splitPDF(ids)
                        }
                        Menu("Rotate All Pages") {
                            Button("Rotate Left") {
                                activate()
                                appState.rotatePDF(-90, ids: ids)
                            }
                            Button("Rotate Right") {
                                activate()
                                appState.rotatePDF(90, ids: ids)
                            }
                        }
                        Button("Export Pages as PNG") {
                            activate()
                            appState.exportPDFPagesAsPNGs(ids)
                        }
                        Button("Optimize PDF") {
                            activate()
                            appState.optimizePDF(ids)
                        }
                        Divider()
                        Button("Add Text Watermark…") {
                            activate()
                            appState.beginPDFTool(.watermark, ids: ids)
                        }
                        Menu("Security") {
                            Button("Protect with Password…") {
                                activate()
                                appState.beginPDFTool(.protect, ids: ids)
                            }
                            Button("Remove Password…") {
                                activate()
                                appState.beginPDFTool(.removePassword, ids: ids)
                            }
                        }
                        Divider()
                        Button("Copy PDF Details") {
                            activate()
                            appState.copyPDFDetails(ids)
                        }
                    }
                } label: {
                    Label("PDF Tools…", systemImage: "doc.richtext")
                }
            }
            if ids.count == 1, let item = items.first {
                menuButton("Rename…", systemImage: "pencil") { appState.renameTarget = item }
                if item.isDirectory, !item.isToolPackage {
                    if appState.canPasteFilesFromClipboard {
                        Divider()
                        menuButton("Move Items Here", systemImage: "arrow.down.doc") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: true)
                        }
                        menuButton("Paste Items Here", systemImage: "clipboard") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: false)
                        }
                    }
                }
            }
            Divider()
            menuButton("Copy Files", systemImage: "doc.on.doc") {
                activate()
                appState.copyFilesOfSelection(ids)
            }
            menuButton("Copy Path", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                activate()
                appState.copyPathOfSelection(ids)
            }
            menuButton("Copy Names As Text", systemImage: "textformat.abc") {
                activate()
                appState.copyNamesOfSelection(ids)
            }
            menuButton("Show Clipboard History", systemImage: "clock.arrow.circlepath") {
                activate()
                appState.showClipboardHistory()
            }
            menuButton("Reveal in Finder", systemImage: "folder") {
                activate()
                appState.revealSelectionInFinder(ids)
            }
            Divider()
            menuButton("Move to Trash", systemImage: "trash", role: .destructive) {
                activate()
                appState.trashSelection(ids)
            }
        }
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
    }

    private func activate() {
        appState.activePaneIndex = paneIndex
        if !ids.isEmpty {
            model.selection = ids
        }
    }

    private var resolvedMenuItems: [FileItem] {
        let visible = model.visibleSource.filter { ids.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))
        let missing = ids.subtracting(visibleIDs).compactMap(PaneModel.itemIfReachable)
        return visible + missing
    }
}
