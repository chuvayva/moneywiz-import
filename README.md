# MoneyWiz importer and offline review app

Download a Bank of Georgia XLSX whenever you need it, then run:

```sh
moneywiz_import.rb import '/path/to/new-statement.xlsx'
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

### 1. Prepare a new import

```sh
moneywiz_import.rb import '/path/to/new-statement.xlsx'
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
| Undo decision | Remove this draft decision, restoring the automatic classification; then save/resolve again. |

**Bulk actions.** Tick the checkbox on several rows, on any page and under any
filter, then use the green bar above the table. The header checkbox selects the
current page; **Select all N matching** extends the selection to every filtered
record on all pages. Bulk **Skip**, **Defer**, **Import as new**, and **Undo
decisions** ask for confirmation once and then write one draft decision per selected
row. Bulk import only affects purchase rows that can be imported automatically and
keeps the category shown in each row; FX, fees, and other non-purchase rows are
reported as skipped so you can classify them individually. Locked rows have no
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

Non-purchase rows require explicit classification as external income or expense.
Do not classify transfers between your own accounts, FX, or cash withdrawals as
income/expense. Automatic historical transfer creation is not implemented.

### 3. Save the decisions file

Click **Save decisions** in the header. Where supported, a file picker saves JSON
at a location you choose. **Download JSON** always offers the download alternative.
The suggested filename is `moneywiz-decisions-<run-id>.json`.

The draft is cached in localStorage after each saved decision. Before closing the
page, export the file: browsers cannot reliably save a file during tab shutdown.
A reminder appears for unexported changes or an unfinished form. A browser cache
is temporary recovery storage, not your durable import ledger.

If the file downloads to Downloads, use its actual name and path. Browsers may
append `(1)` on repeated downloads. The **Workflow & commands** tab has an editable
field for the saved decisions path and generates correctly quoted commands.

### 4. Resolve and inspect the final plan

Copy the command from the workflow tab, or run:

```sh
moneywiz_import.rb resolve '/path/to/run/plan.json' --decisions '/path/to/moneywiz-decisions.json' --open
```

This validates the decisions, checks that the source XLSX files are unchanged,
and compares everything against a fresh backup and ledger again. It writes
`resolved.json`, `resolved.csv`, and `resolved.html` beside the input plan, then
opens the resolved page. **Nothing is created in MoneyWiz yet.**

Inspect **New** again: these are the transactions that will be created. If a
candidate became ambiguous, it remains on review. You can make further decisions,
save them, and resolve again. Exported files contain the complete decision set;
loading/resolving one replaces the previous decision set rather than merging it.

### 5. Apply

```sh
moneywiz_import.rb apply '/path/to/run/resolved.json'
```

This is the command that **creates real MoneyWiz transactions**. It:

1. Checks source hashes and configuration, acquires the importer lock, and takes
   a fresh backup.
2. Rechecks existing entries and remembers matched/skipped source identities in
   `private/ledger.json`.
3. Reconciles again immediately before each new entry.
4. Durably reserves that entry, sends its MoneyWiz URL, and verifies the resulting
   app record through a fresh backup before moving to the next one.
5. Stops if a save cannot be confirmed. It does not blindly retry.

Review and deferred entries remain untouched. You can apply with zero New entries
to persist confirmed matches/skips without creating any transactions.

If you changed no decisions and all automatically proposed New entries are
correct, you can apply `plan.json` directly and omit the save/resolve steps.

### 6. Next time

```sh
moneywiz_import.rb import '/path/to/next-statement.xlsx'
```

Keep **private/ledger.json**. The new import recognizes saved transaction markers,
remembered matches/skips, and existing MoneyWiz entries. You can import the same
statement again or a wider overlapping range; you do not need to edit the XLSX.
Do not carry an old UI decisions file into a different statement: exports are
bound to their source-file hashes and will be rejected for different inputs.

## Full command list

| Command | What it does | App changes? |
| --- | --- | --- |
| `moneywiz_import.rb import FILE.xlsx [MORE.xlsx …]` | Fresh comparison; saves a separate run under `private/imports/` and opens its HTML page. | No |
| `moneywiz_import.rb plan FILE.xlsx [MORE.xlsx …]` | Same comparison; writes `private/plan.json`, `.csv`, `.html` by default without opening a browser. | No |
| `moneywiz_import.rb review [PLAN.json]` | Regenerates and opens HTML from a saved plan. No database access. Defaults to `private/plan.json`. | No |
| `moneywiz_import.rb resolve PLAN.json --decisions FILE.json` | Validates the complete decision set against unchanged sources and a fresh backup; writes `resolved.*` beside the input. | No |
| `moneywiz_import.rb apply PLAN.json` | Creates planned New entries via MoneyWiz URLs, verifies each save, and persists matches/skips. Requires an explicit plan path. | **Yes** |
| `moneywiz_import.rb accounts` | Lists account names, currencies, stable IDs, and archive state using a fresh backup. | No |
| `moneywiz_import.rb --help` | Shows commands, defaults, and flags. `-h` is equivalent. | No |
| `test_moneywiz_import.rb` | Runs importer tests using temporary databases and simulated URL delivery. | No |
| `test_review.rb` | Runs the static UI tests in headless Chrome, using temporary synthetic plans. | No |

