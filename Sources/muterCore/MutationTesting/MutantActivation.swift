/// Whether a mutant's block ran in a run (`ActivationMarker`): `ran` if its marker was created; `didNotRun` if the run
/// reached mutated code, but not the mutant's block; `unknown` if the run showed neither, as a host that can't write
/// there doesn't. A results line holds it as `true`, `false`, or no key for `unknown` (`AbsentOrBool`).
enum MutantActivation: AbsentOrBool {
    case ran
    case didNotRun
    case unknown

    static var whenTrue: Self { .ran }
    static var whenFalse: Self { .didNotRun }
    static var whenAbsent: Self { .unknown }

    /// This, or `fallback` when it's `unknown`.
    func ifUnknown(_ fallback: Self) -> Self {
        self == .unknown ? fallback : self
    }
}
