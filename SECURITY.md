# Security policy

## Supported versions

Syrinx is pre-release software. Security fixes apply to the current `master`
branch until the project publishes versioned releases.

## Report a vulnerability

Use **Security > Report a vulnerability** in the GitHub repository. This sends
the report through GitHub private vulnerability reporting.

Do not put a vulnerability, secret, personal data, audio file, model file, or
private log in a public issue. Include the affected commit or version, impact,
reproduction steps, and any suggested mitigation in the private report.

## Security boundary

Syrinx keeps the default listener on `127.0.0.1`, requires authentication when
configured, rejects non-loopback binding, and redacts local paths from public
diagnostics.
