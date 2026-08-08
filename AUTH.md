# franky-box Authentication & Authorization Architecture

This document specifies how the remote 3rd-party `franky-box` service secures agent inboxes and enables secure, credential-free outbox delegation (invitations).

---

## 1. Credential Hierarchy

When an agent registers (`POST /v1/agents`), it receives:
- **`agent_id`**: Public identifier (e.g., `billing-agent`).
- **`agent_secret`**: Master bearer token stored securely by the agent. It grants rights **only** to manage that agent's own inbox (`claim`) and outbox (`complete`, `fail`, `reject`).

---

## 2. Securing the Inbox

### Who can submit work?
Inboxes support configurable **Producer Policies**:
- **Public**: Any client can drop a task into the inbox.
- **Team-scoped**: Requires a valid team token matching the agent's `team_id`.
- **Authenticated**: Requires a signed producer token (`producer_token`).

### Who can claim work?
- `POST /v1/agents/{name}/inbox/claim` **strictly requires** the agent's `agent_secret`.
- Claims are atomic and locked by `task_id`, ensuring no two worker processes double-process the same task even if keys are leaked or retries overlap.

---

## 3. Outbox Invitation & Delegation (Per-Task Capability Tokens)

To allow another agent or human to read a task result **without** giving them the agent's master secret, `franky-box` issues **Per-Task Grant Tokens**.

### Flow:
1. Agent A completes a task:
   ```http
   POST /v1/agents/billing-agent/outbox/t-102/complete
   Authorization: Bearer <agent_secret>
   ```
2. The service returns a scoped capability grant:
   ```json
   {
     "task_id": "t-102",
     "status": "completed",
     "grant_token": "fb_grant_sig923847..._exp1724000000"
   }
   ```
3. Agent A passes this grant URL (`/v1/results/t-102?token=...`) to downstream Agent B.
4. Agent B consumes the result securely:
   ```http
   GET /v1/results/t-102?token=fb_grant_sig923847...
   ```
   The service validates signature, expiration, and revocation status independently of agent credentials.

---

## 4. Multi-Tenancy Boundary

All requests are scoped by `team_id` at the edge/gateway layer. Cross-team access attempts are intercepted and rejected with `403 Forbidden`, ensuring strict organizational isolation.
