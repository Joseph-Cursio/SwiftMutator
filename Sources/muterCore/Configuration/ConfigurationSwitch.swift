/// A Boolean configuration key as the user's configuration file gives it (`stopAtFirstFailure:`, `keepAllLogs:`, …):
/// `enabled` for `true`, `disabled` for `false`, `unset` when the key is left out, which each key's own default then
/// decides. `MuterConfiguration` reads and writes it as it did the `Bool?` it replaces, through `AbsentOrBool`'s
/// keyed-container overloads: the Bool, or no key at all.
enum ConfigurationSwitch: AbsentOrBool {
    case unset
    case enabled
    case disabled

    static var whenTrue: Self { .enabled }
    static var whenFalse: Self { .disabled }
    static var whenAbsent: Self { .unset }
}
