# MoneyWiz importer and offline review app

Download a Bank of Georgia XLSX whenever you need it, then run the command with
no arguments:

```sh
moneywiz_import
```

It finds the newest `Report-YYYY-MM-DD.xlsx` in `~/Downloads` and asks whether to
import it. Answer yes, review the page, click **Save decisions** and save the file
in Documents or Downloads, then run the same bare command again: it finds the plan
for that statement and its decisions file, and asks whether to apply. Nothing is
created in MoneyWiz until you answer yes to that second question. The explicit
commands below do the same steps with paths you choose:

```sh
moneywiz_import import '/path/to/new-statement.xlsx'
```

The command compares the statement with a fresh MoneyWiz database backup and the
import ledger, then opens a static HTML review page. It shows **every record**, with
filters for **New**, **Need review**, **Matched**, **Skipped**, and **Decisions**.
Starting an import does not create transactions in MoneyWiz.

All Ruby files are executable and load their Gemfile automatically. On this Mac,
links in `~/.local/bin` allow the bare commands below from any directory. Inside
this folder, `./moneywiz_import.rb` also works. No `bundle exec ruby` is needed.
The launcher handles this Mac's asdf fallback to old system Ruby outside the project.

## Main workflow: each new bank export

### 0. Or let the bare command pick the files

```sh
moneywiz_import
```

With no command, the script looks for the newest `Report-YYYY-MM-DD.xlsx` in
`~/Downloads` (a browser's `Report-2026-09-26 (1).xlsx` counts as the same day and
wins when it is newer) and prints what it found. Then it decides by what already
exists for that exact file, and always asks before doing anything:

| Situation | Question | Answer yes and it runs |
| --- | --- | --- |
| No plan was built from this statement | Import it and open the review page? | `import` on that file |
| A plan exists and a decisions file for it sits beside it, in Documents, or in Downloads | Apply this plan: create its New entries in MoneyWiz? | `apply` on that plan |
| A plan exists but no decisions file was found | Reopen its review page? Then: start a fresh import instead? | `review`, or `import` |

Answering anything but `y`/`yes` exits without changes. The flow takes no files or
`--out`/`--decisions`/`--snapshot`; use the named commands for those. Running it a
third time after a successful apply offers to apply again, which is safe: rows
created earlier are recognized by their markers and skipped.

### 1. Prepare a new import

```sh
moneywiz_import import '/path/to/new-statement.xlsx'
```

Use an absolute path, or a path relative to your current terminal directory.
Overlapping dates are fine. You do not need to trim previously imported rows or
export another report from MoneyWiz.

Each `import` creates a separate folder:

```text
private/imports/<timestamp>-<run-id>/
  plan.json       Full comparison, source hashes, configuration, and decisions
  plan.csv        Spreadsheet version of all records and candidate matches
  plan.html       Self-contained offline review page with the plan embedded
  decisions.json  Your saved review decisions; you save this from the page
```

The terminal prints those paths. The page opens automatically. No server starts,
no data is uploaded, and no remote JavaScript, fonts, or other assets are loaded.

### 2. Review New and Need review

Click the summary filters, search by merchant/description/amount/date, filter by
account, or change the sort order. Records are paginated; all records remain in the
plan. Click **Review** on a row to see its original description and existing
MoneyWiz candidates.

Choose an action and click **Save decision** in the transaction panel:

| Action | Meaning |
| --- | --- |
| Import as new | Propose creating this bank transaction. Choose an existing category or leave it uncategorized. |
| Match an existing entry | Associate this bank record with a displayed MoneyWiz candidate. No new app transaction. |
| Skip — do not import | Exclude this bank record. After `apply`, the skip is remembered for future imports. Useful when a combined manual entry already covers it. |
| Defer — review later | Leave the row on review for this plan. It is not imported. Future fresh imports reconsider it. |
| Undo decision | Remove this draft decision, restoring the automatic classification; then save again. |

**Bulk actions.** Tick the checkbox on several rows, on any page and under any
filter, then use the green bar above the table. The header checkbox selects the
current page; **Select all N matching** extends the selection to every filtered
record on all pages. Bulk **Skip**, **Defer**, **Import as new**, and **Undo
decisions** ask for confirmation once and then write one draft decision per selected
row. Bulk import keeps the category shown in each row. Locked rows have no
checkbox. The bar also has a category picker with **Set category**.

