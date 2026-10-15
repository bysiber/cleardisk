import AppKit
import SwiftUI

struct ProjectScanRootsSection: View {
    @ObservedObject var diskMonitor: DiskMonitor
    @State private var isExpanded = false
    @State private var errorMessage: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Built-in folders are always scanned."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(L("Custom folders"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if diskMonitor.customProjectRoots.isEmpty {
                    Text(L("No custom folders yet."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diskMonitor.customProjectRoots, id: \.self) { path in
                        customRootRow(path)
                    }
                }

                let volumes = DiskMonitor.mountedExternalVolumes()
                if !volumes.isEmpty {
                    Text(L("Connected external volumes"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)

                    ForEach(volumes) { volume in
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name)
                                    .lineLimit(1)
                                Text(volume.path)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Button(L("Add")) { addRoot(volume.path) }
                                .buttonStyle(.plain)
                                .disabled(!canAddMore || isAlreadyIncluded(volume.path))
                        }
                    }
                }

                Button(action: chooseFolder) {
                    Label(L("Add folder…"), systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!canAddMore)
                .help(L("Choose a folder to scan for project caches. Press ⌘⇧G to type a path (e.g. /Volumes/YourDisk)."))
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label(L("Scan folders"), systemImage: "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(diskMonitor.customProjectRoots.count)/\(DiskMonitor.maxCustomProjectRoots)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .font(.system(size: 10))
        .padding(10)
        .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .alert(L("Could not add folder"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canAddMore: Bool {
        diskMonitor.customProjectRoots.count < DiskMonitor.maxCustomProjectRoots
    }

    private func customRootRow(_ path: String) -> some View {
        let isAvailable = diskMonitor.isCustomProjectRootAvailable(path)
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isAvailable ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1)
                Text(isAvailable ? path : "\(path) · \(L("Unavailable"))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                diskMonitor.removeCustomProjectRoot(path)
                diskMonitor.rescanProjectArtifacts()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help(L("Remove folder"))
        }
        .help(path)
    }

    private func isAlreadyIncluded(_ path: String) -> Bool {
        let normalized = DiskMonitor.normalizeProjectRootPath(path)
        return (diskMonitor.defaultProjectScanRoots + diskMonitor.customProjectRoots)
            .contains { DiskMonitor.normalizeProjectRootPath($0) == normalized }
    }

    private func chooseFolder() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.pickProjectScanFolder { url in
            guard let url else { return }
            addRoot(url.path)
        }
    }

    private func addRoot(_ path: String) {
        guard canAddMore else {
            errorMessage = String(format: L("You can add up to %d custom folders."), DiskMonitor.maxCustomProjectRoots)
            return
        }
        if let error = diskMonitor.addCustomProjectRoot(path) {
            errorMessage = message(for: error)
            return
        }
        diskMonitor.rescanProjectArtifacts()
    }

    private func message(for error: DiskMonitor.CustomProjectRootError) -> String {
        switch error {
        case .atCapacity:
            return String(format: L("You can add up to %d custom folders."), DiskMonitor.maxCustomProjectRoots)
        case .invalid:
            return L("That path is not a folder.")
        case .duplicate:
            return L("That folder is already included in the scan list.")
        case .nested:
            return L("That folder overlaps another scan root. Pick a non-nested path.")
        case .filesystemRoot:
            return L("The filesystem root cannot be added as a scan folder.")
        }
    }
}
