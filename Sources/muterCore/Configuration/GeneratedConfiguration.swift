/// What `init` makes of a project: the configuration, and, for an Xcode project, how it chose the scheme.
struct GeneratedConfiguration: Equatable {
    let configuration: MuterConfiguration
    let scheme: SchemeChoice?
}