**Categories.** Every importable record has a **Category** field at the top of its
detail panel. The row shows where the category came from: nothing for a category
learned from matched MoneyWiz entries of the same merchant, **chosen** for your own
choice, **merchant rule** for a rule. Whenever you choose a category, the page asks
once whether that category should **always** apply to that merchant. Yes creates an
always rule and immediately suggests the category for every other row of the
merchant that has no explicit choice. No is remembered too, so the same question is
not asked again for that merchant and category. **Ask me later** stores nothing.
Rules are keyed by the store name before the first comma in the bank's merchant
field, so `Nikora, Tbilisi` and `NIKORA, Batumi` share one rule. Review, toggle, or
forget rules under **Import details → Merchant category rules**. Rules and per-row
choices travel in the decisions file; `apply` stores the rules in the ledger so the
next `import` applies them before you open the page.

An automatically proposed **New** entry is included when applying even without
an explicit decision. Use **Defer** if it must wait. Entries still marked
**Need review** are never created automatically.

The UI will not let you override an existing import marker, saved mapping, saved
skip, or unresolved dispatch reservation. A fresh import checks that history again.

Transfers, FX, and other non-purchase rows are proposed as **New** like purchases,
but they are created uncategorized and titled with the bank row type: `Incoming
Transfer`, `Outgoing Transfer`, or `FX`. The sign of the amount decides expense or
income. The counterparty name from the statement is shown in the record panel.
MoneyWiz transfers are not created automatically: convert those records into
transfers, or recategorize them, in the app afterwards. Skip a row when it is
already covered by an existing entry. A record whose title contains "transfer" is
created without the `[bog-v1-…]` memo marker, since MoneyWiz prints the note next
to the title and you are going to rework that record by hand anyway.

### 3. Save the decisions file next to the plan

Click **Save decisions** in the header. In Chrome a file picker opens with the
suggested name `decisions.json`. Save it in this run's folder, next to `plan.json`.
Then `apply` finds it on its own and no path needs to be typed or copied.

The draft is cached in localStorage after each saved decision. Before closing the
page, save the file: browsers cannot reliably save a file during tab shutdown.
A reminder appears for unsaved changes or an unfinished form. A browser cache
is temporary recovery storage, not your durable import ledger.

A page opened from disk cannot write to its own folder or see where a file went,
so the picker has to be pointed at the run folder by hand. If the file ends up in
Documents or Downloads instead, `apply` still finds it: a JSON file there that
belongs to this exact plan is moved into the run folder and used. Safari and
Firefox have no picker and download the file, which the same lookup covers. For
any other location, set the path in the **Workflow & commands** tab, which then
adds `--decisions` to the generated command, or pass the flag yourself.

### 4. Apply

```sh
moneywiz_import apply '/path/to/run/plan.json'
```

This is the command that **creates real MoneyWiz transactions**. MoneyWiz must
already be open and finished syncing: URLs sent while the app is starting are
silently dropped, so apply refuses to run when the app is not running and waits
if it started less than 90 seconds ago. It reads `decisions.json` beside the plan
when present, or the file given with `--decisions PATH`, and then:

1. Checks source hashes and configuration, acquires the importer lock, and takes
   a fresh backup.
2. Rebuilds the comparison against that backup and the ledger with your decisions
   applied. Rows are New only if the review page showed them as New: rows you
   marked **Import as new**, plus automatic proposals you left alone.
3. Remembers matched/skipped source identities in `private/ledger.json`, along
   with your merchant category answers.
4. Reconciles again immediately before each new entry, against the backup that
   verified the previous save in this run. A row that turned ambiguous stops the
   run before anything is sent.
5. Durably reserves that entry, sends its MoneyWiz URL, and verifies the resulting
   app record through a fresh backup before moving to the next one. Transfers carry
   no marker to search for, so they are recorded as imported without a MoneyWiz ID
   and are not verified; check those in the app yourself.
6. Stops if a save cannot be confirmed. It does not blindly retry.

Review and deferred entries remain untouched. You can apply with zero New entries
to persist confirmed matches/skips without creating any transactions. With no
decisions file at all, the automatic New rows of the plan are applied as shown.

