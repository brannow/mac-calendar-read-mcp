# calCall

Read-only MCP server for macOS calendar access via EventKit. Stdio transport.

## Requirements

- macOS 13.0+
- Swift 6.1+
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

## Build

Open in Xcode, add the MCP Swift SDK as a package dependency (select `MCP` library), add `EventKit` framework to the target, build.

Binary location after build:
```
~/Library/Developer/Xcode/DerivedData/calCall-*/Build/Products/Debug/calCall
```

## Calendar Permission

On first run, macOS prompts for calendar access. If it doesn't appear, grant it manually:

**System Settings > Privacy & Security > Calendars > calCall**

## MCP Config

Claude Code (`~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "calCall": {
      "command": "/path/to/calCall"
    }
  }
}
```

## Tools

### list_calendars

No parameters. Returns all calendars with their IDs.

```
[27B2575B-...] Work Calendar (exchange, Office 365)
[A1B2C3D4-...] Personal (local, iCloud)
```

### get_events

| Parameter | Required | Description |
|---|---|---|
| `start_date` | yes | ISO 8601 datetime, e.g. `2026-03-01T00:00:00` |
| `end_date` | yes | ISO 8601 datetime, e.g. `2026-03-04T00:00:00` |
| `calendar_ids` | no | Array of calendar IDs from `list_calendars` |
| `timezone` | no | IANA timezone, e.g. `Europe/Berlin`. Defaults to system tz |

All-day and cancelled events are excluded.

Returns per event: `id | title | start - end | duration | calendar`

```
0F68EC3B-...:4C3568A6-.../RID=794223000 | Team One Daily | 2026-03-03T10:30:00+01:00 - 2026-03-03T11:00:00+01:00 | 30min | Calendar
```

### get_event_detail

| Parameter | Required | Description |
|---|---|---|
| `event_id` | yes | Event ID from `get_events` |

Returns description, location, and URL. Does NOT return dates (use dates from `get_events`).

