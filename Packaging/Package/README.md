# Installer package layout

On macOS, `pkgbuild` creates the unsigned component package from the versioned
payload root. `productsign` signs that package. The workflow then submits the
package with `xcrun notarytool`, staples the result with `xcrun stapler`, and
checks the package with `pkgutil`, `spctl`, and a quarantine assessment.

The local unsigned dry run uses a deterministic package-layout archive. It
does not call `pkgbuild`, `productsign`, `installer`, notarization, stapling,
or Gatekeeper.
