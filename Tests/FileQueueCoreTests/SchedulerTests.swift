import Foundation
import Testing
@testable import FileQueueCore

@Suite("Scheduler (pure rule)")
struct SchedulerTests {
    func job(_ title: String, _ disks: [String], _ state: JobState = .pending, parallel: Bool = false) -> Job {
        Job(
            title: title, operation: .trash(sources: []),
            options: JobOptions(runInParallelAnyway: parallel),
            disks: disks.map { DiskInfo(id: DiskID($0), name: $0, volumePath: "/\($0)") },
            state: state
        )
    }

    @Test("The J1–J5 example from the spec")
    func specExample() {
        let jobs = [
            job("J1", ["HD"]), job("J2", ["HD"]), job("J3", ["USB-A"]),
            job("J4", ["USB-B", "NAS"]), job("J5", ["USB-A", "NAS"]),
        ]
        let d = Scheduler.decide(jobs: jobs, maxConcurrent: 4)
        #expect(d.toStart == [jobs[0].id, jobs[2].id, jobs[3].id])
        #expect(d.waiting[jobs[1].id] == [DiskID("HD")])
        #expect(d.waiting[jobs[4].id] == [DiskID("USB-A"), DiskID("NAS")])
    }

    @Test("A later job never jumps ahead of an earlier waiting job on a shared disk")
    func noJumpingAhead() {
        let jobs = [
            job("running", ["A"], .running),
            job("earlier", ["A", "B"]), // waits for A, reserves B
            job("later", ["B"]),        // must wait behind "earlier"
            job("other", ["C"]),
        ]
        let d = Scheduler.decide(jobs: jobs, maxConcurrent: 4)
        #expect(d.toStart == [jobs[3].id])
        #expect(d.waiting[jobs[2].id] == [DiskID("B")])
    }

    @Test("Global parallel limit; jobs over the limit wait for a slot")
    func globalLimit() {
        let jobs = [job("1", ["A"]), job("2", ["B"]), job("3", ["C"])]
        let d = Scheduler.decide(jobs: jobs, maxConcurrent: 2)
        #expect(d.toStart == [jobs[0].id, jobs[1].id])
        #expect(d.waiting[jobs[2].id] == [])
    }

    @Test("'Run in parallel anyway' ignores busy disks and doesn't block others")
    func override() {
        let jobs = [
            job("running", ["A"], .running),
            job("forced", ["A"], parallel: true),
            job("normal", ["B"]),
        ]
        let d = Scheduler.decide(jobs: jobs, maxConcurrent: 4)
        #expect(d.toStart == [jobs[1].id, jobs[2].id])

        let blocked = [job("forced", ["A"], .running, parallel: true), job("normal", ["A"])]
        #expect(Scheduler.decide(jobs: blocked, maxConcurrent: 4).toStart == [blocked[1].id])
    }

    @Test("Paused jobs keep their disks but free their slot")
    func pausedHoldsDisks() {
        let jobs = [job("paused", ["A"], .paused), job("same", ["A"]), job("other", ["B"])]
        let d = Scheduler.decide(jobs: jobs, maxConcurrent: 1)
        #expect(d.toStart == [jobs[2].id])
        #expect(d.waiting[jobs[1].id] == [DiskID("A")])
    }

    @Test("On-hold jobs don't reserve disks")
    func onHoldDoesNotReserve() {
        let jobs = [job("held", ["A"], .onHold), job("next", ["A"])]
        #expect(Scheduler.decide(jobs: jobs, maxConcurrent: 4).toStart == [jobs[1].id])
    }
}

@Suite("Queue lanes")
struct LaneGroupingTests {
    func job(_ title: String, _ disks: [String]) -> Job {
        Job(title: title, operation: .trash(sources: []), options: JobOptions(),
            disks: disks.map { DiskInfo(id: DiskID($0), name: $0, volumePath: "/\($0)") })
    }

    func names(_ groups: [LaneGrouping.Group]) -> [[String]] { groups.map { $0.jobs.map(\.title) } }
    func disks(_ groups: [LaneGrouping.Group]) -> [[String]] { groups.map { $0.disks.map(\.name) } }

    @Test("A job that uses two disks appears once, in one lane named after both")
    func twoDiskJobOnce() {
        let groups = LaneGrouping.group([job("move", ["EXT-SSD-1", "500GB"])])
        #expect(names(groups) == [["move"]])
        #expect(disks(groups) == [["EXT-SSD-1", "500GB"]])
    }

    @Test("Jobs that share a disk share a lane; separate lanes run in parallel")
    func sharing() {
        let groups = LaneGrouping.group([
            job("J1", ["HD"]), job("J2", ["HD"]), job("J3", ["USB-A"]),
            job("J4", ["USB-B", "NAS"]), job("J5", ["USB-A", "NAS"]),
        ])
        // J5 links USB-A and NAS, so J3, J4 and J5 end up together.
        #expect(names(groups) == [["J1", "J2"], ["J3", "J4", "J5"]])
        #expect(disks(groups) == [["HD"], ["USB-A", "USB-B", "NAS"]])
        // Every job exactly once.
        #expect(groups.flatMap(\.jobs).count == 5)
    }

    @Test("Unrelated disks stay in separate lanes")
    func separate() {
        let groups = LaneGrouping.group([job("a", ["A"]), job("b", ["B"]), job("c", ["C", "D"])])
        #expect(names(groups) == [["a"], ["b"], ["c"]])
    }
}
