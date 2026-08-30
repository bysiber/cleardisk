//
//  AtomicDirectorySummarizer.swift
//  ClearDisk
//
//  Created by Codex on 6/12/26.
//

import Foundation

nonisolated struct AtomicDirectorySummarizer: Sendable {
    #if DEBUG
    typealias ProfileReporter = @Sendable (ScanAutoSummaryProfileEvent) -> Void
    #endif

    let metadataLoader: ScanMetadataLoader
    let diagnostics: ScanDiagnosticsContext?
    let summaryPool: AtomicDirectorySummaryPool?
    let volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy
    #if DEBUG
    let profileReporter: ProfileReporter?
    #endif

    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        summaryPool: AtomicDirectorySummaryPool? = nil,
        volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy = .unrestricted
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.summaryPool = summaryPool
        self.volumeBoundaryPolicy = volumeBoundaryPolicy
        #if DEBUG
        self.profileReporter = nil
        #endif
    }

    #if DEBUG
    init(
        metadataLoader: ScanMetadataLoader,
        diagnostics: ScanDiagnosticsContext? = nil,
        summaryPool: AtomicDirectorySummaryPool? = nil,
        volumeBoundaryPolicy: ScanEngine.ScanVolumeBoundaryPolicy = .unrestricted,
        profileReporter: ProfileReporter?
    ) {
        self.metadataLoader = metadataLoader
        self.diagnostics = diagnostics
        self.summaryPool = summaryPool
        self.volumeBoundaryPolicy = volumeBoundaryPolicy
        self.profileReporter = profileReporter
    }
    #endif

    /// Cheap, synchronous pre-check mirroring `summaryIfNeeded`'s gating: whether the
    /// directory is worth probing or summarizing at all. Runs no descendant I/O, so it
    /// is safe to call on the scan scheduling loop before dispatching the (potentially
    /// slow) `summaryIfNeeded` call off it.
    func isAtomicSummaryCandidate(
        url: URL,
        childEntries: [DirectoryEntry],
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        allowsDescendantProbe: Bool = true,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        guard !childEntries.isEmpty else { return false }
        if childEntries.count >= minFileCount,
           try immediateChildrenSuggestAtomicDirectory(
               childEntries,
               maxAverageFileSize: maxAverageFileSize,
               cancellationCheck: cancellationCheck
           ) {
            return true
        }
        if Self.isKnownGeneratedDirectory(at: url) {
            return true
        }
        guard allowsDescendantProbe else { return false }
        return shouldRunDescendantAtomicProbe(
            childEntries: childEntries,
            minFileCount: minFileCount,
            isNodeDependencyLayout: isNodeDependencyLayout
        )
    }

    /// Determines if a directory should be treated as atomic (summarized without expansion).
    /// Returns a summary if the directory has many small files (like node_modules, caches).
    /// Returns nil if the directory should be expanded normally.
    ///
    /// Sampling uses metadata decoded from `contentsOfDirectory`'s prefetched resource values,
    /// so no additional per-file resource lookups are needed.
    func summaryIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        expectedRootIdentity: FileIdentity? = nil,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        progressWeight: Double = 0,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try await summaryDecisionIfNeeded(
            url: url,
            childEntries: childEntries,
            metadata: metadata,
            expectedRootIdentity: expectedRootIdentity,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            isNodeDependencyLayout: isNodeDependencyLayout,
            minFileCount: minFileCount,
            maxAverageFileSize: maxAverageFileSize,
            workerLimit: workerLimit,
            progressWeight: progressWeight,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ).summary
    }

    /// Produces a summary without applying the density heuristic. Used by
    /// memory-bounded scans once their materialized depth limit is reached.
    /// The already-enumerated immediate children are reused so enforcing the
    /// memory boundary does not add another flat-directory pass.
    func forcedSummaryDecision(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        expectedRootIdentity: FileIdentity?,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        progressWeight: Double,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummaryDecision {
        try cancellationCheck()
        guard !childEntries.isEmpty else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }

        let summary: AtomicDirectorySummary?
        if summaryPool != nil {
            var partial = AtomicDirectorySummaryPartial()
            partial.updateAccessibility(metadata.isReadable)
            let resumeState = AtomicDirectoryProbeResumeState(
                partial: partial,
                workItems: [AtomicSummaryWorkItem(
                    url: url,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    ownerNodeID: url.path,
                    expectedIdentity: expectedRootIdentity,
                    volumeBoundaryPolicy: volumeBoundaryPolicy,
                    bufferedEntries: childEntries,
                    needsCursor: false,
                    reloadsMissingBufferedMetadata: true
                )],
                visitedItemCount: 0
            )
            summary = try await summarize(
                at: url,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                progressWeight: progressWeight,
                progressKind: .autoSummary,
                representedItemCount: childEntries.count,
                ownerNodeID: url.path,
                expectedRootIdentity: expectedRootIdentity,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState,
                resumeState: resumeState
            )
        } else {
            summary = try await summarizeReusingImmediateChildren(
                at: url,
                childEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                ownerNodeID: url.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        #if DEBUG
        reportCreatedSummary(summary)
        #endif
        return AtomicDirectorySummaryDecision(
            summary: summary,
            reusableDirectoryListings: [:],
            descendantProbeFullyExhausted: false
        )
    }

    func summaryDecisionIfNeeded(
        url: URL,
        childEntries: [DirectoryEntry],
        metadata: NodeMetadata,
        expectedRootIdentity: FileIdentity? = nil,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        workerLimit: Int,
        progressWeight: Double = 0,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummaryDecision {
        try cancellationCheck()
        guard !childEntries.isEmpty else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }

        let immediateCandidate: Bool
        if childEntries.count >= minFileCount {
            immediateCandidate = try immediateChildrenSuggestAtomicDirectory(
                childEntries,
                maxAverageFileSize: maxAverageFileSize,
                cancellationCheck: cancellationCheck
            )
        } else {
            immediateCandidate = false
        }

        let deepCandidate: Bool
        var probeResumeState: AtomicDirectoryProbeResumeState? = nil
        var reusableDirectoryListings: [String: AtomicDirectoryProbeListing] = [:]
        var descendantProbeFullyExhausted = false
        if immediateCandidate {
            deepCandidate = true
        } else if Self.isKnownGeneratedDirectory(at: url) {
            deepCandidate = true
        } else {
            guard shouldRunDescendantAtomicProbe(
                childEntries: childEntries,
                minFileCount: minFileCount,
                isNodeDependencyLayout: isNodeDependencyLayout
            ) else {
                return AtomicDirectorySummaryDecision(
                    summary: nil,
                    reusableDirectoryListings: [:],
                    descendantProbeFullyExhausted: false
                )
            }
            let outcome = try descendantAtomicProbeProfile(
                at: url,
                rootEntries: childEntries,
                rootMetadata: metadata,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                isNodeDependencyLayout: isNodeDependencyLayout,
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
            deepCandidate = outcome.profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            )
            #if DEBUG
            profileReporter?(.probeCompleted(
                visitedItemCount: outcome.visitedItemCount,
                wasAccepted: deepCandidate
            ))
            #endif
            probeResumeState = deepCandidate ? outcome.resumeState : nil
            if !deepCandidate {
                reusableDirectoryListings = outcome.reusableDirectoryListings
                descendantProbeFullyExhausted = outcome.fullyExhausted
            }
        }

        guard deepCandidate else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: reusableDirectoryListings,
                descendantProbeFullyExhausted: descendantProbeFullyExhausted
            )
        }

        let directDirectoryCount = childEntries.reduce(into: 0) { count, childEntry in
            if childEntry.metadata?.isDirectory == true {
                count += 1
            }
        }
        let canReuseImmediateEntries = immediateCandidate && directDirectoryCount <= max(8, childEntries.count / 10)
        if canReuseImmediateEntries {
            let summary: AtomicDirectorySummary?
            if summaryPool != nil {
                var partial = AtomicDirectorySummaryPartial()
                partial.updateAccessibility(metadata.isReadable)
                let resumeState = AtomicDirectoryProbeResumeState(
                    partial: partial,
                    workItems: [AtomicSummaryWorkItem(
                        url: url,
                        treatPackagesAsDirectories: treatPackagesAsDirectories,
                        ownerNodeID: url.path,
                        expectedIdentity: expectedRootIdentity,
                        volumeBoundaryPolicy: volumeBoundaryPolicy,
                        bufferedEntries: childEntries,
                        needsCursor: false,
                        reloadsMissingBufferedMetadata: true
                    )],
                    visitedItemCount: 0
                )
                summary = try await summarize(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    progressWeight: progressWeight,
                    progressKind: .autoSummary,
                    representedItemCount: childEntries.count,
                    ownerNodeID: url.path,
                    expectedRootIdentity: expectedRootIdentity,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState,
                    resumeState: resumeState
                )
            } else {
                summary = try await summarizeReusingImmediateChildren(
                    at: url,
                    childEntries: childEntries,
                    rootMetadata: metadata,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: url.path,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            #if DEBUG
            reportCreatedSummary(summary)
            #endif
            return AtomicDirectorySummaryDecision(
                summary: summary,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }

        guard let summary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            progressWeight: progressWeight,
            progressKind: .autoSummary,
            representedItemCount: childEntries.count,
            ownerNodeID: url.path,
            expectedRootIdentity: expectedRootIdentity,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            resumeState: probeResumeState
        ) else {
            return AtomicDirectorySummaryDecision(
                summary: nil,
                reusableDirectoryListings: [:],
                descendantProbeFullyExhausted: false
            )
        }
        #if DEBUG
        reportCreatedSummary(summary)
        #endif
        return AtomicDirectorySummaryDecision(
            summary: summary,
            reusableDirectoryListings: [:],
            descendantProbeFullyExhausted: false
        )
    }

    #if DEBUG
    private func reportCreatedSummary(_ summary: AtomicDirectorySummary?) {
        guard let summary else { return }
        profileReporter?(.directorySummarized(
            descendantFileCount: summary.descendantFileCount
        ))
    }
    #endif

    /// Performs a fast recursive summary of a directory's size and file count.
    /// - Parameters:
    ///   - url: The directory to summarize.
    ///   - includeHiddenFiles: Whether to include hidden files in the summary.
    func summarize(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        progressWeight: Double = 0,
        progressKind: AtomicSummaryProgressKind = .autoSummary,
        representedItemCount: Int = 0,
        ownerNodeID: String,
        expectedRootIdentity: FileIdentity? = nil,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: @escaping CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        resumeState: AtomicDirectoryProbeResumeState? = nil
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        if let summaryPool {
            #if DEBUG
            let summaryStart = diagnostics?.start()
            #endif
            let summary = try await summaryPool.summarize(
                AtomicSummaryPoolRequest(
                    url: url,
                    expectedRootIdentity: expectedRootIdentity,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    progressWeight: progressWeight,
                    progressKind: progressKind,
                    representedItemCount: representedItemCount,
                    ownerNodeID: ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    metadataLoader: metadataLoader,
                    volumeBoundaryPolicy: volumeBoundaryPolicy,
                    cancellationCheck: cancellationCheck,
                    metrics: metrics,
                    continuation: continuation,
                    resumeState: resumeState
                )
            )
            #if DEBUG
            diagnostics?.record(
                operation: "atomic.summary.pool",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount
            )
            #endif
            return summary
        }
        if workerLimit > 1 {
            #if DEBUG
            let summaryStart = diagnostics?.start()
            #endif
            let summary: AtomicDirectorySummary?
            do {
                summary = try await Self.summarizeInParallel(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
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
                    workerLimit: workerLimit,
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
                operation: "atomic.summary.parallel",
                url: url,
                startedAt: summaryStart,
                itemCount: summary?.descendantFileCount,
                detail: "workers=\(workerLimit)"
            )
            #endif
            return summary
        }

        return try await summarizeSerial(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            workerLimit: workerLimit,
            ownerNodeID: ownerNodeID,
            expectedRootIdentity: expectedRootIdentity,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState,
            resumeState: resumeState
        )
    }
}
