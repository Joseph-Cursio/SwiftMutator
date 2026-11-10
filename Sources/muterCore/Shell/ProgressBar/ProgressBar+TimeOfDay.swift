#if os(Linux)
import Glibc
#else
import Darwin.C
#endif

extension ProgressBar {
    /// The seconds since 1970 by the system clock, to the microsecond.
    static func timeOfDay() -> Double {
        var time = timeval()
        gettimeofday(&time, nil)
        return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
