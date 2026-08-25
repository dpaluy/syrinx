# Packaging contract

The release tool creates all packaging assets from a clean exact tag. The
selected product identity is `Syrinx`, with executable `syrinx`, package
identifier `com.dpaluy.syrinx`, and service label `com.dpaluy.syrinx`.

The installer package contains the immutable versioned payload under:

```text
/Library/Application Support/<product-identity>/
  versions/<version>/<executable>
```

The package does not create a system `current` pointer. The service lifecycle
owns the per-user materialized runtime contract, relative to its data root:

```text
service/versions/<version>/<payload>
service/selection.json
```

The service lifecycle writes `selection.json` and selects a version from that
per-user store.
The package remains an immutable source for that copy. This keeps the
installed version immutable and gives the lifecycle code a safe upgrade and
rollback target without claiming a system-wide pointer.

The package includes the executable, any required signed Swift compatibility
dylibs, release metadata, the immutable model
manifest and attribution notice, the source license, third-party licenses and
notices, compatibility metadata, support metadata, and the changelog. Model
files and model weights are never included and are never downloaded by the
release workflow or Homebrew formula.

`scripts/release/release.py build --sign` creates the signed archive, exact-tag
source archive, signed
and notarized installer package, license archive, formula, SPDX 2.3 SBOM,
SLSA-compatible in-toto provenance, manifest digest, inventory, checksums, and
detached signature. `--unsigned-dry-run` creates a package-layout archive and a
fixture signature marker without Apple signing or external publication.
