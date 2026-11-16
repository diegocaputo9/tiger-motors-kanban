# Tiger Motors — Shared Digital Kanban

A buildless HTML/JavaScript version of the Tiger Motors training simulation.
GitHub Pages serves the interface; Supabase stores and synchronizes each room.
No Python installation or local server is needed to use the hosted site.

## Start a session

1. Open the hosted site on the instructor computer and select **Create training room**.
2. Bookmark that page: its link grants instructor access to the room.
3. Expand **Device links & room access**. Copy **Station 11**, **Station 6**, and
   **Station 1** to the other three computers/tablets. More devices can show
   Heijunka, Inventory, Spare Tire, or History.
4. Keep each device online with the browser visible and the screen awake.
5. Select **Start timed run** on the instructor Dashboard.

Every device joins the same production state but keeps its own selected tab.
Opening a room link or refreshing does **not** reset production. The instructor
can reset the shared run explicitly. Starting a new room creates an independent run.

## Production and interruption

- 30 vehicles: 15 A, 15 T; eight Model T spare tire options.
- Five batches of six at minutes 0, 8, 16, 24, and 32.
- Station 11 withdraws from Supermarket 2 and creates a Station 6 Kanban.
- Station 6 withdraws from Supermarket 1, replenishes Supermarket 2, and creates
  a Station 1 Kanban. Station 1 replenishes Supermarket 1.
- **Trigger ransomware** shows a visual training simulation on every station,
  blocks station transactions, and pauses the shared production clock.
- The instructor Dashboard displays the incident and retains **Restore production**.
  Restore unlocks stations and compensates the production clock for the pause.
- **Reset run** resets all devices in this room.

The ransomware display is a simulation. It does not encrypt or delete files.

## Synchronization

Supabase is authoritative. Database transactions lock the room row, check the
room capability, and validate the current item before changing inventory.
Request UUIDs deduplicate retries, and a run generation prevents stale actions
after a reset. Station links cannot start, reset, interrupt, or restore a run.

Realtime Broadcast sends revision hints; clients fetch the authoritative snapshot.
A two-second refresh also catches missed events, advances scheduled batches, and
recovers from reconnects. Time comes from the database, with an offset applied to
each display's countdown. Keep devices awake: sleeping/offline browsers catch up
when they reconnect. Delivery is near realtime, not an exact simultaneous frame
across devices. If the instructor browser closes, the remaining connected stations
continue the run. If every browser closes, the next connection catches up the schedule.

Disconnected screens disable production controls. A request whose response is lost
is retried with the **same** UUID, so it cannot complete another item accidentally.

## Access and deployment

Room access keys are random UUIDs in URL fragments, separate from the public
Supabase publishable key. Keep the instructor URL private and share station URLs
only with the participants. Anyone with a room link has its granted access.
The public repository contains no instructor/station room keys or service-role key.

The database lives in the existing `tiger-motors-lean` Supabase project. Its
`kanban_private.rooms` table is separate from the learning application's tables.
It has RLS enabled, no client table grants, and capability-checked RPC access.
Only SECURITY INVOKER wrappers are exposed by the Data API. Privileged helpers
are in a non-exposed schema with a fixed empty search path and explicit grants.
The unguessable broadcast topic carries only revision hints, never authoritative
state or instructor credentials. Receiving a forged hint cannot mutate a room.

`db/schema.sql` records the one-time installed schema. On another Supabase project,
apply it once with the SQL editor or migration tooling, then change `config.js`
to that project's URL and **publishable** key. Never use a secret/service-role key.
Realtime public Broadcast must be allowed in the project's Realtime settings.
No Auth configuration changes are required.

GitHub Pages publishes the root of the `main` branch. All runtime assets are local,
including the pinned Supabase JavaScript client **2.119.0** (MIT license in `vendor/`).
The original HTML's six model images are extracted into `assets/`.

For a local preview:

```sh
python3 -m http.server 8780 --bind 127.0.0.1
```

Open `http://127.0.0.1:8780/`. This preview still connects to the configured cloud database.

## Verification

Browser checks cover four isolated sessions, Start, the station dependency chain,
simultaneous completion of the same item, invalid keys, instructor permissions,
Realtime-only interruption/restore, offline recovery, and a narrow mobile viewport.
Additional database checks cover timed batches, pause compensation, retry deduplication,
reset generations, and inventory conservation.
