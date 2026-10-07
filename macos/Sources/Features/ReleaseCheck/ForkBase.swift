/// The upstream release this fork is based on. Update it on every upstream merge (see
/// "Upgrading from upstream" in FORK.md); the release check reports only releases whose
/// major.minor is greater than this one's.
enum ForkBase {
    static let version = "1.3.1"
}
