# Archive layout

The archive is a deterministic gzip-compressed tar stream. Files are sorted,
directory metadata is normalized to a fixed epoch, and archive ownership is
normalized to root and wheel. The archive contains the same versioned payload
as the installer package.

The archive is not a model distribution. A release fails if a model byte
suffix or Core ML model directory is present.
