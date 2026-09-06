# NovaPay Payout API Integration

## Generated files / Service

- Service: `nova_pay_payout_api_service.rb`
- Documentation: `INTEGRATION.md`
- Fixtures: `fixtures.json`

## Base URL / Servers

- `https://api.sandbox.novapay.example/v1` — Sandbox
- `https://api.novapay.example/v1` — Production

## Authentication

- Type: `apiKey`
- Scheme key: `ApiKeyAuth`
- Location: `header`
- Name: `X-API-Key`
- Credential path: `api_key`
- Decision: automatic

## Platform runtime contract

- `create_request` returns provider identity as `success(result: { id: provider_id })`; the platform stores it outside the service.
- Status requests read the stored identity from `operation.provider_operation_key`.
- Approved/rejected lifecycle transitions use `approve_operation` / `reject_operation`; in-progress returns plain success.
- Known requisites: SBP uses `operation.payout_requisite.sbp.*`; card uses `operation.payout_requisite.card_number`.
- Request variants: sbp, card.

## Operations

### create_request

- Endpoint: `POST /payouts`
- Operation ID: `createPayout`
- Decision: automatic
- Evidence: http_post, create_action_keyword, payment_semantic_keyword, request_amount_shape, request_recipient_shape, request_external_id_shape, response_provider_id_shape, response_status_shape

### fetch_status

- Endpoint: `GET /payouts/{payout_id}`
- Operation ID: `getPayoutStatus`
- Decision: automatic
- Evidence: http_get, fetch_status_keyword, fetch_payment_semantic, status_path_id_parameter, status_response_shape, status_response_id_shape

### process_callback

- Endpoint: `POST /webhooks/payout`
- Operation ID: `payoutWebhook`
- Decision: automatic
- Evidence: http_post, callback_keyword, callback_event_shape, callback_status_shape, callback_id_shape, callback_signature_header


## Field mapping

| Internal | Provider | Direction | Decision |
| --- | --- | --- | --- |
| `operation.amount` | `amount` | request | manual |
| `operation.id` | `external_id` | request | automatic |
| `operation.payout_requisite.sbp.phone` | `recipient.phone` | request | automatic |
| `operation.payout_requisite.sbp.bank_code` | `recipient.bank_code` | request | automatic |
| `operation.payout_requisite.sbp.bank_name` | `recipient.bank_name` | request | automatic |
| `operation.payout_requisite.card_number` | `recipient.card_number` | request | automatic |
| `operation.provider_operation_key` | `id` | response | automatic |
| `operation.provider_operation_key` | `payout_id` | request | automatic |

## Transformations

- `operation.amount` → `amount`: factor=100, type="money", unit="kopecks"
- `operation.id` → `external_id`: to="string", type="type_cast"
- `operation.provider_operation_key` → `id`: to="string", type="type_cast"
- `operation.provider_operation_key` → `payout_id`: to="string", type="type_cast"

## Conditions

- `amount`: required = `true`
- `amount`: minimum = `100000`
- `currency`: required = `true`
- `currency`: enum = `["RUB"]`
- `external_id`: required = `true`
- `external_id`: max_length = `64`
- `recipient`: required = `true`
- `recipient.type`: required = `true`
- `recipient.type`: enum = `["sbp", "card"]`
- `recipient.phone`: required = `true`
- `recipient.phone`: pattern = `"^7\\d{10}$"`
- `recipient.bank_code`: required_if = `{"internal_path"=>"operation.payout_requisite.sbp", "present"=>true}`
- `recipient.card_number`: required_if = `{"internal_path"=>"operation.payout_requisite.card_number", "present"=>true}`

## Status mapping

- `pending` → `in_progress`
- `processing` → `in_progress`
- `completed` → `approved`
- `failed` → `rejected`
- `cancelled` → `rejected`
- Decision: automatic

## Error mapping

| Role | HTTP | Target | Retry | Decision |
| --- | --- | --- | --- | --- |
| create_request | 400 | `bad_request` | false | automatic |
| create_request | 401 | `unauthorized` | false | automatic |
| create_request | 402 | `unprocessable_entity` | false | automatic |
| create_request | 409 | `unprocessable_entity` | false | automatic |
| create_request | 422 | `unprocessable_entity` | false | automatic |
| create_request | 429 | `too_many_requests` | Retry-After | automatic |
| create_request | 500 | `internal_server_error` | true | automatic |
| fetch_status | 401 | `unauthorized` | false | automatic |
| fetch_status | 404 | `unprocessable_entity` | false | automatic |

## Webhook

- Endpoint: `POST /webhooks/payout`
- Event path: `event`
- Status path: `status`
- Provider operation ID path: `payout_id`
- External ID path: `external_id`
- Error path: `error`
- Signature header: `X-NovaPay-Signature`
- Signature algorithm: `HMAC-SHA256`
- Signature encoding: `hex`
- Signed payload: `raw_body`
- Decision: manual

`process_callback(payload)` receives parsed JSON; webhook signature verification requires an unavailable host API for the raw body and signature header.

## ProviderGateway config

Requires manual/platform configuration.

- external_method: TODO
- gateway: TODO

## Assumptions / Manual decisions / Review notes

- 2 mapping decision(s) were confirmed manually.
- Webhook runtime access remains a host integration responsibility.

