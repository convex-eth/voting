#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

METADATA_FILE="${METADATA_FILE:-deployment/proposal-metadata-replacement-mainnet.json}"
MAINNET_DEPLOYMENT_FILE="${MAINNET_DEPLOYMENT_FILE:-deployment/mainnet.json}"
CHAIN="${CHAIN:-mainnet}"
RPC_URL="${RPC_URL:-${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}}"
VERIFIER="${VERIFIER:-etherscan}"
COMPILER_VERSION="${COMPILER_VERSION:-0.8.35}"
WATCH="${WATCH:-1}"
DRY_RUN="${DRY_RUN:-0}"

if [[ ! -f "$METADATA_FILE" ]]; then
  echo "Missing metadata deployment file: $METADATA_FILE" >&2
  exit 1
fi

if [[ ! -f "$MAINNET_DEPLOYMENT_FILE" ]]; then
  echo "Missing mainnet deployment file: $MAINNET_DEPLOYMENT_FILE" >&2
  exit 1
fi

if [[ "$VERIFIER" == "etherscan" && -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "ETHERSCAN_API_KEY is required for Etherscan verification" >&2
  exit 1
fi

addr() {
  local file="$1"
  local key="$2"
  node -e '
const fs = require("fs");
const file = process.argv[1];
const key = process.argv[2];
const deployment = JSON.parse(fs.readFileSync(file, "utf8"));
if (!deployment[key]) {
  console.error(`Missing ${key} in ${file}`);
  process.exit(1);
}
console.log(deployment[key]);
' "$file" "$key"
}

encode() {
  cast abi-encode "$@"
}

failures=0

verify_metadata() {
  local label="$1"
  local address="$2"
  local name="$3"

  local cmd=(
    forge verify-contract
    "$address"
    src/ProposalMetadata.sol:ProposalMetadata
    --chain "$CHAIN"
    --rpc-url "$RPC_URL"
    --verifier "$VERIFIER"
    --compiler-version "$COMPILER_VERSION"
    --num-of-optimizations 200
    --via-ir
    --constructor-args "$(encode 'constructor(string,address)' "$name" "$CORE")"
  )

  if [[ "$VERIFIER" == "etherscan" ]]; then
    cmd+=(--etherscan-api-key "$ETHERSCAN_API_KEY")
  fi

  if [[ "$WATCH" != "0" ]]; then
    cmd+=(--watch)
  fi

  echo
  echo "==> Verifying $label at $address"
  echo "    src/ProposalMetadata.sol:ProposalMetadata"
  echo "    name: $name"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %q' "${cmd[@]}"
    echo
    return 0
  fi

  if ! "${cmd[@]}"; then
    echo "FAILED: $label" >&2
    failures=$((failures + 1))
  fi
}

CORE="$(addr "$MAINNET_DEPLOYMENT_FILE" ConvexCore)"

echo "Using metadata deployment: $METADATA_FILE"
echo "Using main deployment:     $MAINNET_DEPLOYMENT_FILE"
echo "Using owner/core:          $CORE"
echo "Using chain:               $CHAIN"
echo "Using RPC:                 $RPC_URL"
echo "Using verifier:            $VERIFIER"

verify_metadata "FxProposalMetadata" "$(addr "$METADATA_FILE" FxProposalMetadata)" "Fx Proposal Metadata"
verify_metadata "FraxProposalMetadata" "$(addr "$METADATA_FILE" FraxProposalMetadata)" "Frax Proposal Metadata"
verify_metadata "ConvexProposalMetadata" "$(addr "$METADATA_FILE" ConvexProposalMetadata)" "Convex Proposal Metadata"

if [[ "$failures" -ne 0 ]]; then
  echo
  echo "$failures verification command(s) failed" >&2
  exit 1
fi

echo
echo "All metadata verification commands completed"
