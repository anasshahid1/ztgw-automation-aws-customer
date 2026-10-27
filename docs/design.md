# Design Document

## Overview

This project automates the deployment of Zscaler AWS Zero Trust Gateways (ZTGW) and their consumer-side VPC Gateway Load Balancer Endpoints using Terraform. Since no official Terraform provider exists for ZTGW resources, the Zscaler REST API is invoked via a `local_file` + `null_resource` + `local-exec` pattern (see "ZTGW Creation: Terraform Automation" below) — `data.external` was considered and rejected (see that section for why).

Two supported workflows exist side by side:
- **Pure Terraform** — a single `terraform apply` does everything via the `null_resource` pattern.
- **`zsec` wrapper** — an interactive bash script that prompts for config, caches it in `.zsecrc`, and orchestrates the same underlying script + `terraform apply`.

---

## API Discovery

No public documentation exists for the Zscaler AWS ZTGW API. The request schema was reverse-engineered by probing the live `zscalerbeta` Zscaler API:

1. **List existing gateways** — `GET /ztGateway?platform=AWS` revealed the full JSON structure of an existing AWS ZTGW, including all required and optional fields.
2. **Probe create schema** — `POST /ztGateway` with a minimal payload (`name` + `platform`) returned validation errors that revealed the next required field. This was repeated iteratively with 2s delays to respect the 1 req/s rate limit.
3. **Confirm optional fields** — Testing with and without `allowedAccounts`/`accountGroups` confirmed they are optional.

### Payload structure discovered

```json
{
  "name": "string",
  "platform": "AWS",
  "region": "us-west-2",
  "awsRegion": "US_WEST_2",
  "availabilityZoneIds": ["usw2-az1", "usw2-az2"],
  "provData": {
    "locationName": "string",
    "locationTemplate": {"id": 164780},
    "allowedAccounts": [{"id": 12345678}],
    "accountGroups": [{"id": 87654321}],
    "additionalAwsAccounts": ["123456789012"]
  }
}
```

### Account, group, and AWS account entities

`allowedAccounts` and `accountGroups` reference Zscaler-internal entities configured in the Zscaler Admin Portal. No public API endpoint was found to list or resolve them. They are both optional — if omitted, the ZTGW is created with empty arrays and can be configured later via the admin portal.

`additionalAwsAccounts` is an array of 12-digit AWS account ID strings. These whitelist specific AWS accounts to create Gateway Load Balancer Endpoints to the ZTGW endpoint service. This field is optional — if omitted, no additional AWS accounts are whitelisted (existing `allowedAccounts` mappings still apply).

---

## Key Differences from GCP ZTGW

| Aspect | GCP | AWS |
|--------|-----|-----|
| Region field | `region` | `region` + `awsRegion` (uppercase underscored) |
| AZ format | `us-central1-a` | `usw2-az1` (AWS AZ ID format) |
| IAM integration | `provData.iamPrincipals` | `provData.allowedAccounts` + `provData.accountGroups` |
| Consumer output | `interceptDeploymentGroup` | `endpointServiceName` |
| Consumer resource | GCP NSI Intercept Endpoint Group | AWS VPC Endpoint (GatewayLoadBalancer) |
| AZ discovery | Not needed (GCP AZs are predictable) | Auto-discovered via AWS CLI |

---

## Availability Zone Auto-Discovery

AWS AZ IDs (`usw2-az1`, `use1-az2`, etc.) vary per AWS account and cannot be derived from the region name alone. The `deploy_ztgw.sh` script:

1. Checks if `availability_zone_ids` is empty (`[]`)
2. If empty, runs `aws ec2 describe-availability-zones --region $region --query "AvailabilityZones[*].ZoneId" --output json`
3. If AWS CLI is not available, exits with an error instructing the user to set the variable manually

---

## Force Activation

After every ZTGW create and destroy, the script calls the OneAPI activation endpoint:

```
PUT https://api.{cloud}.zsapi.net/ztw/api/v1/ecAdminActivateStatus/forcedActivate
```

