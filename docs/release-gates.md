# Binary release gates

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
