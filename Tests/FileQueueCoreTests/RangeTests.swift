import Foundation
import Testing
@testable import FileQueueCore

@Suite("Grouping by ranges")
struct RangeTests {
    func video(size: Int64? = nil, minutes: Double? = nil, w: Int? = nil, h: Int? = nil, fps: Double? = nil) -> FileMetadata {
        var m = FileMetadata(); m.kind = .video
        m.size = size; m.duration = minutes.map { $0 * 60 }; m.width = w; m.height = h; m.fps = fps
        return m
    }

    func render(_ t: String, _ m: FileMetadata) -> NameTemplate.Result {
        NameTemplate.render(t, .init(metadata: m, name: "x", ext: "mp4"))
    }

    @Test("Limits in various units")
    func parsing() {
        #expect(RangeField.size.parseLimits("100MB, 1GB") == [100e6, 1e9])
        #expect(RangeField.size.parseLimits("1.5 GB,500mb") == [500e6, 1.5e9]) // sorted
        #expect(RangeField.duration.parseLimits("30m") == [1800])
        #expect(RangeField.duration.parseLimits("1h30m, 90s, 45") == [90, 2700, 5400]) // plain number = minutes
        #expect(RangeField.res.parseLimits("720p,1080p") == [720, 1080])
        #expect(RangeField.res.parseLimits("4k, 1080") == [1080, 2160])
        #expect(RangeField.fps.parseLimits("30,60fps") == [30, 60])
        #expect(RangeField.size.parseLimits("lots") == nil)
        #expect(RangeField.duration.parseLimits("") == nil)
    }

    @Test("Size ranges: the user's example")
    func size() {
        let t = "{size|100MB,1GB}"
        #expect(render(t, video(size: 50_000_000)).text == "Under 100 MB")
        #expect(render(t, video(size: 100_000_000)).text == "100 MB – 1 GB") // a limit belongs to the range above it
        #expect(render(t, video(size: 700_000_000)).text == "100 MB – 1 GB")
        #expect(render(t, video(size: 2_133_166_690)).text == "1 GB or more")
        #expect(render(t, video()).missing == ["Size"])
        #expect(!NameTemplate.needsDetails(t)) // size comes from the file system
    }

    @Test("Duration: more than 30 minutes")
    func duration() {
        let t = "{duration|30m}"
        #expect(render(t, video(minutes: 12)).text == "Under 30 min")
        #expect(render(t, video(minutes: 72)).text == "30 min or longer")
        #expect(render("{duration|10m,30m,1h}", video(minutes: 45)).text == "30 min – 1 h")
        #expect(render("{duration|1h30m}", video(minutes: 120)).text == "1 h 30 min or longer")
        #expect(NameTemplate.needsDetails(t))
    }

    @Test("Resolution: more than 720p / 1080p, judged the way videos are labelled")
    func resolution() {
        let t = "{res|720p,1080p}"
        #expect(render(t, video(w: 640, h: 480)).text == "Under 720p")
        #expect(render(t, video(w: 1280, h: 720)).text == "720p – 1080p")
        #expect(render(t, video(w: 1920, h: 1080)).text == "1080p or higher")
        #expect(render(t, video(w: 1920, h: 800)).text == "1080p or higher")  // widescreen movie is still 1080p
        #expect(render(t, video(w: 1080, h: 1920)).text == "1080p or higher")  // portrait phone video
        #expect(render(t, video(w: 3840, h: 2160)).text == "1080p or higher")
        #expect(render("{res|1080p,4k}", video(w: 3840, h: 2160)).text == "4K or higher")
    }

    @Test("Standard quality classes")
    func quality() {
        #expect(render("{quality}", video(w: 640, h: 480)).text == "SD")
        #expect(render("{quality}", video(w: 1280, h: 720)).text == "720p")
        #expect(render("{quality}", video(w: 1920, h: 800)).text == "1080p")
        #expect(render("{quality}", video(w: 2704, h: 2028)).text == "1440p") // GoPro 2.7K
        #expect(render("{quality}", video(w: 3840, h: 2160)).text == "4K")
        #expect(render("{quality}", video()).missing == ["Resolution"])
    }

    @Test("Frame rate ranges and range names for previews")
    func fpsAndNames() {
        #expect(render("{fps|30,60}", video(fps: 29.97)).text == "Under 30 fps")
        #expect(render("{fps|30,60}", video(fps: 50)).text == "30 – 60 fps")
        #expect(RangeField.size.allRangeNames([100e6, 1e9]) == ["Under 100 MB", "100 MB – 1 GB", "1 GB or more"])
        #expect(RangeField.duration.allRangeNames([1800]) == ["Under 30 min", "30 min or longer"])
    }

    @Test("Bad ranges are reported instead of filing everything as Unsorted")
    func problems() {
        #expect(NameTemplate.problem(in: "{size|abc}") != nil)
        #expect(NameTemplate.problem(in: "{colour|1,2}") != nil)
        #expect(NameTemplate.problem(in: "{nonsense}") != nil)
        #expect(NameTemplate.problem(in: "{quality}/{duration|30m}") == nil)
        #expect(NameTemplate.problem(in: "{taken:yyyy}/{1}") == nil)
        let plan = OrganizePlanner.plan(files: [url("/v/a.mp4")], root: url("/v"), options: .init(template: "{size|abc}"), metadata: [:])
        #expect(plan.error?.contains("couldn’t read the limits") == true)
    }

    @Test("Organize videos into quality / length folders")
    func organize() {
        let root = url("/v")
        let files = ["/v/a.mp4", "/v/b.mp4", "/v/c.mp4", "/v/d.mp4"].map(url)
        let md = [files[0]: video(minutes: 95, w: 1920, h: 800), files[1]: video(minutes: 5, w: 1280, h: 720),
                  files[2]: video(minutes: 45, w: 640, h: 480), files[3]: video()]
        let plan = OrganizePlanner.plan(files: files, root: root, options: .init(template: "{quality}/{duration|30m}"), metadata: md,
                                        lister: { _ in [] })
        #expect(plan.items.map { OrganizePlanner.relativePath($0.destination, root) } == [
            "1080p/30 min or longer/a.mp4", "720p/Under 30 min/b.mp4", "SD/30 min or longer/c.mp4", "Unsorted/d.mp4",
        ])
    }

    @Test("File size is part of the basic info (no reading of contents)")
    func basicSize() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.bin", String(repeating: "x", count: 12345))
        #expect(MetadataReader.readBasic(s.path("a.bin")).size == 12345)
        #expect(MetadataReader.readBasic(s.root).size == nil)
    }
}