Decision files contain the complete decision set. Applying one replaces the plan's
previous decisions rather than merging with them.

### 5. Optional: preview before applying

```sh
moneywiz_import resolve '/path/to/run/plan.json' --decisions '/path/to/run/decisions.json' --open
```

This runs the same recheck as `apply` without creating anything and writes
`resolved.json`, `resolved.csv`, and `resolved.html` beside the plan. Use it when
you want to see the final New list after the fresh backup, for example after a
long pause between review and apply. You can then apply `plan.json` as above.

### 6. Next time

```sh
moneywiz_import import '/path/to/next-statement.xlsx'
```

Keep **private/ledger.json**. The new import recognizes saved transaction markers,
remembered matches/skips, and existing MoneyWiz entries. You can import the same
statement again or a wider overlapping range; you do not need to edit the XLSX.
Do not carry an old UI decisions file into a different statement: exports are
bound to their source-file hashes and will be rejected for different inputs.

## Full command list

| Command | What it does | App changes? |
| --- | --- | --- |
| `moneywiz_import` | Finds the newest `Report-YYYY-MM-DD.xlsx` in `~/Downloads`; asks before importing it, or before applying its plan once a decisions file for that plan exists. | Only after you confirm apply |
| `moneywiz_import import FILE.xlsx [MORE.xlsx …]` | Fresh comparison; saves a separate run under `private/imports/` and opens its HTML page. | No |
| `moneywiz_import plan FILE.xlsx [MORE.xlsx …]` | Same comparison; writes `private/plan.json`, `.csv`, `.html` by default without opening a browser. | No |
| `moneywiz_import review [PLAN.json]` | Regenerates and opens HTML from a saved plan. No database access. Defaults to `private/plan.json`. | No |
| `moneywiz_import apply PLAN.json [--decisions FILE.json]` | Rechecks a fresh backup with your decisions, creates the reviewed New entries via MoneyWiz URLs, verifies each save, and persists matches/skips. Reads `decisions.json` beside the plan by default. Requires an explicit plan path. | **Yes** |
| `moneywiz_import resolve PLAN.json --decisions FILE.json` | Optional preview of the same recheck; writes `resolved.*` beside the input without creating anything. | No |
| `moneywiz_import release ID` | Clears a stuck `dispatching` reservation after confirming, through a fresh backup, that MoneyWiz holds no record marked with that ID. | Ledger only |
| `moneywiz_import accounts` | Lists account names, currencies, stable IDs, and archive state using a fresh backup. | No |
| `moneywiz_import --help` | Shows commands, defaults, and flags. `-h` is equivalent. | No |
| `test_moneywiz_import.rb` | Runs importer tests using temporary databases and simulated URL delivery. | No |
| `test_review.rb` | Runs the static UI tests in headless Chrome, using temporary synthetic plans. | No |

### All options

| Option | Applies to | Meaning |
| --- | --- | --- |
| `--config PATH` | Database-backed commands | Use another configuration JSON. Default: `config.json` beside the script. |
| `--snapshot PATH` | import, plan, resolve, accounts | Use an existing database backup instead of taking a fresh one. Useful offline; it may be stale. Apply always uses fresh snapshots. |
| `--decisions PATH` | import, plan, resolve, apply | Read a raw ID-to-decision JSON map or the UI's source-bound export, which also carries per-row categories and merchant rules. Required for resolve. Apply defaults to `decisions.json` beside the plan. |
| `--out PATH.json` | import, plan, resolve | Choose the plan output path. CSV and HTML use the same stem. Resolve otherwise writes `resolved.json` beside its input. |
| `--open` | import, plan, resolve, review | Open the generated HTML. Default for import and review. |
| `--no-open` | import, plan, resolve, review | Generate files without opening a browser. |
| `-h`, `--help` | Any command | Print help and exit. |

Relative input paths are relative to your current terminal directory. Default
configuration, ledger, backup, and output paths are anchored to the script's
project directory. The browser generates absolute commands for each embedded plan.

## Other workflows

### Resume a review

Reopen the same HTML file, or run:

```sh
moneywiz_import review '/path/to/run/plan.json'
```

Its browser draft is restored for that exact plan when localStorage is available.
If using another browser or another HTML copy, use **Load decisions** to load a
saved decisions JSON. **Load plan** or drag-and-drop loads a plan JSON. A raw XLSX
must first go through `import`/`plan` in Ruby.

