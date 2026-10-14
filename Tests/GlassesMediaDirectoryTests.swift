import Foundation

@main
enum GlassesMediaDirectoryTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    static func main() {
        // October 13 HTTP 200 response after the preceding three files were deleted.
        let empty = """
        <html><head><title>Index of /</title></head><body><h1>Index of /</h1>
        <table><tr><td><a href="/fw_upload">fw_upload/</a></td></tr>
        <tr><td><a href="/airecord">airecord/</a></td></tr></table></body></html>
        \0
        """
        check(GlassesMediaDirectory.isDirectoryListing(empty), "real HTTP directory with transport NUL is valid")
        check(GlassesMediaDirectory.fileNames(from: empty).isEmpty, "firmware/recording directories are not photos or videos")
        let populated = empty.replacingOccurrences(of: "</table>", with: """
        <tr><td><a href="/video_20261013_142314.mp4">video_20261013_142314.mp4</a></td></tr>
        <tr><td><a href="/photo_20261013_142345.jpg">photo_20261013_142345.jpg</a></td></tr>
        <tr><td><a href="/photo_20261013_142401.jpg">photo_20261013_142401.jpg</a></td></tr>
        </table>
        """)
        check(GlassesMediaDirectory.isDirectoryListing(populated), "preceding nonempty directory is valid")
        check(GlassesMediaDirectory.fileNames(from: populated) == [
            "video_20261013_142314.mp4", "photo_20261013_142345.jpg", "photo_20261013_142401.jpg"
        ], "href and visible labels do not duplicate media")
        for invalid in ["", "Error: 301", "<html><body>Sign in to Wi-Fi</body></html>",
                        "<html><title>Index of /</title><body><table>",
                        "<html><body>HTTP 500: directory unavailable</body></html>"] {
            check(!GlassesMediaDirectory.isDirectoryListing(invalid), "invalid/partial/captive response is not an empty directory")
        }
        check(GlassesMediaDirectory.isDirectoryListing(empty.uppercased()), "case-insensitive directory recognition")
        check(GlassesMediaDirectory.fileNames(from: "<a href='/a_thumb.jpg'>a_thumb.jpg</a>").isEmpty,
              "thumbnails are excluded")
        check(GlassesMediaDirectory.fileNames(from: "<a href='/a.JPG?download=1'>a.JPG</a>") == ["a.JPG"],
              "existing query stripping and media-name deduplication retained")
        print("Glasses media directory: \(assertions) assertions passed")
    }
}
