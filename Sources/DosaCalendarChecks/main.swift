import DosaKit
import Foundation

@main
enum DosaCalendarChecks {
    static func main() {
        let failures = CalendarSelfChecks.run()
        if failures > 0 {
            fputs("\(failures) Calendar check(s) failed.\n", stderr)
            exit(1)
        }
        print("All Calendar checks passed.")
    }
}
