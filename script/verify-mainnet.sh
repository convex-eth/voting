#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

DEPLOYMENT_FILE="${DEPLOYMENT_FILE:-deployment/mainnet.json}"
CHAIN="${CHAIN:-mainnet}"
RPC_URL="${RPC_URL:-${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}}"
VERIFIER="${VERIFIER:-etherscan}"
COMPILER_VERSION="${COMPILER_VERSION:-0.8.35}"
WATCH="${WATCH:-1}"
DRY_RUN="${DRY_RUN:-0}"

VLCVX="0x72a19342e8F1838460eBFCCEf09F6585e32db86E"
DEFAULT_QUORUM="1500"

if [[ ! -f "$DEPLOYMENT_FILE" ]]; then
  echo "Missing deployment file: $DEPLOYMENT_FILE" >&2
  exit 1
fi

if [[ "$VERIFIER" == "etherscan" && -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "ETHERSCAN_API_KEY is required for Etherscan verification" >&2
  exit 1
fi

addr() {
  local key="$1"
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
' "$DEPLOYMENT_FILE" "$key"
}

encode() {
  cast abi-encode "$@"
}

failures=0

verify_contract() {
  local label="$1"
  local address="$2"
  local contract="$3"
  local constructor_args="${4:-}"

  local cmd=(
    forge verify-contract
    "$address"
    "$contract"
    --chain "$CHAIN"
    --rpc-url "$RPC_URL"
    --verifier "$VERIFIER"
    --compiler-version "$COMPILER_VERSION"
    --num-of-optimizations 200
    --via-ir
  )

  if [[ "$VERIFIER" == "etherscan" ]]; then
    cmd+=(--etherscan-api-key "$ETHERSCAN_API_KEY")
  fi

  if [[ "$WATCH" != "0" ]]; then
    cmd+=(--watch)
  fi

  if [[ -n "$constructor_args" ]]; then
    cmd+=(--constructor-args "$constructor_args")
  fi

  echo
  echo "==> Verifying $label at $address"
  echo "    $contract"

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

CORE="$(addr ConvexCore)"
VOTE_DELEGATE="$(addr VoteDelegateExtension)"
DAO_DELEGATION="$(addr DaoDelegation)"
GAUGE_DELEGATION="$(addr GaugeDelegation)"
SURROGATE="$(addr SurrogateRegistry)"

CURVE_DAO_VOTING="$(addr CurveDaoVoting)"
CURVE_GAUGE_VOTING="$(addr CurveGaugeVoting)"
CURVE_GAUGE_REGISTRY="$(addr CurveGaugeRegistry)"

FX_DAO_VOTING="$(addr FxDaoVoting)"
FX_GAUGE_VOTING="$(addr FxGaugeVoting)"
FX_GAUGE_REGISTRY="$(addr FxGaugeRegistry)"

FRAX_DAO_VOTING="$(addr FraxDaoVoting)"
CONVEX_DAO_VOTING="$(addr ConvexDaoVoting)"
RESUPPLY_DAO_VOTING="$(addr ResupplyDaoVoting)"

echo "Using deployment: $DEPLOYMENT_FILE"
echo "Using chain:      $CHAIN"
echo "Using RPC:        $RPC_URL"
echo "Using verifier:   $VERIFIER"
echo "Skipping existing ConvexCore and VoteDelegateExtension"

verify_contract "VotingRegistry" "$(addr VotingRegistry)" \
  "src/VotingRegistry.sol:VotingRegistry" \
  "$(encode 'constructor(address)' "$CORE")"

verify_contract "DaoDelegation" "$DAO_DELEGATION" \
  "src/Delegation.sol:Delegation" \
  "$(encode 'constructor(string,address,address)' 'Dao Delegation' "$CORE" "$VLCVX")"

verify_contract "GaugeDelegation" "$GAUGE_DELEGATION" \
  "src/Delegation.sol:Delegation" \
  "$(encode 'constructor(string,address,address)' 'Gauge Delegation' "$CORE" "$VLCVX")"

verify_contract "SurrogateRegistry" "$SURROGATE" \
  "src/SurrogateRegistry.sol:SurrogateRegistry" \
  "$(encode 'constructor(string)' 'Convex Surrogate Registry')"

verify_contract "CurveGaugeRegistry" "$CURVE_GAUGE_REGISTRY" \
  "src/CurveGaugeRegistry.sol:CurveGaugeRegistry" \
  "$(encode 'constructor(string,address,uint256[])' 'Curve Gauge Registry' "$CORE" '[0,1,2,3,4,5,6,7,8,9,10]')"

verify_contract "CurveDaoVoting" "$CURVE_DAO_VOTING" \
  "src/DaoVotePlatform.sol:DaoVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address)' 'Curve Dao Voting' "$CORE" "$VLCVX" "$SURROGATE" "$DAO_DELEGATION")"

verify_contract "CurveGaugeVoting" "$CURVE_GAUGE_VOTING" \
  "src/GaugeVotePlatform.sol:GaugeVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address,address)' 'Curve Gauge Voting' "$CORE" "$VLCVX" "$CURVE_GAUGE_REGISTRY" "$SURROGATE" "$GAUGE_DELEGATION")"

verify_contract "CurveVoteExecutor" "$(addr CurveVoteExecutor)" \
  "src/CurveVoteExecutor.sol:CurveVoteExecutor" \
  "$(encode 'constructor(string,address,address,address,uint256)' 'Curve Vote Executor' "$CORE" "$CURVE_DAO_VOTING" "$VOTE_DELEGATE" "$DEFAULT_QUORUM")"

verify_contract "CurveGaugeExecutor" "$(addr CurveGaugeExecutor)" \
  "src/CurveGaugeExecutor.sol:CurveGaugeExecutor" \
  "$(encode 'constructor(string,address,address)' 'Curve Gauge Executor' "$CURVE_GAUGE_VOTING" "$VOTE_DELEGATE")"

verify_contract "GaugeVoteHelper" "$(addr GaugeVoteHelper)" \
  "src/GaugeVoteHelper.sol:GaugeVoteHelper" \
  "$(encode 'constructor(string,address)' 'Gauge Vote Helper' "$GAUGE_DELEGATION")"

verify_contract "CurveDaoProposer" "$(addr CurveDaoProposer)" \
  "src/CurveDaoProposer.sol:CurveDaoProposer" \
  "$(encode 'constructor(string,address,address)' 'Curve Dao Proposer' "$CORE" "$CURVE_DAO_VOTING")"

verify_contract "CurveGaugeProposer" "$(addr CurveGaugeProposer)" \
  "src/GaugeProposer.sol:GaugeProposer" \
  "$(encode 'constructor(string,address,address,address)' 'Curve Gauge Proposer' "$CORE" "$VLCVX" "$CURVE_GAUGE_VOTING")"

verify_contract "FxGaugeRegistry" "$FX_GAUGE_REGISTRY" \
  "src/FxGaugeRegistry.sol:FxGaugeRegistry" \
  "$(encode 'constructor(string,address,uint256[])' 'Fx Gauge Registry' "$CORE" '[]')"

verify_contract "FxDaoVoting" "$FX_DAO_VOTING" \
  "src/DaoVotePlatform.sol:DaoVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address)' 'Fx Dao Voting' "$CORE" "$VLCVX" "$SURROGATE" "$DAO_DELEGATION")"

verify_contract "FxGaugeVoting" "$FX_GAUGE_VOTING" \
  "src/GaugeVotePlatform.sol:GaugeVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address,address)' 'Fx Gauge Voting' "$CORE" "$VLCVX" "$FX_GAUGE_REGISTRY" "$SURROGATE" "$GAUGE_DELEGATION")"

verify_contract "FxDaoProposer" "$(addr FxDaoProposer)" \
  "src/GenericDaoProposer.sol:GenericDaoProposer" \
  "$(encode 'constructor(string,address,address)' 'Fx Dao Proposer' "$CORE" "$FX_DAO_VOTING")"

verify_contract "FxProposalMetadata" "$(addr FxProposalMetadata)" \
  "src/ProposalMetadata.sol:ProposalMetadata" \
  "$(encode 'constructor(string,address)' 'Fx Proposal Metadata' "$CORE")"

verify_contract "FxGaugeProposer" "$(addr FxGaugeProposer)" \
  "src/GaugeProposer.sol:GaugeProposer" \
  "$(encode 'constructor(string,address,address,address)' 'Fx Gauge Proposer' "$CORE" "$VLCVX" "$FX_GAUGE_VOTING")"

verify_contract "FxGaugeExecutor" "$(addr FxGaugeExecutor)" \
  "src/FxGaugeExecutor.sol:FxGaugeExecutor" \
  "$(encode 'constructor(string,address,address)' 'Fx Gauge Executor' "$FX_GAUGE_VOTING" "$CORE")"

verify_contract "FraxDaoVoting" "$FRAX_DAO_VOTING" \
  "src/DaoVotePlatform.sol:DaoVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address)' 'Frax Dao Voting' "$CORE" "$VLCVX" "$SURROGATE" "$DAO_DELEGATION")"

verify_contract "FraxDaoProposer" "$(addr FraxDaoProposer)" \
  "src/GenericDaoProposer.sol:GenericDaoProposer" \
  "$(encode 'constructor(string,address,address)' 'Frax Dao Proposer' "$CORE" "$FRAX_DAO_VOTING")"

verify_contract "FraxProposalMetadata" "$(addr FraxProposalMetadata)" \
  "src/ProposalMetadata.sol:ProposalMetadata" \
  "$(encode 'constructor(string,address)' 'Frax Proposal Metadata' "$CORE")"

verify_contract "ConvexDaoVoting" "$CONVEX_DAO_VOTING" \
  "src/DaoVotePlatform.sol:DaoVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address)' 'Convex Dao Voting' "$CORE" "$VLCVX" "$SURROGATE" "$DAO_DELEGATION")"

verify_contract "ConvexDaoProposer" "$(addr ConvexDaoProposer)" \
  "src/GenericDaoProposer.sol:GenericDaoProposer" \
  "$(encode 'constructor(string,address,address)' 'Convex Dao Proposer' "$CORE" "$CONVEX_DAO_VOTING")"

verify_contract "ConvexProposalMetadata" "$(addr ConvexProposalMetadata)" \
  "src/ProposalMetadata.sol:ProposalMetadata" \
  "$(encode 'constructor(string,address)' 'Convex Proposal Metadata' "$CORE")"

verify_contract "ResupplyDaoVoting" "$RESUPPLY_DAO_VOTING" \
  "src/DaoVotePlatform.sol:DaoVotePlatform" \
  "$(encode 'constructor(string,address,address,address,address)' 'Resupply Dao Voting' "$CORE" "$VLCVX" "$SURROGATE" "$DAO_DELEGATION")"

verify_contract "ResupplyVoteExecutor" "$(addr ResupplyVoteExecutor)" \
  "src/ResupplyVoteExecutor.sol:ResupplyVoteExecutor" \
  "$(encode 'constructor(string,address,address,uint256)' 'Resupply Vote Executor' "$CORE" "$RESUPPLY_DAO_VOTING" "$DEFAULT_QUORUM")"

verify_contract "ResupplyDaoProposer" "$(addr ResupplyDaoProposer)" \
  "src/ResupplyDaoProposer.sol:ResupplyDaoProposer" \
  "$(encode 'constructor(string,address,address)' 'Resupply Dao Proposer' "$CORE" "$RESUPPLY_DAO_VOTING")"

if [[ "$failures" -ne 0 ]]; then
  echo
  echo "$failures verification command(s) failed" >&2
  exit 1
fi

echo
echo "All verification commands completed"