The standalone `review.html` in this project also opens directly without a server.
When loading a JSON manually, set its full path under **Import details** so copied
terminal commands reference the right file.

### Review only, with a chosen output

```sh
moneywiz_import plan '/path/to/statement.xlsx' --out '/path/to/run/plan.json' --open
```

### Multiple overlapping exports

```sh
moneywiz_import import '/path/to/first.xlsx' '/path/to/wider.xlsx'
```

Overlapping identities use maximum multiplicity across files, not a sum. Truly
indistinguishable repeated bank rows remain on review instead of disappearing.

### Apply a partial import

Defer unresolved New entries, save decisions, and apply the plan. Matched/skipped
entries are remembered, and remaining review entries wait.
Later, reopen the plan and revise those decisions, or start a fresh import.

### Recover after interruption

If `apply` stopped with "Transaction now requires review" or a similar recheck
error, nothing was sent for that row and no reservation exists. Rows verified
earlier in the run are recognized by their markers, so you can simply run the same
`apply` command again; it skips them and continues with the remaining New rows.

If it stopped with "Save unconfirmed", first look at MoneyWiz. If the record is
there, run a new `import` with the same statement: its marker reconciles it. If the
app shows no such record, for example because the app was not running when the URL
was sent, clear the reservation with the ID from the error message:

```sh
moneywiz_import release 'bog-v1-…'
```

Release rechecks a fresh backup for the marker and refuses when a record exists.
Never edit the ledger by hand and never resend a URL manually.

Transactions created by the importer, MoneyWiz entries already matched or
imported in the ledger, and entries exact-matched to another bank row in the same
plan are never duplicate candidates for other bank rows. A
memo marker alone is not treated as proof of authorship: MoneyWiz copies the memo
when you duplicate a record or turn one into a transfer, so an entry whose marker
does not fit its own account and amount stays available to the bank row it really
covers.

### Records you edited in MoneyWiz after importing them

Editing an imported record is expected, and the next import keeps it out of the
New list. Changing its amount or date, duplicating it, or converting it into a
transfer (which replaces it with two legs under new IDs and may drop the memo) all
leave the ledger as the durable proof that the row was created. Such rows stay
**Matched**, with the reason "imported earlier; its MoneyWiz record was edited or
removed since" when neither the marker nor the stored ID identifies the record any
more. They are never proposed again.

### Already covered by a combined or split manual entry

Compare the candidate amounts and descriptions. One-to-one **Match** requires
one bank record per app GID. If an existing combined entry covers multiple bank
rows, skip those covered rows after checking the total. Likewise, skip a bank row
already represented by several app entries after confirming the split.

### Check or change accounts

```sh
moneywiz_import accounts
```

Use the exact active account names and matching currencies in `config.json`.
The current mappings are `GEL → Solo ლ`, `USD → Solo $`, and `EUR → Solo €`.
`payees` lists merchants that should be saved with a MoneyWiz payee instead of a
description: keys are the store name before the first comma in the bank's
merchant field (case-insensitive, like merchant rules), values are the payee
name, for example `"bolt taxi": "Bolt Taxi"`. MoneyWiz creates the payee if it
does not exist; the record's description stays empty. All other merchants keep
the merchant name as description and no payee. The record panel shows **Payee**
for affected rows. After changing mappings or payees, generate a new import.
`apply` rejects a plan whose `database`, `timezone`, `accounts`, `match_days`,
`review_days`, or `payees` differ from the current config. Operational keys may change at any time:
`verification_seconds` (default 60) is how long apply waits for each save to show
up in a fresh backup; `app_process` (default none, set to `MoneyWiz`) names the
process that must be running before apply sends anything; `keep_backups`
(default 1) sets how many database backups stay in `private/backups/`.
Use `--config '/path/to/config.json'` consistently for an alternative configuration.

### Work from a retained backup

```sh
moneywiz_import plan '/path/to/statement.xlsx' --snapshot '/path/to/backup.sqlite' --open
moneywiz_import accounts --snapshot '/path/to/backup.sqlite'
```

These commands do not need to read the live MoneyWiz store. Applying always
rechecks the live state through new backups.

### Set up on another machine

