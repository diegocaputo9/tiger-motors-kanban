# Tiger Motors — Shared Digital Kanban

A buildless HTML/JavaScript version of the Tiger Motors training simulation.
GitHub Pages serves the interface; Supabase stores and synchronizes each room.
No Python installation or local server is needed to use the hosted site.

## Start a session

1. Open the hosted site on the instructor computer and select **Create training room**.
2. Bookmark that page: its link grants instructor access to the room.
3. Expand **Device links & room access**. Copy **Station 11**, **Station 6**, and
   **Station 1** to the other three computers/tablets. Share **Spare Tire** with
   its operator as well. More devices can show Heijunka, Inventory, or History.
4. Keep each device online with the browser visible and the screen awake.
5. Select **Start timed run** on the instructor Dashboard.

Every device joins the same production state. Each shared link is restricted to
its assigned screen and its own station action, enforced by the database.
Station devices cannot navigate to other tabs, obtain other station links, or
control the instructor Dashboard. The instructor retains all eight tabs.
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
recovers from reconnects. The database anchors a monotonic clock on each device.
Every screen shows Chicago wall time, elapsed production time, and the next batch.
Elapsed production time freezes during the interruption; wall time keeps running.
Older tablets have duration-formatting fallbacks without requiring a polyfill.
Keep devices awake: sleeping/offline browsers catch up
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

The active database lives in **diegocaputo9's Project**, Supabase project
`lnlswachpjrxoaealtpd`. All three original rooms were copied from `tiger-motors-lean`
with their state, history, instructor keys, revisions, receipts, and timestamps.
The source project was only read during this migration; nothing there was changed
or deleted. `config.js` connects the GitHub Pages site only to the destination.

`kanban_private.rooms` and `kanban_private.station_access` have RLS enabled,
no client table grants, and capability-checked RPC access. Each screen has an
independent key. Station snapshots contain only that screen's data and shared
clock/interruption fields. Cross-station RPC actions are rejected. Legacy broad
station keys are no longer accepted: existing instructor bookmarks still work,
but instructors must copy fresh assigned-screen links after refreshing the app.
Only SECURITY INVOKER wrappers are exposed by the Data API. Privileged helpers
are in a non-exposed schema with a fixed empty search path and explicit grants.
The unguessable broadcast topic carries only revision hints, never authoritative
state or instructor credentials. Receiving a forged hint cannot mutate a room.

`db/schema.sql` records the base schema; `db/station-access.sql` adds assigned-screen
permissions. On a new Supabase project, apply both files once **in that order**
with the SQL editor or migration tooling, then change `config.js`
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

## Keep-alive

GitHub Actions runs **Kanban database keep-alive** every six hours at 01:37,
07:37, 13:37, and 19:37 UTC. It works while all classroom computers are off.
It calls the read-only `kanban_keepalive` database RPC with the public publishable
key, validates the database response, and retries transient connection failures.
It neither reads room data nor inserts, resets, deletes, or changes any records.
It targets only `lnlswachpjrxoaealtpd`; Tiger Motors Lean is not contacted.

The endpoint is installed by `db/keepalive.sql`. On a fresh database, apply it
after the other schema files. Update both the workflow and `config.js` if the
destination project or publishable key changes.

View runs or start a manual check from the repository's **Actions → Kanban
database keep-alive → Run workflow**. A failed check marks the workflow as failed;
GitHub notifications follow your account's Actions notification settings.

This generates database activity to reduce inactivity pausing; Supabase does not
guarantee that a particular request rate prevents pausing on the Free plan.
GitHub may delay scheduled runs and automatically disables public-repository
schedules after 60 days without repository activity. Make a normal repository
update before then, or re-enable the workflow in Actions if it becomes disabled.
This check does not resume an already paused project and is not a data backup.

## Verification

Browser checks cover four isolated sessions, Start, the station dependency chain,
simultaneous completion of the same item, invalid keys, instructor permissions,
Realtime-only interruption/restore, offline recovery, and a narrow mobile viewport.
Additional database checks cover timed batches, pause compensation, retry deduplication,
reset generations, and inventory conservation.
Migration checks use five isolated sessions to cover all four restricted stations,
URL tampering, cross-station RPC denial, minimal snapshots, all eight clock views,
Realtime interruption/restore, pause behavior, older-tablet formatting, and zero
requests to the source project.