On `zscalerbeta` and non-super-admin accounts, this returns `NON_SUPER_ADMIN_FORCED_ACTIVATE_NOT_ALLOWED`. This is expected. The call is best-effort — failures are logged as warnings and do not block the deploy/destroy flow.

---

## Consumer-Side Design

The consumer VPC Endpoint follows a brownfield pattern:

- **User provides**: VPC ID, subnet IDs (one per AZ), route CIDR
- **Auto-discovered**: Route tables — a `data.aws_route_table` lookup is performed for each subnet to find its attached route table
- **Endpoint created**: One `aws_vpc_endpoint` **per subnet** — AWS requires exactly one subnet per GatewayLoadBalancer-type VPC Endpoint (unlike Interface endpoints, which accept a subnet list in one resource). An earlier version of this code passed the full subnet list to a single endpoint resource and failed with `InvalidParameter: Only one subnet can be specified for GatewayLoadBalancer type VPC Endpoint`.
- **Route created**: One `aws_route` per subnet's route table, pointing `consumer_route_cidr → that subnet's own vpc_endpoint_id`

This avoids requiring users to know their route table IDs while still being explicit about which subnets are used, and correctly supports multi-AZ redundancy (each AZ's traffic goes to its own AZ's endpoint).

### Known pitfall: shared route tables and pre-existing default routes

If two subnets share the **same** route table (common for "public" subnet pairs), you cannot add two different `0.0.0.0/0` routes to it — AWS allows only one route per destination CIDR per table. Attempting to do so fails with `RouteAlreadyExists`. This also surfaces if the route table already has an existing default route (e.g. to an Internet Gateway or NAT Gateway) — the new GWLB Endpoint route collides with it.

For true per-AZ symmetric routing, use (or create) **separate route tables per subnet/AZ** rather than relying on a shared one. This repo's `data.aws_route_table` lookup will find whatever table is currently associated with each subnet — it does not create new route tables for you. If your existing subnets share a table or already have a conflicting default route, you'll need to either point `consumer_subnet_ids` at different subnets (each with its own dedicated route table), or handle the route table restructuring outside this repo (e.g. via the AWS CLI) before running `terraform apply`.

---

## ZTGW Creation: Terraform Automation (`local_file` + `null_resource`)

Terraform cannot create the ZTGW directly (no official provider exists). Two approaches were considered:

1. **`data "external"`** — rejected. This data source re-runs on every `terraform plan`, not just `apply`. That means a plain `terraform plan` (meant to be a safe, read-only preview) would actually call the Zscaler API and attempt to create a real gateway — unacceptable.
2. **`local_file` + `null_resource` + `local-exec` provisioner** — adopted. Provisioners only run during `apply`, never `plan`, which avoids the problem above while still letting a single `terraform apply` do everything.

### How it works

```
local_file.ztgw_input   — writes the API payload (built from this run's
                           variables) to .ztgw-input.json via jsonencode()

null_resource.ztgw       — local-exec provisioner runs:
                              bash scripts/deploy_ztgw.sh < .ztgw-input.json > .ztgw-output.json
                            triggers = { gateway_name, aws_region } — only
                            re-runs if these change, so repeat applies
                            don't recreate an already-existing gateway

data.local_file.ztgw_output — depends_on null_resource.ztgw, reads the
                               script's result back into Terraform
