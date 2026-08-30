//
//  AtomicDirectorySummaryWalker.swift
//  ClearDisk
//
//  Created by Codex on 6/12/26.
//

import Foundation

extension AtomicDirectorySummarizer {
    nonisolated func summarizeSerial(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        expectedRootIdentity: FileIdentity? = nil,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        resumeState: AtomicDirectoryProbeResumeState? = nil
    ) async throws -> AtomicDirectorySummary? {
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let summary: AtomicDirectorySummary?
        do {
            summary = try await Self.summarizeInParallel(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: 1,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                volumeBoundaryPolicy: volumeBoundaryPolicy,
                cancellationCheck: cancellationCheck,
                metrics: metrics,
                continuation: continuation,
                resumeState: resumeState,
                expectedRootIdentity: expectedRootIdentity
            )
        } catch is AtomicSummaryRootFallbackRequired {
            resumeState?.invalidateCursors()
            summary = try await Self.summarizeInParallel(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: 1,
                ownerNodeID: ownerNodeID,
                exclusionMatcher: exclusionMatcher,
                metadataLoader: metadataLoader,
                volumeBoundaryPolicy: volumeBoundaryPolicy,
                cancellationCheck: cancellationCheck,
                metrics: metrics,
                continuation: continuation,
                forcesFoundationTraversal: true,
                expectedRootIdentity: expectedRootIdentity
            )
        }
        #if DEBUG
        diagnostics?.record(
            operation: "atomic.summary.enumerate",
            url: url,
            startedAt: summaryStart,
            itemCount: summary?.descendantFileCount,
            detail: "files=\(summary?.descendantFileCount ?? 0)"
        )
        #endif
        return summary
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    nonisolated func summarizeReusingImmediateChildren(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.summary.reused_entries",
                url: url,
                startedAt: summaryStart,
                itemCount: childEntries.count,
                detail: "files=\(state.descendantFileCount)"
            )
        }
        #endif

        let hasActiveExclusions = !exclusionMatcher.isEmpty
        for (index, childEntry) in childEntries.enumerated() {
            try cancellationCheck()
            state.visitedItemCount = ScanIntegerMath.addingClamped(
                state.visitedItemCount,
                1
            )
            if index == 0 || index.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childEntry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadataLoader.metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            if hasActiveExclusions,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childEntry.url.path,
                   isDirectory: childMetadata.isDirectory
               ) {
                continue
            }
            guard !childMetadata.isDataless else { continue }

            try await accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        return makeAtomicSummary(from: state)
    }

    nonisolated private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws {
        try cancellationCheck()
        guard !metadata.isDataless else { return }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            if let boundaryError = volumeBoundaryPolicy.descentBoundaryError(
                for: url,
                childDeviceID: metadata.fileIdentity?.fileSystemDeviceID
            ) {
                recordAtomicWarning(for: url, error: boundaryError, in: state)
                return
            }
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try await summarize(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: state.ownerNodeID,
                    expectedRootIdentity: metadata.fileIdentity,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        accumulateAtomicFile(metadata, url: url, into: state)
    }

    nonisolated private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize = ScanIntegerMath.addingClamped(state.allocatedSize, summary.allocatedSize)
        state.logicalSize = ScanIntegerMath.addingClamped(state.logicalSize, summary.logicalSize)
        state.descendantFileCount = ScanIntegerMath.addingClamped(
            state.descendantFileCount,
            summary.descendantFileCount
        )
        state.visitedItemCount = ScanIntegerMath.addingClamped(
            state.visitedItemCount,
            summary.visitedItemCount
        )
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
        state.sharedAllocationAccumulator.merge(summary.sharedAllocationAccumulator)
    }

    nonisolated private func updateAtomicAccessibility(_ isReadable: Bool, in state: AtomicDirectorySummaryState) {
        state.isAccessible = state.isAccessible && isReadable
    }

    nonisolated private func recordAtomicWarning(
        for url: URL,
        error: Error,
        in state: AtomicDirectorySummaryState
    ) {
        state.isAccessible = false
        state.warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    nonisolated private func accumulateAtomicFile(_ metadata: NodeMetadata, url: URL, into state: AtomicDirectorySummaryState) {
        state.allocatedSize = ScanIntegerMath.addingClamped(state.allocatedSize, metadata.allocatedSize)
        state.logicalSize = ScanIntegerMath.addingClamped(state.logicalSize, metadata.logicalSize)

        if !metadata.isSymbolicLink {
            state.descendantFileCount = ScanIntegerMath.addingClamped(state.descendantFileCount, 1)
        }

        if let claim = SharedAllocationDeduplicator.claim(
            for: metadata,
            ownerNodeID: state.ownerNodeID,
            path: url.path
        ) {
            state.sharedAllocationAccumulator.record(claim)
        }
    }

    nonisolated private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            visitedItemCount: state.visitedItemCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings,
            sharedAllocationAccumulator: state.sharedAllocationAccumulator
        )
    }

    nonisolated func emitProgressHeartbeat(
        currentURL: URL,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        metrics.currentPath = currentURL.path
        let now = Date()
        guard now.timeIntervalSince(emissionState.lastProgressEmission) >= 0.15 else { return }

        emissionState.lastProgressEmission = now
        if let summaryPool {
            summaryPool.reportCurrentPath(
                currentURL.path,
                continuation: continuation,
            )
        } else {
            continuation.yield(.progress(metrics))
        }
    }
}
