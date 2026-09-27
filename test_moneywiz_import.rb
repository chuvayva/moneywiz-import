#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "moneywiz_import"
require "minitest/autorun"
require "stringio"
require "minitest/mock"
require "tmpdir"

class MoneyWizImportTest < Minitest::Test
  M = MoneyWizImport
  FakeReference = Struct.new(:accounts, :transactions, :category_paths) do
    def marker(id)
      transactions.select { |t| "#{t['description']} #{t['memo']}".include?("[#{id}]") }
    end
  end

  def setup
    @config = { "accounts" => { "GEL" => "Solo ლ" }, "match_days" => 5, "review_days" => 10, "verification_seconds" => 0 }
    @account = { "pk" => 1, "gid" => "account-1", "name" => "Solo ლ", "currency" => "GEL", "archived" => false }
  end

  # Real bank IDs; the importer only treats a memo as its own marker in this form.
  MARKED_IDS = ["bog-v1-#{'a' * 64}-1", "bog-v1-#{'b' * 64}-1"].freeze

  def bank(id: "bank1", amount: -1000, date: "2026-09-01", **extra)
    { "id" => id, "account" => "Solo ლ", "currency" => "GEL", "cents" => amount, "occurred" => "#{date} 12:00:00", "posted" => date,
      "merchant" => "Shop, Tbilisi", "payee" => "Shop", "description" => "Bank description & details", "kind" => "Payment", "indistinguishable_count" => 1, "row" => 2 }.merge(extra.transform_keys(&:to_s))
  end

  def transaction(id: "app1", amount: -1000, date: "2026-09-01", **extra)
    { "gid" => id, "account" => "Solo ლ", "currency" => "GEL", "cents" => amount, "date" => date, "description" => "Groceries", "memo" => "", "payee" => "", "category" => "Groceries" }.merge(extra.transform_keys(&:to_s))
  end

  def plan(banks, transactions, ledger: {}, decisions: {}, categories: {}, rules: {})
    reference = FakeReference.new([@account], transactions, { 1 => "Groceries", 2 => "Cafe" })
    M::Planner.new(banks, reference, @config, ledger: ledger, decisions: decisions, categories: categories, rules: rules).build
  end

  def test_category_override_and_always_rule_beat_learning_and_declined_rule_does_not
    banks = (1..4).map { |i| bank(id: "b#{i}", amount: -1000 * i) }
    transactions = (1..3).map { |i| transaction(id: "t#{i}", amount: -1000 * i) }
    learned = plan(banks, transactions).last
    assert_equal %w[Groceries learned], [learned["category"], learned["category_source"]]
    ruled = plan(banks, transactions, rules: { "shop" => { "category" => "Cafe", "always" => true } }).last
    assert_equal %w[Cafe rule], [ruled["category"], ruled["category_source"]]
    declined = plan(banks, transactions, rules: { "shop" => { "category" => "Cafe", "always" => false } }).last
    assert_equal "Groceries", declined["category"]
    explicit = plan(banks, transactions, categories: { "b4" => "Cafe" }, rules: { "shop" => { "category" => "Groceries", "always" => true } }).last
    assert_equal %w[Cafe decision], [explicit["category"], explicit["category_source"]]
    uncategorized = plan(banks, transactions, categories: { "b4" => nil }).last
    assert_nil uncategorized["category"]
    assert_equal "decision", uncategorized["category_source"]
    assert_includes M.url(plan([bank(id: "b9")], [], categories: { "b9" => "Cafe" }).first), "category=Cafe"
    assert_raises(M::Error) { plan(banks, transactions, categories: { "b4" => "Unknown" }) }
    assert_raises(M::Error) { plan(banks, transactions, rules: { "shop" => { "category" => "Cafe" } }) }
  end

  def test_decision_file_carries_overrides_and_rules
    Dir.mktmpdir do |dir|
      source = File.join(dir, "s.xlsx")
      File.write(source, "x")
      sources = [{ "path" => source, "sha256" => Digest::SHA256.file(source).hexdigest }]
      path = File.join(dir, "d.json")
      File.write(path, JSON.generate("type" => "moneywiz-decisions", "version" => 1, "source_hashes" => [sources.first["sha256"]],
                                     "decisions" => { "b1" => { "action" => "skip" } }, "category_overrides" => { "b2" => "Cafe", "b3" => nil },
                                     "merchant_rules" => { "nikora" => { "category" => "Groceries", "always" => true }, "wolt" => { "category" => "Cafe", "always" => false } }))
      file = M::CLI.read_decision_file(path, sources)
      assert_equal({ "b1" => { "action" => "skip" } }, file["decisions"])
      assert_equal({ "b2" => "Cafe", "b3" => nil }, file["category_overrides"])
      assert_equal false, file.dig("merchant_rules", "wolt", "always")
      assert_equal file["decisions"], M::CLI.read_decisions(path, sources)
      File.write(path, JSON.generate("b1" => { "action" => "defer" }))
      assert_equal({}, M::CLI.read_decision_file(path, sources)["merchant_rules"])
      File.write(path, JSON.generate("type" => "moneywiz-decisions", "version" => 1, "source_hashes" => [sources.first["sha256"]], "decisions" => {}, "merchant_rules" => { "nikora" => { "category" => "" , "always" => true } }))
      assert_raises(M::Error) { M::CLI.read_decision_file(path, sources) }
    end
  end

  def test_exact_money_and_escaped_url
    assert_equal 100000, M.cents("1,000.00")
    assert_equal "-0.26", M.money(-26)
    entry = bank(description: "Café + bread & 50% [x]", payee: "Café & Co", status: "new")
    url = M.url(entry)
    params = URI.decode_www_form(URI(url).query).to_h
    assert_equal "Soloლ", params["account"]
    assert_equal "10.00", params["amount"]
    assert_equal "true", params["save"]
    # Only the merchant name and the marker reach MoneyWiz, not the bank's full text.
    assert_equal "Café & Co", params["description"]
    assert_equal "[bank1]", params["memo"]
    refute_includes url, "bread"
    refute params.key?("category")
    refute_includes url, "+"
  end

  def test_listed_merchants_get_a_payee_instead_of_a_description
    @config["payees"] = { "Bolt Taxi" => " Bolt Taxi " }
    entries = plan([bank(id: "b1", merchant: "BOLT TAXI, Tbilisi, 142 beliashvili str", payee: "BOLT TAXI"),
                    bank(id: "b2", merchant: "Nikora, Tbilisi", payee: "Nikora"),
                    bank(id: "b3", kind: "Outgoing Transfer", payee: "Outgoing Transfer", merchant: "bolt taxi, x")], [])
    assert_equal "Bolt Taxi", entries[0]["moneywiz_payee"]
    refute entries[1].key?("moneywiz_payee")
    refute entries[2].key?("moneywiz_payee"), "only purchases get payees"
    params = URI.decode_www_form(URI(M.url(entries[0].merge("status" => "new"))).query).to_h
    assert_equal "Bolt Taxi", params["payee"]
    refute params.key?("description")
    assert_equal "[b1]", params["memo"]
    plain = URI.decode_www_form(URI(M.url(entries[1].merge("status" => "new"))).query).to_h
    assert_equal "Nikora", plain["description"]
    refute plain.key?("payee")
    assert_raises(M::Error) { M.validate_payees("bolt taxi" => "") }
    assert_raises(M::Error) { M.validate_payees(["bolt taxi"]) }
  end

  def test_title_and_posting_date_can_differ
    result = plan([bank(posted: "2026-09-04")], [transaction(date: "2026-08-31", description: "Something else")])
    assert_equal "existing", result.first["status"]
  end

  def test_account_currency_and_sign_are_not_interchangeable
    [transaction(account: "Cash"), transaction(currency: "USD"), transaction(amount: 1000)].each do |t|
      assert_equal "new", plan([bank], [t]).first["status"]
    end
  end

  def test_nearest_repeated_amounts_match_one_to_one
    entries = plan([bank(id: "a", date: "2026-09-01"), bank(id: "b", date: "2026-09-03")], [transaction(id: "x", date: "2026-09-01"), transaction(id: "y", date: "2026-09-03")])
    assert_equal %w[x y], entries.map { |e| e["match_gid"] }
  end

  def test_tied_candidates_and_competing_rows_remain_review
    assert_equal "review", plan([bank], [transaction(id: "a"), transaction(id: "b")]).first["status"]
    entries = plan([bank(id: "a"), bank(id: "b")], [transaction])
    assert entries.all? { |e| e["status"] == "review" }
  end

  def test_near_amount_alone_is_new_but_a_matching_title_still_needs_review
    assert_equal "new", plan([bank(amount: -1560)], [transaction(amount: -1620, description: "Taxi")]).first["status"]
    assert_equal "review", plan([bank(amount: -1560)], [transaction(amount: -1620, description: "Shop lunch")]).first["status"]
    assert_equal "review", plan([bank(amount: -1560)], [transaction(amount: -1620, payee: "SHOP")]).first["status"]
  end

  def test_aggregated_bank_rows_are_not_new
    result = plan([bank(id: "base", amount: -1749), bank(id: "fee", amount: -26)], [transaction(amount: -1775)])
    assert result.all? { |e| e["status"] == "review" && e["reason"].include?("combined") }
  end

  def test_split_app_entries_are_not_new
    result = plan([bank(amount: -5000)], [transaction(id: "a", amount: -2000), transaction(id: "b", amount: -3000)])
    assert_equal "review", result.first["status"]
    assert_includes result.first["reason"], "split"
  end

  def test_non_purchases_are_created_uncategorized_and_titled_by_kind
    %w[FX Withdrawal Income].each do |kind|
      entry = plan([bank(kind: kind, payee: kind, merchant: "Shop, Tbilisi")], [], rules: { "shop" => { "category" => "Cafe", "always" => true } }).first
      assert_equal "new", entry["status"]
      assert_nil entry["category"], "no rule or learned category applies to #{kind}"
    end
    entry = plan([bank(kind: "Incoming Transfer", payee: "Incoming Transfer", merchant: nil, amount: 1000)], [], decisions: { "bank1" => { "action" => "new" } }).first
    url = M.url(entry)
    assert url.start_with?("moneywiz://income?")
    assert_includes url, "description=Incoming%20Transfer"
    refute_includes url, "category="
    chosen = plan([bank(kind: "FX")], [], decisions: { "bank1" => { "action" => "new" } }, categories: { "bank1" => "Cafe" }).first
    assert_equal "Cafe", chosen["category"], "an explicit per-row choice still applies"
    assert_raises(M::Error) { plan([bank(kind: "FX")], [], decisions: { "bank1" => { "action" => "new", "operation" => "income" } }) }
  end

  def test_transfers_are_created_without_a_memo_marker
    transfer = plan([bank(kind: "Outgoing Transfer", payee: "Outgoing Transfer", merchant: nil)], [], decisions: { "bank1" => { "action" => "new" } }).first
    refute_includes M.url(transfer), "memo=", "a title MoneyWiz shows as a transfer stays clean"
    assert_nil M.memo(transfer)
    %w[FX Income Withdrawal].each do |kind|
      other = plan([bank(kind: kind, payee: kind, merchant: nil)], [], decisions: { "bank1" => { "action" => "new" } }).first
      assert_includes M.url(other), "memo=%5Bbank1%5D", "#{kind} is not titled as a transfer and keeps its marker"
    end
    purchase = plan([bank], [], decisions: { "bank1" => { "action" => "new" } }).first
    assert_includes M.url(purchase), "memo=%5Bbank1%5D"
  end

  def test_applying_a_transfer_records_it_without_a_gid_and_never_repeats_it
    transfer = bank(kind: "Outgoing Transfer", payee: "Outgoing Transfer", merchant: nil)
    with_fake_application(banks: [transfer]) do |dir, plan, calls, snapshots, opener|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      plan = plan.merge("entries" => [transfer.merge("status" => "new")])
      capture_io { runner.apply(plan); runner.apply(plan) }
      assert_equal 1, calls.size, "the ledger alone keeps it from being sent twice"
      refute_includes calls.first, "memo="
      assert_equal({ "status" => "imported" }, runner.ledger["bank1"])
      # A later import sees no marker and no GID, and still keeps the row off New.
      entry = plan([transfer], [], ledger: runner.ledger).first
      assert_equal "existing", entry["status"]
    end
  end

  def test_interrupted_dispatch_never_retries_even_with_old_new_decision
    entry = plan([bank], [], ledger: { "bank1" => { "status" => "dispatching" } }, decisions: { "bank1" => { "action" => "new" } }).first
    assert_equal "review", entry["status"]
    assert_includes entry["reason"], "never automatically retry"
  end

  def test_marker_recovers_after_lost_ledger_and_survives_edits_and_copies
    assert_equal "existing", plan([bank], [transaction(memo: "[bank1]")]).first["status"]
    # Dates get corrected in MoneyWiz; account and amount still identify the record.
    assert_equal "existing", plan([bank], [transaction(memo: "[bank1]", date: "2026-08-20")]).first["status"]
    # Converting a record into a transfer leaves the memo on both legs; only one is this row.
    legs = [transaction(id: "out", amount: -1000, memo: "[bank1]"), transaction(id: "in", amount: 2600, memo: "[bank1]")]
    assert_equal ["existing", "out"], plan([bank], legs).first.values_at("status", "match_gid")
    # Nothing tells two equally plausible copies apart.
    assert_equal "review", plan([bank], [transaction(id: "a", memo: "[bank1]"), transaction(id: "b", memo: "[bank1]")]).first["status"]
    conflicting = plan([bank], [transaction(memo: "[bank1]", amount: -4200)]).first
    assert_equal "review", conflicting["status"]
    assert_includes conflicting["reason"], "marker conflicts"
  end

  def test_imported_row_stays_existing_after_its_record_is_edited_or_removed
    ledger = { "bank1" => { "status" => "imported", "gid" => "gone" } }
    entry = plan([bank], [], ledger: ledger).first
    assert_equal "existing", entry["status"], "never propose a row this importer already created"
    assert_includes entry["reason"], "edited or removed"
    assert_nil entry["match_gid"]
    edited = plan([bank], [transaction(id: "gone", amount: -2400)], ledger: ledger).first
    assert_equal "existing", edited["status"]
    # A row still awaiting confirmation is a different matter and stays on review.
    dispatching = plan([bank], [], ledger: { "bank1" => { "status" => "dispatching" } }).first
    assert_equal "review", dispatching["status"]
    matched_gone = plan([bank], [], ledger: { "bank1" => { "status" => "matched", "gid" => "gone" } }).first
    assert_equal "review", matched_gone["status"]
  end

  def test_entry_carrying_a_copied_marker_still_matches_its_own_bank_row
    first, second = MARKED_IDS
    # The user duplicated an imported record, so an entry of another amount inherited its memo.
    copy = transaction(id: "copy", amount: -2500, memo: "[#{first}]")
    entries = plan([bank(id: first), bank(id: second, amount: -2500)], [transaction(memo: "[#{first}]"), copy])
    assert_equal %w[existing existing], entries.map { |e| e["status"] }
    assert_equal %w[app1 copy], entries.map { |e| e["match_gid"] }
    # A marker whose row is absent from this statement still shields its record.
    foreign = plan([bank(id: second, amount: -2500)], [transaction(id: "copy", amount: -2500, memo: "[#{first}]")]).first
    assert_equal "new", foreign["status"]
  end

  def test_identical_rows_never_silently_collapse
    result = plan([bank(indistinguishable_count: 2)], [])
    assert_equal "review", result.first["status"]
    assert_raises(M::Error) { plan([bank(indistinguishable_count: 2)], [], decisions: { "bank1" => { "action" => "new" } }) }
  end

  def test_deferring_new_record_excludes_it_from_apply_and_retains_base_status
    entry = plan([bank], [], decisions: { "bank1" => { "action" => "defer" } }).first
    assert_equal "new", entry["base_status"]
    assert_equal "review", entry["status"]
    refute entry["decision_locked"]
    assert_raises(M::Error) { M.url(entry) }
  end

  def test_conflicting_manual_mappings_are_rejected
    result = plan([bank(id: "a"), bank(id: "b")], [transaction], decisions: { "a" => { "action" => "match", "gid" => "app1" }, "b" => { "action" => "match", "gid" => "app1" } })
    assert result.all? { |e| e["status"] == "review" }
  end

  def test_transactions_claimed_by_other_rows_are_never_candidates
    # Same merchant, same day, same amount: t1 was created for bank1 moments ago.
    marker_id = "bog-v1-#{'a' * 64}-1"
    created = transaction(id: "t1", description: "Shop", memo: "[#{marker_id}]")
    entries = plan([bank(id: marker_id), bank(id: "bank2")], [created])
    assert_equal %w[existing new], entries.map { |e| e["status"] }
    assert_equal "import marker", entries.first["reason"]
    # Same through the ledger without a marker (older manual match).
    entries = plan([bank(id: "bank2")], [transaction(id: "t1")], ledger: { "other" => { "status" => "matched", "gid" => "t1" } })
    assert_equal "new", entries.first["status"]
    assert_empty entries.first["candidates"]
    # Near amount and merchant title of a claimed row do not trigger review either.
    entries = plan([bank(id: "bank2", amount: -1050, merchant: "Shop, Tbilisi")], [transaction(id: "t1", description: "Shop")], ledger: { "other" => { "status" => "imported", "gid" => "t1" } })
    assert_equal "new", entries.first["status"]
    # An unclaimed transaction titled with the merchant still flags a possible duplicate.
    assert_equal "review", plan([bank(id: "bank2", amount: -1050)], [transaction(id: "t1", description: "Shop")]).first["status"]
    # A transaction exact-matched to another bank row in this same run is spoken for
    # too, even though the ledger learns about it only after apply.
    entries = plan([bank(id: "bank1"), bank(id: "bank2", amount: -1050)], [transaction(id: "t1", description: "Shop")])
    assert_equal %w[existing new], entries.map { |e| e["status"] }
    assert_empty entries.last["candidates"]
  end

  def test_category_learning_requires_repeated_consistent_examples
    banks = (1..4).map { |i| bank(id: "b#{i}", amount: -1000 * i) }
    transactions = (1..3).map { |i| transaction(id: "t#{i}", amount: -1000 * i) }
    assert_equal "Groceries", plan(banks, transactions).last["category"]
    transactions.last["category"] = "Cafe"
    assert_nil plan(banks, transactions).last["category"]
  end

  def test_snapshot_includes_wal_and_leaves_source_unchanged
    Dir.mktmpdir do |dir|
      path = File.join(dir, "live.sqlite")
      db = SQLite3::Database.new(path)
      db.execute("PRAGMA journal_mode=WAL")
      db.execute("CREATE TABLE entries (name TEXT)")
      db.execute("INSERT INTO entries VALUES ('committed in WAL')")
      before = [path, "#{path}-wal"].map { |p| Digest::SHA256.file(p).hexdigest }
      copy = M::Snapshot.take(path, directory: File.join(dir, "backups"))
      reader = SQLite3::Database.new(copy, readonly: true)
      assert_equal "committed in WAL", reader.get_first_value("SELECT name FROM entries")
      assert_equal before, [path, "#{path}-wal"].map { |p| Digest::SHA256.file(p).hexdigest }
      reader.close
      db.close
      # Read-only opens of the copy leave no -wal/-shm files behind.
      assert_equal [File.basename(copy)], Dir.children(File.join(dir, "backups"))
    end
  end

  def test_prune_keeps_newest_backups_and_removes_orphaned_journals
    Dir.mktmpdir do |dir|
      names = %w[20260901T000000-aaaaaaaaaa 20260902T000000-bbbbbbbbbb 20260903T000000-cccccccccc]
      names.each { |n| File.write(File.join(dir, "#{n}.sqlite"), "") }
      File.write(File.join(dir, "20260801T000000-dddddddddd.sqlite-wal"), "")
      File.write(File.join(dir, "20260801T000000-dddddddddd.sqlite-shm"), "")
      File.write(File.join(dir, "notes.txt"), "unrelated")
      M::Snapshot.prune(dir, keep: 2)
      assert_equal %w[20260902T000000-bbbbbbbbbb.sqlite 20260903T000000-cccccccccc.sqlite notes.txt], Dir.children(dir).sort
      M::Snapshot.prune(dir, keep: 5)
      assert_equal 3, Dir.children(dir).size
      assert_raises(M::Error) { M::Snapshot.prune(dir, keep: 0) }
    end
  end

  def test_locate_decisions_prefers_run_folder_then_adopts_a_matching_stray
    Dir.mktmpdir do |dir|
      run, docs = File.join(dir, "run"), File.join(dir, "Documents")
      FileUtils.mkdir_p(run)
      FileUtils.mkdir_p(docs)
      plan = { "id" => "abc" }
      assert_nil M::CLI.locate_decisions(plan, run, search: [docs])
      File.write(File.join(docs, "decisions.json"), JSON.generate("type" => "moneywiz-decisions", "plan_id" => "abc", "decisions" => {}))
      File.write(File.join(docs, "other.json"), JSON.generate("plan_id" => "zzz"))
      File.write(File.join(docs, "broken.json"), "{")
      found = capture_io { @found = M::CLI.locate_decisions(plan, run, search: [docs]) }
      assert_equal File.join(run, "decisions.json"), @found
      assert_includes found.last, "Adopting"
      refute File.exist?(File.join(docs, "decisions.json")), "the stray file is moved, not copied"
      assert_equal File.join(run, "decisions.json"), M::CLI.locate_decisions(plan, run, search: [docs])
      # A newer export beside an adopted copy is the reviewer's latest word and replaces it.
      later = File.join(docs, "again.json")
      File.write(later, JSON.generate("plan_id" => "abc", "decisions" => { "b1" => { "action" => "skip" } }))
      File.utime(Time.now + 60, Time.now + 60, later)
      assert_equal later, M::CLI.find_decisions(plan, run, search: [docs])
      assert_equal later, M::CLI.find_decisions(plan, run, search: [docs], beside: false), "beside: false still sees the stray"
      found = capture_io { @found = M::CLI.locate_decisions(plan, run, search: [docs]) }
      assert_includes found.last, "replacing"
      assert_equal File.join(run, "decisions.json"), @found
      assert_includes File.read(@found), "skip"
      assert_nil M::CLI.find_decisions(plan, run, search: [docs], beside: false), "an adopted copy is not a Documents file"
      File.write(File.join(docs, "a.json"), JSON.generate("plan_id" => "abc"))
      File.write(File.join(docs, "b.json"), JSON.generate("plan_id" => "abc"))
      FileUtils.rm(File.join(run, "decisions.json"))
      assert_raises(M::Error) { M::CLI.locate_decisions(plan, run, search: [docs]) }
    end
  end

  def test_latest_report_prefers_newest_statement_date_then_newest_file
    Dir.mktmpdir do |dir|
      assert_nil M::CLI.latest_report(dir)
      assert_nil M::CLI.latest_report(File.join(dir, "missing"))
      %w[Report-2026-09-06.xlsx other.xlsx Report-2026-09-26.xlsx notes.txt].each { |name| File.write(File.join(dir, name), name) }
      assert_equal File.join(dir, "Report-2026-09-26.xlsx"), M::CLI.latest_report(dir)
      repeat = File.join(dir, "Report-2026-09-26 (1).xlsx")
      File.write(repeat, "again")
      File.utime(Time.now + 60, Time.now + 60, repeat)
      assert_equal repeat, M::CLI.latest_report(dir), "a repeated download of the same day is newer"
    end
  end

  def test_auto_offers_import_then_apply_once_a_decisions_file_exists
    Dir.mktmpdir do |dir|
      downloads, docs, imports = File.join(dir, "Downloads"), File.join(dir, "Documents"), File.join(dir, "imports")
      [downloads, docs, imports].each { |d| FileUtils.mkdir_p(d) }
      auto = ->(answers) { $stdin = StringIO.new(answers); capture_io { @result = M::CLI.auto(downloads: downloads, imports: imports, search: [docs]) }.first }
      assert_raises(M::Error) { auto.call("y\n") }
      report = File.join(downloads, "Report-2026-09-26.xlsx")
      File.write(report, "statement")
      out = auto.call("n\n")
      assert_nil @result
      assert_includes out, "No plan exists"
      auto.call("yes\n")
      assert_equal ["import", [report]], @result
      auto.call("")
      assert_nil @result, "EOF counts as no"

      sha = Digest::SHA256.file(report).hexdigest
      run = File.join(imports, "20260926T100000-abc123")
      FileUtils.mkdir_p(run)
      plan = { "id" => "abc123", "created_at" => "2026-09-26T10:00:00Z", "sources" => [{ "path" => report, "sha256" => sha }], "summary" => { "new" => 2, "review" => 3 } }
      File.write(File.join(run, "plan.json"), JSON.generate(plan))
      other = File.join(imports, "20260901T000000-000000")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, "plan.json"), JSON.generate(plan.merge("id" => "old", "sources" => [{ "path" => "x", "sha256" => "0" * 64 }])))
      out = auto.call("y\n")
      assert_equal ["review", [File.join(run, "plan.json")]], @result
      assert_includes out, "No decisions file"
      auto.call("n\ny\n")
      assert_equal ["import", [report]], @result
      auto.call("n\nn\n")
      assert_nil @result

      File.write(File.join(docs, "moneywiz-decisions-abc123.json"), JSON.generate("type" => "moneywiz-decisions", "version" => 1, "plan_id" => "abc123", "source_hashes" => [sha], "decisions" => { "b1" => { "action" => "skip" } }))
      out = auto.call("y\n")
      assert_equal ["apply", [File.join(run, "plan.json")]], @result
      assert_includes out, "1 decisions"
      assert_includes out, "2 new, 3 need review"
      assert File.exist?(File.join(docs, "moneywiz-decisions-abc123.json")), "asking does not move the export"
      auto.call("n\n")
      assert_nil @result

      # Apply adopts the export beside the plan; that copy means "done", not "apply again".
      FileUtils.mv(File.join(docs, "moneywiz-decisions-abc123.json"), File.join(run, "decisions.json"))
      out = auto.call("y\n")
      assert_equal ["import", [report]], @result
      assert_includes out, "were applied on"
      refute_includes out, "Reopen"
      auto.call("n\n")
      assert_nil @result
      # A fresh export after that offers apply again.
      File.write(File.join(docs, "moneywiz-decisions-abc123.json"), JSON.generate("type" => "moneywiz-decisions", "version" => 1, "plan_id" => "abc123", "source_hashes" => [sha], "decisions" => {}))
      auto.call("y\n")
      assert_equal ["apply", [File.join(run, "plan.json")]], @result
    ensure
      $stdin = STDIN
    end
  end

  def test_lock_prevents_concurrent_importers_and_ledger_is_durable
    Dir.mktmpdir do |dir|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"))
      runner.with_lock do
        runner.save("bank1" => { "status" => "dispatching" })
        assert_equal "dispatching", runner.ledger.dig("bank1", "status")
        assert_raises(M::Error) { runner.with_lock {} }
      end
    end
  end

  def test_real_overlapping_exports_and_fx_detection
    files = ["Report-2026-09-06.xlsx", "Report-2026-09-06 (wider).xlsx"].map { |p| File.join(__dir__, p) }
    skip "Private sample exports not present" unless files.all? { |p| File.exist?(p) }
    first = M::CLI.load_bank(files.first(1))
    both = M::CLI.load_bank(files)
    assert_equal first.map { |e| e["id"] }, both.map { |e| e["id"] }
    assert_equal 488, both.size
    assert both.any? { |e| e["kind"] == "FX" && e["description"].start_with?("Payment") }
    transfers = both.reject { |e| e["kind"] == "Payment" }
    refute_empty transfers
    assert transfers.all? { |e| e["payee"] == e["kind"] }, "non-purchases are titled by their bank row type"
    assert transfers.any? { |e| e["kind"].end_with?("Transfer") && e["counterparty"] }
    assert both.any? { |e| e["bank_payment_code"] }
  end

  def with_fake_application(banks: [bank])
    Dir.mktmpdir do |dir|
      source = File.join(dir, "fake-app.sqlite")
      db = SQLite3::Database.new(source)
      db.execute("CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT)")
      db.execute("INSERT INTO Z_PRIMARYKEY VALUES (11, 'BankChequeAccount'), (48, 'WithdrawTransaction')")
      db.execute("CREATE TABLE ZSYNCOBJECT (Z_PK INTEGER, Z_ENT INTEGER, ZGID TEXT, ZNAME TEXT, ZCURRENCYNAME TEXT, ZARCHIVED INTEGER, ZACCOUNT2 INTEGER, ZDATE1 REAL, ZAMOUNT1 REAL, ZDESC2 TEXT, ZNOTES1 TEXT)")
      db.execute("INSERT INTO ZSYNCOBJECT (Z_PK,Z_ENT,ZGID,ZNAME,ZCURRENCYNAME,ZARCHIVED) VALUES (1,11,'account-1','Solo ლ','GEL',0)")
      db.execute("CREATE TABLE ZCATEGORYASSIGMENT (ZTRANSACTION INTEGER,ZCATEGORY INTEGER)")
      fake_statement = File.join(dir, "input.xlsx")
      File.write(fake_statement, "test input")
      plan = { "config" => @config, "sources" => [{ "path" => fake_statement, "sha256" => Digest::SHA256.file(fake_statement).hexdigest }],
               "entries" => [bank(status: "new")], "decisions" => {} }
      calls = []
      snapshots = -> { M::Snapshot.take(source, directory: File.join(dir, "backups")) }
      save_in_fake_app = lambda do |url|
        calls << url
        params = URI.decode_www_form(URI(url).query).to_h
        db.execute("INSERT INTO ZSYNCOBJECT (Z_PK,Z_ENT,ZGID,ZACCOUNT2,ZDATE1,ZAMOUNT1,ZDESC2,ZNOTES1) VALUES (?,48,?,1,?,?,?,?)",
                   [calls.size + 1, "created-#{calls.size}", Time.local(2026, 9, 1, 12).to_i - 978_307_200, params.fetch("amount").to_f * -1, params.fetch("description"), params["memo"].to_s])
      end
      M::CLI.stub(:load_bank, banks) do
        yield dir, plan, calls, snapshots, save_in_fake_app
      end
    ensure
      db&.close
    end
  end

  def test_apply_twice_creates_once_and_verifies_app_record
    with_fake_application do |dir, plan, calls, snapshots, opener|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      capture_io { runner.apply(plan); runner.apply(plan) }
      assert_equal 1, calls.size
      assert_equal "created-1", runner.ledger.dig("bank1", "gid")
    end
  end

  def test_apply_reuses_verification_snapshots_and_keeps_only_one_backup
    second = bank(id: "bank2", amount: -2000)
    with_fake_application(banks: [bank, second]) do |dir, plan, calls, snapshots, opener|
      taken = []
      counting = -> { snapshots.call.tap { |path| taken << path } }
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: counting, opener: opener)
      plan = plan.merge("entries" => [bank(status: "new"), second.merge("status" => "new")])
      capture_io { runner.apply(plan) }
      assert_equal 2, calls.size
      assert_equal %w[created-1 created-2], %w[bank1 bank2].map { |id| runner.ledger.dig(id, "gid") }
      # One retained backup plus one verification copy per entry; nothing copied twice.
      assert_equal 3, taken.size
      assert_equal [File.basename(taken.first)], Dir.children(File.join(dir, "backups"))
    end
  end

  def test_apply_with_decisions_file_creates_decided_new_rows_and_honors_defer
    second = bank(id: "bank2", amount: -2000)
    with_fake_application(banks: [bank, second]) do |dir, plan, calls, snapshots, opener|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      # The page showed bank1 on review and bank2 as New; the reviewer marked bank1 new and deferred bank2.
      plan = plan.merge("entries" => [bank(status: "review", reason: "ambiguous"), second.merge("status" => "new")])
      decisions = { "decisions" => { "bank1" => { "action" => "new" }, "bank2" => { "action" => "defer" } },
                    "category_overrides" => {}, "merchant_rules" => { "shop" => { "category" => "Groceries", "always" => false } } }
      capture_io { runner.apply(plan, decisions) }
      assert_equal 1, calls.size
      assert_includes calls.first, "memo=%5Bbank1%5D"
      assert_equal "created-1", runner.ledger.dig("bank1", "gid")
      assert_nil runner.ledger["bank2"], "deferred rows are neither created nor remembered"
      assert_equal false, runner.merchant_rules.dig("shop", "always")
    end
  end

  def test_apply_with_decisions_file_rejects_unknown_ids_and_skips_decided_rows
    with_fake_application do |dir, plan, calls, snapshots, opener|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      stray = { "decisions" => { "other" => { "action" => "skip" } }, "category_overrides" => {}, "merchant_rules" => {} }
      assert_raises(M::Error) { runner.apply(plan, stray) }
      skip = { "decisions" => { "bank1" => { "action" => "skip" } }, "category_overrides" => {}, "merchant_rules" => {} }
      capture_io { runner.apply(plan, skip) }
      assert_empty calls
      assert_equal "skipped", runner.ledger.dig("bank1", "status")
    end
  end

  def test_apply_persists_merchant_rules_including_declined_answers
    with_fake_application do |dir, plan, calls, snapshots, opener|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      runner.save({}, { "old" => { "category" => "Cafe", "always" => true }, "wolt" => { "category" => "Cafe", "always" => true } })
      plan = plan.merge("merchant_rules" => { "wolt" => { "category" => "Cafe", "always" => false }, "nikora" => { "category" => "Groceries", "always" => true } })
      capture_io { runner.apply(plan) }
      assert_equal 1, calls.size
      rules = runner.merchant_rules
      assert_equal true, rules.dig("old", "always"), "existing rules survive"
      assert_equal false, rules.dig("wolt", "always"), "plan answers replace older ones"
      assert_equal "Groceries", rules.dig("nikora", "category")
      assert_equal "created-1", runner.ledger.dig("bank1", "gid")
    end
  end

  def test_apply_refuses_when_the_app_is_not_running_and_release_clears_a_dead_reservation
    with_fake_application do |dir, plan, calls, snapshots, opener|
      config = @config.merge("app_process" => "NoSuchProcess#{Process.pid}", "verification_seconds" => 5)
      runner = M::Runner.new(config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      error = assert_raises(M::Error) { runner.apply(plan) }
      assert_includes error.message, "not running", "operational config keys do not invalidate the plan"
      assert_empty calls
      other = M::Runner.new(@config.merge("match_days" => 9), state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      assert_includes assert_raises(M::Error) { other.apply(plan) }.message, "match_days"
      # A reservation left by a lost URL is released only when the app is up and holds no marked record.
      runner.save({ "bank1" => { "status" => "dispatching", "at" => "2026-09-11T23:08:40Z" } }, {})
      assert_raises(M::Error) { runner.release("bank1") }
      running = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: opener)
      capture_io { running.release("bank1") }
      assert_nil running.ledger["bank1"]
      assert_raises(M::Error) { running.release("bank1") }
      capture_io { running.apply(plan) }
      assert_equal 1, calls.size
      assert_raises(M::Error, "imported rows are never released") { running.release("bank1") }
    end
  end

  def test_crash_after_app_save_is_reconciled_without_second_dispatch
    with_fake_application do |dir, plan, calls, snapshots, save_app|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: ->(url) { save_app.call(url); raise M::Error, "simulated process failure" })
      assert_raises(M::Error) { runner.apply(plan) }
      assert_equal "dispatching", runner.ledger.dig("bank1", "status")
      capture_io { runner.apply(plan) }
      assert_equal 1, calls.size
      assert_equal "created-1", runner.ledger.dig("bank1", "gid")
    end
  end

  def test_timeout_without_save_retains_reservation_and_stops_retries
    with_fake_application do |dir, plan, calls, snapshots, _|
      runner = M::Runner.new(@config, state_path: File.join(dir, "ledger.json"), snapshotter: snapshots, opener: ->(url) { calls << url })
      error = assert_raises(M::Error) { runner.apply(plan) }
      assert_includes error.message, "Save unconfirmed"
      assert_equal "dispatching", runner.ledger.dig("bank1", "status")
      assert_raises(M::Error) { runner.apply(plan) }
      assert_equal 1, calls.size
    end
  end
end
