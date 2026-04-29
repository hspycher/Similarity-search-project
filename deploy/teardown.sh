#!/usr/bin/env bash
# teardown.sh — terminate the EC2 instance and delete the security group
# created by deploy.sh. Reads deploy.state.

set -euo pipefail

cd "$(dirname "$0")"
[[ -f deploy.state ]] || { echo "deploy.state not found — nothing to tear down."; exit 1; }

# shellcheck disable=SC1091
source deploy.state

log() { printf "\033[1;36m[teardown]\033[0m %s\n" "$*"; }

log "Terminating instance $INSTANCE_ID in $REGION…"
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null

log "Waiting for termination…"
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

log "Deleting security group $SG_NAME ($SG_ID)…"
# Retry briefly — ENIs sometimes take a moment to detach
for i in 1 2 3 4 5; do
    if aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null; then
        break
    fi
    log "  SG still in use, retrying ($i/5)…"
    sleep 5
done

# Key pair is intentionally NOT deleted — keep it for future deploys.
# Uncomment to also remove the key pair and local .pem:
# aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
# rm -f "${KEY_NAME}.pem"

rm -f deploy.state
log "Done."
