# Publication and release gates

## Public source repository

Keep the repository private until all of these checks pass on the exact commit
that will become public:

1. Scan the current tree and complete Git history for credentials, personal
   paths, private planning material, model bytes, audio, and copied reference
   source or assets.
2. Run both Swift test suites, the clean-source audit, release workflow
   validation, and the release fixture suite.
3. Obtain explicit approval for the GitHub visibility change.
4. Change the repository to public, immediately enable
   [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository),
   and verify that **Security > Report a vulnerability** is available before
   announcing the repository.

GitHub permits private vulnerability reporting only on public repositories,
so that setting cannot be enabled while this repository remains private.

## Signed binary release

A public source repository does not claim that a signed binary release exists.
A signed binary release is blocked until all of these decisions have evidence:

1. Record the selected product name `Syrinx`, executable `syrinx`, environment
   prefix `SYRINX_`, package identity `com.dpaluy.syrinx`, service label
   `com.dpaluy.syrinx`, owner, and security contact.
2. Record the MIT project source license and add its complete license text.
3. Complete the clean-source audit with no copied reference application source,
   assets, branding, package identity, or history.
4. Record every direct dependency, model, fixture, and reference notice.
5. Complete native runtime, model lifecycle, HTTP contract, signing, and
   clean-machine verification in the later dependency tree stages.

The identity, source license, repository support process, and private
vulnerability-reporting process are defined. A signed binary release remains
blocked until the release owner and security metadata, model license review,
Apple signing, notarization, and clean-machine verification have evidence.
