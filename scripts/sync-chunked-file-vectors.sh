#!/bin/sh
# Copies the canonical chunked-file decrypt vectors from neutrino, the only editable copy
# (neutrino/agent_docs/chunked-file-encryption.md §11). Run after neutrino changes them; the tests
# here must then still open every case and reject every rejection.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
src="$here/../neutrino/web/packages/e2e-crypto/src/__tests__/fixtures/chunked_file_vectors.json"
dst="$here/Tests/NeutrinoCryptoTests/Fixtures/chunked_file_vectors.json"
[ -f "$src" ] || { echo "not found: $src (neutrino must be a sibling checkout)" >&2; exit 1; }
cp "$src" "$dst"
echo "synced $dst"
