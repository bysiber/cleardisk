//
//  SharedAllocationOwnerAccumulator.swift
//  ClearDisk
//
//  Created by Codex on 7/10/26.
//

import Foundation

/// Assigns hard-linked storage to one path, then assigns each APFS clone
/// group's shared data-fork allocation to one distinct inode.
///
/// Hard links share every fork, while APFS clone IDs describe the data fork.
/// Keeping those stages separate preserves allocation that belongs only to a
/// clone's resource fork and prevents hard-linked paths from entering clone
/// accounting more than once.
nonisolated struct SharedAllocationOwnerAccumulator: Sendable {
    private enum CloneFileKey: Hashable, Sendable {
        case identity(FileIdentity)
        case path(String)
    }

    private var hardLinkWinnerByIdentity: [FileIdentity: SharedAllocationClaim] = [:]
    private var standaloneCloneWinnerByFile: [CloneFileKey: SharedAllocationClaim] = [:]
    private var hardLinkDuplicateAllocatedSizeByOwner: [String: Int64] = [:]

    nonisolated init() {}

    nonisolated init<S: Sequence>(_ claims: S) where S.Element == SharedAllocationClaim {
        record(contentsOf: claims)
    }

    nonisolated var duplicateAllocatedSizeByOwner: [String: Int64] {
        duplicateAllocatedSizeByOwner(cancellationCheck: {})
    }

    nonisolated func duplicateAllocatedSizeByOwner(
        cancellationCheck: () throws -> Void
    ) rethrows -> [String: Int64] {
        var corrections = hardLinkDuplicateAllocatedSizeByOwner
        var cloneWinnerByIdentity: [CloneIdentity: SharedAllocationClaim] = [:]

        for (offset, claim) in hardLinkWinnerByIdentity.values.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            Self.recordCloneCorrection(
                for: claim,
                winnerByIdentity: &cloneWinnerByIdentity,
                corrections: &corrections
            )
        }
        for (offset, claim) in standaloneCloneWinnerByFile.values.enumerated() {
            if offset.isMultiple(of: 256) {
                try cancellationCheck()
            }
            Self.recordCloneCorrection(
                for: claim,
                winnerByIdentity: &cloneWinnerByIdentity,
                corrections: &corrections
            )
        }
        return corrections
    }

    nonisolated var identityCount: Int {
        var cloneIdentities = Set<CloneIdentity>()
        for claim in hardLinkWinnerByIdentity.values {
            if let cloneIdentity = claim.cloneIdentity {
                cloneIdentities.insert(cloneIdentity)
            }
        }
        for claim in standaloneCloneWinnerByFile.values {
            if let cloneIdentity = claim.cloneIdentity {
                cloneIdentities.insert(cloneIdentity)
            }
        }
        return hardLinkWinnerByIdentity.count + cloneIdentities.count
    }

    nonisolated var isEmpty: Bool {
        hardLinkWinnerByIdentity.isEmpty && standaloneCloneWinnerByFile.isEmpty
    }

    nonisolated func winner(for identity: FileIdentity) -> SharedAllocationClaim? {
        hardLinkWinnerByIdentity[identity]
    }

    nonisolated mutating func record(_ claim: SharedAllocationClaim) {
        guard claim.allocatedSize > 0 else { return }

        if let hardLinkIdentity = claim.hardLinkIdentity {
            recordHardLink(claim, identity: hardLinkIdentity)
        } else if claim.cloneIdentity != nil {
            let key = claim.fileIdentity.map(CloneFileKey.identity) ?? .path(claim.path)
            if let currentWinner = standaloneCloneWinnerByFile[key] {
                if Self.precedes(claim, currentWinner) {
                    standaloneCloneWinnerByFile[key] = claim
                }
            } else {
                standaloneCloneWinnerByFile[key] = claim
            }
        }
    }

    nonisolated mutating func record<S: Sequence>(contentsOf claims: S) where S.Element == SharedAllocationClaim {
        for claim in claims {
            record(claim)
        }
    }

    /// Merges package-local state without reconstructing discarded duplicate claims.
    nonisolated mutating func merge(_ other: Self) {
        for (ownerNodeID, allocatedSize) in other.hardLinkDuplicateAllocatedSizeByOwner {
            hardLinkDuplicateAllocatedSizeByOwner[ownerNodeID, default: 0] += allocatedSize
        }
        for winner in other.hardLinkWinnerByIdentity.values {
            record(winner)
        }
        for winner in other.standaloneCloneWinnerByFile.values {
            record(winner)
        }
    }

    private nonisolated mutating func recordHardLink(_ claim: SharedAllocationClaim, identity: FileIdentity) {
        guard let currentWinner = hardLinkWinnerByIdentity[identity] else {
            hardLinkWinnerByIdentity[identity] = claim
            return
        }

        if Self.precedes(claim, currentWinner) {
            addHardLinkDuplicate(currentWinner)
            hardLinkWinnerByIdentity[identity] = claim
        } else {
            addHardLinkDuplicate(claim)
        }
    }

    private nonisolated static func recordCloneCorrection(
        for claim: SharedAllocationClaim,
        winnerByIdentity: inout [CloneIdentity: SharedAllocationClaim],
        corrections: inout [String: Int64]
    ) {
        guard let cloneIdentity = claim.cloneIdentity,
              claim.cloneAllocatedSize > 0 else {
            return
        }
        guard let currentWinner = winnerByIdentity[cloneIdentity] else {
            winnerByIdentity[cloneIdentity] = claim
            return
        }

        if precedes(claim, currentWinner) {
            corrections[currentWinner.ownerNodeID, default: 0] += currentWinner.cloneAllocatedSize
            winnerByIdentity[cloneIdentity] = claim
        } else {
            corrections[claim.ownerNodeID, default: 0] += claim.cloneAllocatedSize
        }
    }

    private nonisolated static func precedes(_ lhs: SharedAllocationClaim, _ rhs: SharedAllocationClaim) -> Bool {
        if lhs.path == rhs.path {
            return lhs.ownerNodeID < rhs.ownerNodeID
        }
        return lhs.path < rhs.path
    }

    private nonisolated mutating func addHardLinkDuplicate(_ claim: SharedAllocationClaim) {
        hardLinkDuplicateAllocatedSizeByOwner[claim.ownerNodeID, default: 0] += claim.allocatedSize
    }
}
