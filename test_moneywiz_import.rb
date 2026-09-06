#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "moneywiz_import"
require "minitest/autorun"
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
    entry = bank(description: "Café + bread & 50% [x]", status: "new")
    url = M.url(entry)
    params = URI.decode_www_form(URI(url).query).to_h
    assert_equal "Soloლ", params["account"]
    assert_equal "10.00", params["amount"]
    assert_equal "true", params["save"]
    assert_equal "Café + bread & 50% [x] [bank1]", params["description"]
    refute params.key?("category")
    refute_includes url, "+"
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

  def test_small_amount_change_is_not_imported
    assert_equal "review", plan([bank(amount: -1749)], [transaction(amount: -1775)]).first["status"]
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

  def test_non_purchases_need_explicit_classification
    %w[FX Withdrawal Income].each { |kind| assert_equal "review", plan([bank(kind: kind)], []).first["status"] }
    assert_raises(M::Error) { plan([bank(kind: "Incoming Transfer", amount: 1000)], [], decisions: { "bank1" => { "action" => "new" } }) }
    entry = plan([bank(kind: "Incoming Transfer", amount: 1000)], [], decisions: { "bank1" => { "action" => "new", "operation" => "income" } }).first
    assert M.url(entry).start_with?("moneywiz://income?")
  end

  def test_interrupted_dispatch_never_retries_even_with_old_new_decision
    entry = plan([bank], [], ledger: { "bank1" => { "status" => "dispatching" } }, decisions: { "bank1" => { "action" => "new" } }).first
    assert_equal "review", entry["status"]
    assert_includes entry["reason"], "never automatically retry"
  end

  def test_marker_recovers_after_lost_ledger_but_wrong_date_does_not
    assert_equal "existing", plan([bank], [transaction(memo: "[bank1]")]).first["status"]
    assert_equal "review", plan([bank], [transaction(memo: "[bank1]", date: "2026-08-20")]).first["status"]
    assert_equal "review", plan([bank], [transaction(id: "a", memo: "[bank1]"), transaction(id: "b", memo: "[bank1]")]).first["status"]
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
    created = transaction(id: "t1", description: "Bank description & details [#{marker_id}]", memo: "Bank of Georgia; posted 2026-09-01; [#{marker_id}]")
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
    # An unclaimed transaction still flags a possible duplicate.
    assert_equal "review", plan([bank(id: "bank2", amount: -1050)], [transaction(id: "t1")]).first["status"]
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
    assert both.any? { |e| e["bank_payment_code"] }
  end

  def with_fake_application
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
        db.execute("INSERT INTO ZSYNCOBJECT (Z_PK,Z_ENT,ZGID,ZACCOUNT2,ZDATE1,ZAMOUNT1,ZDESC2,ZNOTES1) VALUES (2,48,'created-1',1,?,-10,?,?)",
                   [Time.local(2026, 9, 1, 12).to_i - 978_307_200, params.fetch("description"), params.fetch("memo")])
      end
      M::CLI.stub(:load_bank, [bank]) do
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
