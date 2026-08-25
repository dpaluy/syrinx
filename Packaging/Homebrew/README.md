# Homebrew formula

The release tool generates a formula with an immutable versioned release URL
and the declared SHA-256 of the signed executable archive. The formula installs
the versioned payload under Homebrew's Cellar-local `libexec` directory and
symlinks the executable into `bin`. It does not invoke `/usr/sbin/installer`,
need sudo, include model bytes, download a model, or select a mutable `latest`,
`main`, or `master` URL.

The formula caveat gives the explicit model setup command,
`<executable> models install --activate`. The model manifest must be reviewed
and approved before a real formula is generated.
