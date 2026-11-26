import Foundation

/// The disk-aware scheduling rule, as a pure function.
///
/// - Jobs whose disk sets overlap run one at a time, in queue order.
/// - Jobs whose disk sets don't overlap run in parallel.
/// - A job starts only when *all* its disks are free; running and paused jobs hold their disks.
/// - A queued job also reserves its disks, so a later job can never jump ahead of an earlier
///   job on the same disk (no starvation).
/// - `runInParallelAnyway` jobs ignore disks entirely: they don't wait and don't block.
/// - At most `maxConcurrent` jobs run at once (paused jobs don't use a slot).
public enum Scheduler {
    public struct Decision: Equatable, Sendable {
        public var toStart: [UUID] = []
        /// Disks each remaining queued job is waiting for (empty = waiting for a free slot).
        public var waiting: [UUID: Set<DiskID>] = [:]
    }

    public static func decide(jobs: [Job], maxConcurrent: Int) -> Decision {
        var busy = Set<DiskID>()
        var running = 0
        for job in jobs {
            if job.state == .running { running += 1 }
            if job.state.isStarted && !job.options.runInParallelAnyway {
                busy.formUnion(job.diskIDs)
            }
        }

        var decision = Decision()
        var reserved = Set<DiskID>()
        for job in jobs where job.state.isQueued {
            let disks = job.diskIDs
            if job.options.runInParallelAnyway {
                if running < maxConcurrent {
                    decision.toStart.append(job.id)
                    running += 1
                } else {
                    decision.waiting[job.id] = []
                }
                continue
            }
            let blockers = disks.intersection(busy.union(reserved))
            if blockers.isEmpty && running < maxConcurrent {
                decision.toStart.append(job.id)
                busy.formUnion(disks)
                running += 1
            } else {
                decision.waiting[job.id] = blockers
                reserved.formUnion(disks)
            }
        }
        return decision
    }
}

/// Groups active jobs for display: jobs that share any disk (directly or through another job)
/// go in the same lane, so each job appears exactly once and separate lanes are exactly the
/// jobs that can run in parallel with each other.
public enum LaneGrouping {
    public struct Group: Sendable, Equatable {
        /// Every disk used by the group's jobs, in first-seen order.
        public var disks: [DiskInfo]
        /// The group's jobs, in queue order.
        public var jobs: [Job]
    }

    public static func group(_ jobs: [Job]) -> [Group] {
        var groups: [Group] = []
        for job in jobs {
            // All existing groups this job touches merge into one.
            let touching = groups.indices.filter { !Set(groups[$0].disks.map(\.id)).isDisjoint(with: job.diskIDs) }
            var merged = Group(disks: [], jobs: [])
            for index in touching {
                merged.disks += groups[index].disks
                merged.jobs += groups[index].jobs
            }
            for disk in job.disks where !merged.disks.contains(where: { $0.id == disk.id }) {
                merged.disks.append(disk)
            }
            merged.jobs.append(job)
            let order = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($1.id, $0) })
            merged.jobs.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
            let insertAt = touching.first ?? groups.count
            for index in touching.reversed() { groups.remove(at: index) }
            groups.insert(merged, at: min(insertAt, groups.count))
        }
        return groups
    }
}
