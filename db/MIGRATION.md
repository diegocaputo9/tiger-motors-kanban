# Kanban project migration — November 16, 2026

- Source: `tiger-motors-lean` (`txmcwrwxqbribdhyprqu`). Source operations were read-only.
- Destination: `diegocaputo9's Project` (`lnlswachpjrxoaealtpd`).
- Cutover snapshot: 2026-11-16 17:54 UTC (11:54 AM Chicago).
- Copied all **3 original rooms**, including state, events, inventory, queues,
  instructor keys, revisions, retry receipts, and creation timestamps.
- Source/destination checksum of the copied original rows matched:
  `4d77df61c96041a5d3f468baef759de5`.
- Copied base schema, RLS, grants, and five unchanged production/helper/API routines.
  Upgraded room creation/action routines in the destination for assigned-screen access.
- Generated independent station permissions for all copied rooms. Instructor URLs
  remain valid; legacy shared station URLs must be replaced with the new links.
- No source schema, functions, data, settings, or credentials were changed or deleted.

The copy is a point-in-time cutover. Browsers still running the previous app can
continue writing to the source until reloaded. Refresh every device after the
GitHub Pages update, then share the fresh assigned-station links from the instructor
Dashboard. New source-side changes after the snapshot are not automatically mirrored.

All new application requests go to the destination project. The old source copy
is retained as requested. Test rooms in the destination are separate from the three
copied original rooms and are not included in the migration checksum.

Fresh setup: apply `schema.sql`, then `station-access.sql`. No room access keys or
private export data are stored in this repository.
