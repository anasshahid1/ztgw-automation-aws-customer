#!/usr/bin/env bash
#
# destroy_ztgw.sh — Delete an AWS ZTGW via the Zscaler REST API
#
# Reads credentials from environment variables (sourced from .zsecrc):
#   TF_VAR_client_id, TF_VAR_client_secret, TF_VAR_vanity_domain,
#   TF_VAR_cloud, TF_VAR_gateway_name
#
# Usage: ./scripts/destroy_ztgw.sh
#

set -eo pipefail

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

CLIENT_ID="${TF_VAR_client_id}"
CLIENT_SECRET="${TF_VAR_client_secret}"
VANITY_DOMAIN="${TF_VAR_vanity_domain}"
CLOUD="${TF_VAR_cloud}"
LOGIN_DOMAIN_OVERRIDE="${TF_VAR_login_domain}"
GATEWAY_NAME="${TF_VAR_gateway_name}"

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$VANITY_DOMAIN" ]; then
    echo "${RED}Zscaler credentials not found in environment. Cannot delete AWS ZTGW.${RESET}"
    exit 1
fi

if [ -z "$GATEWAY_NAME" ]; then
    echo "${YELLOW}No gateway_name set. Skipping AWS ZTGW deletion.${RESET}"
    exit 0
fi

if [ "$CLOUD" = "zscaler" ]; then
    LOGIN_DOMAIN="zslogin.net"
elif [ "$CLOUD" = "zscalerbeta" ]; then
    LOGIN_DOMAIN="zsloginbeta.net"
elif [ "$CLOUD" = "zscalerthree" ]; then
    LOGIN_DOMAIN="zsloginthree.net"
elif [ "$CLOUD" = "zscalerone" ]; then
    LOGIN_DOMAIN="zsloginone.net"
elif [ "$CLOUD" = "zscalertwo" ]; then
    LOGIN_DOMAIN="zslogintwo.net"
else
    LOGIN_DOMAIN="zslogin.net"
fi

if [ -n "$LOGIN_DOMAIN_OVERRIDE" ]; then
    LOGIN_DOMAIN="$LOGIN_DOMAIN_OVERRIDE"
    echo "${YELLOW}Using custom login domain: ${LOGIN_DOMAIN}${RESET}"
fi

TOKEN_URL="https://${VANITY_DOMAIN}.${LOGIN_DOMAIN}/oauth2/v1/token"
BASE_URL="https://connector.${CLOUD}.net/api/v1"

echo "${CYAN}Authenticating to Zscaler OneAPI...${RESET}"
TOKEN_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 30 -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" 2>/dev/null || true)

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

if [ -z "$ACCESS_TOKEN" ]; then
    echo "${RED}Authentication failed. Cannot delete AWS ZTGW.${RESET}"
    echo "${YELLOW}You may need to delete the AWS ZTGW manually from the Zscaler portal.${RESET}"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"

force_activation() {
    echo "${CYAN}Triggering force activation via OneAPI...${RESET}"
    case "${CLOUD}" in
        zscaler)      ACTIVATION_BASE="https://api.zsapi.net" ;;
        zscalerbeta)  ACTIVATION_BASE="https://api.beta.zsapi.net" ;;
        zscalerone)   ACTIVATION_BASE="https://api.one.zsapi.net" ;;
        zscalertwo)   ACTIVATION_BASE="https://api.two.zsapi.net" ;;
        zscalerthree) ACTIVATION_BASE="https://api.three.zsapi.net" ;;
        *) echo "${YELLOW}Warning: unknown cloud '${CLOUD}', skipping activation${RESET}"; return ;;
    esac

    local ACTIVATE_URL="${ACTIVATION_BASE}/ztw/api/v1/ecAdminActivateStatus/forcedActivate"
    local ACTIVATE_RESPONSE
    ACTIVATE_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 60 -X PUT "$ACTIVATE_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' 2>/dev/null || true)

    echo "Force activation response: $ACTIVATE_RESPONSE"
}

echo "${CYAN}Looking up AWS ZTGW '${GATEWAY_NAME}'...${RESET}"
EXISTING=$(curl -sk --connect-timeout 10 --max-time 30 "$BASE_URL/ztGateway?platform=AWS" -H "$AUTH_HEADER" 2>/dev/null || true)
GATEWAY_ID=$(echo "$EXISTING" | python3 -c "
import sys, json
data = json.load(sys.stdin)
gateways = data if isinstance(data, list) else data.get('list', data.get('gateways', []))
for gw in gateways:
    if gw.get('name') == '${GATEWAY_NAME}':
        print(gw['id'])
        break
" 2>/dev/null || true)

if [ -z "$GATEWAY_ID" ] || [ "$GATEWAY_ID" = "" ]; then
    echo "${YELLOW}AWS ZTGW '${GATEWAY_NAME}' not found. It may have already been deleted.${RESET}"
    exit 0
fi

echo "${CYAN}Found AWS ZTGW '${GATEWAY_NAME}' (ID: ${GATEWAY_ID}). Deleting...${RESET}"

DELETE_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 30 -X DELETE "$BASE_URL/ztGateway/$GATEWAY_ID" \
    -H "$AUTH_HEADER" \
    -w "\n%{http_code}" 2>/dev/null || true)

HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -1)
BODY=$(echo "$DELETE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "${GREEN}AWS ZTGW '${GATEWAY_NAME}' (ID: ${GATEWAY_ID}) deleted successfully.${RESET}"

    echo "${CYAN}Waiting 10s before triggering force activation...${RESET}"
    sleep 10
    force_activation
elif [ "$HTTP_CODE" = "404" ]; then
    echo "${YELLOW}AWS ZTGW '${GATEWAY_NAME}' (ID: ${GATEWAY_ID}) not found (already deleted).${RESET}"
else
    echo "${RED}Failed to delete AWS ZTGW '${GATEWAY_NAME}' (ID: ${GATEWAY_ID}). HTTP ${HTTP_CODE}${RESET}"
    echo "${RED}${BODY}${RESET}"
    echo "${YELLOW}You may need to delete the AWS ZTGW manually from the Zscaler portal.${RESET}"
    exit 1
fi