Requires macOS, MoneyWiz, Ruby 3.3+, and Bundler. Tested here on Ruby 3.4.7.
From this folder, install dependencies once with `bundle install`, then use
`./moneywiz_import.rb`. To use a bare name elsewhere, place a symlink to this
script in a directory on PATH. On this Mac that link is `~/.local/bin/moneywiz_import`,
beside links for the two test scripts; if you move the project, update those links. UI tests require Google Chrome;
`CHROME_PATH` can select another Chrome/Chromium executable.

## How matching and duplicate prevention work

- Account, currency, signed amount, and purchase/posting dates drive matching.
  Reciprocal closest exact-amount matches within five days can match completely
  different titles; this is a heuristic, not proof of identity. Ties remain review.
- Near amounts, dates up to ten days apart, competing matches, and possible
  combined/split entries are flagged instead of automatically imported.
- Category precedence: your explicit per-row choice, then an "always" merchant
  rule from the ledger or the decisions file, then a category learned from at
  least three unambiguous exact matches of the merchant that all agree. Otherwise
  the URL omits category. MoneyWiz's own categorization preferences can still
  affect the saved category.
- Created records get the merchant name as description and only the source marker
  (`[bog-v1-…]`) as memo, except records titled as a transfer, which get no memo.
  Merchants listed under `payees` in `config.json` get that payee and an empty
  description instead. The full bank text stays in the plan JSON/CSV.
- Payment-service `payment code` values identify some bank rows. Card purchases
  use a SHA-256 fingerprint of bank account, currency, signed amount, purchase
  timestamp, full merchant, and card suffix. Filename and posting date are excluded
  from card fingerprints. Fallback rows use timestamp/date plus full description.
- Matched source identities map to MoneyWiz's stable `ZGID`. Imported records carry
  a source marker in the memo, supporting recovery without the ledger. When one
  marker sits on several records, the single copy matching the row's account and
  amount wins; the ledger decides when no copy does. Transfers have no marker at
  all, so `private/ledger.json` is the only thing keeping them off the New list.
- If bank amounts/descriptions change enough to alter a fingerprint, reconciliation
  still runs. Without true bank IDs, perfect automatic matching is not guaranteed.

The supplied two XLSX files both contain the same 488 bank entries for June 6–
September 5, 2026, including some earlier purchase dates. Despite their filenames,
they are bank statements, not MoneyWiz reports. The initial plan found 298 matched,
7 proposed New, and 183 needing review. These are estimates, not proof that every
proposed New record is absent.

The app provides neither an idempotency key nor a transactional success callback.
Exactly-once delivery therefore cannot be guaranteed. The ledger, process lock,
markers, fresh checks, durable reservations and stop-on-uncertainty behavior prevent
blind duplicate retries. Avoid concurrent manual/sync imports during apply: a
snapshot cannot lock MoneyWiz against another writer between checks.

## Files, privacy, and browser limits

- `private/ledger.json`: durable importer history, including merchant category
  rules and declined suggestions. Keep this across all runs.
- `private/backups/`: consistent SQLite backups including committed WAL data.
  The live connection is read-only and only used for backup; reconciliation SELECTs
  run on copies. Only the newest `keep_backups` pre-import backups are retained
  (default 1); verification copies are temporary.
- These snapshots are not a complete attachment/cloud export. The script never
  restores or directly modifies MoneyWiz's database.
- Private artifacts contain financial information. They and XLSX files are ignored
  by `.gitignore`; generated private files use owner-only permissions. Browser
  downloads follow the browser's permissions/settings.
- The HTML embeds the plan and uses localStorage only for draft decisions. It has
  no fetch requests, external assets, server, or direct financial write controls.
- Saving a file on tab exit is unreliable. Use the explicit Save/Download action.
  File-URL localStorage behavior varies by browser; private browsing, moving the
  page, or clearing browser data can lose drafts. Keep the exported decisions.

References: [MoneyWiz URL automation](https://help.wiz.money/en/articles/4525440-automate-transaction-management-with-url-schemas),
[MoneyWiz importing](https://help.wiz.money/en/collections/2553010-importing),
[MDN localStorage](https://developer.mozilla.org/en-US/docs/Web/API/Window/localStorage),
[MDN beforeunload](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event),
[MDN file saving](https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker).