```

### Known tradeoff: secrets in state

`local_file.ztgw_input`'s `content` includes `client_secret` (needed by the script). This means `client_secret` ends up in Terraform state (`.tfstate`) in plaintext. This was a deliberate choice — the alternative (passing secrets via the `local-exec` provisioner's `environment` block instead of a file) avoids state exposure but requires `deploy_ztgw.sh` to read from env vars instead of stdin JSON, which wasn't implemented. If you need secrets out of state, that's the next refactor to make.

### Known gap: no update-in-place for an existing gateway

If a gateway with the given `gateway_name` already exists and is healthy, `deploy_ztgw.sh` just checks its health and returns — it does **not** update `allowedAccounts`, `accountGroups`, or `additionalAwsAccounts` on an already-existing gateway. These fields are only applied at creation time. To change them on a live gateway today, you must delete and recreate it (which also means redoing the consumer-side VPC Endpoint, since the service name changes).

### Known gap: no destroy-time Zscaler cleanup from pure Terraform

`terraform destroy` removes the AWS-side resources (`aws_vpc_endpoint`, `aws_route`) and Terraform's own bookkeeping (`local_file.ztgw_input`, `null_resource.ztgw`), but there is no `provisioner "local-exec" { when = destroy ... }` block wired up to call `scripts/destroy_ztgw.sh`. This means the actual ZT Gateway is **not** deleted from Zscaler by `terraform destroy` alone — you must run `destroy_ztgw.sh` separately (see README → Destroy).

### Known issue: orphaned Location objects

Each gateway creation also creates a Zscaler **Location** object (`provData.locationName`). Deleting a gateway — whether via the Admin UI or via `destroy_ztgw.sh` — does **not** delete its associated Location. If you reuse the same `location_name` for a new gateway afterward, creation can fail with:
```json
{"code": "INVALID_INPUT_ARGUMENT", "message": "Mentioned location name already exists. Please enter new location name"}
```
Workaround: use a different `location_name` for each new gateway, or manually find/delete the orphaned Location first via `GET /location` / presumably `DELETE /location/{id}` against `https://connector.<cloud>.net/api/v1/location` (list endpoint confirmed working; delete endpoint not yet tested against this API).

### Known issue: pending activation blocks new gateway creation

Zscaler requires configuration changes to be "activated" (a staged-config → explicit-push workflow). A recent unactivated change (e.g. a gateway deletion) can block creating a new gateway with:
```json
{"code": "INVALID_OPERATION", "message": "Cannot create Zero Trust Gateway while there are pending activation changes. Please activate the pending changes first."}
```
Workaround: activate pending changes via the Admin Portal, or retry the force-activation API call, before creating a new gateway.

---

## Interactive Wrapper (`zsec`)

The `zsec` script mirrors the same structure as the GCP `ztgw-terraform-gcp` project:

1. Downloads Terraform binary for the detected OS/arch
2. Provides a 3-mode interactive menu
3. Prompts for all required and optional parameters
4. Caches configuration in `.zsecrc`
5. On destroy, deletes the ZTGW via API first, then runs `terraform destroy`
6. Archives `.zsecrc` on destroy for recovery
7. Supports `AUTO_APPROVE` env var for CI/CD

---

## File Structure

```
├── main.tf                           # local_file.ztgw_input, null_resource.ztgw,
│                                      # data.local_file.ztgw_output, aws_vpc_endpoint,
│                                      # data.aws_route_table, aws_route (one each per subnet)
├── variables.tf                      # Variables across 4 categories
├── outputs.tf                        # Outputs (ZTGW + endpoint)
├── provider.tf                       # AWS provider configuration
├── versions.tf                       # Version constraints (Terraform >= 1.0, AWS >= 5.0, local >= 2.0, null >= 3.0)
├── ztgw-full-deploy.tfvars.example   # Template for the pure-Terraform workflow
├── zsec                              # Interactive deployment wrapper (alternative workflow)
├── LICENSE                           # MIT
├── docs/
│   ├── design.md                     # This file
│   └── workflow.html                 # Visual diagram of the deployment workflow
└── scripts/
    ├── deploy_ztgw.sh      # ZTGW deployment with health polling
    └── destroy_ztgw.sh     # ZTGW deletion with force activation
```

---

## Terraform Provider

The `hashicorp/aws` provider is configured via `provider.tf` with the region set from `var.aws_endpoint_region`. No AWS credentials are hardcoded — the provider uses the standard AWS credential chain (environment variables, `~/.aws/credentials`, IAM role, etc.).

The Zscaler API can now be called **either** by pure Terraform (via the `local_file` + `null_resource` pattern described above, triggered automatically during `terraform apply`) **or** by `zsec` (which invokes `deploy_ztgw.sh` directly before running `terraform init`/`apply` itself). Both paths write the same `.ztgw-output.json`, which `data.local_file.ztgw_output` reads — this avoids the premature ZTGW creation that a plain `data.external` would trigger during `terraform plan`.
