# Acme CRM Webhooks

Acme CRM supports manual webhook setup only. There is no public API for creating or deleting webhook subscriptions.

Supported events:

- `ticket.created`: sent when a ticket is created
- `ticket.updated`: sent when a ticket status, title, or assignee changes

All events use a JSON payload shaped like:

```json
{
  "event": "ticket.created",
  "timestamp": "2026-01-01T00:00:00Z",
  "data": {
    "ticketId": "TCK-123",
    "title": "Cannot log in",
    "status": "open",
    "assigneeEmail": "agent@example.com"
  }
}
```

Users configure webhooks from Settings > Developer > Webhooks and paste the Sim webhook URL.

