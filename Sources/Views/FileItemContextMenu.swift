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
            Button("New Folder") {
                activate()
                appState.showNewFolderPrompt = true
            }
            Button("New Text File") {
                activate()
                appState.showNewFilePrompt = true
            }
            if appState.canPasteFilesFromClipboard {
                Divider()
                Button("Paste Item") {
                    activate()
                    appState.pasteClipboardFiles(to: model.currentURL, move: false)
                }
            }
            Divider()
            Button("Open in Terminal") {
                activate()
                appState.openTerminal(at: model.currentURL)
            }
            Button("Refresh") { model.refresh() }
        } else {
            Button("Open") {
                activate()
                model.open(ids)
            }
            if ids.count == 1, let item = items.first, !item.isDirectory, !item.isText {
                Button("Edit in Text Editor") {
                    activate()
                    appState.beginEditText(ids)
                }
            }
            Button("Quick Look") {
                activate()
                appState.quickLookSelection()
            }
            Button("Share via AirDrop") {
                activate()
                appState.shareSelectionViaAirDrop(ids)
            }
            if items.contains(where: { !$0.isDirectory }) {
                Button("Create As Snippet") {
                    activate()
                    appState.createSnippetFromSelection(ids)
                }
            }
            Divider()
            if appState.isDualPane {
                Button("Copy to Other Pane") {
                    activate()
                    appState.transferSelection(ids, move: false)
                }
                Button("Move to Other Pane") {
                    activate()
                    appState.transferSelection(ids, move: true)
                }
                Divider()
            }
            Button("Move into New Folder…") {
                activate()
                appState.beginMoveSelectionIntoNewFolder(ids)
            }
            Button("Duplicate") {
                activate()
                appState.duplicateSelection(ids)
            }
            Button("Batch Rename…") {
                activate()
                appState.beginBatchRename(ids)
            }
            Menu("Rating") {
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
            }
            if imageOnlySelection {
                Menu("Image Tools…") {
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
                }
            }
            if visualMediaSelection, !imageOnlySelection {
                Menu("Media Tools…") {
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
                }
            }
            if audioOnlySelection {
                Menu("Audio Tools…") {
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
                }
            }
            if spreadsheetOnlySelection {
                Menu("Spreadsheet Tools…") {
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
                }
            }
            if textCodeSelection, let textFile = items.first {
                Menu("Text & Code Tools…") {
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
                }
            }
            if documentOnlySelection {
                Menu("Document Tools…") {
                    Button("Convert to PDF") {
                        activate()
                        appState.convertDocumentToPDF(ids)
                    }
                    Button("Open in Pages") {
                        activate()
                        appState.openDocumentsInPages(ids)
                    }
                }
            }
            if applicationSelection, let application = items.first {
                Menu("App Tools…") {
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
                }
            }
            if diskImageSelection {
                Menu("Disk Image Tools…") {
                    Button("Mount Disk Image") {
                        activate()
                        appState.mountDiskImage(ids)
                    }
                    Divider()
                    Button("Copy SHA-256 Checksum") {
                        activate()
                        appState.copyDiskImageChecksum(ids)
                    }
                }
            }
            if installerSelection, let installer = items.first {
                Menu("Installer Tools…") {
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
                }
            }
            if presentationOnlySelection {
                Menu("Presentation Tools…") {
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
                }
            }
            if fontOnlySelection {
                Menu("Font Tools…") {
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
                }
            }
            if eBookSelection {
                Menu("EPUB Tools…") {
                    Button("Open in Books") {
                        activate()
                        appState.openEBooksInBooks(ids)
                    }
                    Button("Copy Book Details") {
                        activate()
                        appState.copyEBookDetails(ids)
                    }
                }
            }
            if contactCardOnlySelection {
                Menu("Contact Tools…") {
                    Button("Open in Contacts") {
                        activate()
                        appState.openContactCardsInContacts(ids)
                    }
                    Button("Copy Contact Details") {
                        activate()
                        appState.copyContactDetails(ids)
                    }
                }
            }
            if folderOnlySelection {
                Menu("Folder Tools…") {
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
                }
            }
            if archiveSelection, let archive = items.first {
                Menu("Archive Tools…") {
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
                }
            }
            if items.contains(where: MediaConverter.canConvert),
               !imageOnlySelection,
               !visualMediaSelection {
                Button("Convert…") {
                    activate()
                    appState.beginConvert(ids)
                }
            }
            if !items.isEmpty, items.allSatisfy(PDFTools.isPDF) {
                Menu("PDF Tools…") {
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
                }
            }
            if ids.count == 1, let item = items.first {
                Button("Rename…") { appState.renameTarget = item }
                if item.isDirectory, !item.isToolPackage {
                    if appState.canPasteFilesFromClipboard {
                        Divider()
                        Button("Move files here") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: true)
                        }
                        Button("Copy files here") {
                            activate()
                            appState.pasteClipboardFiles(to: item.url, move: false)
                        }
                    }
                }
            }
            Divider()
            Button("Copy Files") {
                activate()
                appState.copyFilesOfSelection(ids)
            }
            Button("Copy Path") {
                activate()
                appState.copyPathOfSelection(ids)
            }
            Button("Copy Names As Text") {
                activate()
                appState.copyNamesOfSelection(ids)
            }
            Button("Show Clipboard History") {
                activate()
                appState.showClipboardHistory()
            }
            Button("Reveal in Finder") {
                activate()
                appState.revealSelectionInFinder(ids)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                activate()
                appState.trashSelection(ids)
            }
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
