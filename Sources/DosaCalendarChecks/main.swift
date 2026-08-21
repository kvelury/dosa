import DosaKit
import Foundation

@main
enum DosaCalendarChecks {
    static func main() {
        let failures = CalendarSelfChecks.run() + TypographySelfChecks.run()
        if failures > 0 {
            fputs("\(failures) check(s) failed.\n", stderr)
            exit(1)
        }
        print("All checks passed.")
    }
}
