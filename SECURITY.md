# Security policy

## Supported versions

SwiftMutator has no release yet. Only `main` is supported: a fix goes there, and nowhere else.
Once there are releases, the latest one and `main` will be.

## Reporting a vulnerability

Please don't report a vulnerability in a public issue, pull request or discussion.

Report it privately through GitHub: on the repository's **Security** tab, choose **Report a
vulnerability**, or go straight to
<https://github.com/Joseph-Cursio/SwiftMutator/security/advisories/new>. Only the repository's
maintainers see the report.

Please include:

- what the problem is, and what someone could do with it;
- how to reproduce it: the command, the `muter.conf.yml`, and a project or the smallest example
  that shows it;
- the SwiftMutator version or commit, your macOS version, and your Xcode or Swift version;
- a fix or a workaround, if you have one.

SwiftMutator runs your project's tests, and the commands in your `muter.conf.yml`, as you. A
configuration that runs a harmful command does what it says, so that alone isn't a
vulnerability. A way to make SwiftMutator run something its configuration and arguments don't
name, or to read or write outside the project, its copies and its logs, would be.

## What to expect

SwiftMutator has one maintainer, so this is best effort, with no set time for a reply or a fix.
Once the problem is confirmed, the fix is worked out in the private advisory, with you if
you'd like. The advisory is published once the fix is on `main`, crediting you unless you'd
rather not be.