### All options

| Option | Applies to | Meaning |
| --- | --- | --- |
| `--config PATH` | Database-backed commands | Use another configuration JSON. Default: `config.json` beside the script. |
| `--snapshot PATH` | import, plan, resolve, accounts | Use an existing database backup instead of taking a fresh one. Useful offline; it may be stale. Apply always uses fresh snapshots. |
| `--decisions PATH` | import, plan, resolve | Read a raw ID-to-decision JSON map or the UI's source-bound export, which also carries per-row categories and merchant rules. Required for resolve. |
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
moneywiz_import.rb review '/path/to/run/plan.json'
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
moneywiz_import.rb plan '/path/to/statement.xlsx' --out '/path/to/run/plan.json' --open
```

### Multiple overlapping exports

```sh
moneywiz_import.rb import '/path/to/first.xlsx' '/path/to/wider.xlsx'
```

Overlapping identities use maximum multiplicity across files, not a sum. Truly
indistinguishable repeated bank rows remain on review instead of disappearing.

### Apply a partial import

Defer unresolved New entries, save decisions, resolve, and apply the resolved
plan. Matched/skipped entries are remembered, and remaining review entries wait.
Later, reopen the plan and revise those decisions, or start a fresh import.

### Recover after interruption

If `apply` stopped with "Transaction now requires review" or a similar recheck
error, nothing was sent for that row and no reservation exists. Rows verified
earlier in the run are recognized by their markers, so you can simply run the same
`apply` command again; it skips them and continues with the remaining New rows.

If it stopped with "Save unconfirmed", run a new `import` with the same statement.
If MoneyWiz saved after the timeout, its marker allows reconciliation. Otherwise
the reservation remains locked on review. Do not delete the ledger or send the URL
again: the prior outcome may be uncertain. There is no automatic reset/retry command.

Transactions created by the importer, and MoneyWiz entries already matched or
imported in the ledger, are never duplicate candidates for other bank rows.

### Already covered by a combined or split manual entry

Compare the candidate amounts and descriptions. One-to-one **Match** requires
one bank record per app GID. If an existing combined entry covers multiple bank
rows, skip those covered rows after checking the total. Likewise, skip a bank row
already represented by several app entries after confirming the split.

### Check or change accounts

```sh
moneywiz_import.rb accounts
```

Use the exact active account names and matching currencies in `config.json`.
The current mappings are `GEL → Solo ლ`, `USD → Solo $`, and `EUR → Solo €`.
After changing mappings, generate a new import. `apply` rejects a changed config.
Use `--config '/path/to/config.json'` consistently for an alternative configuration.

### Work from a retained backup

```sh
moneywiz_import.rb plan '/path/to/statement.xlsx' --snapshot '/path/to/backup.sqlite' --open
moneywiz_import.rb accounts --snapshot '/path/to/backup.sqlite'
```

These commands do not need to read the live MoneyWiz store. Applying always
rechecks the live state through new backups.

### Set up on another machine

Requires macOS, MoneyWiz, Ruby 3.3+, and Bundler. Tested here on Ruby 3.4.7.
From this folder, install dependencies once with `bundle install`, then use
`./moneywiz_import.rb`. To use a bare name elsewhere, place a symlink to this
script in a directory on PATH. The existing links on this Mac point into this
project; if you move it, update those links. UI tests require Google Chrome;
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
  the URL omits category and retains the full bank description. MoneyWiz's own
  categorization preferences can still affect the saved category.
- Payment-service `payment code` values identify some bank rows. Card purchases
  use a SHA-256 fingerprint of bank account, currency, signed amount, purchase
  timestamp, full merchant, and card suffix. Filename and posting date are excluded
  from card fingerprints. Fallback rows use timestamp/date plus full description.
- Matched source identities map to MoneyWiz's stable `ZGID`. Imported records carry
  a source marker in description and memo, supporting recovery without the ledger.
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
  run on copies. Pre-import backups are retained; verification copies are temporary.
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
